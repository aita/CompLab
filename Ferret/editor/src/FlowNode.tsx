import { memo, useContext } from "react";
import {
  Handle,
  Position,
  useReactFlow,
  type Node,
  type NodeProps,
} from "@xyflow/react";
import { SPEC_BY_TYPE, describe, portValue, type NodeData } from "./spec";
import { ConnectedContext, ErrorContext, portKey } from "./errors";

export type FerretNode = Node<NodeData, string>;

// The header is 42px tall, so this is the line the flow runs along.
const HEADER_MID = 21;

// One renderer for every kind: the catalogue says which ports to draw, so a
// new node kind is an entry in `compiler/lib/spec.ml` and a case in the
// lowering next to it -- nothing here.
function FlowNode({ id, type, data, selected }: NodeProps<FerretNode>) {
  const spec = SPEC_BY_TYPE[type];
  const problems = useContext(ErrorContext).get(id);
  const connected = useContext(ConnectedContext);
  const { updateNodeData } = useReactFlow();
  if (!spec) return <div className="fnode">unknown node {type}</div>;

  // What this one node looks like -- its name, its sign, the ports it draws
  // -- is worked out by the compiler, which is also the thing that reads
  // those port ids back.
  const { title, glyph, badge, inputs, outputs } = describe(type, data);
  const headerExec = spec.execOut.length === 1 ? spec.execOut[0] : undefined;
  const bodyExec = headerExec ? [] : spec.execOut;

  const setPortValue = (port: string, text: string) => {
    const values = { ...((data.values as Record<string, number>) ?? {}) };
    if (text === "") delete values[port];
    else values[port] = Number(text);
    updateNodeData(id, { values });
  };

  return (
    <div
      className={
        "fnode" +
        (selected ? " is-selected" : "") +
        (problems ? " is-bad" : "") +
        (data.breakpoint ? " is-watched" : "")
      }
      title={problems?.join("\n")}
    >
      {spec.execIn && (
        <Handle
          id="in"
          type="target"
          position={Position.Left}
          className="handle handle-exec"
          style={{ top: HEADER_MID }}
        />
      )}
      {headerExec && (
        <Handle
          id={headerExec.id}
          type="source"
          position={Position.Right}
          className="handle handle-exec"
          style={{ top: HEADER_MID }}
        />
      )}

      <div className="fnode-head">
        <span
          className={"fnode-glyph" + (glyph.length > 1 ? " is-word" : "")}
          style={{ background: spec.color }}
        >
          {glyph}
        </span>
        <span className="fnode-title">{title}</span>
        {data.breakpoint === true && (
          <span className="fnode-dot" title="Breakpoint" />
        )}
        {badge !== null && badge !== "" && (
          <span className="fnode-badge">{badge}</span>
        )}
      </div>

      {spec.entry && (
        <div className="fnode-body fnode-entry">
          <input
            className="nodrag"
            spellCheck={false}
            placeholder={spec.entry.placeholder}
            value={String(data[spec.entry.key] ?? "")}
            onChange={(e) =>
              updateNodeData(id, { [spec.entry!.key]: e.target.value })
            }
          />
        </div>
      )}

      {bodyExec.length > 0 && (
        <div className="fnode-body fnode-flow">
          {bodyExec.map((p) => (
            <div className="port port-out port-exec" key={p.id}>
              <span className="port-label">{p.label}</span>
              <Handle
                id={p.id}
                type="source"
                position={Position.Right}
                className="handle handle-exec"
              />
            </div>
          ))}
        </div>
      )}

      {(inputs.length > 0 || outputs.length > 0) && (
        <div className="fnode-body">
          {inputs.map((p) => {
            // An unconnected number port is a place to type one into.
            const open = p.kind === "num" && !connected.has(portKey(id, p.id));
            return (
              <div className="port port-in" key={p.id}>
                <Handle
                  id={p.id}
                  type="target"
                  position={Position.Left}
                  className={`handle handle-${p.kind}`}
                />
                <span className="port-label">{p.label}</span>
                {open ? (
                  <input
                    className="port-value nodrag"
                    type="number"
                    step="any"
                    placeholder="—"
                    value={portValue(data, p.id) ?? ""}
                    onChange={(e) => setPortValue(p.id, e.target.value)}
                  />
                ) : (
                  <span className="port-type">
                    {p.kind === "bool" ? "bool" : "num"}
                  </span>
                )}
              </div>
            );
          })}
          {outputs.map((p) => (
            <div className="port port-out" key={p.id}>
              <span className="port-label">{p.label}</span>
              <span className="port-type">
                {p.kind === "bool" ? "bool" : "num"}
              </span>
              <Handle
                id={p.id}
                type="source"
                position={Position.Right}
                className={`handle handle-${p.kind}`}
              />
            </div>
          ))}
        </div>
      )}

      {problems && <div className="fnode-error">{problems[0]}</div>}
    </div>
  );
}

export default memo(FlowNode);
