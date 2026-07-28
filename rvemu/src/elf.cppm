// ELF partition — reading a RISC-V ELF64 into the guest address space.
//
// This is a program loader, not a linker: it handles what the kernel handles.
// PT_LOAD segments are mapped and filled, the bss tail is left zero (pages are
// born zeroed), and the interesting addresses the C runtime will ask for --
// entry, the phdr table, the initial break -- come back in an `Image`.
//
// Two things it deliberately does not do:
//
//   * Dynamic linking. There is no ld.so here, so a PT_INTERP is a hard error
//     with a message telling you to relink with -static. Static PIE is fine,
//     though: it has no interpreter, only R_RISCV_RELATIVE entries, and those
//     are applied below.
//   * Program headers it does not recognise. PT_TLS in particular needs no
//     special handling -- static glibc finds its own TLS image by walking the
//     phdrs at AT_PHDR, which is exactly why AT_PHDR has to be right.
//
// `Image` is also what the assembler produces, so the Machine above does not
// care which front end built the program it is about to run.
export module rvemu:elf;

import std;
import :common;
import :memory;

export namespace rvemu {

// A symbol worth reporting in a trace or a fault message. Only defined function
// and object symbols are kept; gdb reads the real symbol table from the file.
struct Sym {
  u64 addr = 0;
  u64 size = 0;
  std::string name;
};

struct Image {
  u64 entry = 0;
  u64 brk = 0;    // first byte past the highest PT_LOAD, page-aligned
  u64 phdr = 0;   // AT_PHDR: guest address of the program header table
  u64 phent = 0;  // AT_PHENT
  u64 phnum = 0;  // AT_PHNUM
  u64 load_bias = 0;
  std::string path;  // what AT_EXECFN and /proc/self/exe should say
  std::vector<Sym> symbols;
  // The executable ranges, so `--disassemble` knows what to walk.
  std::vector<std::pair<u64, u64>> text;

  // Name the address, for traces and fault reports: "main+0x1c". The nearest
  // symbol at or below wins, which is what objdump does and what makes a trace
  // of hand-written assembly -- where every label has size zero -- readable. A
  // sized symbol that does not reach the address means we are in a gap between
  // functions, and naming it after the previous one would be a lie.
  //
  // `symbols` is kept sorted so this stays a binary search: --trace calls it
  // once per instruction.
  std::string describe(u64 addr) const {
    auto it = std::ranges::upper_bound(symbols, addr, {}, &Sym::addr);
    if (it == symbols.begin()) return {};
    --it;
    if (it->size && addr >= it->addr + it->size) return {};
    const u64 off = addr - it->addr;
    return off ? std::format("{}+{:#x}", it->name, off) : it->name;
  }

  void sort_symbols() {
    std::ranges::sort(symbols, {}, &Sym::addr);
  }
};

// Where a static-PIE image is placed. Well clear of the fixed-address ELFs that
// land at 0x10000 and of the mmap arena higher up.
inline constexpr u64 kPieBase = 0x0000'0000'4000'0000;

namespace elf {

inline constexpr u16 ET_EXEC = 2, ET_DYN = 3;
inline constexpr u16 EM_RISCV = 243;
inline constexpr u32 PT_LOAD = 1, PT_DYNAMIC = 2, PT_INTERP = 3, PT_PHDR = 6;
inline constexpr u32 PF_X = 1, PF_W = 2, PF_R = 4;
inline constexpr u32 SHT_SYMTAB = 2;
inline constexpr u64 DT_NULL = 0, DT_RELA = 7, DT_RELASZ = 8, DT_RELAENT = 9;
inline constexpr u32 R_RISCV_RELATIVE = 3;

// Little-endian field reads, so the loader never depends on struct layout.
inline u16 rd16(std::span<const u8> b, u64 off) {
  return u16(b[off]) | u16(b[off + 1]) << 8;
}
inline u32 rd32(std::span<const u8> b, u64 off) {
  return u32(rd16(b, off)) | u32(rd16(b, off + 2)) << 16;
}
inline u64 rd64(std::span<const u8> b, u64 off) {
  return u64(rd32(b, off)) | u64(rd32(b, off + 4)) << 32;
}

}  // namespace elf

// Read a whole file. Returns false (with `d` set) if it cannot be read.
inline bool read_file(const std::string& path, std::vector<u8>& out, Diag& d) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    d.fail(std::format("cannot open {}", path));
    return false;
  }
  in.seekg(0, std::ios::end);
  const std::streamoff size = in.tellg();
  if (size < 0) {
    d.fail(std::format("cannot size {}", path));
    return false;
  }
  in.seekg(0, std::ios::beg);
  out.resize(static_cast<std::size_t>(size));
  if (size && !in.read(reinterpret_cast<char*>(out.data()), size)) {
    d.fail(std::format("cannot read {}", path));
    return false;
  }
  return true;
}

// Is this file an ELF at all? The CLI uses it to decide between the loader and
// the assembler when the caller did not say.
inline bool looks_like_elf(std::span<const u8> b) {
  return b.size() >= 4 && b[0] == 0x7f && b[1] == 'E' && b[2] == 'L' && b[3] == 'F';
}

// Defined below; load_elf calls it for static-PIE images.
inline bool apply_relative_relocs(Memory& mem, u64 bias, u64 dynamic_vaddr, Diag& d);

inline bool load_elf(std::span<const u8> b, const std::string& path, Memory& mem,
                     Image& img, Diag& d) {
  using namespace elf;

  if (b.size() < 64 || !looks_like_elf(b)) {
    d.fail(std::format("{}: not an ELF file", path));
    return false;
  }
  if (b[4] != 2) {
    d.fail(std::format("{}: not ELF64 (this is an RV64 emulator)", path));
    return false;
  }
  if (b[5] != 1) {
    d.fail(std::format("{}: not little-endian", path));
    return false;
  }
  const u16 e_type = rd16(b, 16);
  const u16 e_machine = rd16(b, 18);
  if (e_machine != EM_RISCV) {
    d.fail(std::format("{}: e_machine is {}, expected RISC-V ({})", path, e_machine,
                       EM_RISCV));
    return false;
  }
  if (e_type != ET_EXEC && e_type != ET_DYN) {
    d.fail(std::format("{}: not an executable (e_type {})", path, e_type));
    return false;
  }

  const u64 e_entry = rd64(b, 24);
  const u64 e_phoff = rd64(b, 32);
  const u64 e_shoff = rd64(b, 40);
  const u16 e_phentsize = rd16(b, 54);
  const u16 e_phnum = rd16(b, 56);
  const u16 e_shentsize = rd16(b, 58);
  const u16 e_shnum = rd16(b, 60);

  if (e_phoff + u64(e_phnum) * e_phentsize > b.size()) {
    d.fail(std::format("{}: program headers run past end of file", path));
    return false;
  }

  // A PIE has no fixed address of its own; everything shifts by the bias.
  const u64 bias = (e_type == ET_DYN) ? kPieBase : 0;
  img.load_bias = bias;
  img.entry = e_entry + bias;
  img.phent = e_phentsize;
  img.phnum = e_phnum;
  img.path = path;

  u64 highest = 0;
  u64 phdr_vaddr = 0;
  u64 dynamic_vaddr = 0, dynamic_size = 0;

  for (u16 i = 0; i < e_phnum; ++i) {
    const u64 ph = e_phoff + u64(i) * e_phentsize;
    const u32 p_type = rd32(b, ph);
    const u32 p_flags = rd32(b, ph + 4);
    const u64 p_offset = rd64(b, ph + 8);
    const u64 p_vaddr = rd64(b, ph + 16) + bias;
    const u64 p_filesz = rd64(b, ph + 32);
    const u64 p_memsz = rd64(b, ph + 40);

    if (p_type == PT_INTERP) {
      std::string interp(reinterpret_cast<const char*>(b.data() + p_offset),
                         p_filesz ? p_filesz - 1 : 0);
      d.fail(std::format("{}: dynamically linked (needs {}). rvemu has no dynamic "
                         "loader -- rebuild with -static.",
                         path, interp));
      return false;
    }
    if (p_type == PT_PHDR) {
      phdr_vaddr = p_vaddr;
      continue;
    }
    if (p_type == PT_DYNAMIC) {
      dynamic_vaddr = p_vaddr;
      dynamic_size = p_memsz;
      continue;
    }
    if (p_type != PT_LOAD || p_memsz == 0) continue;

    if (p_offset + p_filesz > b.size()) {
      d.fail(std::format("{}: PT_LOAD {} runs past end of file", path, i));
      return false;
    }

    u8 perm = 0;
    if (p_flags & PF_R) perm |= PermR;
    if (p_flags & PF_W) perm |= PermW;
    if (p_flags & PF_X) perm |= PermX;
    // Segments can share a page, so permissions accumulate rather than replace.
    mem.map_merge(p_vaddr, p_memsz, perm);
    // poke, not write: text is about to be read-only and this is the loader.
    if (p_filesz && !mem.poke(p_vaddr, b.data() + p_offset, p_filesz)) {
      d.fail(std::format("{}: cannot fill PT_LOAD {} at {}", path, i, hex(p_vaddr)));
      return false;
    }
    highest = std::max(highest, p_vaddr + p_memsz);
    if (p_flags & PF_X) img.text.push_back({p_vaddr, p_memsz});

    // If the ELF header itself is inside this segment, the phdr table is too --
    // that is how AT_PHDR is derived when there is no PT_PHDR.
    if (!phdr_vaddr && p_offset <= e_phoff && e_phoff < p_offset + p_filesz) {
      phdr_vaddr = p_vaddr + (e_phoff - p_offset);
    }
  }

  if (highest == 0) {
    d.fail(std::format("{}: no loadable segments", path));
    return false;
  }
  img.phdr = phdr_vaddr;
  img.brk = align_up(highest, kPageSize);

  // Static PIE: no interpreter ran, so nobody has applied the RELATIVE
  // relocations that turn link-time addresses into loaded ones.
  if (bias && dynamic_size && !apply_relative_relocs(mem, bias, dynamic_vaddr, d)) {
    return false;
  }

  // Symbols, purely for our own diagnostics. A stripped binary just has none.
  if (e_shoff && e_shnum && e_shoff + u64(e_shnum) * e_shentsize <= b.size()) {
    for (u16 i = 0; i < e_shnum; ++i) {
      const u64 sh = e_shoff + u64(i) * e_shentsize;
      if (rd32(b, sh + 4) != SHT_SYMTAB) continue;
      const u32 link = rd32(b, sh + 40);
      const u64 off = rd64(b, sh + 24), size = rd64(b, sh + 32), entsz = rd64(b, sh + 56);
      if (!entsz || off + size > b.size() || link >= e_shnum) continue;
      const u64 strsh = e_shoff + u64(link) * e_shentsize;
      const u64 stroff = rd64(b, strsh + 24), strsize = rd64(b, strsh + 32);
      if (stroff + strsize > b.size()) continue;

      for (u64 s = 0; s + entsz <= size; s += entsz) {
        const u64 e = off + s;
        const u32 name_off = rd32(b, e);
        const u8 info = b[e + 4];
        const u16 shndx = rd16(b, e + 6);
        const u64 value = rd64(b, e + 8);
        const u64 sz = rd64(b, e + 16);
        const u8 type = info & 0xf;
        if (shndx == 0 || !value) continue;  // undefined or absolute-zero
        // NOTYPE as well as OBJECT and FUNC: a hand-written `_start:` with no
        // `.type` directive is NOTYPE, and it is exactly the label you want to
        // see in a trace.
        if (type > 2) continue;
        if (name_off >= strsize) continue;
        const char* nm = reinterpret_cast<const char*>(b.data() + stroff + name_off);
        if (!*nm) continue;
        // `$xrv64i2p1...` and friends are ISA mapping symbols, not code labels,
        // and they sit on the same address as the real one.
        if (*nm == '$') continue;
        img.symbols.push_back(Sym{value + bias, sz, std::string(nm)});
      }
    }
    img.sort_symbols();
  }
  return true;
}

// Walk PT_DYNAMIC for the RELA table and apply every R_RISCV_RELATIVE entry.
// A static PIE has nothing else in there that matters to us.
inline bool apply_relative_relocs(Memory& mem, u64 bias, u64 dynamic_vaddr, Diag& d) {
  using namespace elf;
  u64 rela = 0, relasz = 0, relaent = 24;

  for (u64 p = dynamic_vaddr;; p += 16) {
    u64 tag = 0, val = 0;
    if (!mem.peek(p, &tag, 8) || !mem.peek(p + 8, &val, 8)) {
      d.fail("PT_DYNAMIC runs outside the loaded image");
      return false;
    }
    if (tag == DT_NULL) break;
    if (tag == DT_RELA) rela = val + bias;
    else if (tag == DT_RELASZ) relasz = val;
    else if (tag == DT_RELAENT) relaent = val;
  }
  if (!rela || !relasz || !relaent) return true;

  for (u64 off = 0; off + relaent <= relasz; off += relaent) {
    u64 r_offset = 0, r_info = 0, r_addend = 0;
    if (!mem.peek(rela + off, &r_offset, 8) || !mem.peek(rela + off + 8, &r_info, 8) ||
        !mem.peek(rela + off + 16, &r_addend, 8)) {
      d.fail("relocation table runs outside the loaded image");
      return false;
    }
    if (u32(r_info) != R_RISCV_RELATIVE) continue;  // no symbols to resolve here
    const u64 value = bias + r_addend;
    if (!mem.poke(r_offset + bias, &value, 8)) {
      d.fail(std::format("relocation target {} is not mapped", hex(r_offset + bias)));
      return false;
    }
  }
  return true;
}

}  // namespace rvemu
