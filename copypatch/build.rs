//! Turns `csrc/stencils.c` into Rust source containing machine code.
//!
//! 1. clang compiles the stencil file to a relocatable object.
//! 2. We slice each `st_*` function's bytes out of its own `.text.st_*`
//!    section and write them into `stencils.rs` as byte literals -- so the
//!    x86-64 the JIT copies is in the source, readable next to the
//!    relocations that describe it, rather than in a side file.
//! 3. Each relocation against one of the `HOLE_*` symbols becomes a `Hole`
//!    entry beside its stencil: an offset into that stencil's bytes plus
//!    what the JIT has to write there.
//! 4. The object is disassembled again and the listing becomes comments, one
//!    instruction per line, so the generated table can be read as assembly
//!    instead of as an opaque wall of hex.
//!
//! The Rust crate therefore ships real x86-64 code without ever containing an
//! assembler -- at run time it only copies bytes and rewrites jump
//! displacements and 32-bit immediates.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use object::elf;
use object::read::{Object, ObjectSection, ObjectSymbol};
use object::{RelocationFlags, RelocationTarget, SymbolKind};

/// Kinds of hole, in the order the generated Rust enum declares them.
const HOLE_SYMBOLS: &[(&str, &str)] = &[
    ("HOLE_NEXT", "Next"),
    ("HOLE_TARGET", "Target"),
    ("HOLE_A", "ImmA"),
    ("HOLE_B", "ImmB"),
    ("HOLE_PC", "ImmPc"),
];

struct Hole {
    kind: &'static str,
    offset: u64,
    addend: i64,
    pcrel: bool,
}

struct Stencil {
    name: String,
    /// The machine code clang emitted for this op, verbatim.
    code: Vec<u8>,
    /// `(offset, mnemonic)` per instruction, for the comments in the
    /// generated source. Empty if no disassembler was available.
    asm: Vec<(usize, String)>,
    /// The stencil's last instruction is `jmp HOLE_NEXT`.
    tail_jump: bool,
    holes: Vec<Hole>,
}

/// Instruction listings keyed by section name.
type Disassembly = BTreeMap<String, Vec<(usize, String)>>;

fn main() {
    println!("cargo:rerun-if-changed=csrc/stencils.c");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=CLANG");

    let target = std::env::var("TARGET").unwrap();
    if !target.starts_with("x86_64") || !target.contains("linux") {
        panic!(
            "copypatch's JIT is x86-64 Linux only (target is `{target}`); \
             the interpreter would still work but the stencil pipeline does not"
        );
    }

    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let obj_path = out_dir.join("stencils.o");
    compile_stencils(&obj_path);

    let data = std::fs::read(&obj_path).expect("failed to read stencils.o");
    let disasm = disassemble(&obj_path);
    if disasm.is_empty() {
        println!(
            "cargo:warning=no disassembler found ({}); \
             the generated stencil table will have byte offsets but no assembly comments",
            OBJDUMPS.join(" / ")
        );
    }
    let stencils = extract(&data, &disasm);

    std::fs::write(out_dir.join("stencils.rs"), render(&stencils)).unwrap();
}

/// Disassemblers to try, in order. `llvm-objdump` ships with clang, which is
/// already a hard requirement, and GNU `objdump` is the usual fallback.
const OBJDUMPS: &[&str] = &["llvm-objdump", "objdump"];

/// Reads back the object file as assembly, so the generated source can say
/// what each run of bytes actually is.
///
/// Purely cosmetic: if nothing here works the build carries on without the
/// comments.
fn disassemble(obj_path: &Path) -> Disassembly {
    for tool in OBJDUMPS {
        let out = Command::new(tool)
            .args(["-d", "--no-show-raw-insn"])
            .arg(obj_path)
            .output();
        let Ok(out) = out else { continue };
        if !out.status.success() {
            continue;
        }
        let text = String::from_utf8_lossy(&out.stdout);
        let parsed = parse_disassembly(&text);
        if !parsed.is_empty() {
            return parsed;
        }
    }
    Disassembly::new()
}

/// Pulls `section -> [(offset, instruction)]` out of objdump's listing.
///
/// Written against the common shape of GNU objdump and llvm-objdump output:
/// a `Disassembly of section NAME:` header, then lines whose first field is a
/// hex offset followed by a colon. Anything else -- banners, symbol lines,
/// blank lines -- fails the offset parse and is skipped.
fn parse_disassembly(text: &str) -> Disassembly {
    let mut out = Disassembly::new();
    let mut section: Option<String> = None;

    for line in text.lines() {
        if let Some(name) = line.strip_prefix("Disassembly of section ") {
            section = Some(name.trim_end_matches(':').trim().to_string());
            continue;
        }
        let Some(sec) = section.as_ref() else {
            continue;
        };
        let Some((head, rest)) = line.split_once(':') else {
            continue;
        };
        let Ok(offset) = usize::from_str_radix(head.trim(), 16) else {
            continue;
        };
        let insn = rest.split_whitespace().collect::<Vec<_>>().join(" ");
        if insn.is_empty() {
            continue;
        }
        out.entry(sec.clone()).or_default().push((offset, insn));
    }

    for insns in out.values_mut() {
        insns.sort_by_key(|(off, _)| *off);
    }
    out
}

fn compile_stencils(obj_path: &Path) {
    let clang = std::env::var("CLANG").unwrap_or_else(|_| "clang".to_string());
    let src = Path::new("csrc/stencils.c");

    let status = Command::new(&clang)
        .args([
            "-std=c11",
            "-O2",
            "-c",
            // No PIC and the small code model, so a `&HOLE_X` turns into a
            // plain 32-bit absolute immediate we can overwrite.
            "-fno-pic",
            "-mcmodel=small",
            // Keep the emitted code minimal and self-contained.
            "-fomit-frame-pointer",
            "-fno-stack-protector",
            "-fno-asynchronous-unwind-tables",
            "-fno-unwind-tables",
            "-fcf-protection=none",
            // A jump table would live in .rodata and need a second relocated
            // section; keep every branch inside the stencil.
            "-fno-jump-tables",
            // One section per stencil, so slicing is unambiguous.
            "-ffunction-sections",
            "-Wall",
            "-Wextra",
            "-Werror",
        ])
        .arg(src)
        .arg("-o")
        .arg(obj_path)
        .status()
        .unwrap_or_else(|e| panic!("failed to run `{clang}`: {e}"));

    assert!(
        status.success(),
        "`{clang}` failed to compile {}",
        src.display()
    );
}

fn extract(data: &[u8], disasm: &Disassembly) -> Vec<Stencil> {
    let file = object::File::parse(data).expect("stencils.o is not a valid object file");

    let hole_names: BTreeMap<&str, &str> = HOLE_SYMBOLS.iter().copied().collect();

    // Map each text section to the single `st_*` symbol it defines.
    let mut by_section: BTreeMap<usize, (String, u64)> = BTreeMap::new();
    for sym in file.symbols() {
        if sym.kind() != SymbolKind::Text {
            continue;
        }
        let Ok(name) = sym.name() else { continue };
        let Some(name) = name.strip_prefix("st_") else {
            continue;
        };
        let Some(idx) = sym.section_index() else {
            continue;
        };
        assert_eq!(
            sym.address(),
            0,
            "stencil st_{name} is not at the start of its section"
        );
        let prev = by_section.insert(idx.0, (name.to_string(), sym.size()));
        assert!(prev.is_none(), "two stencils share one section: {name}");
    }
    assert!(
        !by_section.is_empty(),
        "no st_* symbols found in stencils.o"
    );

    let mut stencils: Vec<Stencil> = Vec::new();

    for section in file.sections() {
        let Some((name, size)) = by_section.get(&section.index().0) else {
            continue;
        };
        let bytes = section.data().expect("stencil section has no data");
        let size = *size as usize;
        assert!(
            size <= bytes.len(),
            "stencil st_{name}: symbol size {size} exceeds section size {}",
            bytes.len()
        );

        let code = bytes[..size].to_vec();

        // Instructions inside the function proper; any alignment padding the
        // section carries past `size` is not part of the stencil.
        let asm = section
            .name()
            .ok()
            .and_then(|sec| disasm.get(sec))
            .map(|insns| {
                insns
                    .iter()
                    .filter(|(off, _)| *off < size)
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();

        let mut holes = Vec::new();
        for (offset, reloc) in section.relocations() {
            let RelocationTarget::Symbol(sym_idx) = reloc.target() else {
                panic!("stencil st_{name}: relocation against a non-symbol target");
            };
            let sym = file.symbol_by_index(sym_idx).unwrap();
            let sym_name = sym.name().unwrap_or("<unnamed>");
            let Some(kind) = hole_names.get(sym_name) else {
                panic!(
                    "stencil st_{name}: unexpected relocation against `{sym_name}`. \
                     Stencils may only reference HOLE_* symbols -- reaching a real \
                     symbol (a libc call, a constant pool entry, ...) would need a \
                     relocation the runtime patcher cannot resolve."
                );
            };

            let RelocationFlags::Elf { r_type } = reloc.flags() else {
                panic!("stencil st_{name}: non-ELF relocation flags");
            };
            let pcrel = match r_type {
                elf::R_X86_64_PLT32 | elf::R_X86_64_PC32 => true,
                elf::R_X86_64_32 => false,
                other => panic!(
                    "stencil st_{name}: unsupported relocation type {other} against \
                     `{sym_name}`; only PLT32/PC32/32 are patchable"
                ),
            };
            assert!(
                offset as usize + 4 <= size,
                "stencil st_{name}: relocation at {offset:#x} falls outside the function"
            );

            holes.push(Hole {
                kind,
                offset,
                addend: reloc.addend(),
                pcrel,
            });
        }
        holes.sort_by_key(|h| h.offset);

        // `E9 rel32` as the final instruction, with the displacement pointing
        // at the next op. Since the next op's code is laid down immediately
        // after this stencil, the jump is always a no-op and the JIT can drop
        // it. `0xE9` at len-5 identifies a near `jmp` unambiguously: a
        // `jcc rel32` would have `0x0F 0x8x` there instead.
        let tail_jump = size >= 5
            && code[size - 5] == 0xE9
            && holes
                .last()
                .is_some_and(|h| h.kind == "Next" && h.offset as usize == size - 4);

        stencils.push(Stencil {
            name: name.clone(),
            code,
            asm,
            tail_jump,
            holes,
        });
    }

    stencils.sort_by(|a, b| a.name.cmp(&b.name));
    stencils
}

/// Lays a stencil's bytes out one instruction per line, commented with the
/// assembly clang produced and with any hole that lands in that instruction.
///
/// Without a disassembler this degrades to fixed-width rows carrying only the
/// byte offset.
fn render_code(st: &Stencil) -> String {
    let mut s = String::new();

    // Instruction boundaries: each listed offset runs to the next one.
    let mut spans: Vec<(usize, usize, Option<&str>)> = Vec::new();
    if st.asm.is_empty() {
        for start in (0..st.code.len()).step_by(12) {
            spans.push((start, (start + 12).min(st.code.len()), None));
        }
    } else {
        for (i, (offset, insn)) in st.asm.iter().enumerate() {
            let end = st.asm.get(i + 1).map_or(st.code.len(), |(next, _)| *next);
            spans.push((*offset, end, Some(insn.as_str())));
        }
    }

    let hex = |span: &(usize, usize, Option<&str>)| {
        use std::fmt::Write as _;
        st.code[span.0..span.1]
            .iter()
            .fold(String::new(), |mut out, b| {
                let _ = write!(out, "0x{b:02x}, ");
                out
            })
    };
    let width = spans.iter().map(|sp| hex(sp).len()).max().unwrap_or(0);

    for span in &spans {
        let (start, end, insn) = *span;
        // Holes are 4-byte fields; find the ones patched inside this span.
        let holes: Vec<&Hole> = st
            .holes
            .iter()
            .filter(|h| (h.offset as usize) >= start && (h.offset as usize) < end)
            .collect();
        let branch = holes.iter().find(|h| h.pcrel);
        let immediates: Vec<&str> = holes.iter().filter(|h| !h.pcrel).map(|h| h.kind).collect();

        let mut note = format!("+{start:<3}");
        if let Some(insn) = insn {
            // A branch displacement is still zero here, so the disassembler
            // resolved it to the next instruction -- a target that is simply
            // untrue. Show what the JIT will write there instead.
            let text = match branch {
                Some(h) => format!(
                    "{} <{}>",
                    insn.split_whitespace().next().unwrap_or(insn),
                    h.kind
                ),
                None => insn.to_string(),
            };
            note.push_str(&format!(" {text}"));
        }
        if !immediates.is_empty() {
            note.push_str(&format!("   <- {}", immediates.join(", ")));
        }
        if st.tail_jump && end == st.code.len() {
            note.push_str("   (elided by the JIT)");
        }

        s.push_str(&format!(
            "            {:<width$} // {}\n",
            hex(span).trim_end(),
            note
        ));
    }
    s
}

fn render(stencils: &[Stencil]) -> String {
    let total: usize = stencils.iter().map(|st| st.code.len()).sum();
    let mut s = String::new();

    s.push_str("// @generated by build.rs -- do not edit.\n");
    s.push_str("//\n");
    s.push_str("// Machine code compiled from csrc/stencils.c by clang, written out as\n");
    s.push_str("// byte literals so the x86-64 the JIT copies is right here in the source\n");
    s.push_str("// rather than in a side file, plus the relocations the JIT fills in.\n\n");

    s.push_str("/// What the JIT must write into a hole.\n");
    s.push_str("#[derive(Clone, Copy, PartialEq, Eq, Debug)]\npub enum HoleKind {\n");
    s.push_str("    /// Address of the next bytecode op's code.\n    Next,\n");
    s.push_str("    /// Address of the branch target's code.\n    Target,\n");
    s.push_str("    /// Primary 32-bit operand.\n    ImmA,\n");
    s.push_str("    /// Secondary 32-bit operand.\n    ImmB,\n");
    s.push_str("    /// Bytecode index, used for error reporting.\n    ImmPc,\n}\n\n");

    s.push_str("/// One relocation inside a stencil.\n");
    s.push_str("#[derive(Clone, Copy, Debug)]\npub struct Hole {\n");
    s.push_str("    pub kind: HoleKind,\n");
    s.push_str("    /// Byte offset of the 4-byte field, relative to the stencil start.\n");
    s.push_str("    pub offset: u32,\n");
    s.push_str("    pub addend: i64,\n");
    s.push_str("    /// True for jump displacements, false for absolute immediates.\n");
    s.push_str("    pub pcrel: bool,\n}\n\n");

    s.push_str("/// A single op's machine code template.\n");
    s.push_str("#[derive(Clone, Copy, Debug)]\npub struct Stencil {\n");
    s.push_str("    pub name: &'static str,\n");
    s.push_str("    /// The template exactly as clang emitted it.\n");
    s.push_str("    pub code: &'static [u8],\n");
    s.push_str("    /// The last instruction is `jmp HOLE_NEXT`, which always\n");
    s.push_str("    /// lands on the byte right after the stencil and can be\n");
    s.push_str("    /// dropped along with its hole.\n");
    s.push_str("    pub tail_jump: bool,\n");
    s.push_str("    pub holes: &'static [Hole],\n}\n\n");

    s.push_str("impl Stencil {\n");
    s.push_str("    /// How many bytes of `code` the JIT actually copies.\n");
    s.push_str("    pub fn emitted_len(&self) -> usize {\n");
    s.push_str("        self.code.len() - if self.tail_jump { 5 } else { 0 }\n    }\n}\n\n");

    s.push_str(&format!(
        "/// Total x86-64 embedded below: {total} bytes across {} stencils.\n",
        stencils.len()
    ));
    s.push_str(&format!("pub const CODE_SIZE: usize = {total};\n\n"));

    s.push_str("pub static STENCILS: &[Stencil] = &[\n");
    for st in stencils {
        s.push_str(&format!("    Stencil {{\n        name: {:?},\n", st.name));
        s.push_str(&format!("        tail_jump: {},\n", st.tail_jump));
        s.push_str("        code: &[\n");
        s.push_str(&render_code(st));
        s.push_str("        ],\n        holes: &[\n");
        for h in &st.holes {
            s.push_str(&format!(
                "            Hole {{ kind: HoleKind::{}, offset: {}, addend: {}, pcrel: {} }},\n",
                h.kind, h.offset, h.addend, h.pcrel
            ));
        }
        s.push_str("        ],\n    },\n");
    }
    s.push_str("];\n\n");

    s.push_str("/// Index of each stencil in [`STENCILS`].\n#[allow(dead_code)]\npub mod id {\n");
    for (i, st) in stencils.iter().enumerate() {
        s.push_str(&format!(
            "    pub const {}: usize = {};\n",
            st.name.to_uppercase(),
            i
        ));
    }
    s.push_str("}\n");
    s
}
