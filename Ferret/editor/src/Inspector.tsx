import { useContext } from "react";
import { SPEC_BY_TYPE, describe, portValue, type NodeData } from "./spec";
import { ConnectedContext, portKey } from "./errors";
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
  const connected = useContext(ConnectedContext);
  if (!node) {
    return (
      <div className="panel-empty">
        Pick a node to configure it here.
        <br />
        What a Feedback holds, and what an Input asks for, are set from this
        panel; a number wired to nothing can be typed into the card itself.
      </div>
    );
  }
  const spec = SPEC_BY_TYPE[node.type!];
  const data = node.data;
  const shown = describe(node.type!, data);
  const set = (patch: NodeData) => onChange(node.id, patch);

  // An input with nothing wired into it is a number to give, and the card's
  // own box is small and easy to miss -- an Expression's inputs are named by
  // whatever its text left free, so this is where you go looking for them.
  const open = shown.inputs.filter(
    (p) => p.kind === "num" && !connected.has(portKey(node.id, p.id)),
  );
  const setPortValue = (port: string, text: string) => {
    const values = { ...((data.values as Record<string, number>) ?? {}) };
    if (text === "") delete values[port];
    else values[port] = Number(text);
    set({ values });
  };

  return (
    <div className="inspector">
      <div className="inspector-head">
        <span
          className={"fnode-glyph" + (shown.glyph.length > 1 ? " is-word" : "")}
          style={{ background: spec.color }}
        >
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

      {shown.fields.map((field) => {
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

      {open.length > 0 && (
        <div className="field">
          <label>Inputs</label>
          {open.map((p) => (
            <div className="param-row" key={p.id}>
              <span className="input-name">{p.label}</span>
              <input
                type="number"
                step="any"
                placeholder="—"
                value={portValue(data, p.id) ?? ""}
                onChange={(e) => setPortValue(p.id, e.target.value)}
              />
            </div>
          ))}
        </div>
      )}

      {!spec.unique && (
        <button className="danger" onClick={() => onDelete(node.id)}>
          Delete this node
        </button>
      )}
    </div>
  );
}
