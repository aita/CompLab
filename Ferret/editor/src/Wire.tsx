import {
  BaseEdge,
  getBezierPath,
  type EdgeProps,
  type Position,
} from "@xyflow/react";

export interface WireData {
  color: string;
  /** Feeds a Feedback: what goes along it is not read until the next cook. */
  later: boolean;
  /** Dimmed because it does not touch the selected node. */
  faded: boolean;
  [key: string]: unknown;
}

// A wire in the Blueprint sense: one curve that leaves horizontally and
// arrives horizontally, drawn twice.  The first pass is a wider stroke in the
// canvas colour, which cuts a gap wherever wires cross, so the one in front
// stays readable instead of the two merging into a knot.  The second is the
// wire itself.
interface Ends {
  sourceX: number;
  sourceY: number;
  sourcePosition: Position;
  targetX: number;
  targetY: number;
  targetPosition: Position;
}

// A wire that runs backwards feeds something to the left of what made it,
// and when the nodes it joins are side by side it would come back along the
// very line they sit on -- a straight stroke through the row, which is the
// one shape a wire that doubles back must not have.  Those take a route of their own: out to the right, up and over
// at a height of their own, then down into the target from the left.  Both
// ends still leave and arrive horizontally, so it reads as one stroke.
function route(e: Ends): string {
  // Strictly backwards: a short forward hop between two cards that nearly
  // touch is a straight line and wants to stay one, not go over the top.
  const backwards = e.targetX < e.sourceX + 4;
  // Only a wire that comes back along the row it left needs the detour.  One
  // that also changes height already reads as a curve, and sending it over
  // the top would take it further from the nodes it belongs to, not closer.
  const level = Math.abs(e.sourceY - e.targetY) < 56;
  if (!backwards || !level) {
    const [path] = getBezierPath({ ...e, curvature: backwards ? 0.6 : 0.35 });
    return path;
  }
  const reach = 36;
  const clear = 56 + Math.min(60, Math.abs(e.sourceX - e.targetX) * 0.06);
  // Over the top when the two ends are level or the target is higher, which
  // is where a row of nodes leaves room; under the bottom otherwise.
  const over = e.targetY <= e.sourceY + 24;
  const apex = over
    ? Math.min(e.sourceY, e.targetY) - clear
    : Math.max(e.sourceY, e.targetY) + clear;
  const out = e.sourceX + reach;
  const into = e.targetX - reach;
  const mid = (out + into) / 2;
  return [
    `M ${e.sourceX},${e.sourceY}`,
    `C ${out},${e.sourceY} ${out},${apex} ${mid},${apex}`,
    `C ${into},${apex} ${into},${e.targetY} ${e.targetX},${e.targetY}`,
  ].join(" ");
}

export default function Wire({
  id,
  sourceX,
  sourceY,
  sourcePosition,
  targetX,
  targetY,
  targetPosition,
  data,
}: EdgeProps) {
  const { color, later, faded } = (data ?? {}) as WireData;
  const path = route({
    sourceX,
    sourceY,
    sourcePosition,
    targetX,
    targetY,
    targetPosition,
  });
  return (
    <g className={"wire" + (faded ? " is-faded" : "")}>
      <path className="wire-casing" d={path} strokeWidth={6} />
      <BaseEdge
        id={id}
        path={path}
        style={{
          stroke: color,
          strokeWidth: 2,
          // The one wire in a graph that crosses from this cook to the next.
          strokeDasharray: later ? "7 5" : undefined,
        }}
      />
    </g>
  );
}
