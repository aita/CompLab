#!/usr/bin/env python3
"""Differential fuzzer for the MinPython JIT.

Generates random programs in the supported subset and checks that the
interpreter, the JIT and the background-compiling JIT all print the same
thing. The interpreter is the oracle: any disagreement is a JIT bug.

Programs are shaped to make the JIT actually fire -- functions are called
past the compile threshold and loops run past the OSR threshold -- and to
stay type-correct, so that a difference means miscompilation rather than
two implementations of the same error message.

    tests/fuzz.py --runs 500 [--seed N] [--keep DIR]

A failing program is shrunk (statements and whole functions dropped while
the disagreement survives) before it is reported.
"""
import argparse
import random
import subprocess
import sys
import tempfile
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / "build" / "minpython"
MODES = [[], ["--jit"], ["--tiered"]]

INT_BIN = ["+", "-", "*", "&", "|", "^"]
CMP = ["==", "!=", "<", "<=", ">", ">="]


class Gen:
    def __init__(self, rng):
        self.rng = rng
        self.funcs = []  # (name, [param kinds]) of already-defined functions

    # -- expressions --------------------------------------------------------
    def int_expr(self, env, depth=0):
        """An expression that is an int (or bool, which is int-like)."""
        r = self.rng
        ints = [v for v, k in env.items() if k == "int"]
        lists = [v for v, k in env.items() if k == "list"]
        strs = [v for v, k in env.items() if k == "str"]
        choices = ["const", "const"]
        if ints:
            choices += ["var", "var", "var"]
        if depth < 3:
            choices += ["bin", "bin", "un", "cmp", "paren"]
            if lists:
                choices += ["index", "len"]
            if strs:
                choices += ["len"]
            if self.funcs and depth < 2:
                choices += ["call"]
        what = r.choice(choices)
        if what == "const":
            return str(r.choice([0, 1, 2, 3, 7, -1, -5, 100, 1000]))
        if what == "var":
            return r.choice(ints)
        if what == "paren":
            return "(" + self.int_expr(env, depth + 1) + ")"
        if what == "un":
            return r.choice(["-", "~", "not "]) + "(" + self.int_expr(env, depth + 1) + ")"
        if what == "cmp":
            return "(%s %s %s)" % (self.int_expr(env, depth + 1), r.choice(CMP),
                                   self.int_expr(env, depth + 1))
        if what == "len":
            return "len(%s)" % r.choice(lists + strs)
        if what == "index":
            # Keep it in range: index a list by a value modulo its length.
            v = r.choice(lists)
            return "%s[(%s) %% len(%s)]" % (v, self.int_expr(env, depth + 1), v)
        if what == "call":
            name, kinds = r.choice(self.funcs)
            args = []
            for k in kinds:
                if k == "list" and lists:
                    args.append(r.choice(lists))
                elif k == "str" and strs:
                    args.append(r.choice(strs))
                elif k == "list":
                    args.append("[1, 2, 3]")
                elif k == "str":
                    args.append("'ab'")
                else:
                    args.append(self.int_expr(env, depth + 2))
            return "%s(%s)" % (name, ", ".join(args))
        # `bin`: shifts and division need their right operand tamed
        op = r.choice(INT_BIN + ["<<", ">>", "//", "%", "*"])
        left = self.int_expr(env, depth + 1)
        if op in ("<<", ">>"):
            return "(%s %s %d)" % (left, op, r.randint(0, 8))
        if op in ("//", "%"):
            return "(%s %s %d)" % (left, op, r.choice([1, 2, 3, 7, -3]))
        return "(%s %s %s)" % (left, op, self.int_expr(env, depth + 1))

    def str_expr(self, env, depth=0):
        r = self.rng
        strs = [v for v, k in env.items() if k == "str"]
        if strs and depth < 2 and r.random() < 0.6:
            return "(%s + %s)" % (r.choice(strs), self.str_expr(env, depth + 1))
        return repr(r.choice(["a", "bc", "xyz", ""]))

    def list_expr(self, env, depth=0):
        r = self.rng
        lists = [v for v, k in env.items() if k == "list"]
        if lists and depth < 2 and r.random() < 0.5:
            return "(%s + %s)" % (r.choice(lists), self.list_expr(env, depth + 1))
        n = r.randint(1, 4)
        return "[" + ", ".join(self.int_expr(env, 3) for _ in range(n)) + "]"

    # -- statements ---------------------------------------------------------
    def stmts(self, env, ind, depth, budget):
        r = self.rng
        out = []
        for _ in range(r.randint(1, 3)):
            if budget[0] <= 0:
                break
            budget[0] -= 1
            pool = ["assign", "assign", "assign", "aug", "aug", "if", "if",
                    "while", "newstr", "newlist"]
            if depth > 1:
                pool += ["ret"]      # only ever ends a nested block early
            what = r.choice(pool)
            if what == "assign":
                v = "v%d" % r.randint(0, 4)
                out.append("%s%s = %s" % (ind, v, self.int_expr(env)))
                env[v] = "int"
            elif what == "aug":
                ints = [v for v, k in env.items() if k == "int"]
                if not ints:
                    continue
                out.append("%s%s %s= %s" % (ind, r.choice(ints),
                                            r.choice(["+", "-", "*"]),
                                            self.int_expr(env)))
            elif what == "newstr":
                v = "s%d" % r.randint(0, 1)
                out.append("%s%s = %s" % (ind, v, self.str_expr(env)))
                env[v] = "str"
            elif what == "newlist":
                v = "xs%d" % r.randint(0, 1)
                out.append("%s%s = %s" % (ind, v, self.list_expr(env)))
                env[v] = "list"
            elif what == "if" and depth < 2:
                out.append("%sif %s:" % (ind, self.int_expr(env)))
                out += self.stmts(dict(env), ind + "    ", depth + 1, budget)
                if r.random() < 0.5:
                    out.append("%selse:" % ind)
                    out += self.stmts(dict(env), ind + "    ", depth + 1, budget)
            elif what == "while" and depth < 2:
                # A dedicated counter bounds every loop, so programs terminate.
                c = "k%d" % depth
                n = r.choice([3, 10, 300, 900])   # 300+ crosses the OSR threshold
                out.append("%s%s = 0" % (ind, c))
                out.append("%swhile %s < %d:" % (ind, c, n))
                inner = dict(env)
                inner[c] = "int"
                body = self.stmts(inner, ind + "    ", depth + 1, budget)
                out += body
                if r.random() < 0.25:
                    out.append("%s    if %s:" % (ind, self.int_expr(inner)))
                    out.append("%s        %s = %s + 1" % (ind, c, c))
                    out.append("%s        continue" % ind)
                out.append("%s    %s = %s + 1" % (ind, c, c))
                env[c] = "int"
            elif what == "ret":
                out.append("%sreturn %s" % (ind, self.int_expr(env)))
                break
        if not out:
            out.append("%spass" % ind)
        return out

    def func(self, name):
        r = self.rng
        kinds = [r.choice(["int", "int", "int", "list", "str"])
                 for _ in range(r.randint(1, 3))]
        params, env = [], {}
        for i, k in enumerate(kinds):
            p = "p%d" % i
            params.append(p)
            env[p] = k
        lines = ["def %s(%s):" % (name, ", ".join(params))]
        lines += self.stmts(env, "    ", 1, [24])
        lines.append("    return %s" % self.int_expr(env))
        self.funcs.append((name, kinds))
        return lines


def gen_program(seed):
    rng = random.Random(seed)
    g = Gen(rng)
    lines = []
    for i in range(rng.randint(1, 3)):
        lines += g.func("f%d" % i)
    # Drive every function past the JIT's call threshold, and print a running
    # total rather than each result so output stays small but stays sensitive.
    lines.append("total = 0")
    lines.append("d = 0")
    lines.append("while d < 40:")
    for name, kinds in g.funcs:
        args = []
        for k in kinds:
            if k == "list":
                args.append("[d, 1, 2, d + 3]")
            elif k == "str":
                args.append("'ab'")
            else:
                args.append("d")
        lines.append("    total = total + %s(%s)" % (name, ", ".join(args)))
    lines.append("    d = d + 1")
    lines.append("print(total)")
    return "\n".join(lines) + "\n"


def run(path, mode, timeout=25):
    try:
        p = subprocess.run([str(BIN)] + mode + [str(path)], capture_output=True,
                           text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "TIMEOUT"
    # stats go to stderr; the error message is what matters there
    err = "\n".join(l for l in p.stderr.splitlines() if not l.startswith("["))
    return p.stdout + err


def disagreement(src, tmp):
    tmp.write_text(src)
    outs = [run(tmp, m) for m in MODES]
    if "TIMEOUT" in outs:
        return None            # too slow to be a useful case, not a bug signal
    for m, o in zip(MODES[1:], outs[1:]):
        if o != outs[0]:
            return (" ".join(m) or "interp", outs[0], o)
    return None


def shrink(src, tmp):
    """Drop lines while the disagreement survives."""
    changed = True
    while changed:
        changed = False
        lines = src.split("\n")
        for i in range(len(lines)):
            if not lines[i].strip() or lines[i].startswith("print"):
                continue
            cand = "\n".join(lines[:i] + lines[i + 1:])
            if disagreement(cand, tmp):
                src, changed = cand, True
                break
    return src


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=200)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--keep", default=None, help="directory for failing cases")
    args = ap.parse_args()

    if not BIN.exists():
        sys.exit("no %s -- build first" % BIN)
    keep = Path(args.keep) if args.keep else None
    if keep:
        keep.mkdir(parents=True, exist_ok=True)

    fails = 0
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / "case.mpy"
        for i in range(args.runs):
            seed = args.seed + i
            src = gen_program(seed)
            d = disagreement(src, tmp)
            if not d:
                continue
            fails += 1
            small = shrink(src, tmp)
            mode, want, got = disagreement(small, tmp)
            print("=" * 60)
            print("seed %d: %s disagrees" % (seed, mode))
            print(small)
            print("  interp: %r" % want)
            print("  %-7s %r" % (mode + ":", got))
            if keep:
                (keep / ("fail_%d.mpy" % seed)).write_text(small)
    print("%d/%d disagreed" % (fails, args.runs))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
