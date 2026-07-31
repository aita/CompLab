"""Lowering: the typed syntax tree becomes a control flow graph.

Two things are worth knowing about this pass.

It never builds a phi.  A variable written in two branches is written to the
same register twice, and `ssa.py` is what turns those two writes into one phi.
Lowering only has to make sure a definition reaches every use, which structured
control flow does for free.

It decides where a variable lives.  A variable the checker did not mark as
escaping becomes a register; one that escaped becomes a frame slot, reached
through `LoadSlot`/`StoreSlot` in its own function and through a chain of
static links from a nested one.
"""

from __future__ import annotations

from dataclasses import dataclass

from wolv import ast, ir
from wolv.types import FunSym, RecordT, StringT, UnitT, VarSym

CMP_OF_OP = {"=": "=", "<>": "<>", "<": "<", "<=": "<=", ">": ">", ">=": ">="}

ARGUMENT_REGISTERS = ir.ARGUMENT_REGISTERS


@dataclass(slots=True)
class Options:
    checks: bool = True


class Lowerer:
    """Owns what the whole module shares: string literals and the function list."""

    def __init__(self, opts: Options) -> None:
        self.opts = opts
        self.mod = ir.Module()
        self.string_symbols: dict[str, str] = {}

    def string(self, text: str) -> str:
        symbol = self.string_symbols.get(text)
        if symbol is None:
            symbol = f".Lstr{len(self.string_symbols)}"
            self.string_symbols[text] = symbol
            self.mod.strings[symbol] = text
        return symbol

    def program(self, prog: ast.Program) -> ir.Module:
        main = FuncLowerer(self, "wol_main", "main", depth=0, params=[])
        main.top_level(prog.decls)
        return self.mod

    def function(self, bind: ast.FunBind) -> None:
        sym = bind.sym
        assert sym is not None
        fl = FuncLowerer(
            self, sym.label, sym.name, depth=sym.depth, params=sym.params
        )
        fl.function_body(bind, sym)


class FuncLowerer:
    def __init__(
        self,
        parent: Lowerer,
        label: str,
        name: str,
        depth: int,
        params: list[VarSym],
    ) -> None:
        self.up = parent
        self.opts = parent.opts
        self.func = ir.Func(label=label, name=name, params=[], depth=depth)
        self.cur = self.func.add_block("entry")
        self.breaks: list[str] = []
        self.counter = 0
        self.has_children = False
        if depth > 0:
            self.func.static_link_slot = self.func.new_slot()
        parent.mod.funcs.append(self.func)

    # -- block plumbing ---------------------------------------------------

    def fresh(self, hint: str) -> ir.Block:
        self.counter += 1
        return self.func.add_block(f"{hint}{self.counter}")

    def emit(self, instr: ir.Instr) -> None:
        self.cur.instrs.append(instr)

    def terminate(self, term: ir.Terminator) -> None:
        self.emit(term)
        self.cur = self.fresh("dead")

    def jump(self, block: ir.Block) -> None:
        self.terminate(ir.Jmp(block.label))

    def branch(self, cond: ir.Reg, yes: ir.Block, no: ir.Block) -> None:
        self.terminate(ir.CBr(cond, yes.label, no.label))

    def reg(self) -> ir.Reg:
        return self.func.new_reg()

    def const(self, value: int) -> ir.Reg:
        r = self.reg()
        self.emit(ir.Const(r, value))
        return r

    # -- function bodies --------------------------------------------------

    def top_level(self, decls: list[ast.Decl]) -> None:
        self.decls(decls)
        self.terminate(ir.Ret(None))
        self.finish()

    def function_body(self, bind: ast.FunBind, sym: FunSym) -> None:
        if self.func.depth > 0:
            link = self.reg()
            self.func.params.append(link)
            self.emit(ir.StoreSlot(self.func.static_link_slot, link))
        for index, psym in enumerate(sym.params, start=len(self.func.params)):
            if index >= ARGUMENT_REGISTERS:
                psym.escapes = True
                psym.slot = -(index - ARGUMENT_REGISTERS + 1)
                continue
            r = self.reg()
            self.func.params.append(r)
            if psym.escapes:
                psym.slot = self.func.new_slot()
                self.emit(ir.StoreSlot(psym.slot, r))
            else:
                psym.reg = r
        value = self.exp(bind.body)
        self.func.returns_value = not isinstance(sym.result, UnitT)
        self.terminate(ir.Ret(value if self.func.returns_value else None))
        self.finish()

    def finish(self) -> None:
        ir.drop_unreachable(self.func)
        self.drop_unused_static_link()

    def drop_unused_static_link(self) -> None:
        """A function nobody nests inside, and that never looks outward, keeps
        no static link: the slot goes, and every later slot moves down one."""
        slot = self.func.static_link_slot
        if slot < 0 or self.has_children:
            return
        reads = any(
            isinstance(i, ir.LoadSlot) and i.slot == slot
            for block in self.func.walk()
            for i in block.instrs
        )
        if reads:
            return
        for block in self.func.walk():
            kept: list[ir.Instr] = []
            for instr in block.instrs:
                match instr:
                    case ir.StoreSlot(s, _) if s == slot:
                        continue
                    case ir.StoreSlot(s, _) if s > slot:
                        instr.slot -= 1
                    case ir.LoadSlot(_, s) if s > slot:
                        instr.slot -= 1
                kept.append(instr)
            block.instrs = kept
        self.func.nslots -= 1
        self.func.static_link_slot = -1

    # -- declarations -----------------------------------------------------

    def decls(self, decls: list[ast.Decl]) -> None:
        for decl in decls:
            match decl:
                case ast.TypeDecl():
                    pass
                case ast.ValDecl():
                    self.val_decl(decl)
                case ast.FunDecl():
                    self.has_children = True
                    for bind in decl.binds:
                        self.up.function(bind)
                case _:
                    raise AssertionError("unknown declaration")

    def val_decl(self, decl: ast.ValDecl) -> None:
        value = self.exp(decl.init)
        sym = decl.sym
        if sym is None:
            return
        if isinstance(sym.ty, UnitT):
            return
        assert value is not None
        self.bind(sym, value)

    def bind(self, sym: VarSym, value: ir.Reg) -> None:
        """Give a variable its home, and put the initial value in it."""
        if sym.escapes:
            sym.slot = self.func.new_slot()
            self.emit(ir.StoreSlot(sym.slot, value))
        else:
            sym.reg = self.reg()
            self.emit(ir.Move(sym.reg, value))

    # -- reaching variables and frames ------------------------------------

    def frame_at(self, depth: int) -> ir.Reg:
        """A register holding the frame pointer of the function at `depth`."""
        r = self.reg()
        if depth == self.func.depth:
            self.emit(ir.FrameAddr(r))
            return r
        self.emit(ir.LoadSlot(r, self.func.static_link_slot))
        here = self.func.depth - 1
        while here > depth:
            nxt = self.reg()
            self.emit(ir.Load(nxt, r, ir.slot_offset(0)))
            r = nxt
            here -= 1
        return r

    def read_var(self, sym: VarSym) -> ir.Reg:
        if not sym.escapes:
            return sym.reg
        if sym.depth == self.func.depth:
            r = self.reg()
            self.emit(ir.LoadSlot(r, sym.slot))
            return r
        base = self.frame_at(sym.depth)
        r = self.reg()
        self.emit(ir.Load(r, base, ir.slot_offset(sym.slot)))
        return r

    def write_var(self, sym: VarSym, value: ir.Reg) -> None:
        if not sym.escapes:
            self.emit(ir.Move(sym.reg, value))
        elif sym.depth == self.func.depth:
            self.emit(ir.StoreSlot(sym.slot, value))
        else:
            base = self.frame_at(sym.depth)
            self.emit(ir.Store(base, ir.slot_offset(sym.slot), value))

    # -- expressions ------------------------------------------------------

    def value(self, e: ast.Exp) -> ir.Reg:
        r = self.exp(e)
        assert r is not None, f"expected a value from {type(e).__name__}"
        return r

    def exp(self, e: ast.Exp) -> ir.Reg | None:
        match e:
            case ast.IntLit():
                return self.const(e.value)
            case ast.BoolLit():
                return self.const(1 if e.value else 0)
            case ast.NilLit():
                return self.const(0)
            case ast.UnitLit():
                return None
            case ast.StrLit():
                r = self.reg()
                self.emit(ir.StrConst(r, self.up.string(e.value)))
                return r
            case ast.Var():
                assert e.sym is not None
                return self.read_var(e.sym)
            case ast.Call():
                return self.call(e)
            case ast.RecordLit():
                return self.record(e)
            case ast.Index():
                return self.index(e)
            case ast.Field():
                return self.field(e)
            case ast.Neg():
                zero = self.const(0)
                return self.binop("-", zero, self.value(e.operand))
            case ast.Bin():
                return self.bin(e)
            case ast.Logic():
                return self.logic(e)
            case ast.Assign():
                self.assign(e)
                return None
            case ast.If():
                return self.if_exp(e)
            case ast.While():
                self.while_exp(e)
                return None
            case ast.For():
                self.for_exp(e)
                return None
            case ast.Break():
                self.terminate(ir.Jmp(self.breaks[-1]))
                return None
            case ast.Seq():
                last: ir.Reg | None = None
                for item in e.items:
                    last = self.exp(item)
                return last
            case ast.Let():
                self.decls(e.decls)
                return self.exp(e.body)
            case _:
                raise AssertionError(f"unknown expression {type(e).__name__}")

    def binop(self, op: str, lhs: ir.Reg, rhs: ir.Reg) -> ir.Reg:
        r = self.reg()
        self.emit(ir.Bin(r, op, lhs, rhs))
        return r

    def compare(self, op: str, lhs: ir.Reg, rhs: ir.Reg) -> ir.Reg:
        r = self.reg()
        self.emit(ir.Cmp(r, op, lhs, rhs))
        return r

    def call_runtime(self, name: str, args: list[ir.Reg]) -> ir.Reg:
        r = self.reg()
        self.emit(ir.Call(r, name, args))
        return r

    def bin(self, e: ast.Bin) -> ir.Reg:
        lhs = self.value(e.lhs)
        rhs = self.value(e.rhs)
        if e.op == "^":
            return self.call_runtime("wol_concat", [lhs, rhs])
        if e.op in ("/", "mod"):
            self.check_nonzero(rhs)
            if e.op == "/":
                return self.binop("/", lhs, rhs)
            # The remainder is spelled out rather than left to the emitter: the
            # quotient it needs in between is a value like any other, and the
            # allocator can find it a register.  The emitter fuses the last two
            # back into one `msub`.
            quotient = self.binop("/", lhs, rhs)
            product = self.binop("*", quotient, rhs)
            return self.binop("-", lhs, product)
        if e.op in ("+", "-", "*"):
            return self.binop(e.op, lhs, rhs)
        if isinstance(e.lhs.ty, StringT):
            order = self.call_runtime("wol_string_cmp", [lhs, rhs])
            return self.compare(CMP_OF_OP[e.op], order, self.const(0))
        return self.compare(CMP_OF_OP[e.op], lhs, rhs)

    def logic(self, e: ast.Logic) -> ir.Reg:
        """`andalso` and `orelse` are branches, so the result needs a register."""
        result = self.reg()
        rhs_block = self.fresh("logic")
        join = self.fresh("logicjoin")
        lhs = self.value(e.lhs)
        self.emit(ir.Move(result, lhs))
        if e.op == "andalso":
            self.branch(lhs, rhs_block, join)
        else:
            self.branch(lhs, join, rhs_block)
        self.cur = rhs_block
        self.emit(ir.Move(result, self.value(e.rhs)))
        self.jump(join)
        self.cur = join
        return result

    def call(self, e: ast.Call) -> ir.Reg | None:
        sym = e.sym
        assert sym is not None
        match sym.builtin:
            case "not":
                return self.binop("xor", self.value(e.args[0]), self.const(1))
            case "array":
                n = self.value(e.args[0])
                init = self.value(e.args[1])
                return self.call_runtime("wol_array", [n, init])
            case "length":
                arr = self.value(e.args[0])
                self.check_not_nil(arr)
                r = self.reg()
                self.emit(ir.Load(r, arr, 0))
                return r
        args = [self.value(a) for a in e.args]
        if sym.builtin is None:
            args = [self.frame_at(sym.depth - 1), *args]
        if isinstance(sym.result, UnitT):
            self.emit(ir.Call(None, sym.label, args))
            return None
        return self.call_runtime(sym.label, args)

    def record(self, e: ast.RecordLit) -> ir.Reg:
        rec = e.ty
        assert isinstance(rec, RecordT)
        size = self.const(ir.WORD * max(len(rec.fields), 1))
        base = self.call_runtime("wol_alloc", [size])
        for i, f in enumerate(e.fields):
            self.emit(ir.Store(base, ir.WORD * i, self.value(f.value)))
        return base

    def index(self, e: ast.Index) -> ir.Reg:
        addr = self.element_address(e)
        r = self.reg()
        self.emit(ir.Load(r, addr, ir.WORD))
        return r

    def element_address(self, e: ast.Index) -> ir.Reg:
        """The address of `a[i]`, without the length word the elements follow.

        The selector turns this into one `add` with a shifted operand, and the
        word is the load's displacement, so the two instructions that come out
        are the two the machine has.
        """
        base = self.value(e.array)
        idx = self.value(e.index)
        self.check_not_nil(base)
        self.check_bounds(base, idx)
        return self.binop("+", base, self.binop("shl", idx, self.const(3)))

    def field(self, e: ast.Field) -> ir.Reg:
        base = self.value(e.record)
        self.check_not_nil(base)
        r = self.reg()
        self.emit(ir.Load(r, base, ir.WORD * e.offset))
        return r

    def assign(self, e: ast.Assign) -> None:
        match e.target:
            case ast.Var():
                assert e.target.sym is not None
                self.write_var(e.target.sym, self.value(e.value))
            case ast.Index():
                addr = self.element_address(e.target)
                self.emit(ir.Store(addr, ir.WORD, self.value(e.value)))
            case ast.Field():
                base = self.value(e.target.record)
                self.check_not_nil(base)
                self.emit(
                    ir.Store(base, ir.WORD * e.target.offset, self.value(e.value))
                )
            case _:
                raise AssertionError("assignment to something that is not a place")

    def if_exp(self, e: ast.If) -> ir.Reg | None:
        wants_value = not isinstance(e.ty, UnitT)
        result = self.reg() if wants_value else None
        yes = self.fresh("then")
        no = self.fresh("else")
        join = self.fresh("join")
        self.branch(self.value(e.cond), yes, no)

        self.cur = yes
        value = self.exp(e.then)
        if result is not None and value is not None:
            self.emit(ir.Move(result, value))
        self.jump(join)

        self.cur = no
        if e.els is not None:
            value = self.exp(e.els)
            if result is not None and value is not None:
                self.emit(ir.Move(result, value))
        self.jump(join)

        self.cur = join
        return result

    def while_exp(self, e: ast.While) -> None:
        test = self.fresh("test")
        body = self.fresh("body")
        done = self.fresh("done")
        self.jump(test)
        self.cur = test
        self.branch(self.value(e.cond), body, done)
        self.cur = body
        self.breaks.append(done.label)
        self.exp(e.body)
        self.breaks.pop()
        self.jump(test)
        self.cur = done

    def for_exp(self, e: ast.For) -> None:
        """`for i = lo to hi` counts up, and stops before overflowing at `hi`."""
        sym = e.sym
        assert sym is not None
        lo = self.value(e.lo)
        hi_value = self.value(e.hi)
        hi = self.reg()
        self.emit(ir.Move(hi, hi_value))
        self.bind(sym, lo)
        body = self.fresh("forbody")
        step = self.fresh("forstep")
        done = self.fresh("fordone")
        self.branch(self.compare("<=", lo, hi), body, done)

        self.cur = body
        self.breaks.append(done.label)
        self.exp(e.body)
        self.breaks.pop()
        i = self.read_var(sym)
        self.branch(self.compare("<", i, hi), step, done)

        self.cur = step
        self.write_var(sym, self.binop("+", self.read_var(sym), self.const(1)))
        self.jump(body)

        self.cur = done

    # -- run-time checks --------------------------------------------------

    def check_not_nil(self, base: ir.Reg) -> None:
        if not self.opts.checks:
            return
        bad = self.fresh("nil")
        ok = self.fresh("ok")
        self.branch(self.compare("=", base, self.const(0)), bad, ok)
        self.cur = bad
        self.emit(ir.Call(None, "wol_nil_error", []))
        self.jump(ok)
        self.cur = ok

    def check_bounds(self, base: ir.Reg, idx: ir.Reg) -> None:
        if not self.opts.checks:
            return
        length = self.reg()
        self.emit(ir.Load(length, base, 0))
        bad = self.fresh("oob")
        ok = self.fresh("ok")
        self.branch(self.compare("u<", idx, length), ok, bad)
        self.cur = bad
        self.emit(ir.Call(None, "wol_bounds_error", [idx, length]))
        self.jump(ok)
        self.cur = ok

    def check_nonzero(self, rhs: ir.Reg) -> None:
        if not self.opts.checks:
            return
        bad = self.fresh("divzero")
        ok = self.fresh("ok")
        self.branch(self.compare("=", rhs, self.const(0)), bad, ok)
        self.cur = bad
        self.emit(ir.Call(None, "wol_div_error", []))
        self.jump(ok)
        self.cur = ok


def lower(prog: ast.Program, opts: Options | None = None) -> ir.Module:
    return Lowerer(opts or Options()).program(prog)
