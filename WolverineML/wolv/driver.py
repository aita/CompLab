"""The pipeline, and the toolchain around it.

    source ─lex─▶ tokens ─parse─▶ tree ─check─▶ typed tree ─lower─▶ CFG
           ─ssa─▶ SSA ─opt─▶ SSA ─regalloc─▶ coloured SSA ─emit─▶ ARMv8

Assembling and linking is left to a cross `gcc`, and running to `qemu-aarch64`
when the machine underneath is not itself an ARM.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from wolv import (
    allocator,
    dag,
    emit,
    ir,
    lexer,
    lower,
    opt,
    outofssa,
    parser,
    select,
    ssa,
    typecheck,
)
from wolv.astshow import show_program
from wolv.machine import Registers, limited

RUNTIME = Path(__file__).parent / "runtime" / "runtime.c"

STAGES = ("tokens", "ast", "ir", "ssa", "opt", "dag", "mach", "flat", "ra", "asm")


@dataclass(slots=True)
class Options:
    checks: bool = True
    optimise: bool = True
    max_regs: int | None = None
    regalloc: str = allocator.DEFAULT

    def registers(self) -> Registers:
        return Registers() if self.max_regs is None else limited(self.max_regs)

    def allocator(self) -> allocator.Allocator:
        return allocator.ALLOCATORS[self.regalloc]


def to_ir(source: str, opts: Options) -> ir.Module:
    program = parser.parse(source)
    typecheck.check(program)
    return lower.lower(program, lower.Options(checks=opts.checks))


def compile_module(source: str, opts: Options) -> ir.Module:
    mod = to_ir(source, opts)
    ssa.construct_module(mod)
    if opts.optimise:
        opt.optimise(mod)
    for func in mod.funcs:
        ssa.split_critical_edges(func)
    select.select_module(mod)
    chosen = opts.allocator()
    if not chosen.on_ssa:
        outofssa.destruct_module(mod)
    allocator.allocate_module(mod, chosen, opts.registers())
    return mod


def compile_to_asm(source: str, opts: Options) -> str:
    return emit.emit_module(compile_module(source, opts))


def stage(source: str, name: str, opts: Options) -> str:
    """Run the pipeline as far as `name`, and show what it has by then."""
    if name == "tokens":
        return "\n".join(f"{t.span}\t{t.kind.name}\t{t.text}" for t in lexer.lex(source))
    if name == "ast":
        program = parser.parse(source)
        typecheck.check(program)
        return show_program(program)
    mod = to_ir(source, opts)
    if name == "ir":
        return ir.show_module(mod)
    ssa.construct_module(mod)
    if name == "ssa":
        return ir.show_module(mod)
    if opts.optimise:
        opt.optimise(mod)
    if name == "opt":
        return ir.show_module(mod)
    for func in mod.funcs:
        ssa.split_critical_edges(func)
    if name == "dag":
        return "\n\n".join(
            f"fun {func.label}\n"
            + "\n".join(
                f"{label}:\n{dag.show(graph)}"
                for label, graph in select.graphs(func).items()
            )
            for func in mod.funcs
        ) + "\n"
    select.select_module(mod)
    if name == "mach":
        return ir.show_module(mod)
    chosen = opts.allocator()
    if not chosen.on_ssa:
        outofssa.destruct_module(mod)
    if name == "flat":
        return ir.show_module(mod)
    allocator.allocate_module(mod, chosen, opts.registers())
    if name == "ra":
        return ir.show_module(mod)
    return emit.emit_module(mod)


# -- the toolchain ------------------------------------------------------------


class ToolchainError(Exception):
    pass


def cross_cc() -> str:
    override = os.environ.get("WOLV_CC")
    if override:
        return override
    for name in ("aarch64-linux-gnu-gcc", "aarch64-linux-gnu-cc", "aarch64-none-linux-gnu-gcc"):
        found = shutil.which(name)
        if found:
            return found
    if platform.machine() in ("aarch64", "arm64"):
        native = shutil.which("cc") or shutil.which("gcc")
        if native:
            return native
    raise ToolchainError(
        "no ARM compiler found; install aarch64-linux-gnu-gcc or set WOLV_CC"
    )


def emulator() -> list[str]:
    if platform.machine() in ("aarch64", "arm64"):
        return []
    for name in ("qemu-aarch64", "qemu-aarch64-static"):
        found = shutil.which(name)
        if found:
            return [found]
    raise ToolchainError("no qemu-aarch64 found, and this machine is not an ARM")


def build(source: str, out: Path, opts: Options) -> None:
    asm = compile_to_asm(source, opts)
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "program.s"
        path.write_text(asm)
        command = [cross_cc(), "-static", "-O2", "-o", str(out), str(path), str(RUNTIME)]
        done = subprocess.run(command, capture_output=True, text=True, check=False)
        if done.returncode != 0:
            raise ToolchainError(f"the assembler refused it:\n{done.stderr}")


def run(source: str, opts: Options, stdin: str = "") -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as tmp:
        binary = Path(tmp) / "program"
        build(source, binary, opts)
        return subprocess.run(
            [*emulator(), str(binary)],
            input=stdin,
            capture_output=True,
            text=True,
            check=False,
        )
