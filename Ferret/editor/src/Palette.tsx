import { useRef, useState } from "react";
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
    label: op.name,
    glyph: op.sign ?? spec.glyph,
    color: spec.color,
    hint: `${op.name} — ${spec.hint}`,
    data: { [key]: op.id },
  }));
}

// The whole catalogue, grouped the way the palette offers it: a category
// first, then the families inside it -- a family being one node kind that
// stands for a set of operators.
function groups(): { name: string; choices: Choice[] }[] {
  const out: { name: string; choices: Choice[] }[] = [];
  for (const category of CATEGORIES) {
    const here = SPECS.filter((s) => s.category === category);
    const plain = here.filter((s) => !s.variants).flatMap(choicesOf);
    if (plain.length > 0) out.push({ name: category, choices: plain });
    for (const spec of here.filter((s) => s.variants))
      out.push({
        name: `${category} · ${spec.title}`,
        choices: choicesOf(spec),
      });
  }
  return out;
}

export default function Palette({
  onAdd,
}: {
  onAdd: (type: string, data?: NodeData) => void;
}) {
  const all = groups();
  const [open, setOpen] = useState<string | null>(null);
  const [at, setAt] = useState({ left: 0, top: 0 });
  // Moving the pointer from a group to its menu crosses a gap, so closing
  // waits a moment for it to arrive rather than happening on the way.
  const closing = useRef<ReturnType<typeof setTimeout> | null>(null);

  const show = (name: string, row: DOMRect) => {
    if (closing.current) clearTimeout(closing.current);
    closing.current = null;
    setAt({
      left: row.right + 6,
      top: Math.min(row.top, Math.max(8, window.innerHeight - 360)),
    });
    setOpen(name);
  };
  const hide = () => {
    if (closing.current) clearTimeout(closing.current);
    closing.current = setTimeout(() => setOpen(null), 140);
  };
  const keep = () => {
    if (closing.current) clearTimeout(closing.current);
    closing.current = null;
  };

  const here = all.find((g) => g.name === open);

  return (
    <aside className="palette">
      <div className="palette-title">Nodes</div>

      {all.map((g) => (
        <button
          key={g.name}
          className={"palette-group-row" + (open === g.name ? " is-open" : "")}
          onMouseEnter={(e) => show(g.name, e.currentTarget.getBoundingClientRect())}
          onMouseLeave={hide}
          onClick={(e) =>
            open === g.name
              ? setOpen(null)
              : show(g.name, e.currentTarget.getBoundingClientRect())
          }
        >
          <span className="palette-label">{g.name}</span>
          <span className="palette-more">›</span>
        </button>
      ))}

      {here && (
        <div
          className="palette-menu"
          style={{ left: at.left, top: at.top }}
          onMouseEnter={keep}
          onMouseLeave={hide}
        >
          {here.choices.map((c) => (
            <button
              key={c.key}
              className="palette-choice"
              title={c.hint}
              draggable
              onDragStart={(e) => {
                e.dataTransfer.setData(
                  "application/ferret-node",
                  JSON.stringify({ type: c.type, data: c.data }),
                );
                e.dataTransfer.effectAllowed = "move";
                setOpen(null);
              }}
              onClick={() => {
                onAdd(c.type, c.data);
                setOpen(null);
              }}
            >
              <span
                // A sign spelled out -- sqrt, floor, min -- needs more room in
                // the same square than one character does.
                className={"fnode-glyph" + (c.glyph.length > 1 ? " is-word" : "")}
                style={{ background: c.color }}
              >
                {c.glyph}
              </span>
              <span className="palette-label">{c.label}</span>
            </button>
          ))}
        </div>
      )}

      <p className="palette-note">
        Hover a group and pick a node, then click it to add or drag it onto the
        canvas. A port's colour is what it carries: numbers, yes-or-nos, text.
        A number port with nothing plugged into it can be typed into.
        Right-click a node or a wire to duplicate or delete it.
      </p>
    </aside>
  );
}
