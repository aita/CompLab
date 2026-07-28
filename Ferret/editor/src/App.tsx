import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Background,
  BackgroundVariant,
  Controls,
  MarkerType,
  MiniMap,
  ReactFlow,
  addEdge,
  useEdgesState,
  useNodesInitialized,
  useNodesState,
  useReactFlow,
  type Connection,
  type Edge,
  type OnConnect,
} from "@xyflow/react";
import FlowNode, { type FerretNode } from "./FlowNode";
import Palette from "./Palette";
import Inspector from "./Inspector";
import RunPanel from "./RunPanel";
import CodePanel from "./CodePanel";
import ContextMenu, { type MenuItem } from "./ContextMenu";
import Wire from "./Wire";
import { ConnectedContext, ErrorContext, portKey } from "./errors";
import { SPECS, SPEC_BY_TYPE, describe, portKind, type NodeData } from "./spec";
import { compile, type CompileResult } from "./ferret";
import { EXAMPLES, blank } from "./examples";

const nodeTypes = Object.fromEntries(SPECS.map((s) => [s.type, FlowNode]));
const edgeTypes = { wire: Wire };
const STORAGE_KEY = "ferret.graph";

const EXEC_COLOR = "#94a3b8";
const NUM_COLOR = "#38bdf8";
const BOOL_COLOR = "#a78bfa";

type Tab = "node" | "run" | "code";
type Menu = { x: number; y: number; title: string; items: MenuItem[] };

interface Doc {
  name?: string;
  nodes: { type?: string }[];
  edges: unknown[];
}

/** Is this something the editor can open?  A file from an older node set, or
 *  from something else entirely, is refused rather than half-loaded. */
function readable(doc: unknown): doc is Doc {
  const d = doc as Doc;
  return (
    !!d &&
    Array.isArray(d.nodes) &&
    Array.isArray(d.edges) &&
    d.nodes.every((n) => !!n.type && n.type in SPEC_BY_TYPE)
  );
}

export default function App() {
  const [nodes, setNodes, onNodesChange] = useNodesState<FerretNode>([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<Edge>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("run");
  const [fitToken, setFitToken] = useState(0);
  const [menu, setMenu] = useState<Menu | null>(null);
  const [docName, setDocName] = useState("Untitled");
  const [notice, setNotice] = useState<string | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  const counter = useRef(1);
  const lastPicked = useRef<string | null>(null);
  const flowRef = useRef<HTMLDivElement>(null);
  const { screenToFlowPosition, fitView, getNode, setCenter, getZoom } =
    useReactFlow();
  const measured = useNodesInitialized();

  const loadDoc = useCallback(
    (doc: { name?: string; nodes: unknown[]; edges: unknown[] }) => {
      const nodes = structuredClone(doc.nodes) as FerretNode[];
      setNodes(nodes);
      setEdges(structuredClone(doc.edges) as Edge[]);
      setSelected(null);
      setDocName(doc.name ?? "Untitled");
      // Ids from a file may already use the `kind_7` shape, so start counting
      // past the highest one rather than at the node count.
      counter.current =
        nodes.reduce((top, n) => {
          const tail = /_(\d+)$/.exec(n.id);
          return tail ? Math.max(top, Number(tail[1])) : top;
        }, 0) + 1;
      setFitToken((n) => n + 1);
    },
    [setNodes, setEdges],
  );

  // A fit before the cards have been measured uses placeholder sizes and lands
  // on the wrong zoom, so wait for the measurement to land.
  useEffect(() => {
    if (measured && fitToken > 0) fitView({ padding: 0.2 });
  }, [measured, fitToken, fitView]);

  // Start on whatever was last edited, or the first example.  A save made by
  // an older node set is dropped rather than restored into a graph the
  // compiler no longer understands.
  useEffect(() => {
    const saved = window.localStorage.getItem(STORAGE_KEY);
    if (saved) {
      try {
        const doc = JSON.parse(saved);
        if (readable(doc)) {
          loadDoc(doc);
          return;
        }
      } catch {
        /* fall through to the example */
      }
    }
    loadDoc(EXAMPLES[0].graph);
  }, [loadDoc]);

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
      window.localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({ name: docName, ...graph }),
      );
  }, [graph, docName, nodes.length]);

  // Compiling on every edit is what makes the errors feel like a linter; the
  // whole pipeline is well under a millisecond for graphs this size.
  const compiled: CompileResult = useMemo(() => compile(graph), [graph]);

  // The same graph with a breakpoint on everything, which is all stepping is:
  // the run stops wherever a value is worked out, in the order it happens.
  const stepwise: CompileResult = useMemo(
    () =>
      compile({
        ...graph,
        nodes: graph.nodes.map((n) => ({
          ...n,
          data: { ...n.data, breakpoint: true },
        })),
      }),
    [graph],
  );

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

  const connected = useMemo(
    () => new Set(edges.map((e) => portKey(e.target, e.targetHandle ?? "in"))),
    [edges],
  );

  const kindOf = useCallback(
    (nodeId: string, handle: string | null) => {
      const node = nodes.find((n) => n.id === nodeId);
      if (!node?.type) return undefined;
      return portKind(node.type, node.data, handle);
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
        // A value input takes one connection and an exec output leads one
        // place, so dropping a new wire on either replaces what was there.
        // An exec *input* takes as many as it likes: that is how a loop is
        // closed, with the end of the body running back into a condition.
        let kept =
          kind === "exec"
            ? current.filter(
                (e) =>
                  !(e.source === c.source && e.sourceHandle === c.sourceHandle),
              )
            : current.filter(
                (e) =>
                  !(e.target === c.target && e.targetHandle === c.targetHandle),
              );
        return addEdge(c, kept);
      });
    },
    [kindOf, setEdges],
  );

  // While a node is selected, every wire that does not touch it fades, which
  // is the only way to follow one thread through a loop's feedback.
  const styledEdges = useMemo(
    () =>
      edges.map((e) => {
        const kind = kindOf(e.source, e.sourceHandle ?? null);
        const exec = kind === "exec";
        const color = exec
          ? EXEC_COLOR
          : kind === "bool"
            ? BOOL_COLOR
            : NUM_COLOR;
        const near =
          selected === null || e.source === selected || e.target === selected;
        return {
          ...e,
          type: "wire" as const,
          data: { color, exec, faded: !near },
          // Only the thread of execution carries an arrowhead; a value's
          // direction is already told by which side of a card it leaves.
          markerEnd: exec
            ? { type: MarkerType.ArrowClosed, width: 13, height: 13, color }
            : undefined,
        };
      }),
    [edges, kindOf, selected],
  );

  const addNode = useCallback(
    (
      type: string,
      at?: { x: number; y: number },
      preset?: NodeData,
    ) => {
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
        {
          id,
          type,
          position,
          // The palette offers one operator of a family at a time, so what it
          // asks for arrives here already set.
          data: { ...structuredClone(spec.data), ...preset },
        },
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

  const duplicateNode = useCallback(
    (id: string) => {
      const source = nodes.find((n) => n.id === id);
      if (!source) return;
      const copy = {
        ...source,
        id: `${source.type}_${counter.current++}`,
        position: { x: source.position.x + 40, y: source.position.y + 40 },
        data: structuredClone(source.data),
        selected: false,
      };
      setNodes((current) => [...current, copy]);
      setSelected(copy.id);
    },
    [nodes, setNodes],
  );

  const disconnectNode = useCallback(
    (id: string) => {
      setEdges((current) =>
        current.filter((e) => e.source !== id && e.target !== id),
      );
    },
    [setEdges],
  );

  const saveFile = useCallback(() => {
    const doc = JSON.stringify({ name: docName, ...graph }, null, 2);
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([doc], { type: "application/json" }));
    a.download = `${docName.trim().replace(/[^\w.-]+/g, "-") || "flow"}.json`;
    a.click();
    URL.revokeObjectURL(a.href);
  }, [docName, graph]);

  const openFile = useCallback(
    async (file: File) => {
      try {
        const doc = JSON.parse(await file.text());
        if (!readable(doc)) throw new Error("not a Ferret graph");
        loadDoc({ ...doc, name: doc.name ?? file.name.replace(/\.json$/i, "") });
        setNotice(null);
      } catch (e) {
        setNotice(
          `${file.name}: ${e instanceof Error ? e.message : String(e)}`,
        );
      }
    },
    [loadDoc],
  );

  const openFileMenu = useCallback(
    (event: React.MouseEvent) => {
      const box = (event.target as HTMLElement)
        .closest("button")!
        .getBoundingClientRect();
      setMenu({
        x: box.left,
        y: box.bottom + 6,
        title: "File",
        items: [
          { label: "New", onPick: () => loadDoc(blank()) },
          { label: "Open…", onPick: () => fileInput.current?.click() },
          { label: "Save as JSON", onPick: saveFile },
          ...EXAMPLES.map((x, i) => ({
            label: x.name,
            heading: i === 0 ? "Examples" : undefined,
            onPick: () => loadDoc(x.graph),
          })),
        ],
      });
    },
    [loadDoc, saveFile],
  );

  const openNodeMenu = useCallback(
    (event: React.MouseEvent, node: FerretNode) => {
      event.preventDefault();
      const spec = SPEC_BY_TYPE[node.type!];
      const attached = edges.some(
        (e) => e.source === node.id || e.target === node.id,
      );
      const items: MenuItem[] = [];
      // A breakpoint on the start node would report what the caller passed in,
      // which the Run panel already shows.
      if (node.type !== "start")
        items.push({
          label: node.data.breakpoint
            ? "Remove breakpoint"
            : "Add breakpoint",
          onPick: () =>
            patchNode(node.id, { breakpoint: !node.data.breakpoint }),
        });
      // There can only be one start node, so it can be neither copied nor cut.
      if (!spec?.unique)
        items.push({ label: "Duplicate", onPick: () => duplicateNode(node.id) });
      if (attached)
        items.push({
          label: "Disconnect",
          onPick: () => disconnectNode(node.id),
        });
      if (!spec?.unique)
        items.push({
          label: "Delete",
          hint: "Del",
          danger: true,
          onPick: () => deleteNode(node.id),
        });
      setSelected(node.id);
      setMenu({
        x: event.clientX,
        y: event.clientY,
        title: spec ? describe(node.type!, node.data).title : node.id,
        items,
      });
    },
    [edges, patchNode, duplicateNode, disconnectNode, deleteNode],
  );

  // Bring a node into view without taking the panel away from what is
  // running, which is what stepping needs on every stop.
  const reveal = useCallback(
    (id: string) => {
      const n = getNode(id);
      if (!n) return;
      const w = n.measured?.width ?? 236;
      const h = n.measured?.height ?? 96;
      setCenter(n.position.x + w / 2, n.position.y + h / 2, {
        zoom: Math.max(getZoom(), 0.75),
        duration: 250,
      });
      setSelected(id);
      setNodes((current) =>
        current.map((x) => ({ ...x, selected: x.id === id })),
      );
    },
    [getNode, setCenter, getZoom, setNodes],
  );

  const selectedNode = nodes.find((n) => n.id === selected);

  return (
    <ErrorContext.Provider value={problems}>
      <ConnectedContext.Provider value={connected}>
        <div className="app">
          <header className="topbar">
            <span className="brand">
              <span className="brand-mark">F</span> Ferret
            </span>
            <button className="ghost" onClick={openFileMenu}>
              File ▾
            </button>
            <input
              ref={fileInput}
              type="file"
              accept="application/json,.json"
              hidden
              onChange={(e) => {
                const file = e.target.files?.[0];
                if (file) openFile(file);
                e.target.value = "";
              }}
            />
            <input
              className="docname"
              value={docName}
              spellCheck={false}
              onChange={(e) => setDocName(e.target.value)}
            />
            <div className="spacer" />
            {notice && <span className="notice">{notice}</span>}
            <span className={"pill " + (compiled.ok ? "ok" : "bad")}>
              {compiled.ok
                ? `${compiled.wasm.length} bytes`
                : `${compiled.errors.length} problem${
                    compiled.errors.length === 1 ? "" : "s"
                  }`}
            </span>
            <button
              className="primary"
              onClick={() => setTab("run")}
              disabled={!compiled.ok}
            >
              ▶ Run
            </button>
          </header>

          <div className="workspace">
            <Palette
              onAdd={(type, preset) => addNode(type, undefined, preset)}
            />

            <div
              className="canvas"
              ref={flowRef}
              onDragOver={(e) => {
                e.preventDefault();
                e.dataTransfer.dropEffect = "move";
              }}
              onDrop={(e) => {
                e.preventDefault();
                const dropped = e.dataTransfer.getData(
                  "application/ferret-node",
                );
                if (!dropped) return;
                const { type, data } = JSON.parse(dropped) as {
                  type: string;
                  data?: NodeData;
                };
                addNode(
                  type,
                  screenToFlowPosition({ x: e.clientX, y: e.clientY }),
                  data,
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
                onNodeClick={(_, node) => {
                  // Opening the inspector belongs to the click, not to the
                  // selection: stepping selects nodes too, and it must not
                  // take the panel away from the run that is paused.
                  setSelected(node.id);
                  setTab("node");
                }}
                onSelectionChange={({ nodes: picked }) => {
                  // This fires again on any store update while something is
                  // selected, not only when the selection changes, so react to
                  // the change alone.
                  const id = picked[0]?.id ?? null;
                  if (id === lastPicked.current) return;
                  lastPicked.current = id;
                  setSelected(id);
                }}
                onNodeContextMenu={openNodeMenu}
                onEdgeContextMenu={(event, edge) => {
                  event.preventDefault();
                  setMenu({
                    x: event.clientX,
                    y: event.clientY,
                    title: "Connection",
                    items: [
                      {
                        label: "Delete",
                        danger: true,
                        onPick: () =>
                          setEdges((current) =>
                            current.filter((e) => e.id !== edge.id),
                          ),
                      },
                    ],
                  });
                }}
                onPaneContextMenu={(event) => {
                  event.preventDefault();
                  setMenu({
                    x: (event as React.MouseEvent).clientX,
                    y: (event as React.MouseEvent).clientY,
                    title: "Canvas",
                    items: [
                      {
                        label: "Fit view",
                        onPick: () => fitView({ padding: 0.2 }),
                      },
                    ],
                  });
                }}
                onPaneClick={() => setMenu(null)}
                onMoveStart={() => setMenu(null)}
                deleteKeyCode={["Delete", "Backspace"]}
                onBeforeDelete={async ({ nodes: picked, edges: cut }) => ({
                  // The start node is the entry point; there is nothing to
                  // compile without it.
                  nodes: picked.filter((n) => !SPEC_BY_TYPE[n.type!]?.unique),
                  edges: cut,
                })}
                proOptions={{ hideAttribution: true }}
                fitView
                fitViewOptions={{ padding: 0.2 }}
                minZoom={0.15}
              >
                <Background variant={BackgroundVariant.Dots} gap={16} size={1} />
                <Controls showInteractive={false} />
                <MiniMap
                  pannable
                  zoomable
                  style={{ width: 152, height: 104 }}
                  nodeColor={(n) => SPEC_BY_TYPE[n.type!]?.color ?? "#cbd5e1"}
                />
              </ReactFlow>
              {menu && <ContextMenu {...menu} onClose={() => setMenu(null)} />}
            </div>

            <aside className="side">
              <div className="tabs">
                <button
                  className={tab === "node" ? "on" : ""}
                  onClick={() => setTab("node")}
                >
                  Node
                </button>
                <button
                  className={tab === "run" ? "on" : ""}
                  onClick={() => setTab("run")}
                >
                  Run
                </button>
                <button
                  className={tab === "code" ? "on" : ""}
                  onClick={() => setTab("code")}
                >
                  Code
                </button>
              </div>
              <div className="side-body">
                {tab === "node" && (
                  <Inspector
                    node={selectedNode}
                    problems={selected ? (problems.get(selected) ?? []) : []}
                    onChange={patchNode}
                    onDelete={deleteNode}
                  />
                )}
                {tab === "run" && (
                  <RunPanel
                    compiled={compiled}
                    stepwise={stepwise}
                    onReveal={reveal}
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
      </ConnectedContext.Provider>
    </ErrorContext.Provider>
  );
}
