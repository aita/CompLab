// The editor loads the very same files ferretc takes on the command line.
import sum from "../../examples/sum.json";
import collatz from "../../examples/collatz.json";

export interface Example {
  key: string;
  name: string;
  graph: { nodes: unknown[]; edges: unknown[] };
}

export const EXAMPLES: Example[] = [
  { key: "sum", name: sum.name, graph: sum },
  { key: "collatz", name: collatz.name, graph: collatz },
];
