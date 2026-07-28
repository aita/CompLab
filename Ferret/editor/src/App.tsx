import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Background,
  BackgroundVariant,
  Controls,
  MiniMap,
  ReactFlow,
  addEdge,
  useEdgesState,
  useNodesInitialized,
  useNodesState,
  useReactFlow,
  type Connection,
  type Edge,
  type EdgeTypes,
  type OnConnect,
} from "@xyflow/react";
import FlowNode, { type FerretNode } from "./FlowNode";
import Palette from "./Palette";
import Inspector from "./Inspector";
import RunPanel from "./RunPanel";
import CodePanel from "./CodePanel";
import { ErrorContext } from "./errors";
import { SPECS, SPEC_BY_TYPE, portKind, type NodeData } from "./spec";
import { compile, type CompileResult } from "./ferret";
import { EXAMPLES } from "./examples";

const nodeTypes = Object.fromEntries(SPECS.map((s) => [s.type, FlowNode]));
const edgeTypes: EdgeTypes = {};
const STORAGE_KEY = "ferret.graph";

type Tab = "node" | "run" | "code";

export default function App() {
  const [nodes, setNodes, onNodesChange] = useNodesState<FerretNode>([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<Edge>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("run");
  const [exampleKey, setExampleKey] = useState(EXAMPLES[0].key);
  const [fitToken, setFitToken] = useState(0);
  const counter = useRef(1);
  const flowRef = useRef<HTMLDivElement>(null);
  const { screenToFlowPosition, fitView } = useReactFlow();
  const measured = useNodesInitialized();

  const loadGraph = useCallback(
    (graph: { nodes: unknown[]; edges: unknown[] }) => {
      setNodes(structuredClone(graph.nodes) as FerretNode[]);
      setEdges(structuredClone(graph.edges) as Edge[]);
      setSelected(null);
      counter.current = graph.nodes.length + 1;
      setFitToken((n) => n + 1);
    },
    [setNodes, setEdges],
  );

  // A fit before the cards have been measured uses placeholder sizes and lands
  // on the wrong zoom, so wait for the measurement to land.
  useEffect(() => {
    if (measured && fitToken > 0) fitView({ padding: 0.2 });
  }, [measured, fitToken, fitView]);

  // Start on whatever was last edited, or the first example.
  useEffect(() => {
    const saved = window.localStorage.getItem(STORAGE_KEY);
    if (saved) {
      try {
        loadGraph(JSON.parse(saved));
        return;
      } catch {
        /* fall through to the example */
      }
    }
    loadGraph(EXAMPLES[0].graph);
  }, [loadGraph]);

  const graph = useMemo(
    () => ({
      nodes: nodes.map((n) => ({
        id: n.id,
        type: n.type,
        position: n.position,
        data: n.data,
      })),
      edges: edges.map((e) => ({
        id: e.id,
        source: e.source,
        sourceHandle: e.sourceHandle,
        target: e.target,
        targetHandle: e.targetHandle,
      })),
    }),
    [nodes, edges],
  );

  useEffect(() => {
    if (nodes.length > 0)
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(graph));
  }, [graph, nodes.length]);

  // Compiling on every edit is what makes the errors feel like a linter; the
  // whole pipeline is well under a millisecond for graphs this size.
  const compiled: CompileResult = useMemo(() => compile(graph), [graph]);

  const problems = useMemo(() => {
    const map = new Map<string, string[]>();
    if (!compiled.ok) {
      for (const e of compiled.errors) {
        if (!e.node) continue;
        const list = map.get(e.node) ?? [];
        list.push(e.message);
        map.set(e.node, list);
      }
    }
    return map;
  }, [compiled]);

  const variables = useMemo(() => {
    const names = new Set<string>();
    for (const n of nodes) {
      if (n.type === "get" || n.type === "set") names.add(String(n.data.name));
      if (n.type === "start")
        for (const p of (n.data.params as { name: string }[]) ?? [])
          names.add(p.name);
    }
    names.delete("");
    return [...names].sort();
  }, [nodes]);

  const kindOf = useCallback(
    (nodeId: string, handle: string | null) => {
      const node = nodes.find((n) => n.id === nodeId);
      if (!node?.type) return undefined;
      return portKind(SPEC_BY_TYPE[node.type], node.data, handle);
    },
    [nodes],
  );

  const isValidConnection = useCallback(
    (c: Connection | Edge) => {
      if (c.source === c.target) return false;
      const from = kindOf(c.source, c.sourceHandle ?? null);
      const to = kindOf(c.target, c.targetHandle ?? null);
      return from !== undefined && from === to;
    },
    [kindOf],
  );

  const onConnect: OnConnect = useCallback(
    (c) => {
      const kind = kindOf(c.source, c.sourceHandle ?? null);
      setEdges((current) => {
        // An input takes one connection, and so does an exec output: dropping
        // a new edge on an occupied port replaces what was there.
        let kept = current.filter(
          (e) => !(e.target === c.target && e.targetHandle === c.targetHandle),
        );
        if (kind === "exec")
          kept = kept.filter(
            (e) => !(e.source === c.source && e.sourceHandle === c.sourceHandle),
          );
        return addEdge(c, kept);
      });
    },
    [kindOf, setEdges],
  );

  const styledEdges = useMemo(
    () =>
      edges.map((e) => {
        const exec = kindOf(e.source, e.sourceHandle ?? null) === "exec";
        const bool = kindOf(e.source, e.sourceHandle ?? null) === "bool";
        return {
          ...e,
          type: "smoothstep" as const,
          style: {
            strokeWidth: exec ? 2 : 1.5,
            stroke: exec ? "#94a3b8" : bool ? "#a78bfa" : "#7dd3fc",
          },
        };
      }),
    [edges, kindOf],
  );

  const addNode = useCallback(
    (type: string, at?: { x: number; y: number }) => {
      const spec = SPEC_BY_TYPE[type];
      if (spec.unique && nodes.some((n) => n.type === type)) return;
      const id = `${type}_${counter.current++}`;
      const position =
        at ??
        screenToFlowPosition({
          x: (flowRef.current?.clientWidth ?? 800) / 2,
          y: (flowRef.current?.clientHeight ?? 600) / 2,
        });
      setNodes((current) => [
        ...current,
        { id, type, position, data: structuredClone(spec.data) },
      ]);
      setSelected(id);
      setTab("node");
    },
    [nodes, screenToFlowPosition, setNodes],
  );

  const patchNode = useCallback(
    (id: string, patch: NodeData) => {
      setNodes((current) =>
        current.map((n) =>
          n.id === id ? { ...n, data: { ...n.data, ...patch } } : n,
        ),
      );
    },
    [setNodes],
  );

  const deleteNode = useCallback(
    (id: string) => {
      setNodes((current) => current.filter((n) => n.id !== id));
      setEdges((current) =>
        current.filter((e) => e.source !== id && e.target !== id),
      );
      setSelected(null);
    },
    [setNodes, setEdges],
  );

  const selectedNode = nodes.find((n) => n.id === selected);

  return (
    <ErrorContext.Provider value={problems}>
      <div className="app">
        <header className="topbar">
          <span className="brand">
            <span className="brand-mark">F</span> Ferret
          </span>
          <span className="tagline">ノードをつないで wasm にする</span>
          <div className="spacer" />
          <select
            value={exampleKey}
            onChange={(e) => {
              setExampleKey(e.target.value);
              const found = EXAMPLES.find((x) => x.key === e.target.value);
              if (found) loadGraph(found.graph);
            }}
          >
            {EXAMPLES.map((x) => (
              <option key={x.key} value={x.key}>
                {x.name}
              </option>
            ))}
          </select>
          <button
            className="ghost"
            onClick={() => {
              const found = EXAMPLES.find((x) => x.key === exampleKey);
              if (found) loadGraph(found.graph);
            }}
          >
            読み直す
          </button>
          <span className={"pill " + (compiled.ok ? "ok" : "bad")}>
            {compiled.ok
              ? `${compiled.wasm.length} バイト`
              : `${compiled.errors.length} 件の問題`}
          </span>
          <button
            className="primary"
            onClick={() => setTab("run")}
            disabled={!compiled.ok}
          >
            ▶ 実行
          </button>
        </header>

        <div className="workspace">
          <Palette onAdd={(type) => addNode(type)} />

          <div
            className="canvas"
            ref={flowRef}
            onDragOver={(e) => {
              e.preventDefault();
              e.dataTransfer.dropEffect = "move";
            }}
            onDrop={(e) => {
              e.preventDefault();
              const type = e.dataTransfer.getData("application/ferret-node");
              if (!type) return;
              addNode(
                type,
                screenToFlowPosition({ x: e.clientX, y: e.clientY }),
              );
            }}
          >
            <ReactFlow
              nodes={nodes}
              edges={styledEdges}
              nodeTypes={nodeTypes}
              edgeTypes={edgeTypes}
              onNodesChange={onNodesChange}
              onEdgesChange={onEdgesChange}
              onConnect={onConnect}
              isValidConnection={isValidConnection}
              onSelectionChange={({ nodes: picked }) => {
                setSelected(picked[0]?.id ?? null);
                if (picked[0]) setTab("node");
              }}
              defaultEdgeOptions={{ type: "smoothstep" }}
              proOptions={{ hideAttribution: true }}
              fitView
              fitViewOptions={{ padding: 0.2 }}
              // The default floor of 0.5 is above what a whole flow needs.
              minZoom={0.15}
            >
              <Background variant={BackgroundVariant.Dots} gap={16} size={1} />
              <Controls showInteractive={false} />
              <MiniMap
                pannable
                zoomable
                nodeColor={(n) => SPEC_BY_TYPE[n.type!]?.color ?? "#cbd5e1"}
              />
            </ReactFlow>
          </div>

          <aside className="side">
            <div className="tabs">
              <button
                className={tab === "node" ? "on" : ""}
                onClick={() => setTab("node")}
              >
                設定
              </button>
              <button
                className={tab === "run" ? "on" : ""}
                onClick={() => setTab("run")}
              >
                実行
              </button>
              <button
                className={tab === "code" ? "on" : ""}
                onClick={() => setTab("code")}
              >
                生成コード
              </button>
            </div>
            <div className="side-body">
              {tab === "node" && (
                <Inspector
                  node={selectedNode}
                  variables={variables}
                  problems={selected ? (problems.get(selected) ?? []) : []}
                  onChange={patchNode}
                  onDelete={deleteNode}
                />
              )}
              {tab === "run" && (
                <RunPanel
                  compiled={compiled}
                  onFocusNode={(id) => {
                    setSelected(id);
                    setTab("node");
                    setNodes((current) =>
                      current.map((n) => ({ ...n, selected: n.id === id })),
                    );
                  }}
                />
              )}
              {tab === "code" && <CodePanel compiled={compiled} />}
            </div>
          </aside>
        </div>
      </div>
    </ErrorContext.Provider>
  );
}
