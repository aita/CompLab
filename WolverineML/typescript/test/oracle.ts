// Random programs whose answer is known before they are compiled.
//
// The other tests say what the compiler should do; these say what the program
// should print, which is the only thing a user cares about.  A program is built at
// random, worked out here in TypeScript with the language's arithmetic, and then
// compiled — so any disagreement is a bug in the compiler and not in a comparison
// between two of its own configurations.

const SIZE = 16;
const VARS = ["v0", "v1", "v2", "v3"];
const CONSTANTS = [0n, 1n, 2n, 3n, 7n, 8n, 15n, 16n, 100n, 4095n, 4096n, 65536n, -1n, -8n, 1n << 40n];
const ARGUMENTS: [bigint, bigint, bigint][] = [
  [0n, 0n, 0n],
  [1n, 2n, 3n],
  [-1n, 7n, -13n],
  [(1n << 63n) - 1n, -(1n << 63n), 2n],
];
const COMPARISONS = ["=", "<>", "<", "<=", ">", ">="];

const wrap = (v: bigint): bigint => BigInt.asIntN(64, v);

/** `~` is applied to a literal, and the most negative one does not fit as one. */
export const literal = (value: bigint): string =>
  value < 0n ? `~${-value}` : String(value);

/** A seeded generator, because `Math.random` cannot be given one. */
class Rng {
  private state: number;
  constructor(seed: number) { this.state = seed >>> 0; }

  next(): number {
    // mulberry32
    this.state = (this.state + 0x6d2b79f5) >>> 0;
    let t = this.state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  int(bound: number): number { return Math.floor(this.next() * bound); }

  pick<T>(list: readonly T[]): T { return list[this.int(list.length)]!; }
}

export const compare = (op: string, a: bigint, b: bigint): boolean => {
  switch (op) {
    case "=": return a === b;
    case "<>": return a !== b;
    case "<": return a < b;
    case "<=": return a <= b;
    case ">": return a > b;
    default: return a >= b;
  }
};

// -- expressions ---------------------------------------------------------------

type Node =
  | { kind: "num"; value: bigint }
  | { kind: "read"; name: string }
  | { kind: "bin"; op: string; lhs: Node; rhs: Node }
  | { kind: "choose"; op: string; x: Node; y: Node; then: Node; els: Node }
  | { kind: "get"; where: Node };

class DividedByZero extends Error {}

/** `+` four times as often as `/`, so a program is mostly arithmetic. */
function weightedOp(rng: Rng): string {
  const ops: [string, number][] = [["+", 4], ["-", 3], ["*", 3], ["/", 1], ["mod", 1]];
  let roll = rng.int(ops.reduce((n, [, w]) => n + w, 0));
  for (const [op, w] of ops) {
    roll -= w;
    if (roll < 0) return op;
  }
  return "+";
}

function expression(rng: Rng, depth: number): Node {
  if (depth === 0 || rng.next() < 0.25) {
    if (rng.next() < 0.5) return { kind: "read", name: rng.pick(["a", "b", "c"]) };
    return { kind: "num", value: rng.pick(CONSTANTS) };
  }
  if (rng.next() < 0.1) {
    return {
      kind: "choose",
      op: rng.pick(COMPARISONS),
      x: expression(rng, depth - 1),
      y: expression(rng, depth - 1),
      then: expression(rng, depth - 1),
      els: expression(rng, depth - 1),
    };
  }
  return {
    kind: "bin",
    op: weightedOp(rng),
    lhs: expression(rng, depth - 1),
    rhs: expression(rng, depth - 1),
  };
}

function evaluate(node: Node, env: Map<string, bigint>): bigint {
  switch (node.kind) {
    case "read": return env.get(node.name)!;
    case "num": return node.value;
    case "choose": {
      const taken = compare(node.op, evaluate(node.x, env), evaluate(node.y, env));
      return evaluate(taken ? node.then : node.els, env);
    }
    case "bin": {
      const a = evaluate(node.lhs, env);
      const b = evaluate(node.rhs, env);
      if (node.op === "+") return wrap(a + b);
      if (node.op === "-") return wrap(a - b);
      if (node.op === "*") return wrap(a * b);
      if (b === 0n) throw new DividedByZero();
      return wrap(node.op === "/" ? a / b : a % b);
    }
    default: throw new Error("an array read has no meaning here");
  }
}

function show(node: Node): string {
  switch (node.kind) {
    case "read": return node.name;
    case "num": return literal(node.value);
    case "choose":
      return `(if ${show(node.x)} ${node.op} ${show(node.y)} `
        + `then ${show(node.then)} else ${show(node.els)})`;
    case "bin": return `(${show(node.lhs)} ${node.op} ${show(node.rhs)})`;
    default: return `xs[index (${show(node.where)})]`;
  }
}

/** `count` functions of three arguments, and what they print. */
export function arithmetic(seed: number, count: number): [string, string] {
  const rng = new Rng(seed);
  const definitions: string[] = [];
  const calls: string[] = [];
  const expected: string[] = [];
  let made = 0;
  while (made < count) {
    const tree = expression(rng, 1 + rng.int(5));
    let values: bigint[];
    try {
      values = ARGUMENTS.map(([a, b, c]) =>
        evaluate(tree, new Map([["a", a], ["b", b], ["c", c]])),
      );
    } catch (e) {
      if (e instanceof DividedByZero) continue;
      throw e;
    }
    definitions.push(`fun f${made} (a : int, b : int, c : int) : int = ${show(tree)}`);
    ARGUMENTS.forEach(([a, b, c], at) => {
      const written = [a, b, c].map(literal).join(", ");
      calls.push(`val () = (printInt (f${made} (${written})); print ("\\n"))`);
      expected.push(String(values[at]!));
    });
    made += 1;
  }
  return [[...definitions, ...calls].join("\n") + "\n", expected.join("\n") + "\n"];
}

// -- statements ----------------------------------------------------------------

type Stmt =
  | { kind: "set"; name: string; value: Node }
  | { kind: "put"; where: Node; value: Node }
  | { kind: "seq"; items: Stmt[] }
  | { kind: "if"; op: string; x: Node; y: Node; then: Stmt; els: Stmt }
  | { kind: "for"; name: string; lo: number; hi: number; body: Stmt };

/** An expression over the variables in scope and the array. */
function place(rng: Rng, scope: string[]): Node {
  const roll = rng.next();
  if (roll < 0.35) return { kind: "read", name: rng.pick(scope) };
  if (roll < 0.5) return { kind: "num", value: rng.pick(CONSTANTS) };
  if (roll < 0.65) return { kind: "get", where: place(rng, scope) };
  return { kind: "bin", op: rng.pick(["+", "-", "*"]), lhs: place(rng, scope), rhs: place(rng, scope) };
}

function statement(rng: Rng, depth: number, scope: string[], fresh: { n: number }): Stmt {
  const roll = rng.next();
  if (depth > 0 && roll < 0.2) {
    return {
      kind: "if",
      op: rng.pick(COMPARISONS),
      x: place(rng, scope),
      y: place(rng, scope),
      then: statement(rng, depth - 1, scope, fresh),
      els: statement(rng, depth - 1, scope, fresh),
    };
  }
  if (depth > 0 && roll < 0.45) {
    fresh.n += 1;
    const name = `i${fresh.n}`;
    return {
      kind: "for", name, lo: rng.int(3), hi: 2 + rng.int(4),
      body: statement(rng, depth - 1, [...scope, name], fresh),
    };
  }
  if (depth > 0 && roll < 0.55) {
    return {
      kind: "seq",
      items: [statement(rng, depth - 1, scope, fresh), statement(rng, depth - 1, scope, fresh)],
    };
  }
  if (roll < 0.8) return { kind: "set", name: rng.pick(VARS), value: place(rng, scope) };
  return { kind: "put", where: place(rng, scope), value: place(rng, scope) };
}

/** `index` in the generated program: the remainder, made positive. */
const cell = (value: bigint): number => Number(((value % 16n) + 16n) % 16n);

function runPlace(node: Node, env: Map<string, bigint>, array: bigint[]): bigint {
  switch (node.kind) {
    case "read": return env.get(node.name)!;
    case "num": return node.value;
    case "get": return array[cell(runPlace(node.where, env, array))]!;
    case "bin": {
      const a = runPlace(node.lhs, env, array);
      const b = runPlace(node.rhs, env, array);
      if (node.op === "+") return wrap(a + b);
      if (node.op === "-") return wrap(a - b);
      return wrap(a * b);
    }
    default: throw new Error("a branch is not a place");
  }
}

function runStatement(node: Stmt, env: Map<string, bigint>, array: bigint[]): void {
  switch (node.kind) {
    case "set": env.set(node.name, runPlace(node.value, env, array)); return;
    case "put":
      array[cell(runPlace(node.where, env, array))] = runPlace(node.value, env, array);
      return;
    case "seq": for (const item of node.items) runStatement(item, env, array); return;
    case "if": {
      const a = runPlace(node.x, env, array);
      const b = runPlace(node.y, env, array);
      runStatement(compare(node.op, a, b) ? node.then : node.els, env, array);
      return;
    }
    default:
      for (let i = node.lo; i <= node.hi; i++) {
        env.set(node.name, BigInt(i));
        runStatement(node.body, env, array);
      }
  }
}

function showStatement(node: Stmt, indent: string): string {
  switch (node.kind) {
    case "set": return `${indent}${node.name} := ${show(node.value)}`;
    case "put": return `${indent}xs[index (${show(node.where)})] := ${show(node.value)}`;
    case "seq": {
      const inner = node.items.map((i) => showStatement(i, indent + "  ")).join(";\n");
      return `${indent}(\n${inner}\n${indent})`;
    }
    case "if":
      return `${indent}if ${show(node.x)} ${node.op} ${show(node.y)} then\n`
        + `${showStatement(node.then, indent + "  ")}\n${indent}else\n`
        + showStatement(node.els, indent + "  ");
    default:
      return `${indent}for ${node.name} = ${node.lo} to ${node.hi} do\n`
        + showStatement(node.body, indent + "  ");
  }
}

const PREAMBLE = `val xs = array (16, 0)
fun index (n : int) : int =
  let val r = n - n / 16 * 16 in
    if r < 0 then r + 16 else r
  end`;

/** A program of assignments, loops and branches over an array. */
export function imperative(seed: number, count: number): [string, string] {
  const rng = new Rng(seed);
  const fresh = { n: 0 };
  const body = Array.from({ length: count }, () => statement(rng, 3, VARS, fresh));
  const env = new Map(VARS.map((name) => [name, 0n] as const));
  const array = Array.from({ length: SIZE }, () => 0n);
  for (const item of body) runStatement(item, env, array);

  const expected = [
    ...VARS.map((name) => String(env.get(name)!)),
    ...array.map(String),
  ];
  const lines = [
    PREAMBLE,
    ...VARS.map((name) => `var ${name} = 0`),
    "val () = (",
    body.map((item) => showStatement(item, "  ")).join(";\n"),
    ")",
    ...VARS.map((name) => `val () = (printInt (${name}); print ("\\n"))`),
    'val () = for k = 0 to 15 do (printInt (xs[k]); print ("\\n"))',
  ];
  return [lines.join("\n") + "\n", expected.join("\n") + "\n"];
}
