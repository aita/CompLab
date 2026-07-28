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
  | { key: string; label: string; kind: "variable" }
  | { key: string; label: string; kind: "select"; options: [string, string][] }
  | { key: "params"; label: string; kind: "params" };

export interface NodeData {
  [key: string]: unknown;
}

export interface Spec {
  type: string;
  title: string;
  glyph: string;
  color: string;
  category: "フロー" | "変数" | "計算" | "値";
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

const NEXT: Port[] = [{ id: "next", label: "次へ", kind: "exec" }];

const ARITH: [string, string][] = [
  ["add", "+  たす"],
  ["sub", "−  ひく"],
  ["mul", "×  かける"],
  ["div", "÷  わる"],
  ["mod", "%  あまり"],
  ["min", "min  小さいほう"],
  ["max", "max  大きいほう"],
];

const ARITH_SIGN: Record<string, string> = {
  add: "+",
  sub: "−",
  mul: "×",
  div: "÷",
  mod: "%",
  min: "min",
  max: "max",
};

const FUNCS: [string, string][] = [
  ["neg", "neg  符号を反転"],
  ["abs", "abs  絶対値"],
  ["sqrt", "sqrt  平方根"],
  ["floor", "floor  切り捨て"],
  ["ceil", "ceil  切り上げ"],
  ["round", "round  四捨五入"],
];

const CMPS: [string, string][] = [
  ["lt", "<   より小さい"],
  ["le", "≤   以下"],
  ["gt", ">   より大きい"],
  ["ge", "≥   以上"],
  ["eq", "=   等しい"],
  ["ne", "≠   等しくない"],
];

const CMP_SIGN: Record<string, string> = {
  lt: "<",
  le: "≤",
  gt: ">",
  ge: "≥",
  eq: "=",
  ne: "≠",
};

const LOGIC: [string, string][] = [
  ["and", "かつ (and)"],
  ["or", "または (or)"],
  ["not", "でない (not)"],
];

export const SPECS: Spec[] = [
  {
    type: "start",
    title: "開始",
    glyph: "▶",
    color: "#12b76a",
    category: "フロー",
    hint: "ここから実行が始まる。入力がそのまま wasm の引数になる",
    execIn: false,
    execOut: NEXT,
    inputs: [],
    outputs: (d) =>
      ((d.params as { name: string }[]) ?? []).map((p) => ({
        id: `var:${p.name}`,
        label: p.name,
        kind: "num" as const,
      })),
    data: { params: [{ name: "n" }] },
    fields: [{ key: "params", label: "入力", kind: "params" }],
    unique: true,
  },
  {
    type: "end",
    title: "終了",
    glyph: "■",
    color: "#f79009",
    category: "フロー",
    hint: "値を返して実行を終える",
    execIn: true,
    execOut: [],
    inputs: [{ id: "value", label: "戻り値", kind: "num" }],
    outputs: [],
    data: {},
    fields: [],
  },
  {
    type: "if",
    title: "条件分岐",
    glyph: "⑂",
    color: "#f04438",
    category: "フロー",
    hint: "条件で流れを分け、どちらの枝も終わったら「次へ」に合流する",
    execIn: true,
    execOut: [
      { id: "then", label: "true のとき", kind: "exec" },
      { id: "else", label: "false のとき", kind: "exec" },
      { id: "next", label: "合流して次へ", kind: "exec" },
    ],
    inputs: [{ id: "cond", label: "条件", kind: "bool" }],
    outputs: [],
    data: {},
    fields: [],
  },
  {
    type: "while",
    title: "繰り返し",
    glyph: "↻",
    color: "#f04438",
    category: "フロー",
    hint: "条件が true のあいだ「本体」を繰り返す",
    execIn: true,
    execOut: [
      { id: "body", label: "本体", kind: "exec" },
      { id: "next", label: "抜けたら次へ", kind: "exec" },
    ],
    inputs: [{ id: "cond", label: "条件", kind: "bool" }],
    outputs: [],
    data: {},
    fields: [],
  },
  {
    type: "log",
    title: "ログ出力",
    glyph: "✎",
    color: "#0ba5ec",
    category: "フロー",
    hint: "値をホストに渡す。wasm から見ると env.log の呼び出し",
    execIn: true,
    execOut: NEXT,
    inputs: [{ id: "value", label: "値", kind: "num" }],
    outputs: [],
    data: {},
    fields: [],
  },
  {
    type: "set",
    title: "変数に代入",
    glyph: "=",
    color: "#6172f3",
    category: "変数",
    hint: "変数を書き換える。初出の名前はその場で f64 のローカルになる",
    execIn: true,
    execOut: NEXT,
    inputs: [{ id: "value", label: "値", kind: "num" }],
    outputs: [],
    data: { name: "x" },
    fields: [{ key: "name", label: "変数名", kind: "variable" }],
    badge: (d) => String(d.name ?? ""),
  },
  {
    type: "get",
    title: "変数を読む",
    glyph: "x",
    color: "#6172f3",
    category: "変数",
    hint: "変数の現在の値。まだ代入されていなければ 0",
    execIn: false,
    execOut: [],
    inputs: [],
    outputs: [{ id: "out", label: "値", kind: "num" }],
    data: { name: "x" },
    fields: [{ key: "name", label: "変数名", kind: "variable" }],
    badge: (d) => String(d.name ?? ""),
  },
  {
    type: "const",
    title: "定数",
    glyph: "#",
    color: "#667085",
    category: "値",
    hint: "そのまま f64.const になる",
    execIn: false,
    execOut: [],
    inputs: [],
    outputs: [{ id: "out", label: "値", kind: "num" }],
    data: { value: 0 },
    fields: [{ key: "value", label: "値", kind: "number" }],
    badge: (d) => String(d.value ?? 0),
  },
  {
    type: "binop",
    title: "計算",
    glyph: "+",
    color: "#2e90fa",
    category: "計算",
    hint: "2 つの数を組み合わせる",
    execIn: false,
    execOut: [],
    inputs: [
      { id: "a", label: "A", kind: "num" },
      { id: "b", label: "B", kind: "num" },
    ],
    outputs: [{ id: "out", label: "結果", kind: "num" }],
    data: { op: "add" },
    fields: [{ key: "op", label: "演算", kind: "select", options: ARITH }],
    badge: (d) => ARITH_SIGN[String(d.op)] ?? String(d.op),
  },
  {
    type: "unop",
    title: "関数",
    glyph: "ƒ",
    color: "#2e90fa",
    category: "計算",
    hint: "数を 1 つ受け取る組み込み関数",
    execIn: false,
    execOut: [],
    inputs: [{ id: "a", label: "A", kind: "num" }],
    outputs: [{ id: "out", label: "結果", kind: "num" }],
    data: { op: "abs" },
    fields: [{ key: "op", label: "関数", kind: "select", options: FUNCS }],
    badge: (d) => String(d.op ?? ""),
  },
  {
    type: "compare",
    title: "比較",
    glyph: "<",
    color: "#7a5af8",
    category: "計算",
    hint: "数どうしを比べて true / false を出す",
    execIn: false,
    execOut: [],
    inputs: [
      { id: "a", label: "A", kind: "num" },
      { id: "b", label: "B", kind: "num" },
    ],
    outputs: [{ id: "out", label: "結果", kind: "bool" }],
    data: { op: "lt" },
    fields: [{ key: "op", label: "比較", kind: "select", options: CMPS }],
    badge: (d) => CMP_SIGN[String(d.op)] ?? String(d.op),
  },
  {
    type: "logic",
    title: "論理",
    glyph: "&",
    color: "#7a5af8",
    category: "計算",
    hint: "true / false を組み合わせる。and と or は両辺とも評価される",
    execIn: false,
    execOut: [],
    inputs: (d) =>
      d.op === "not"
        ? [{ id: "a", label: "A", kind: "bool" as const }]
        : [
            { id: "a", label: "A", kind: "bool" as const },
            { id: "b", label: "B", kind: "bool" as const },
          ],
    outputs: [{ id: "out", label: "結果", kind: "bool" }],
    data: { op: "and" },
    fields: [{ key: "op", label: "演算", kind: "select", options: LOGIC }],
    badge: (d) => String(d.op ?? ""),
  },
];

export const SPEC_BY_TYPE: Record<string, Spec> = Object.fromEntries(
  SPECS.map((s) => [s.type, s]),
);

export const CATEGORIES = ["フロー", "変数", "計算", "値"] as const;

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
