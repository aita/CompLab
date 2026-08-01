"""Random programs whose answer is known before they are compiled.

The other tests say what the compiler should do; these say what the program
should print, which is the only thing a user cares about.  A program is built
at random, worked out here in Python with the language's arithmetic, and then
compiled — so any disagreement is a bug in the compiler and not in a
comparison between two of its own configurations.
"""

from __future__ import annotations

import random

WORD = 1 << 64
SIZE = 16
VARS = [f"v{i}" for i in range(4)]
CONSTANTS = [0, 1, 2, 3, 7, 8, 15, 16, 100, 4095, 4096, 65536, -1, -8, 1 << 40]
ARGUMENTS = [(0, 0, 0), (1, 2, 3), (-1, 7, -13), ((1 << 63) - 1, -(1 << 63), 2)]


def wrap(value: int) -> int:
    value &= WORD - 1
    return value - WORD if value >= (1 << 63) else value


def divide(a: int, b: int) -> int:
    """Towards zero, which is what `sdiv` does."""
    magnitude = abs(a) // abs(b)
    return wrap(magnitude if (a < 0) == (b < 0) else -magnitude)


def modulo(a: int, b: int) -> int:
    return wrap(a - divide(a, b) * b)


def literal(value: int) -> str:
    return f"~{-value}" if value < 0 else str(value)


class DividedByZero(Exception):
    pass


# -- expressions --------------------------------------------------------------


# A small s-expression: ("int", 3), ("bin", "+", left, right), and so on.  It
# is not worth a class each, but it is worth saying that what comes out of a
# `case` is not to be trusted without asking.
type Node = tuple[object, ...]


def expression(rng: random.Random, depth: int) -> Node:
    if depth == 0 or rng.random() < 0.25:
        if rng.random() < 0.5:
            return ("var", rng.choice("abc"))
        return ("int", rng.choice(CONSTANTS))
    if rng.random() < 0.1:
        return (
            "if",
            rng.choice(["=", "<>", "<", "<=", ">", ">="]),
            expression(rng, depth - 1),
            expression(rng, depth - 1),
            expression(rng, depth - 1),
            expression(rng, depth - 1),
        )
    op = rng.choices(["+", "-", "*", "/", "mod"], [4, 3, 3, 1, 1])[0]
    return ("bin", op, expression(rng, depth - 1), expression(rng, depth - 1))


def evaluate(node: object, env: dict[str, int]) -> int:
    match node:
        case ("var", str(name)):
            return env[name]
        case ("int", int(value)):
            return value
        case ("if", str(op), x, y, then, els):
            taken = compare(op, evaluate(x, env), evaluate(y, env))
            return evaluate(then if taken else els, env)
        case ("bin", str(op), x, y):
            a, b = evaluate(x, env), evaluate(y, env)
            if op == "+":
                return wrap(a + b)
            if op == "-":
                return wrap(a - b)
            if op == "*":
                return wrap(a * b)
            if b == 0:
                raise DividedByZero
            return divide(a, b) if op == "/" else modulo(a, b)
        case _:
            raise AssertionError(node)


def compare(op: str, a: int, b: int) -> bool:
    return {
        "=": a == b, "<>": a != b, "<": a < b,
        "<=": a <= b, ">": a > b, ">=": a >= b,
    }[op]


def show(node: object) -> str:
    match node:
        case ("var", str(name)):
            return name
        case ("int", int(value)):
            return literal(value)
        case ("if", str(op), x, y, then, els):
            return f"(if {show(x)} {op} {show(y)} then {show(then)} else {show(els)})"
        case ("bin", str(op), x, y):
            return f"({show(x)} {op} {show(y)})"
        case _:
            raise AssertionError(node)


def arithmetic(seed: int, count: int) -> tuple[str, str]:
    """`count` functions of three arguments, and what they print."""
    rng = random.Random(seed)
    definitions: list[str] = []
    calls: list[str] = []
    expected: list[str] = []
    made = 0
    while made < count:
        tree = expression(rng, rng.randint(1, 5))
        try:
            values = [
                evaluate(tree, {"a": a, "b": b, "c": c}) for a, b, c in ARGUMENTS
            ]
        except DividedByZero:
            continue
        definitions.append(
            f"fun f{made} (a : int, b : int, c : int) : int = {show(tree)}"
        )
        for (a, b, c), want in zip(ARGUMENTS, values, strict=True):
            arguments = ", ".join(literal(v) for v in (a, b, c))
            calls.append(f'val () = (printInt (f{made} ({arguments})); print ("\\n"))')
            expected.append(str(want))
        made += 1
    return "\n".join(definitions + calls) + "\n", "\n".join(expected) + "\n"


# -- statements ---------------------------------------------------------------


def statement(rng: random.Random, depth: int, scope: list[str], fresh: list[int]) -> Node:
    roll = rng.random()
    if depth > 0 and roll < 0.2:
        return (
            "if",
            rng.choice(["=", "<>", "<", "<=", ">", ">="]),
            place(rng, scope),
            place(rng, scope),
            statement(rng, depth - 1, scope, fresh),
            statement(rng, depth - 1, scope, fresh),
        )
    if depth > 0 and roll < 0.45:
        fresh[0] += 1
        name = f"i{fresh[0]}"
        return (
            "for",
            name,
            rng.randint(0, 2),
            rng.randint(2, 5),
            statement(rng, depth - 1, [*scope, name], fresh),
        )
    if depth > 0 and roll < 0.55:
        return ("seq", [statement(rng, depth - 1, scope, fresh) for _ in range(2)])
    if roll < 0.8:
        return ("set", rng.choice(VARS), place(rng, scope))
    return ("put", place(rng, scope), place(rng, scope))


def place(rng: random.Random, scope: list[str]) -> Node:
    """An expression over the variables in scope and the array."""
    roll = rng.random()
    if roll < 0.35:
        return ("var", rng.choice(scope))
    if roll < 0.5:
        return ("int", rng.choice(CONSTANTS))
    if roll < 0.65:
        return ("get", place(rng, scope))
    op = rng.choice(["+", "-", "*"])
    return ("bin", op, place(rng, scope), place(rng, scope))


def cell(value: int) -> int:
    """`index` in the generated program: the remainder, made positive."""
    return (value - divide(value, SIZE) * SIZE + SIZE) % SIZE


def run_place(node: object, env: dict[str, int], array: list[int]) -> int:
    match node:
        case ("var", str(name)):
            return env[name]
        case ("int", int(value)):
            return value
        case ("get", inner):
            return array[cell(run_place(inner, env, array))]
        case ("bin", str(op), x, y):
            a, b = run_place(x, env, array), run_place(y, env, array)
            return wrap({"+": a + b, "-": a - b, "*": a * b}[op])
        case _:
            raise AssertionError(node)


def run_statement(node: object, env: dict[str, int], array: list[int]) -> None:
    match node:
        case ("set", str(name), value):
            env[name] = run_place(value, env, array)
        case ("put", where, value):
            array[cell(run_place(where, env, array))] = run_place(value, env, array)
        case ("seq", [*items]):
            for item in items:
                run_statement(item, env, array)
        case ("if", str(op), x, y, then, els):
            a, b = run_place(x, env, array), run_place(y, env, array)
            run_statement(then if compare(op, a, b) else els, env, array)
        case ("for", str(name), int(lo), int(hi), body):
            for i in range(lo, hi + 1):
                env[name] = i
                run_statement(body, env, array)
        case _:
            raise AssertionError(node)


def show_place(node: object) -> str:
    match node:
        case ("get", inner):
            return f"xs[index ({show_place(inner)})]"
        case ("bin", op, x, y):
            return f"({show_place(x)} {op} {show_place(y)})"
        case _:
            return show(node)


def show_statement(node: object, indent: str) -> str:
    match node:
        case ("set", str(name), value):
            return f"{indent}{name} := {show_place(value)}"
        case ("put", where, value):
            return f"{indent}xs[index ({show_place(where)})] := {show_place(value)}"
        case ("seq", [*items]):
            inner = ";\n".join(show_statement(i, indent + "  ") for i in items)
            return f"{indent}(\n{inner}\n{indent})"
        case ("if", str(op), x, y, then, els):
            return (
                f"{indent}if {show_place(x)} {op} {show_place(y)} then\n"
                f"{show_statement(then, indent + '  ')}\n{indent}else\n"
                f"{show_statement(els, indent + '  ')}"
            )
        case ("for", str(name), int(lo), int(hi), body):
            return (
                f"{indent}for {name} = {lo} to {hi} do\n"
                f"{show_statement(body, indent + '  ')}"
            )
        case _:
            raise AssertionError(node)


PREAMBLE = """val xs = array (16, 0)
fun index (n : int) : int =
  let val r = n - n / 16 * 16 in
    if r < 0 then r + 16 else r
  end
"""


def imperative(seed: int, count: int) -> tuple[str, str]:
    """A program of assignments, loops and branches over an array."""
    rng = random.Random(seed)
    body = [statement(rng, 3, VARS, [0]) for _ in range(count)]
    env = dict.fromkeys(VARS, 0)
    array = [0] * SIZE
    for item in body:
        run_statement(item, env, array)
    expected = [str(env[name]) for name in VARS] + [str(v) for v in array]

    lines = [PREAMBLE, *[f"var {name} = 0" for name in VARS], "val () = ("]
    lines.append(";\n".join(show_statement(item, "  ") for item in body))
    lines.append(")")
    lines += [f'val () = (printInt ({name}); print ("\\n"))' for name in VARS]
    lines.append('val () = for k = 0 to 15 do (printInt (xs[k]); print ("\\n"))')
    return "\n".join(lines) + "\n", "\n".join(expected) + "\n"
