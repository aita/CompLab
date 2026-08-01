// An indented dump of the typed syntax tree, for `wolv emit -s ast`.

import * as ast from "./ast.ts";

const put = (lines: string[], depth: number, text: string): void => {
  lines.push("  ".repeat(depth) + text);
};

const showType = (e: ast.Exp): string => (e.ty === null ? "" : ` : ${e.ty}`);

/**
 * A string literal, written the way the Python tree writes it, so that a dump
 * taken from either is the same dump.  Every character of one is a byte, and a
 * byte that stands for nothing printable is shown as `\xNN`.
 */
function quoted(text: string): string {
  const quote = text.includes("'") && !text.includes('"') ? '"' : "'";
  const out: string[] = [quote];
  for (const ch of text) {
    const code = ch.charCodeAt(0);
    if (ch === quote || ch === "\\") out.push("\\" + ch);
    else if (ch === "\n") out.push("\\n");
    else if (ch === "\r") out.push("\\r");
    else if (ch === "\t") out.push("\\t");
    else if (printable(ch)) out.push(ch);
    else out.push("\\x" + code.toString(16).padStart(2, "0"));
  }
  out.push(quote);
  return out.join("");
}

/** What Python calls printable: anything but a control, a format or a stray space. */
function printable(ch: string): boolean {
  if (ch === " ") return true;
  return !/[\p{Cc}\p{Cf}\p{Cs}\p{Co}\p{Cn}\p{Zl}\p{Zp}\p{Zs}]/u.test(ch);
}

const escapes = (sym: { escapes: boolean } | null): string =>
  sym !== null && sym.escapes ? " (escapes)" : "";

function showDecl(decl: ast.Decl, depth: number, lines: string[]): void {
  if (decl instanceof ast.TypeDecl) {
    for (const t of decl.binds) put(lines, depth, `type ${t.name}`);
    return;
  }
  if (decl instanceof ast.ValDecl) {
    const keyword = decl.mutable ? "var" : "val";
    put(lines, depth, `${keyword} ${decl.name ?? "()"}${escapes(decl.sym)}`);
    showExp(decl.init, depth + 1, lines);
    return;
  }
  for (const f of decl.binds) {
    const params = f.params.map((p) => p.name + escapes(p.sym)).join(", ");
    const result = f.sym !== null ? String(f.sym.result) : "?";
    put(lines, depth, `fun ${f.name}(${params}) : ${result}`);
    showExp(f.body, depth + 1, lines);
  }
}

function showExp(e: ast.Exp, depth: number, lines: string[]): void {
  if (e instanceof ast.IntLit) { put(lines, depth, `int ${e.value}`); return; }
  if (e instanceof ast.StrLit) { put(lines, depth, `string ${quoted(e.value)}`); return; }
  if (e instanceof ast.BoolLit) {
    put(lines, depth, `bool ${e.value ? "true" : "false"}`);
    return;
  }
  if (e instanceof ast.NilLit) { put(lines, depth, "nil"); return; }
  if (e instanceof ast.UnitLit) { put(lines, depth, "()"); return; }
  if (e instanceof ast.Var) { put(lines, depth, `var ${e.name}${showType(e)}`); return; }
  if (e instanceof ast.Call) {
    put(lines, depth, `call ${e.name}${showType(e)}`);
    for (const a of e.args) showExp(a, depth + 1, lines);
    return;
  }
  if (e instanceof ast.RecordLit) {
    put(lines, depth, `record ${e.tyname}${showType(e)}`);
    for (const f of e.fields) {
      put(lines, depth + 1, `${f.name} =`);
      showExp(f.value, depth + 2, lines);
    }
    return;
  }
  if (e instanceof ast.Index) {
    put(lines, depth, `index${showType(e)}`);
    showExp(e.array, depth + 1, lines);
    showExp(e.index, depth + 1, lines);
    return;
  }
  if (e instanceof ast.Field) {
    put(lines, depth, `field .${e.name}${showType(e)}`);
    showExp(e.record, depth + 1, lines);
    return;
  }
  if (e instanceof ast.Neg) {
    put(lines, depth, "neg");
    showExp(e.operand, depth + 1, lines);
    return;
  }
  if (e instanceof ast.Bin || e instanceof ast.Logic) {
    put(lines, depth, `${e.op}${showType(e)}`);
    showExp(e.lhs, depth + 1, lines);
    showExp(e.rhs, depth + 1, lines);
    return;
  }
  if (e instanceof ast.Assign) {
    put(lines, depth, ":=");
    showExp(e.target, depth + 1, lines);
    showExp(e.value, depth + 1, lines);
    return;
  }
  if (e instanceof ast.If) {
    put(lines, depth, `if${showType(e)}`);
    showExp(e.cond, depth + 1, lines);
    showExp(e.then, depth + 1, lines);
    if (e.els !== null) showExp(e.els, depth + 1, lines);
    return;
  }
  if (e instanceof ast.While) {
    put(lines, depth, "while");
    showExp(e.cond, depth + 1, lines);
    showExp(e.body, depth + 1, lines);
    return;
  }
  if (e instanceof ast.For) {
    put(lines, depth, `for ${e.name}${escapes(e.sym)}`);
    showExp(e.lo, depth + 1, lines);
    showExp(e.hi, depth + 1, lines);
    showExp(e.body, depth + 1, lines);
    return;
  }
  if (e instanceof ast.Break) { put(lines, depth, "break"); return; }
  if (e instanceof ast.Seq) {
    put(lines, depth, `seq${showType(e)}`);
    for (const item of e.items) showExp(item, depth + 1, lines);
    return;
  }
  put(lines, depth, `let${showType(e)}`);
  for (const d of e.decls) showDecl(d, depth + 1, lines);
  put(lines, depth, "in");
  showExp(e.body, depth + 1, lines);
}

export function showProgram(prog: ast.Program): string {
  const lines: string[] = [];
  for (const decl of prog.decls) showDecl(decl, 0, lines);
  return lines.join("\n") + "\n";
}
