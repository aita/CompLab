import { SPEC_BY_TYPE, type NodeData } from "./spec";
import type { FerretNode } from "./FlowNode";

interface Props {
  node: FerretNode | undefined;
  variables: string[];
  problems: string[];
  onChange: (id: string, patch: NodeData) => void;
  onDelete: (id: string) => void;
}

export default function Inspector({
  node,
  variables,
  problems,
  onChange,
  onDelete,
}: Props) {
  if (!node) {
    return (
      <div className="panel-empty">
        ノードを選ぶとここで設定できます。
        <br />
        開始ノードを選べば、実行時の入力を増やせます。
      </div>
    );
  }
  const spec = SPEC_BY_TYPE[node.type!];
  const data = node.data;
  const set = (patch: NodeData) => onChange(node.id, patch);
  const params = (data.params as { name: string }[]) ?? [];

  return (
    <div className="inspector">
      <div className="inspector-head">
        <span className="fnode-glyph" style={{ background: spec.color }}>
          {spec.glyph}
        </span>
        <div>
          <div className="inspector-title">{spec.title}</div>
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
        if (field.kind === "params") {
          return (
            <div className="field" key={field.key}>
              <label>{field.label}</label>
              {params.map((p, i) => (
                <div className="param-row" key={i}>
                  <input
                    value={p.name}
                    onChange={(e) => {
                      const next = params.map((q, j) =>
                        j === i ? { name: e.target.value } : q,
                      );
                      set({ params: next });
                    }}
                  />
                  <button
                    onClick={() =>
                      set({ params: params.filter((_, j) => j !== i) })
                    }
                    title="この入力を消す"
                  >
                    ×
                  </button>
                </div>
              ))}
              <button
                className="ghost"
                onClick={() =>
                  set({ params: [...params, { name: `x${params.length}` }] })
                }
              >
                + 入力を追加
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
        if (field.kind === "number") {
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
        }
        return (
          <div className="field" key={field.key}>
            <label>{field.label}</label>
            <input
              list="ferret-variables"
              value={String(data[field.key] ?? "")}
              onChange={(e) => set({ [field.key]: e.target.value })}
            />
            <datalist id="ferret-variables">
              {variables.map((v) => (
                <option key={v} value={v} />
              ))}
            </datalist>
          </div>
        );
      })}

      {!spec.unique && (
        <button className="danger" onClick={() => onDelete(node.id)}>
          このノードを削除
        </button>
      )}
    </div>
  );
}
