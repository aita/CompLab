import { useEffect, useRef, useState } from "react";
import type { CompileResult, Paused, Run, RunResult } from "./ferret";
import { canPause, start } from "./ferret";

interface Props {
  compiled: CompileResult;
  /** The same program with a report on every node, which is what a run that
   *  has to stop anywhere -- at a breakpoint or a step -- is run from. */
  stepwise: CompileResult;
  /** The nodes the user marked, by id. */
  breakpoints: Set<string>;
  onFocusNode: (id: string) => void;
  onReveal: (id: string) => void;
}

/** How long the panel leaves between cooks when it is driving them. */
const FRAME_MS = 100;

// What the graph is holding between cooks: its Feedbacks and its Inputs, read
// straight out of the module's globals rather than reported by it.
function Held({ held }: { held: { name: string; value: number }[] }) {
  return (
    <div className="logs">
      <div className="logs-title">State</div>
      <table className="hits">
        <tbody>
          {held.map((h) => (
            <tr key={h.name}>
              <td>{h.name}</td>
              <td className="hits-value">{format(h.value)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export default function RunPanel({
  compiled,
  stepwise,
  breakpoints,
  onFocusNode,
  onReveal,
}: Props) {
  const [result, setResult] = useState<RunResult | null>(null);
  const [paused, setPaused] = useState<Paused | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // Whether a run is up at all: the module stays instantiated between cooks,
  // so what it holds carries over until this goes back to false.
  const [live, setLive] = useState(false);
  const [playing, setPlaying] = useState(false);
  // Which build a run is using decides which watch table its indices mean.
  const [debugging, setDebugging] = useState(false);
  /** What the panel will write into the module's input globals. */
  const [given, setGiven] = useState<Record<string, string>>({});
  const ticker = useRef<ReturnType<typeof setInterval> | null>(null);
  const run = useRef<Run | null>(null);
  // The ticker fires from outside the render that started it, so what it asks
  // about a cook in flight has to be a ref rather than a piece of state.
  const inFlight = useRef(false);

  // An edit to the graph is a new program, and what the running one is holding
  // has nothing to do with it: the run ends rather than carrying state over
  // from a graph that is no longer on the canvas.
  useEffect(() => {
    if (ticker.current) clearInterval(ticker.current);
    ticker.current = null;
    run.current?.stop();
    run.current = null;
    inFlight.current = false;
    setPlaying(false);
    setLive(false);
    setBusy(false);
    setPaused(null);
    setResult(null);
    setFailure(null);
  }, [compiled]);

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

  const where = (watch: number) => {
    const table = debugging && stepwise.ok ? stepwise.watches : compiled.watches;
    return table[watch] ?? { node: "?", label: "?" };
  };

  const settle = (r: RunResult) => {
    inFlight.current = false;
    setResult(r);
    setPaused(null);
    setBusy(false);
  };

  const crashed = (e: unknown) => {
    setFailure(e instanceof Error ? e.message : String(e));
    stopRun();
  };

  const cooking = () => {
    inFlight.current = true;
    setBusy(true);
  };

  // Starting a run instantiates the module and cooks it once.  A run that
  // might have to stop runs the build that reports at every node, and the
  // page says where to stop; with nothing to stop for, what runs is the graph
  // as drawn.
  const begin = async (step: boolean) => {
    stopTicker();
    run.current?.stop();
    const watched = (step || breakpoints.size > 0) && stepwise.ok;
    const build = watched ? stepwise : compiled;
    cooking();
    setDebugging(watched);
    setFailure(null);
    setResult(null);
    setPaused(null);
    const active = start(
      build.wasm,
      Object.fromEntries(
        build.inputs.map((i) => [
          i.export,
          given[i.export] === undefined || given[i.export] === ""
            ? i.value
            : Number(given[i.export]),
        ]),
      ),
      build.watches.map((w) => breakpoints.has(w.node)),
      step,
      (p: Paused) => {
        setPaused(p);
        const w = build.ok ? build.watches[p.watch] : undefined;
        if (w) onReveal(w.node);
      },
    );
    run.current = active;
    setLive(true);
    try {
      settle(await active.done);
    } catch (e) {
      crashed(e);
    }
  };

  // Another cook, on what the last one left behind.  This is the whole of how
  // a dataflow program gets anywhere: the graph itself has no loop in it.
  const again = async (step = false) => {
    const active = run.current;
    // Starting a run is itself the first cook, so there is nothing more to do.
    if (!active) return begin(step);
    cooking();
    try {
      settle(await active.again(step));
    } catch (e) {
      crashed(e);
    }
  };

  const stopTicker = () => {
    if (ticker.current) clearInterval(ticker.current);
    ticker.current = null;
    setPlaying(false);
  };

  const stopRun = () => {
    stopTicker();
    run.current?.stop();
    run.current = null;
    inFlight.current = false;
    setLive(false);
    setBusy(false);
    setPaused(null);
  };

  // Cooking over and over is what makes a graph a program that runs, the way
  // a frame does in a patcher: the host drives it, the graph does not loop.
  const play = async () => {
    if (playing) {
      stopTicker();
      return;
    }
    if (!run.current) await begin(false);
    if (!run.current) return;
    setPlaying(true);
    ticker.current = setInterval(() => {
      // A cook still going, or held at a breakpoint, keeps its turn.
      if (!inFlight.current) void again();
    }, FRAME_MS);
  };

  const resume = (step = false) => {
    setPaused(null);
    run.current?.resume(step);
  };

  return (
    <div className="runpanel">
      <div className="run-status ok">
        Compiled — {compiled.wasm.length} bytes of wasm
      </div>

      {compiled.inputs.length === 0 ? (
        <p className="muted">
          This graph asks for nothing. Add an Input node for a number to give
          it before the run.
        </p>
      ) : (
        compiled.inputs.map((i) => (
          <div className="field" key={i.export}>
            <label>{i.label}</label>
            <input
              type="number"
              step="any"
              value={given[i.export] ?? String(i.value)}
              disabled={live}
              onChange={(e) =>
                setGiven({ ...given, [i.export]: e.target.value })
              }
            />
          </div>
        ))
      )}

      <div className="run-buttons">
        <button className={playing ? "" : "primary"} onClick={() => void play()}>
          {playing ? "❚❚ Pause" : "▶ Play"}
        </button>
        <button
          disabled={busy && !paused}
          onClick={() => void again()}
          title="Work the graph out once"
        >
          ↻ Cook
        </button>
        <button
          disabled={busy && !paused}
          onClick={() => void again(true)}
          title="Cook it, stopping at every node"
        >
          ⏭ Step
        </button>
        {live && <button onClick={stopRun}>■ Stop</button>}
      </div>

      <p className="muted">
        {live
          ? `Cooking on; the graph keeps what it holds until Stop.${
              playing ? ` One cook every ${FRAME_MS} ms.` : ""
            }`
          : "Play cooks the graph over and over; Cook does it once. What the Feedbacks hold carries from one cook to the next."}
      </p>

      {breakpoints.size > 0 && !busy && (
        <p className="muted breakpoint-note">
          {breakpoints.size} breakpoint{breakpoints.size === 1 ? "" : "s"} set;
          a cook stops at them, and Next carries on a node at a time.
          {!canPause() &&
            " This page is not cross-origin isolated, so a cook reports them rather than stopping at them."}
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
            <span className="paused-where">cook {paused.cook}</span>
          </div>
          <div className="result">
            <span className="result-label">{where(paused.watch).label}</span>
            <span className="result-value">{format(paused.value)}</span>
          </div>
          <div className="muted">hit {paused.hit}</div>
          {paused.state.length > 0 && <Held held={paused.state} />}
          <div className="paused-buttons">
            <button className="primary" onClick={() => resume(true)}>
              ⏭ Next
            </button>
            <button onClick={() => resume(false)}>Continue</button>
            <button onClick={stopRun}>Stop</button>
          </div>
        </div>
      )}

      {failure && <div className="run-status bad">{failure}</div>}

      {result && !paused && (
        <>
          <div className="result">
            <span className="result-label">
              {result.stopped ? "stopped" : `cook ${result.cook} gave`}
            </span>
            <span className="result-value">
              {result.value === null ? "—" : format(result.value)}
            </span>
          </div>
          <div className="muted">{result.ms.toFixed(2)} ms</div>

          {result.state.length > 0 && <Held held={result.state} />}

          {result.said.length > 0 && (
            <div className="logs">
              <div className="logs-title">Said ({result.said.length})</div>
              <ol className="said">
                {result.said.map((s, i) => (
                  <li key={i}>{s}</li>
                ))}
              </ol>
            </div>
          )}

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
