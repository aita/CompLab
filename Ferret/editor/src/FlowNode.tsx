import { memo, useContext } from "react";
import { Handle, Position, type Node, type NodeProps } from "@xyflow/react";
import { SPEC_BY_TYPE, ports, type NodeData } from "./spec";
import { ErrorContext } from "./errors";

export type FerretNode = Node<NodeData, string>;

// One renderer for every kind: the spec says which ports to draw, so adding a
// node kind is a matter of adding an entry to SPECS (and a case in the OCaml
// lowering).
function FlowNode({ id, type, data, selected }: NodeProps<FerretNode>) {
  const spec = SPEC_BY_TYPE[type];
  const problems = useContext(ErrorContext).get(id);
  if (!spec) return <div className="fnode">unknown node {type}</div>;

  const inputs = ports(spec.inputs, data);
  const outputs = ports(spec.outputs, data);
  const headerExec = spec.execOut.length === 1 ? spec.execOut[0] : undefined;
  const bodyExec = headerExec ? [] : spec.execOut;
  const badge = spec.badge?.(data);

  return (
    <div
      className={
        "fnode" + (selected ? " is-selected" : "") + (problems ? " is-bad" : "")
      }
      title={problems?.join("\n")}
    >
      {spec.execIn && (
        <Handle
          id="in"
          type="target"
          position={Position.Left}
          className="handle handle-exec"
          style={{ top: 25 }}
        />
      )}
      {headerExec && (
        <Handle
          id={headerExec.id}
          type="source"
          position={Position.Right}
          className="handle handle-exec"
          style={{ top: 25 }}
        />
      )}

      <div className="fnode-head">
        <span className="fnode-glyph" style={{ background: spec.color }}>
          {spec.glyph}
        </span>
        <span className="fnode-title">{spec.title}</span>
        {badge !== undefined && badge !== "" && (
          <span className="fnode-badge">{badge}</span>
        )}
      </div>

      {(inputs.length > 0 || outputs.length > 0 || bodyExec.length > 0) && (
        <div className="fnode-body">
          {inputs.map((p) => (
            <div className="port port-in" key={p.id}>
              <Handle
                id={p.id}
                type="target"
                position={Position.Left}
                className={`handle handle-${p.kind}`}
              />
              <span className="port-label">{p.label}</span>
              <span className="port-type">{p.kind === "bool" ? "真偽" : "数"}</span>
            </div>
          ))}
          {outputs.map((p) => (
            <div className="port port-out" key={p.id}>
              <span className="port-label">{p.label}</span>
              <span className="port-type">{p.kind === "bool" ? "真偽" : "数"}</span>
              <Handle
                id={p.id}
                type="source"
                position={Position.Right}
                className={`handle handle-${p.kind}`}
              />
            </div>
          ))}
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

      {problems && <div className="fnode-error">{problems[0]}</div>}
    </div>
  );
}

export default memo(FlowNode);
