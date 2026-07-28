import { useRef, useState } from "react";
import type { CompileResult, Paused, Run, RunResult } from "./ferret";
import { canPause, start } from "./ferret";

interface Props {
  compiled: CompileResult;
  onFocusNode: (id: string) => void;
}

export default function RunPanel({ compiled, onFocusNode }: Props) {
  const [args, setArgs] = useState<Record<string, string>>({});
  const [result, setResult] = useState<RunResult | null>(null);
  const [paused, setPaused] = useState<Paused | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const run = useRef<Run | null>(null);

  if (!compiled.ok) {
    return (
      <div className="runpanel">
        <div className="run-status bad">
          Nothing to run: the graph does not compile.
        </div>
        <ul className="problem-list">
          {compiled.errors.map((e, i) => (
            <li key={i}>
              {e.node && (
                <button className="linkish" onClick={() => onFocusNode(e.node!)}>
                  {e.node}
                </button>
              )}
              <span>{e.message}</span>
            </li>
          ))}
        </ul>
      </div>
    );
  }

  const watches = compiled.watches;
  const where = (watch: number) => watches[watch] ?? { node: "?", label: "?" };

  const go = async () => {
    setBusy(true);
    setFailure(null);
    setResult(null);
    setPaused(null);
    const active = start(
      compiled.wasm,
      compiled.params.map((p) => Number(args[p] ?? 0)),
      setPaused,
    );
    run.current = active;
    try {
      const finished = await active.done;
      setResult(finished);
    } catch (e) {
      setFailure(e instanceof Error ? e.message : String(e));
    } finally {
      setPaused(null);
      setBusy(false);
      run.current = null;
    }
  };

  const resume = () => {
    setPaused(null);
    run.current?.resume();
  };

  return (
    <div className="runpanel">
      <div className="run-status ok">
        Compiled — {compiled.wasm.length} bytes of wasm
      </div>

      {compiled.params.length === 0 ? (
        <p className="muted">The start node takes no inputs.</p>
      ) : (
        compiled.params.map((p) => (
          <div className="field" key={p}>
            <label>{p}</label>
            <input
              type="number"
              step="any"
              value={args[p] ?? ""}
              placeholder="0"
              disabled={busy}
              onChange={(e) => setArgs({ ...args, [p]: e.target.value })}
            />
          </div>
        ))
      )}

      <button className="primary" disabled={busy} onClick={go}>
        {busy ? "Running…" : "▶ Run"}
      </button>

      {watches.length > 0 && !busy && (
        <p className="muted breakpoint-note">
          {watches.length} breakpoint{watches.length === 1 ? "" : "s"} set.
          {!canPause() &&
            " This page is not cross-origin isolated, so a run reports them rather than stopping at them."}
        </p>
      )}

      {paused && (
        <div className="paused">
          <div className="paused-head">
            Paused at{" "}
            <button
              className="linkish"
              onClick={() => onFocusNode(where(paused.watch).node)}
            >
              {where(paused.watch).node}
            </button>
          </div>
          <div className="result">
            <span className="result-label">{where(paused.watch).label}</span>
            <span className="result-value">{format(paused.value)}</span>
          </div>
          <div className="muted">hit {paused.hit}</div>
          <div className="paused-buttons">
            <button className="primary" onClick={resume}>
              Continue
            </button>
            <button onClick={() => run.current?.stop()}>Stop</button>
          </div>
        </div>
      )}

      {failure && <div className="run-status bad">{failure}</div>}

      {result && (
        <>
          <div className="result">
            <span className="result-label">
              {result.stopped ? "stopped" : "returned"}
            </span>
            <span className="result-value">
              {result.value === null ? "—" : format(result.value)}
            </span>
          </div>
          <div className="muted">{result.ms.toFixed(2)} ms</div>

          {result.hits.length > 0 && (
            <div className="logs">
              <div className="logs-title">Breakpoints ({result.hits.length})</div>
              <table className="hits">
                <tbody>
                  {result.hits.slice(0, 300).map((h, i) => (
                    <tr key={i}>
                      <td className="hits-n">{i + 1}</td>
                      <td>
                        <button
                          className="linkish"
                          onClick={() => onFocusNode(where(h.watch).node)}
                        >
                          {where(h.watch).node}
                        </button>
                      </td>
                      <td className="hits-label">{where(h.watch).label}</td>
                      <td className="hits-value">{format(h.value)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {result.hits.length > 300 && (
                <div className="muted">first 300 shown</div>
              )}
            </div>
          )}

          {result.logs.length > 0 && (
            <div className="logs">
              <div className="logs-title">
                Log output ({result.logs.length}
                {result.truncated ? "+" : ""})
              </div>
              <ol>
                {result.logs.map((x, i) => (
                  <li key={i}>{format(x)}</li>
                ))}
              </ol>
            </div>
          )}
        </>
      )}
    </div>
  );
}

function format(x: number) {
  return Number.isInteger(x) ? String(x) : String(Number(x.toPrecision(15)));
}
