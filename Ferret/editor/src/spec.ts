// The node catalogue, as the compiler describes it.
//
// Everything the editor knows about a node kind -- its ports, its colour, the
// fields the inspector shows -- is defined in `compiler/lib/spec.ml` and
// arrives over the same bridge a compile does.  This file is the typed side
// of that: it parses what comes back and remembers the per-node answers.
//
// Nothing here decides anything.  A port id drawn on a card is the string the
// OCaml lowering reads out of `sourceHandle` / `targetHandle`, and it is the
// same string because it came from there.

import { rawDescribe, rawSpecs } from "./ferret";

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
  /** The family the node belongs to; a card names itself after its operator. */
  title: string;
  glyph: string;
  color: string;
  category: string;
  hint: string;
  execIn: boolean;
  execOut: Port[];
  /** The ports of the kind, before one node's own settings are read. */
  inputs: Port[];
  outputs: Port[];
  data: NodeData;
  fields: Field[];
  /** A line of text edited on the card, for a node that mostly *is* its text. */
  entry: { key: string; placeholder: string } | null;
  unique: boolean;
}

/** One node's own answers: what it is called, its sign, and its ports. */
export interface Described {
  title: string;
  glyph: string;
  badge: string | null;
  inputs: Port[];
  outputs: Port[];
}

const catalogue: { categories: string[]; nodes: Spec[] } = (() => {
  const raw = rawSpecs();
  return raw ? JSON.parse(raw) : { categories: [], nodes: [] };
})();

export const SPECS: Spec[] = catalogue.nodes;
export const CATEGORIES: string[] = catalogue.categories;

export const SPEC_BY_TYPE: Record<string, Spec> = Object.fromEntries(
  SPECS.map((s) => [s.type, s]),
);

// A card asks what it looks like on every render, so the answer is kept: the
// same settings give the same answer, and settings only change on an edit.
const described = new Map<string, Described>();

export function describe(type: string, data: NodeData): Described {
  const settings = JSON.stringify(data ?? {});
  const key = `${type} ${settings}`;
  const known = described.get(key);
  if (known) return known;
  const raw = rawDescribe(type, settings);
  const spec = SPEC_BY_TYPE[type];
  const answer: Described = raw
    ? JSON.parse(raw)
    : {
        title: spec?.title ?? type,
        glyph: spec?.glyph ?? "?",
        badge: null,
        inputs: spec?.inputs ?? [],
        outputs: spec?.outputs ?? [],
      };
  if (described.size > 400) described.clear();
  described.set(key, answer);
  return answer;
}

/** A number typed into a port rather than fed to it by an edge. */
export function portValue(d: NodeData, port: string): number | undefined {
  const values = d.values as Record<string, number> | undefined;
  const v = values?.[port];
  return typeof v === "number" ? v : undefined;
}

export function portKind(
  type: string | undefined,
  data: NodeData,
  handle: string | null,
): PortKind | undefined {
  if (!handle || !type) return undefined;
  const spec = SPEC_BY_TYPE[type];
  if (!spec) return undefined;
  const node = describe(type, data);
  const all = [
    ...spec.execOut,
    ...(spec.execIn ? [{ id: "in", kind: "exec" as const, label: "" }] : []),
    ...node.inputs,
    ...node.outputs,
  ];
  return all.find((p) => p.id === handle)?.kind;
}
