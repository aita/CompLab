import { CATEGORIES, SPECS, type NodeData, type Spec } from "./spec";

// One thing to pick: either a whole node, or one operator of a node that
// stands for a family of them.  What lands on the canvas is the same node
// either way; a variant simply arrives with its operator already set.
interface Choice {
  key: string;
  type: string;
  label: string;
  glyph: string;
  color: string;
  hint: string;
  data?: NodeData;
}

function choicesOf(spec: Spec): Choice[] {
  if (!spec.variants) {
    return [
      {
        key: spec.type,
        type: spec.type,
        label: spec.title,
        glyph: spec.glyph,
        color: spec.color,
        hint: spec.hint,
      },
    ];
  }
  const { key, of } = spec.variants;
  return of.map((op) => ({
    key: `${spec.type}:${op.id}`,
    type: spec.type,
    label: op.short ?? op.name,
    glyph: op.sign ?? spec.glyph,
    color: spec.color,
    // The chip is narrow enough to cut a long name off, so the tooltip says
    // it in full before saying what the family is for.
    hint: `${op.name} — ${spec.hint}`,
    data: { [key]: op.id },
  }));
}

export default function Palette({
  onAdd,
}: {
  onAdd: (type: string, data?: NodeData) => void;
}) {
  const item = (c: Choice, className: string) => (
    <button
      key={c.key}
      className={className}
      title={c.hint}
      draggable
      onDragStart={(e) => {
        e.dataTransfer.setData(
          "application/ferret-node",
          JSON.stringify({ type: c.type, data: c.data }),
        );
        e.dataTransfer.effectAllowed = "move";
      }}
      onClick={() => onAdd(c.type, c.data)}
    >
      <span
        // A sign spelled out -- sqrt, floor, min -- needs more room in the
        // same square than one character does.
        className={"fnode-glyph" + (c.glyph.length > 1 ? " is-word" : "")}
        style={{ background: c.color }}
      >
        {c.glyph}
      </span>
      <span className="palette-label">{c.label}</span>
    </button>
  );

  return (
    <aside className="palette">
      <div className="palette-title">Nodes</div>
      {CATEGORIES.map((category) => (
        <div className="palette-group" key={category}>
          <div className="palette-group-title">{category}</div>
          {SPECS.filter((s) => s.category === category).map((spec) =>
            spec.variants ? (
              // A family gets its name as a heading and its operators laid out
              // underneath, so the operator is what you reach for.
              <div className="palette-family" key={spec.type}>
                <div className="palette-family-title">{spec.title}</div>
                <div className="palette-variants">
                  {choicesOf(spec).map((c) => item(c, "palette-chip"))}
                </div>
              </div>
            ) : (
              item(choicesOf(spec)[0], "palette-item")
            ),
          )}
        </div>
      ))}
      <p className="palette-note">
        Click to add, or drag onto the canvas. Square ports are the flow of
        execution, round ones are values. A number port with nothing plugged
        into it can be typed into. Right-click a node or a wire to duplicate or
        delete it.
      </p>
    </aside>
  );
}
