// The editor loads the very same files ferretc takes on the command line.
import sum from "../../examples/sum.json";
import collatz from "../../examples/collatz.json";
import montecarlo from "../../examples/montecarlo.json";

export interface Example {
  key: string;
  name: string;
  graph: { name?: string; nodes: unknown[]; edges: unknown[] };
}

/** What File > New starts you with: the two ends of a flow, already wired. */
export function blank(): Example["graph"] & { name: string } {
  return {
    name: "Untitled",
    nodes: [
      {
        id: "start",
        type: "start",
        position: { x: 0, y: 0 },
        data: { params: [{ name: "n" }] },
      },
      {
        id: "end",
        type: "end",
        position: { x: 400, y: 0 },
        data: { values: { value: 0 } },
      },
    ],
    edges: [
      {
        id: "start-end",
        source: "start",
        sourceHandle: "next",
        target: "end",
        targetHandle: "in",
      },
    ],
  };
}

export const EXAMPLES: Example[] = [
  { key: "sum", name: sum.name, graph: sum },
  { key: "collatz", name: collatz.name, graph: collatz },
  { key: "montecarlo", name: montecarlo.name, graph: montecarlo },
];
