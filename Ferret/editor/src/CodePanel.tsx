import { useState } from "react";
import type { CompileResult } from "./ferret";

type View = "ir" | "wat" | "bytes";

export default function CodePanel({ compiled }: { compiled: CompileResult }) {
  const [view, setView] = useState<View>("wat");
  if (!compiled.ok) {
    return <div className="panel-empty">This fills in once the graph compiles.</div>;
  }
  return (
    <div className="codepanel">
      <div className="subtabs">
        <button
          className={view === "ir" ? "on" : ""}
          onClick={() => setView("ir")}
        >
          IR
        </button>
        <button
          className={view === "wat" ? "on" : ""}
          onClick={() => setView("wat")}
        >
          wat
        </button>
        <button
          className={view === "bytes" ? "on" : ""}
          onClick={() => setView("bytes")}
        >
          bytes
        </button>
      </div>
      <pre className="code">
        {view === "ir" && compiled.ir}
        {view === "wat" && compiled.wat}
        {view === "bytes" && hexdump(compiled.wasm)}
      </pre>
      <button
        className="ghost"
        onClick={() => {
          const blob = new Blob([compiled.wasm as BlobPart], {
            type: "application/wasm",
          });
          const a = document.createElement("a");
          a.href = URL.createObjectURL(blob);
          a.download = "flow.wasm";
          a.click();
          URL.revokeObjectURL(a.href);
        }}
      >
        Download flow.wasm
      </button>
    </div>
  );
}

function hexdump(bytes: Uint8Array) {
  const lines: string[] = [];
  for (let i = 0; i < bytes.length; i += 16) {
    const row = Array.from(bytes.slice(i, i + 16));
    const hex = row.map((b) => b.toString(16).padStart(2, "0")).join(" ");
    const text = row
      .map((b) => (b >= 0x20 && b < 0x7f ? String.fromCharCode(b) : "."))
      .join("");
    lines.push(`${i.toString(16).padStart(6, "0")}  ${hex.padEnd(47)}  ${text}`);
  }
  return lines.join("\n");
}
