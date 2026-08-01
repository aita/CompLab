// An indented dump of the typed syntax tree, for `wolv emit -s ast`.

package main

import (
	"fmt"
	"strings"
	"unicode"
)

func showProgram(prog *Program) string {
	var lines []string
	for _, d := range prog.Decls {
		showDecl(d, 0, &lines)
	}
	return strings.Join(lines, "\n") + "\n"
}

func put(lines *[]string, depth int, text string) {
	*lines = append(*lines, strings.Repeat("  ", depth)+text)
}

func showType(e Exp) string {
	if e.ty() == nil {
		return ""
	}
	return " : " + e.ty().String()
}

// quoted writes a string literal the way the Python tree writes it, so that a dump
// taken from either is the same dump.  Every character of one is a byte, and a byte
// that stands for nothing printable is shown as `\xNN`.
func quoted(text string) string {
	quote := byte('\'')
	if strings.IndexByte(text, '\'') >= 0 && strings.IndexByte(text, '"') < 0 {
		quote = '"'
	}
	var out strings.Builder
	out.WriteByte(quote)
	for i := 0; i < len(text); i++ {
		ch := text[i]
		switch {
		case ch == quote || ch == '\\':
			out.WriteByte('\\')
			out.WriteByte(ch)
		case ch == '\n':
			out.WriteString("\\n")
		case ch == '\r':
			out.WriteString("\\r")
		case ch == '\t':
			out.WriteString("\\t")
		case unicode.IsPrint(rune(ch)):
			out.WriteRune(rune(ch))
		default:
			out.WriteString(fmt.Sprintf("\\x%02x", ch))
		}
	}
	out.WriteByte(quote)
	return out.String()
}

func escapesMark(sym *VarSym) string {
	if sym != nil && sym.Escapes {
		return " (escapes)"
	}
	return ""
}

func showDecl(decl Decl, depth int, lines *[]string) {
	switch d := decl.(type) {
	case *TypeDecl:
		for _, t := range d.Binds {
			put(lines, depth, "type "+t.Name)
		}
	case *ValDecl:
		keyword := "val"
		if d.Mutable {
			keyword = "var"
		}
		name := d.Name
		if name == "" {
			name = "()"
		}
		put(lines, depth, keyword+" "+name+escapesMark(d.Sym))
		showExp(d.Init, depth+1, lines)
	case *FunDecl:
		for _, f := range d.Binds {
			params := make([]string, len(f.Params))
			for at, p := range f.Params {
				params[at] = p.Name + escapesMark(p.Sym)
			}
			result := "?"
			if f.Sym != nil {
				result = f.Sym.Result.String()
			}
			put(lines, depth, fmt.Sprintf("fun %s(%s) : %s",
				f.Name, strings.Join(params, ", "), result))
			showExp(f.Body, depth+1, lines)
		}
	}
}

func showExp(e Exp, depth int, lines *[]string) {
	switch e := e.(type) {
	case *IntLit:
		put(lines, depth, fmt.Sprintf("int %d", e.Value))
	case *StrLit:
		put(lines, depth, "string "+quoted(e.Value))
	case *BoolLit:
		word := "false"
		if e.Value {
			word = "true"
		}
		put(lines, depth, "bool "+word)
	case *NilLit:
		put(lines, depth, "nil")
	case *UnitLit:
		put(lines, depth, "()")
	case *VarExp:
		put(lines, depth, "var "+e.Name+showType(e))
	case *CallExp:
		put(lines, depth, "call "+e.Name+showType(e))
		for _, a := range e.Args {
			showExp(a, depth+1, lines)
		}
	case *RecordLit:
		put(lines, depth, "record "+e.TyName+showType(e))
		for _, f := range e.Fields {
			put(lines, depth+1, f.Name+" =")
			showExp(f.Value, depth+2, lines)
		}
	case *IndexExp:
		put(lines, depth, "index"+showType(e))
		showExp(e.Array, depth+1, lines)
		showExp(e.Index, depth+1, lines)
	case *FieldExp:
		put(lines, depth, "field ."+e.Name+showType(e))
		showExp(e.Record, depth+1, lines)
	case *NegExp:
		put(lines, depth, "neg")
		showExp(e.Operand, depth+1, lines)
	case *BinExp:
		put(lines, depth, e.Op+showType(e))
		showExp(e.Lhs, depth+1, lines)
		showExp(e.Rhs, depth+1, lines)
	case *LogicExp:
		put(lines, depth, e.Op+showType(e))
		showExp(e.Lhs, depth+1, lines)
		showExp(e.Rhs, depth+1, lines)
	case *AssignExp:
		put(lines, depth, ":=")
		showExp(e.Target, depth+1, lines)
		showExp(e.Value, depth+1, lines)
	case *IfExp:
		put(lines, depth, "if"+showType(e))
		showExp(e.Cond, depth+1, lines)
		showExp(e.Then, depth+1, lines)
		if e.Else != nil {
			showExp(e.Else, depth+1, lines)
		}
	case *WhileExp:
		put(lines, depth, "while")
		showExp(e.Cond, depth+1, lines)
		showExp(e.Body, depth+1, lines)
	case *ForExp:
		put(lines, depth, "for "+e.Name+escapesMark(e.Sym))
		showExp(e.Lo, depth+1, lines)
		showExp(e.Hi, depth+1, lines)
		showExp(e.Body, depth+1, lines)
	case *BreakExp:
		put(lines, depth, "break")
	case *SeqExp:
		put(lines, depth, "seq"+showType(e))
		for _, item := range e.Items {
			showExp(item, depth+1, lines)
		}
	case *LetExp:
		put(lines, depth, "let"+showType(e))
		for _, d := range e.Decls {
			showDecl(d, depth+1, lines)
		}
		put(lines, depth, "in")
		showExp(e.Body, depth+1, lines)
	default:
		put(lines, depth, "?")
	}
}
