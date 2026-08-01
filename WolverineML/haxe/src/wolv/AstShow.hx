package wolv;

import wolv.Ast;
import wolv.Types;

/* An indented dump of the typed syntax tree, for `wolv emit -s ast`. */

function showProgram(prog:Program):String {
  final out = new Dump();
  for (d in prog.decls) out.decl(0, d);
  return out.lines.join("\n") + "\n";
}

/**
 * A string literal, written the way the Python tree writes it, so that a dump
 * taken from either is the same dump.  Every character of one is a byte, and a
 * byte that stands for nothing printable is shown as `\xNN`.
 *
 * The other ports ask a Unicode database which bytes those are.  Haxe has none,
 * but it does not need one: a literal is bytes, so only U+0000 to U+00FF can ever
 * appear, and over that range the answer is a fixed four ranges — C0 and C1
 * controls, no-break space, and the soft hyphen.
 */
function quoted(text:String):String {
  final quote = text.indexOf("'") >= 0 && text.indexOf('"') < 0 ? '"' : "'";
  final out = new StringBuf();
  out.add(quote);
  for (at in 0...text.length) {
    final c = text.charCodeAt(at);
    final ch = String.fromCharCode(c);
    if (ch == quote || ch == "\\") out.add("\\" + ch);
    else if (c == 0x0A) out.add("\\n");
    else if (c == 0x0D) out.add("\\r");
    else if (c == 0x09) out.add("\\t");
    else if (c <= 0x1F || (c >= 0x7F && c <= 0xA0) || c == 0xAD) {
      out.add("\\x" + StringTools.hex(c, 2).toLowerCase());
    } else if (c < 0x80) out.addChar(c);
    else {
      out.addChar(0xC0 | (c >> 6));
      out.addChar(0x80 | (c & 0x3F));
    }
  }
  out.add(quote);
  return out.toString();
}

private function escapes(sym:Null<VarSym>):String {
  return sym != null && sym.escapes ? " (escapes)" : "";
}

private function boundVar(e:Exp):Null<VarSym> {
  return switch e.sym {
    case Var(v): v;
    case _: null;
  }
}

private class Dump {
  public final lines:Array<String> = [];

  public function new() {}

  function put(depth:Int, text:String):Void {
    lines.push(StringTools.lpad("", " ", depth * 2) + text);
  }

  function showType(e:Exp):String {
    return e.ty == null ? "" : " : " + Types.show(e.ty);
  }

  public function decl(depth:Int, d:Decl):Void {
    switch d {
      case DType(_, binds):
        for (b in binds) put(depth, "type " + b.name);

      case DVal(v):
        final keyword = v.mutable ? "var" : "val";
        final name = v.name == null ? "()" : v.name;
        put(depth, keyword + " " + name + escapes(v.sym));
        exp(depth + 1, v.init);

      case DFun(_, binds):
        for (b in binds) {
          final params = b.params.map(p -> p.name + escapes(p.sym)).join(", ");
          final result = b.sym == null ? "?" : Types.show(b.sym.result);
          put(depth, 'fun ${b.name}($params) : $result');
          exp(depth + 1, b.body);
        }
    }
  }

  public function exp(depth:Int, e:Exp):Void {
    switch e.def {
      case EInt(v): put(depth, "int " + Std.string(v));
      case EStr(v): put(depth, "string " + quoted(v));
      case EBool(b): put(depth, "bool " + (b ? "true" : "false"));
      case ENil: put(depth, "nil");
      case EUnit: put(depth, "()");
      case EVar(name): put(depth, "var " + name + showType(e));

      case ECall(name, args):
        put(depth, "call " + name + showType(e));
        for (a in args) exp(depth + 1, a);

      case ERecord(tyname, fields):
        put(depth, "record " + tyname + showType(e));
        for (f in fields) {
          put(depth + 1, f.name + " =");
          exp(depth + 2, f.value);
        }

      case EIndex(array, index):
        put(depth, "index" + showType(e));
        exp(depth + 1, array);
        exp(depth + 1, index);

      case EField(record, name):
        put(depth, "field ." + name + showType(e));
        exp(depth + 1, record);

      case ENeg(operand):
        put(depth, "neg");
        exp(depth + 1, operand);

      case EBin(op, lhs, rhs) | ELogic(op, lhs, rhs):
        put(depth, op + showType(e));
        exp(depth + 1, lhs);
        exp(depth + 1, rhs);

      case EAssign(target, value):
        put(depth, ":=");
        exp(depth + 1, target);
        exp(depth + 1, value);

      case EIf(cond, then, els):
        put(depth, "if" + showType(e));
        exp(depth + 1, cond);
        exp(depth + 1, then);
        if (els != null) exp(depth + 1, els);

      case EWhile(cond, body):
        put(depth, "while");
        exp(depth + 1, cond);
        exp(depth + 1, body);

      case EFor(name, lo, hi, body):
        put(depth, "for " + name + escapes(boundVar(e)));
        exp(depth + 1, lo);
        exp(depth + 1, hi);
        exp(depth + 1, body);

      case EBreak:
        put(depth, "break");

      case ESeq(items):
        put(depth, "seq" + showType(e));
        for (item in items) exp(depth + 1, item);

      case ELet(ds, body):
        put(depth, "let" + showType(e));
        for (d in ds) decl(depth + 1, d);
        put(depth, "in");
        exp(depth + 1, body);
    }
  }
}
