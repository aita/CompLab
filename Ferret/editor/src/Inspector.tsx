import { SPEC_BY_TYPE, describe, type NodeData } from "./spec";
import type { FerretNode } from "./FlowNode";

interface Props {
  node: FerretNode | undefined;
  problems: string[];
  onChange: (id: string, patch: NodeData) => void;
  onDelete: (id: string) => void;
}

export default function Inspector({
  node,
  problems,
  onChange,
  onDelete,
}: Props) {
  if (!node) {
    return (
      <div className="panel-empty">
        Pick a node to configure it here.
        <br />
        The start node's inputs and a loop's state slots are edited from this
        panel; everything else can be set on the card itself.
      </div>
    );
  }
  const spec = SPEC_BY_TYPE[node.type!];
  const data = node.data;
  const shown = describe(node.type!, data);
  const set = (patch: NodeData) => onChange(node.id, patch);

  return (
    <div className="inspector">
      <div className="inspector-head">
        <span className="fnode-glyph" style={{ background: spec.color }}>
          {shown.glyph}
        </span>
        <div>
          <div className="inspector-title">{shown.title}</div>
          <div className="inspector-id">{node.id}</div>
        </div>
      </div>
      <p className="inspector-hint">{spec.hint}</p>

      {problems.length > 0 && (
        <ul className="inspector-problems">
          {problems.map((p, i) => (
            <li key={i}>{p}</li>
          ))}
        </ul>
      )}

      {spec.fields.map((field) => {
        if (field.kind === "names") {
          const items = (data[field.key] as { name: string }[] | undefined) ?? [];
          return (
            <div className="field" key={field.key}>
              <label>{field.label}</label>
              {items.map((item, i) => (
                <div className="param-row" key={i}>
                  <input
                    value={item.name}
                    onChange={(e) =>
                      set({
                        [field.key]: items.map((q, j) =>
                          j === i ? { name: e.target.value } : q,
                        ),
                      })
                    }
                  />
                  <button
                    onClick={() =>
                      set({ [field.key]: items.filter((_, j) => j !== i) })
                    }
                    title={`Remove this ${field.itemLabel}`}
                  >
                    ×
                  </button>
                </div>
              ))}
              <button
                className="ghost"
                onClick={() =>
                  set({
                    [field.key]: [...items, { name: `x${items.length}` }],
                  })
                }
              >
                + Add {field.itemLabel}
              </button>
            </div>
          );
        }
        if (field.kind === "select") {
          return (
            <div className="field" key={field.key}>
              <label>{field.label}</label>
              <select
                value={String(data[field.key] ?? "")}
                onChange={(e) => set({ [field.key]: e.target.value })}
              >
                {field.options.map(([value, label]) => (
                  <option key={value} value={value}>
                    {label}
                  </option>
                ))}
              </select>
            </div>
          );
        }
        if (field.kind === "text") {
          return (
            <div className="field" key={field.key}>
              <label>{field.label}</label>
              <input
                value={String(data[field.key] ?? "")}
                spellCheck={false}
                onChange={(e) => set({ [field.key]: e.target.value })}
              />
            </div>
          );
        }
        return (
          <div className="field" key={field.key}>
            <label>{field.label}</label>
            <input
              type="number"
              step="any"
              value={String(data[field.key] ?? 0)}
              onChange={(e) => set({ [field.key]: Number(e.target.value) })}
            />
          </div>
        );
      })}

      {!spec.unique && (
        <button className="danger" onClick={() => onDelete(node.id)}>
          Delete this node
        </button>
      )}
    </div>
  );
}
