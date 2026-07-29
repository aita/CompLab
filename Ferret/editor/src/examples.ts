// The editor loads the very same files ferretc takes on the command line.
import count from "../../examples/count.json";
import wave from "../../examples/wave.json";
import bounce from "../../examples/bounce.json";
import blink from "../../examples/blink.json";
import walk from "../../examples/walk.json";
import pi from "../../examples/pi.json";

export interface Example {
  key: string;
  name: string;
  graph: { name?: string; nodes: unknown[]; edges: unknown[] };
}

/** What File > New starts you with: a feedback counting, and a way out. */
export function blank(): Example["graph"] & { name: string } {
  return {
    name: "Untitled",
    nodes: [
      {
        id: "held",
        type: "feedback",
        position: { x: 0, y: 0 },
        data: { name: "count", holds: "number", start: 0 },
      },
      {
        id: "plus",
        type: "binop",
        position: { x: 380, y: 200 },
        data: { op: "add", values: { b: 1 } },
      },
      {
        id: "out",
        type: "out",
        position: { x: 760, y: 0 },
        data: {},
      },
    ],
    edges: [
      {
        id: "held-plus",
        source: "held",
        sourceHandle: "out",
        target: "plus",
        targetHandle: "a",
      },
      {
        id: "plus-held",
        source: "plus",
        sourceHandle: "out",
        target: "held",
        targetHandle: "value",
      },
      {
        id: "held-out",
        source: "held",
        sourceHandle: "out",
        target: "out",
        targetHandle: "value",
      },
    ],
  };
}

export const EXAMPLES: Example[] = [
  { key: "count", name: count.name, graph: count },
  { key: "wave", name: wave.name, graph: wave },
  { key: "bounce", name: bounce.name, graph: bounce },
  { key: "blink", name: blink.name, graph: blink },
  { key: "walk", name: walk.name, graph: walk },
  { key: "pi", name: pi.name, graph: pi },
];
