import { CATEGORIES, SPECS } from "./spec";

export default function Palette({ onAdd }: { onAdd: (type: string) => void }) {
  return (
    <aside className="palette">
      <div className="palette-title">Nodes</div>
      {CATEGORIES.map((category) => (
        <div className="palette-group" key={category}>
          <div className="palette-group-title">{category}</div>
          {SPECS.filter((s) => s.category === category).map((spec) => (
            <button
              key={spec.type}
              className="palette-item"
              title={spec.hint}
              draggable
              onDragStart={(e) => {
                e.dataTransfer.setData("application/ferret-node", spec.type);
                e.dataTransfer.effectAllowed = "move";
              }}
              onClick={() => onAdd(spec.type)}
            >
              <span className="fnode-glyph" style={{ background: spec.color }}>
                {spec.glyph}
              </span>
              <span>{spec.title}</span>
            </button>
          ))}
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
