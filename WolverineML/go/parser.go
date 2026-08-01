// A Pratt parser.
//
// Every expression form is either a prefix form (nud, in atom) or an infix one
// (led, in exp), and the table below is the whole of the precedence.  The prefix
// forms that end in an expression — `if`, `while`, `for`, `:=` — take their tail
// at binding power 0, so `if c then x := 1 else x := 2` reads the way it looks.

package main

import "strconv"

type power struct{ left, right int }

var bindingPower = map[tok]power{
	tASSIGN:  {2, 1}, // right associative
	tORELSE:  {4, 5},
	tANDALSO: {6, 7},
	tEQ:      {8, 9},
	tNE:      {8, 9},
	tLT:      {8, 9},
	tLE:      {8, 9},
	tGT:      {8, 9},
	tGE:      {8, 9},
	tCARET:   {10, 11},
	tPLUS:    {12, 13},
	tMINUS:   {12, 13},
	tSTAR:    {14, 15},
	tSLASH:   {14, 15},
	tMOD:     {14, 15},
}

const unaryBP = 16

var binops = map[tok]string{
	tPLUS: "+", tMINUS: "-", tSTAR: "*", tSLASH: "/", tMOD: "mod", tCARET: "^",
	tEQ: "=", tNE: "<>", tLT: "<", tLE: "<=", tGT: ">", tGE: ">=",
}

func declStarter(t tok) bool {
	return t == tVAL || t == tVAR || t == tFUN || t == tTYPE
}

// parse reads a whole program.
func parse(source string) (prog *Program, err error) {
	defer catch(&err)
	toks, err := lex(source)
	if err != nil {
		return nil, err
	}
	return (&parser{toks: toks}).program(), nil
}

// parseExp reads a single expression — the tests use it, the compiler does not.
func parseExp(source string) (e Exp, err error) {
	defer catch(&err)
	toks, err := lex(source)
	if err != nil {
		return nil, err
	}
	p := &parser{toks: toks}
	e = p.exp(0)
	if !p.at(tEOF) {
		panic(parseErrorf(p.cur().at, "unexpected %v after the expression", p.cur()))
	}
	return e, nil
}

type parser struct {
	toks []token
	pos  int
}

// -- token plumbing ----------------------------------------------------------

func (p *parser) cur() token { return p.toks[p.pos] }

func (p *parser) at(kind tok) bool { return p.cur().kind == kind }

func (p *parser) take(kind tok) (token, bool) {
	if p.cur().kind != kind {
		return token{}, false
	}
	t := p.cur()
	p.pos++
	return t, true
}

func (p *parser) took(kind tok) bool {
	_, ok := p.take(kind)
	return ok
}

func (p *parser) expect(kind tok) token {
	t, ok := p.take(kind)
	if !ok {
		panic(parseErrorf(p.cur().at, "expected `%s`, found %v", kind.text(), p.cur()))
	}
	return t
}

func (p *parser) expectIdent() token {
	t, ok := p.take(tIDENT)
	if !ok {
		panic(parseErrorf(p.cur().at, "expected a name, found %v", p.cur()))
	}
	return t
}

// -- programs and declarations -----------------------------------------------

func (p *parser) program() *Program {
	prog := &Program{}
	for !p.at(tEOF) {
		prog.Decls = append(prog.Decls, p.decl())
	}
	return prog
}

func (p *parser) decl() Decl {
	switch p.cur().kind {
	case tTYPE:
		return p.typeDecl()
	case tVAL, tVAR:
		return p.valDecl()
	case tFUN:
		return p.funDecl()
	default:
		panic(parseErrorf(p.cur().at,
			"expected a declaration (`val`, `var`, `fun`, `type`), found %v", p.cur()))
	}
}

func (p *parser) typeDecl() *TypeDecl {
	start := p.expect(tTYPE).at
	binds := []TypeBind{p.typeBind()}
	for p.took(tAND) {
		binds = append(binds, p.typeBind())
	}
	return &TypeDecl{Span: start, Binds: binds}
}

func (p *parser) typeBind() TypeBind {
	name := p.expectIdent()
	p.expect(tEQ)
	return TypeBind{Name: name.text, Ty: p.ty(), Span: name.at}
}

func (p *parser) valDecl() *ValDecl {
	mutable := p.cur().kind == tVAR
	start := p.cur().at
	p.pos++
	name := ""
	if p.took(tLPAREN) {
		p.expect(tRPAREN)
	} else {
		name = p.expectIdent().text
	}
	var written TyExp
	if p.took(tCOLON) {
		written = p.ty()
	}
	p.expect(tEQ)
	return &ValDecl{Span: start, Name: name, Ty: written, Init: p.exp(0), Mutable: mutable}
}

func (p *parser) funDecl() *FunDecl {
	start := p.expect(tFUN).at
	binds := []FunBind{p.funBind()}
	for p.took(tAND) {
		binds = append(binds, p.funBind())
	}
	return &FunDecl{Span: start, Binds: binds}
}

func (p *parser) funBind() FunBind {
	name := p.expectIdent()
	p.expect(tLPAREN)
	var params []Param
	if !p.took(tRPAREN) {
		for {
			pname := p.expectIdent()
			p.expect(tCOLON)
			params = append(params, Param{Name: pname.text, Ty: p.ty(), Span: pname.at})
			if !p.took(tCOMMA) {
				break
			}
		}
		p.expect(tRPAREN)
	}
	var result TyExp
	if p.took(tCOLON) {
		result = p.ty()
	}
	p.expect(tEQ)
	return FunBind{Name: name.text, Params: params, Result: result, Body: p.exp(0), Span: name.at}
}

// -- types -------------------------------------------------------------------

func (p *parser) ty() TyExp {
	start := p.cur().at
	var base TyExp
	switch {
	case p.took(tLBRACE):
		var fields []TyField
		if !p.took(tRBRACE) {
			for {
				fname := p.expectIdent()
				p.expect(tCOLON)
				fields = append(fields, TyField{Name: fname.text, Ty: p.ty(), Span: fname.at})
				if !p.took(tCOMMA) {
					break
				}
			}
			p.expect(tRBRACE)
		}
		base = &TyRecord{Span: start, Fields: fields}
	case p.took(tLPAREN):
		base = p.ty()
		p.expect(tRPAREN)
	default:
		base = &TyName{Span: start, Name: p.expectIdent().text}
	}
	for p.cur().kind == tIDENT && p.cur().text == "array" {
		p.pos++
		base = &TyArray{Span: start, Elem: base}
	}
	return base
}

// -- expressions -------------------------------------------------------------

func (p *parser) exp(minBP int) Exp {
	left := p.atom()
	for {
		bp, ok := bindingPower[p.cur().kind]
		if !ok || bp.left < minBP {
			return left
		}
		t := p.cur()
		p.pos++
		switch t.kind {
		case tASSIGN:
			p.checkLvalue(left)
			left = &AssignExp{ExpNode: node(t.at), Target: left, Value: p.exp(bp.right)}
		case tANDALSO, tORELSE:
			left = &LogicExp{ExpNode: node(t.at), Op: t.text, Lhs: left, Rhs: p.exp(bp.right)}
		default:
			left = &BinExp{ExpNode: node(t.at), Op: binops[t.kind], Lhs: left, Rhs: p.exp(bp.right)}
		}
	}
}

func (p *parser) checkLvalue(e Exp) {
	switch e.(type) {
	case *VarExp, *IndexExp, *FieldExp:
		return
	}
	panic(parseErrorf(e.at(), "the left of `:=` is not assignable"))
}

func (p *parser) atom() Exp {
	t := p.cur()
	start := t.at
	switch t.kind {
	case tINT:
		p.pos++
		return p.postfix(&IntLit{ExpNode: node(start), Value: p.integer(t)})
	case tSTRING:
		p.pos++
		return p.postfix(&StrLit{ExpNode: node(start), Value: t.text})
	case tTRUE, tFALSE:
		p.pos++
		return &BoolLit{ExpNode: node(start), Value: t.kind == tTRUE}
	case tNIL:
		p.pos++
		return &NilLit{ExpNode: node(start)}
	case tBREAK:
		p.pos++
		return &BreakExp{ExpNode: node(start)}
	case tTILDE:
		p.pos++
		return &NegExp{ExpNode: node(start), Operand: p.exp(unaryBP)}
	case tMINUS:
		panic(parseErrorf(start, "negation is written `~`, not `-`"))
	case tLPAREN:
		return p.postfix(p.parens())
	case tIDENT:
		return p.postfix(p.named())
	case tIF:
		return p.ifExp()
	case tWHILE:
		return p.whileExp()
	case tFOR:
		return p.forExp()
	case tLET:
		return p.letExp()
	default:
		panic(parseErrorf(start, "expected an expression, found %v", p.cur()))
	}
}

// integer reads a literal.  Integers are 64 bits and wrap, so the largest one is
// the one written `~9223372036854775808`.
func (p *parser) integer(t token) int64 {
	value, err := strconv.ParseUint(t.text, 10, 64)
	if err != nil {
		panic(parseErrorf(t.at, "`%s` does not fit in 64 bits", t.text))
	}
	return int64(value)
}

func (p *parser) parens() Exp {
	start := p.expect(tLPAREN).at
	if p.took(tRPAREN) {
		return &UnitLit{ExpNode: node(start)}
	}
	items := p.sequence(tRPAREN)
	p.expect(tRPAREN)
	if len(items) == 1 {
		return items[0]
	}
	return &SeqExp{ExpNode: node(start), Items: items}
}

func (p *parser) sequence(end tok) []Exp {
	items := []Exp{p.exp(0)}
	for p.took(tSEMI) {
		if p.at(end) {
			break
		}
		items = append(items, p.exp(0))
	}
	return items
}

func (p *parser) named() Exp {
	t := p.expectIdent()
	switch p.cur().kind {
	case tLPAREN:
		p.pos++
		var args []Exp
		if !p.took(tRPAREN) {
			for {
				args = append(args, p.exp(0))
				if !p.took(tCOMMA) {
					break
				}
			}
			p.expect(tRPAREN)
		}
		return &CallExp{ExpNode: node(t.at), Name: t.text, Args: args}
	case tLBRACE:
		p.pos++
		var fields []FieldInit
		if !p.took(tRBRACE) {
			for {
				fname := p.expectIdent()
				p.expect(tEQ)
				fields = append(fields, FieldInit{Name: fname.text, Value: p.exp(0), Span: fname.at})
				if !p.took(tCOMMA) {
					break
				}
			}
			p.expect(tRBRACE)
		}
		return &RecordLit{ExpNode: node(t.at), TyName: t.text, Fields: fields}
	default:
		return &VarExp{ExpNode: node(t.at), Name: t.text}
	}
}

func (p *parser) postfix(base Exp) Exp {
	for {
		switch p.cur().kind {
		case tLBRACK:
			start := p.cur().at
			p.pos++
			index := p.exp(0)
			p.expect(tRBRACK)
			base = &IndexExp{ExpNode: node(start), Array: base, Index: index}
		case tDOT:
			start := p.cur().at
			p.pos++
			base = &FieldExp{ExpNode: node(start), Record: base, Name: p.expectIdent().text, Offset: -1}
		default:
			return base
		}
	}
}

func (p *parser) ifExp() Exp {
	start := p.expect(tIF).at
	cond := p.exp(0)
	p.expect(tTHEN)
	then := p.exp(0)
	var els Exp
	if p.took(tELSE) {
		els = p.exp(0)
	}
	return &IfExp{ExpNode: node(start), Cond: cond, Then: then, Else: els}
}

func (p *parser) whileExp() Exp {
	start := p.expect(tWHILE).at
	cond := p.exp(0)
	p.expect(tDO)
	return &WhileExp{ExpNode: node(start), Cond: cond, Body: p.exp(0)}
}

func (p *parser) forExp() Exp {
	start := p.expect(tFOR).at
	name := p.expectIdent()
	p.expect(tEQ)
	lo := p.exp(0)
	p.expect(tTO)
	hi := p.exp(0)
	p.expect(tDO)
	return &ForExp{ExpNode: node(start), Name: name.text, Lo: lo, Hi: hi, Body: p.exp(0)}
}

func (p *parser) letExp() Exp {
	start := p.expect(tLET).at
	var decls []Decl
	for declStarter(p.cur().kind) {
		decls = append(decls, p.decl())
	}
	p.expect(tIN)
	var body Exp
	if p.at(tEND) {
		body = &UnitLit{ExpNode: node(start)}
	} else if items := p.sequence(tEND); len(items) == 1 {
		body = items[0]
	} else {
		body = &SeqExp{ExpNode: node(start), Items: items}
	}
	p.expect(tEND)
	return &LetExp{ExpNode: node(start), Decls: decls, Body: body}
}
