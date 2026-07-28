import { useState } from "react";
import type { CompileResult, RunResult } from "./ferret";
import { run } from "./ferret";

interface Props {
  compiled: CompileResult;
  onFocusNode: (id: string) => void;
}

export default function RunPanel({ compiled, onFocusNode }: Props) {
  const [args, setArgs] = useState<Record<string, string>>({});
  const [result, setResult] = useState<RunResult | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  if (!compiled.ok) {
    return (
      <div className="runpanel">
        <div className="run-status bad">
          コンパイルが通っていないので実行できません。
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

  const go = async () => {
    setBusy(true);
    setFailure(null);
    try {
      const values = compiled.params.map((p) => Number(args[p] ?? 0));
      setResult(await run(compiled.wasm, values));
    } catch (e) {
      setResult(null);
      setFailure(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="runpanel">
      <div className="run-status ok">
        コンパイル成功 — {compiled.wasm.length} バイトの wasm
      </div>

      {compiled.params.length === 0 ? (
        <p className="muted">開始ノードに入力はありません。</p>
      ) : (
        compiled.params.map((p) => (
          <div className="field" key={p}>
            <label>{p}</label>
            <input
              type="number"
              step="any"
              value={args[p] ?? ""}
              placeholder="0"
              onChange={(e) => setArgs({ ...args, [p]: e.target.value })}
            />
          </div>
        ))
      )}

      <button className="primary" disabled={busy} onClick={go}>
        {busy ? "実行中…" : "▶ 実行する"}
      </button>

      {failure && <div className="run-status bad">{failure}</div>}

      {result && (
        <>
          <div className="result">
            <span className="result-label">戻り値</span>
            <span className="result-value">{format(result.value)}</span>
          </div>
          <div className="muted">{result.ms.toFixed(2)} ms</div>
          {result.logs.length > 0 && (
            <div className="logs">
              <div className="logs-title">
                ログ出力 ({result.logs.length}
                {result.truncated ? " 以上" : ""})
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
