import { CATEGORIES, SPECS } from "./spec";

export default function Palette({ onAdd }: { onAdd: (type: string) => void }) {
  return (
    <aside className="palette">
      <div className="palette-title">ノード</div>
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
        クリックで追加、ドラッグでも置けます。四角い端子が実行の流れ、丸い端子が値です。
      </p>
    </aside>
  );
}
