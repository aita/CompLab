// The node catalogue.  Everything the editor knows about a node kind lives
// here: its ports, its colour, the fields the inspector shows.  The port ids
// are the ones the OCaml compiler reads out of `sourceHandle` /
// `targetHandle`, so they are not decoration.

export type PortKind = "exec" | "num" | "bool";

export interface Port {
  id: string;
  label: string;
  kind: PortKind;
}

export type Field =
  | { key: string; label: string; kind: "number" }
  | { key: string; label: string; kind: "text" }
  | { key: string; label: string; kind: "select"; options: [string, string][] }
  | { key: string; label: string; kind: "names"; itemLabel: string };

export interface NodeData {
  [key: string]: unknown;
}

export interface Spec {
  type: string;
  /** The palette label: the family the node belongs to. */
  title: string;
  /** What the card says once an operator is picked: Arithmetic becomes Multiply. */
  titleOf?: (d: NodeData) => string;
  glyph: string;
  /** The sign in the icon, where the operator has one. */
  glyphOf?: (d: NodeData) => string;
  color: string;
  category: "Flow" | "Operators" | "Values";
  hint: string;
  execIn: boolean;
  execOut: Port[];
  inputs: Port[] | ((d: NodeData) => Port[]);
  outputs: Port[] | ((d: NodeData) => Port[]);
  data: NodeData;
  fields: Field[];
  unique?: boolean;
  badge?: (d: NodeData) => string | undefined;
}

// A start node's inputs and a loop's state slots are both edited as a list of
// names, and both turn into `var:<name>` output ports.
export function names(d: NodeData, key: string): string[] {
  const list = (d[key] as { name?: string }[] | undefined) ?? [];
  return list.map((x) => x?.name ?? "").filter((s) => s !== "");
}

/** A number typed into a port rather than fed to it by an edge. */
export function portValue(d: NodeData, port: string): number | undefined {
  const values = d.values as Record<string, number> | undefined;
  const v = values?.[port];
  return typeof v === "number" ? v : undefined;
}

const NEXT: Port[] = [{ id: "next", label: "next", kind: "exec" }];

// Each operator carries the name the card shows and, where there is one, the
// sign that goes in the icon.  The dropdown is built from the same table, so
// what you pick and what the node then calls itself cannot drift apart.
interface Op {
  id: string;
  name: string;
  sign?: string;
}

const ARITH: Op[] = [
  { id: "add", name: "Add", sign: "+" },
  { id: "sub", name: "Subtract", sign: "−" },
  { id: "mul", name: "Multiply", sign: "×" },
  { id: "div", name: "Divide", sign: "÷" },
  { id: "mod", name: "Remainder", sign: "%" },
  { id: "min", name: "Minimum", sign: "min" },
  { id: "max", name: "Maximum", sign: "max" },
];

const FUNCS: Op[] = [
  { id: "neg", name: "Negate", sign: "neg" },
  { id: "abs", name: "Absolute value", sign: "abs" },
  { id: "sqrt", name: "Square root", sign: "sqrt" },
  { id: "floor", name: "Round down", sign: "floor" },
  { id: "ceil", name: "Round up", sign: "ceil" },
  { id: "round", name: "Round", sign: "round" },
];

const CMPS: Op[] = [
  { id: "lt", name: "Less than", sign: "<" },
  { id: "le", name: "At most", sign: "≤" },
  { id: "gt", name: "Greater than", sign: ">" },
  { id: "ge", name: "At least", sign: "≥" },
  { id: "eq", name: "Equal", sign: "=" },
  { id: "ne", name: "Not equal", sign: "≠" },
];

const LOGIC: Op[] = [
  { id: "and", name: "And", sign: "and" },
  { id: "or", name: "Or", sign: "or" },
  { id: "not", name: "Not", sign: "not" },
];

const options = (ops: Op[]): [string, string][] =>
  ops.map((o) => [o.id, o.sign ? `${o.name}  ${o.sign}` : o.name]);

const named = (ops: Op[], fallback: string) => (d: NodeData) =>
  ops.find((o) => o.id === d.op)?.name ?? fallback;

const signed = (ops: Op[], fallback: string) => (d: NodeData) =>
  ops.find((o) => o.id === d.op)?.sign ?? fallback;

export const SPECS: Spec[] = [
  {
    type: "start",
    title: "Start",
    glyph: "▶",
    color: "#12b76a",
    category: "Flow",
    hint: "Where the flow begins. Its inputs are the exported function's parameters.",
    execIn: false,
    execOut: NEXT,
    inputs: [],
    outputs: (d) =>
      names(d, "params").map((n) => ({
        id: `var:${n}`,
        label: n,
        kind: "num" as const,
      })),
    data: { params: [{ name: "n" }] },
    fields: [
      { key: "params", label: "Inputs", kind: "names", itemLabel: "input" },
    ],
    unique: true,
  },
  {
    type: "end",
    title: "End",
    glyph: "■",
    color: "#f79009",
    category: "Flow",
    hint: "Return a value and stop.",
    execIn: true,
    execOut: [],
    inputs: [{ id: "value", label: "result", kind: "num" }],
    outputs: [],
    data: {},
    fields: [],
  },
  {
    type: "while",
    title: "Loop",
    glyph: "↻",
    color: "#f04438",
    category: "Flow",
    hint: "The only node that holds state. While the condition is true, every slot is replaced by its next value, all at once.",
    execIn: true,
    execOut: [
      { id: "body", label: "each pass", kind: "exec" },
      { id: "next", label: "after the loop", kind: "exec" },
    ],
    inputs: (d) => [
      { id: "cond", label: "while", kind: "bool" as const },
      ...names(d, "states").flatMap((n) => [
        { id: `init:${n}`, label: `${n} starts at`, kind: "num" as const },
        { id: `step:${n}`, label: `${n} becomes`, kind: "num" as const },
      ]),
    ],
    outputs: (d) =>
      names(d, "states").map((n) => ({
        id: `var:${n}`,
        label: n,
        kind: "num" as const,
      })),
    data: { states: [{ name: "i" }], values: { "init:i": 0 } },
    fields: [{ key: "states", label: "State", kind: "names", itemLabel: "slot" }],
  },
  {
    type: "for",
    title: "Count",
    glyph: "i",
    color: "#f04438",
    category: "Flow",
    hint: "A loop that keeps the counter for you: it runs from `from` up to and including `to`, gaining `by` each pass. State slots work as they do on Loop, for whatever the count is adding up.",
    execIn: true,
    execOut: [
      { id: "body", label: "each pass", kind: "exec" },
      { id: "next", label: "after the loop", kind: "exec" },
    ],
    inputs: (d) => [
      { id: "from", label: "from", kind: "num" as const },
      { id: "to", label: "to (included)", kind: "num" as const },
      { id: "by", label: "by", kind: "num" as const },
      ...names(d, "states").flatMap((n) => [
        { id: `init:${n}`, label: `${n} starts at`, kind: "num" as const },
        { id: `step:${n}`, label: `${n} becomes`, kind: "num" as const },
      ]),
    ],
    outputs: (d) => [
      { id: "i", label: String(d.name ?? "i"), kind: "num" as const },
      ...names(d, "states").map((n) => ({
        id: `var:${n}`,
        label: n,
        kind: "num" as const,
      })),
    ],
    data: {
      name: "i",
      states: [],
      values: { from: 1, to: 10, by: 1 },
    },
    fields: [
      { key: "name", label: "Counter", kind: "text" },
      { key: "states", label: "State", kind: "names", itemLabel: "slot" },
    ],
  },
  {
    type: "select",
    title: "Choose",
    glyph: "?",
    color: "#f04438",
    category: "Flow",
    hint: "The only branch there is: pick one of two numbers by a condition. Both are evaluated, which is safe because nothing in an expression has an effect.",
    execIn: false,
    execOut: [],
    inputs: [
      { id: "cond", label: "if", kind: "bool" },
      { id: "a", label: "then", kind: "num" },
      { id: "b", label: "else", kind: "num" },
    ],
    outputs: [{ id: "out", label: "result", kind: "num" }],
    data: {},
    fields: [],
  },
  {
    type: "log",
    title: "Log",
    glyph: "✎",
    color: "#0ba5ec",
    category: "Flow",
    hint: "Hand a value to the host. In the module this is a call to env.log.",
    execIn: true,
    execOut: NEXT,
    inputs: [{ id: "value", label: "value", kind: "num" }],
    outputs: [],
    data: {},
    fields: [],
  },
  {
    type: "const",
    title: "Constant",
    glyph: "#",
    color: "#667085",
    category: "Values",
    hint: "One f64.const, for when the same number is wanted in several places. A single use can be typed into the port instead.",
    execIn: false,
    execOut: [],
    inputs: [],
    outputs: [{ id: "out", label: "value", kind: "num" }],
    data: { value: 0 },
    fields: [{ key: "value", label: "Value", kind: "number" }],
    badge: (d) => String(d.value ?? 0),
  },
  {
    type: "random",
    title: "Random",
    glyph: "~",
    color: "#ee46bc",
    category: "Values",
    hint: "A number in [min, max), drawn from the host. The one impure node: it is drawn once each time the node is reached, and every reader of that node sees the same draw.",
    execIn: false,
    execOut: [],
    inputs: [
      { id: "min", label: "min", kind: "num" },
      { id: "max", label: "max", kind: "num" },
    ],
    outputs: [{ id: "out", label: "value", kind: "num" }],
    data: { values: { min: 0, max: 1 } },
    fields: [],
  },
  {
    type: "binop",
    title: "Arithmetic",
    titleOf: named(ARITH, "Arithmetic"),
    glyph: "+",
    glyphOf: signed(ARITH, "+"),
    color: "#2e90fa",
    category: "Operators",
    hint: "Combine two numbers.",
    execIn: false,
    execOut: [],
    inputs: [
      { id: "a", label: "A", kind: "num" },
      { id: "b", label: "B", kind: "num" },
    ],
    outputs: [{ id: "out", label: "result", kind: "num" }],
    data: { op: "add" },
    fields: [
      { key: "op", label: "Operator", kind: "select", options: options(ARITH) },
    ],
  },
  {
    type: "unop",
    title: "Math function",
    titleOf: named(FUNCS, "Math function"),
    glyph: "ƒ",
    color: "#2e90fa",
    category: "Operators",
    hint: "A built-in that takes one number.",
    execIn: false,
    execOut: [],
    inputs: [{ id: "a", label: "A", kind: "num" }],
    outputs: [{ id: "out", label: "result", kind: "num" }],
    data: { op: "abs" },
    fields: [
      { key: "op", label: "Function", kind: "select", options: options(FUNCS) },
    ],
  },
  {
    type: "compare",
    title: "Comparison",
    titleOf: named(CMPS, "Comparison"),
    glyph: "<",
    glyphOf: signed(CMPS, "<"),
    color: "#7a5af8",
    category: "Operators",
    hint: "Compare two numbers and produce true or false.",
    execIn: false,
    execOut: [],
    inputs: [
      { id: "a", label: "A", kind: "num" },
      { id: "b", label: "B", kind: "num" },
    ],
    outputs: [{ id: "out", label: "result", kind: "bool" }],
    data: { op: "lt" },
    fields: [
      { key: "op", label: "Test", kind: "select", options: options(CMPS) },
    ],
  },
  {
    type: "logic",
    title: "Logic",
    titleOf: named(LOGIC, "Logic"),
    glyph: "&",
    color: "#7a5af8",
    category: "Operators",
    hint: "Combine true and false. And and Or evaluate both sides.",
    execIn: false,
    execOut: [],
    inputs: (d) =>
      d.op === "not"
        ? [{ id: "a", label: "A", kind: "bool" as const }]
        : [
            { id: "a", label: "A", kind: "bool" as const },
            { id: "b", label: "B", kind: "bool" as const },
          ],
    outputs: [{ id: "out", label: "result", kind: "bool" }],
    data: { op: "and" },
    fields: [
      { key: "op", label: "Operator", kind: "select", options: options(LOGIC) },
    ],
  },
];

export const SPEC_BY_TYPE: Record<string, Spec> = Object.fromEntries(
  SPECS.map((s) => [s.type, s]),
);

export const CATEGORIES = ["Flow", "Operators", "Values"] as const;

export function ports(list: Spec["inputs"], data: NodeData): Port[] {
  return typeof list === "function" ? list(data) : list;
}

export function portKind(spec: Spec, data: NodeData, handle: string | null) {
  if (!handle) return undefined;
  const all = [
    ...spec.execOut,
    ...(spec.execIn ? [{ id: "in", kind: "exec" as const, label: "" }] : []),
    ...ports(spec.inputs, data),
    ...ports(spec.outputs, data),
  ];
  return all.find((p) => p.id === handle)?.kind;
}
