// The type checker, which also decides which variables escape.
//
// Types are monomorphic and there is nothing to infer but the type of a `val`.
// A `fun` without a result type is a procedure and returns `unit`, which is what
// makes recursion checkable without inference: every function's signature is
// known before any body is.
//
// The pass has a second job.  A variable read from inside a function nested more
// deeply than the one that binds it cannot live in a register, because the inner
// function reaches it through a static link at run time.  Every lookup that
// crosses a function boundary marks the variable as escaping, and the lowering
// pass gives those a frame slot instead.

package main

import "fmt"

type builtinSig struct {
	name   string
	params []Type
	result Type
	symbol string
}

var builtinSigs = []builtinSig{
	{"print", []Type{tyString}, tyUnit, "wol_print"},
	{"println", []Type{tyString}, tyUnit, "wol_println"},
	{"printInt", []Type{tyInt}, tyUnit, "wol_print_int"},
	{"flush", nil, tyUnit, "wol_flush"},
	{"getChar", nil, tyString, "wol_getchar"},
	{"ord", []Type{tyString}, tyInt, "wol_ord"},
	{"chr", []Type{tyInt}, tyString, "wol_chr"},
	{"size", []Type{tyString}, tyInt, "wol_size"},
	{"substring", []Type{tyString, tyInt, tyInt}, tyString, "wol_substring"},
	{"concat", []Type{tyString, tyString}, tyString, "wol_concat"},
	{"intToString", []Type{tyInt}, tyString, "wol_int_to_string"},
	{"stringToInt", []Type{tyString}, tyInt, "wol_string_to_int"},
	{"exit", []Type{tyInt}, tyUnit, "wol_exit"},
}

func arithmetic(op string) bool {
	return op == "+" || op == "-" || op == "*" || op == "/" || op == "mod"
}

func ordering(op string) bool {
	return op == "<" || op == "<=" || op == ">" || op == ">="
}

func equality(op string) bool { return op == "=" || op == "<>" }

// check types the program in place: every node comes back with its type filled in.
func check(prog *Program) (err error) {
	defer catch(&err)
	c := &checker{labels: map[string]int{}}
	c.scopes = []*scope{prelude()}
	c.program(prog)
	return nil
}

type scope struct {
	types map[string]Type
	vals  map[string]Sym
}

func newScope() *scope {
	return &scope{types: map[string]Type{}, vals: map[string]Sym{}}
}

func prelude() *scope {
	s := newScope()
	s.types["int"] = tyInt
	s.types["string"] = tyString
	s.types["bool"] = tyBool
	s.types["unit"] = tyUnit
	for _, sig := range builtinSigs {
		params := make([]*VarSym, len(sig.params))
		for at, t := range sig.params {
			params[at] = newVar(fmt.Sprintf("a%d", at), t, false, 0)
		}
		s.vals[sig.name] = &FunSym{
			Name: sig.name, Label: sig.symbol, Params: params,
			Result: sig.result, Depth: 0, Builtin: sig.symbol,
		}
	}
	for _, name := range []string{"array", "length", "not"} {
		s.vals[name] = &FunSym{Name: name, Label: name, Result: tyUnit, Builtin: name}
	}
	return s
}

type checker struct {
	scopes []*scope
	depth  int
	loops  int
	labels map[string]int
}

// -- scopes ------------------------------------------------------------------

func (c *checker) push() { c.scopes = append(c.scopes, newScope()) }
func (c *checker) pop()  { c.scopes = c.scopes[:len(c.scopes)-1] }

func (c *checker) bindVal(name string, sym Sym)  { c.scopes[len(c.scopes)-1].vals[name] = sym }
func (c *checker) bindType(name string, ty Type) { c.scopes[len(c.scopes)-1].types[name] = ty }

func (c *checker) lookupVal(name string, at span) Sym {
	for i := len(c.scopes) - 1; i >= 0; i-- {
		if sym, ok := c.scopes[i].vals[name]; ok {
			return sym
		}
	}
	panic(typeErrorf(at, "`%s` is not bound", name))
}

func (c *checker) lookupType(name string, at span) Type {
	for i := len(c.scopes) - 1; i >= 0; i-- {
		if ty, ok := c.scopes[i].types[name]; ok {
			return ty
		}
	}
	panic(typeErrorf(at, "`%s` is not a type", name))
}

func (c *checker) uniqueLabel(name string) string {
	n := c.labels[name]
	c.labels[name] = n + 1
	if n == 0 {
		return "wol_" + name
	}
	return fmt.Sprintf("wol_%s.%d", name, n)
}

// -- programs ----------------------------------------------------------------

func (c *checker) program(prog *Program) {
	c.push()
	c.decls(prog.Decls)
	c.pop()
}

func (c *checker) decls(decls []Decl) {
	for _, decl := range decls {
		switch d := decl.(type) {
		case *TypeDecl:
			c.typeDecl(d)
		case *ValDecl:
			c.valDecl(d)
		case *FunDecl:
			c.funDecl(d)
		}
	}
}

func (c *checker) typeDecl(decl *TypeDecl) {
	type pending struct {
		rec    *RecordT
		syntax *TyRecord
	}
	var records []pending
	for _, bind := range decl.Binds {
		if syntax, ok := bind.Ty.(*TyRecord); ok {
			rec := &RecordT{Name: bind.Name}
			c.bindType(bind.Name, rec)
			records = append(records, pending{rec, syntax})
		}
	}
	for _, bind := range decl.Binds {
		if _, ok := bind.Ty.(*TyRecord); !ok {
			c.bindType(bind.Name, c.resolve(bind.Ty))
		}
	}
	for _, p := range records {
		seen := map[string]bool{}
		for _, f := range p.syntax.Fields {
			if seen[f.Name] {
				panic(typeErrorf(f.Span, "duplicate field `%s`", f.Name))
			}
			seen[f.Name] = true
			p.rec.Fields = append(p.rec.Fields, RecordField{Name: f.Name, Ty: c.resolve(f.Ty)})
		}
	}
}

func (c *checker) resolve(ty TyExp) Type {
	switch t := ty.(type) {
	case *TyName:
		return c.lookupType(t.Name, t.Span)
	case *TyArray:
		return &ArrayT{Elem: c.resolve(t.Elem)}
	case *TyRecord:
		panic(typeErrorf(t.Span, "a record type has to be given a name by `type`"))
	default:
		panic(typeErrorf(ty.at(), "unknown type"))
	}
}

func (c *checker) valDecl(decl *ValDecl) {
	got := c.exp(decl.Init)
	if decl.Ty != nil {
		want := c.resolve(decl.Ty)
		c.unify(want, got, decl.Init.at(), "in this binding")
		got = want
	}
	if decl.Name == "" {
		c.unify(tyUnit, got, decl.Init.at(), "in `val () =`")
		return
	}
	if _, isNil := got.(NilT); isNil {
		panic(typeErrorf(decl.Span, "`%s` needs a type annotation to hold `nil`", decl.Name))
	}
	decl.Sym = newVar(decl.Name, got, decl.Mutable, c.depth)
	c.bindVal(decl.Name, decl.Sym)
}

func (c *checker) funDecl(decl *FunDecl) {
	for at := range decl.Binds {
		bind := &decl.Binds[at]
		var params []*VarSym
		seen := map[string]bool{}
		for pAt := range bind.Params {
			p := &bind.Params[pAt]
			if seen[p.Name] {
				panic(typeErrorf(p.Span, "duplicate parameter `%s`", p.Name))
			}
			seen[p.Name] = true
			p.Sym = newVar(p.Name, c.resolve(p.Ty), false, c.depth+1)
			params = append(params, p.Sym)
		}
		result := tyUnit
		if bind.Result != nil {
			result = c.resolve(bind.Result)
		}
		bind.Sym = &FunSym{
			Name: bind.Name, Label: c.uniqueLabel(bind.Name),
			Params: params, Result: result, Depth: c.depth + 1,
		}
		c.bindVal(bind.Name, bind.Sym)
	}
	for at := range decl.Binds {
		bind := &decl.Binds[at]
		c.depth++
		outer := c.loops
		c.loops = 0
		c.push()
		for _, p := range bind.Params {
			c.bindVal(p.Name, p.Sym)
		}
		got := c.exp(bind.Body)
		c.unify(bind.Sym.Result, got, bind.Body.at(), "in the body of `"+bind.Name+"`")
		c.pop()
		c.loops = outer
		c.depth--
	}
}

// -- expressions -------------------------------------------------------------

func (c *checker) unify(want, got Type, at span, where string) {
	if !compatible(want, got) {
		panic(typeErrorf(at, "expected `%v`, found `%v` %s", want, got, where))
	}
}

func (c *checker) exp(e Exp) Type {
	ty := c.infer(e)
	e.setTy(ty)
	return ty
}

func (c *checker) infer(e Exp) Type {
	switch e := e.(type) {
	case *IntLit:
		return tyInt
	case *StrLit:
		return tyString
	case *BoolLit:
		return tyBool
	case *NilLit:
		return tyNil
	case *UnitLit:
		return tyUnit
	case *VarExp:
		return c.variable(e)
	case *CallExp:
		return c.call(e)
	case *RecordLit:
		return c.recordLit(e)
	case *IndexExp:
		return c.index(e)
	case *FieldExp:
		return c.field(e)
	case *NegExp:
		c.unify(tyInt, c.exp(e.Operand), e.Span, "in a negation")
		return tyInt
	case *BinExp:
		return c.binop(e)
	case *LogicExp:
		c.unify(tyBool, c.exp(e.Lhs), e.Lhs.at(), "on the left of `"+e.Op+"`")
		c.unify(tyBool, c.exp(e.Rhs), e.Rhs.at(), "on the right of `"+e.Op+"`")
		return tyBool
	case *AssignExp:
		return c.assign(e)
	case *IfExp:
		return c.ifExp(e)
	case *WhileExp:
		c.unify(tyBool, c.exp(e.Cond), e.Cond.at(), "as a `while` condition")
		c.loops++
		c.unify(tyUnit, c.exp(e.Body), e.Body.at(), "in a `while` body")
		c.loops--
		return tyUnit
	case *ForExp:
		return c.forExp(e)
	case *BreakExp:
		if c.loops == 0 {
			panic(typeErrorf(e.Span, "`break` is outside any loop"))
		}
		return tyUnit
	case *SeqExp:
		ty := tyUnit
		for _, item := range e.Items {
			ty = c.exp(item)
		}
		return ty
	case *LetExp:
		c.push()
		c.decls(e.Decls)
		ty := c.exp(e.Body)
		c.pop()
		return ty
	default:
		panic(typeErrorf(e.at(), "unknown expression"))
	}
}

func (c *checker) variable(e *VarExp) Type {
	sym := c.lookupVal(e.Name, e.Span)
	v, ok := sym.(*VarSym)
	if !ok {
		panic(typeErrorf(e.Span, "`%s` is a function, and functions are not values", e.Name))
	}
	if v.Depth < c.depth {
		v.Escapes = true
	}
	e.Sym = v
	return v.Ty
}

func (c *checker) call(e *CallExp) Type {
	sym := c.lookupVal(e.Name, e.Span)
	f, ok := sym.(*FunSym)
	if !ok {
		panic(typeErrorf(e.Span, "`%s` is a variable, not a function", e.Name))
	}
	e.Sym = f
	switch f.Builtin {
	case "array":
		return c.arrayCall(e)
	case "length":
		return c.lengthCall(e)
	case "not":
		c.arity(e, 1)
		c.unify(tyBool, c.exp(e.Args[0]), e.Span, "in a call to `not`")
		return tyBool
	}
	c.arity(e, len(f.Params))
	for at, arg := range e.Args {
		c.unify(f.Params[at].Ty, c.exp(arg), arg.at(), "in a call to `"+e.Name+"`")
	}
	return f.Result
}

func (c *checker) arity(e *CallExp, want int) {
	if len(e.Args) == want {
		return
	}
	plural := "s"
	if want == 1 {
		plural = ""
	}
	panic(typeErrorf(e.Span, "`%s` takes %d argument%s, given %d",
		e.Name, want, plural, len(e.Args)))
}

func (c *checker) arrayCall(e *CallExp) Type {
	c.arity(e, 2)
	c.unify(tyInt, c.exp(e.Args[0]), e.Args[0].at(), "as an array length")
	elem := c.exp(e.Args[1])
	if _, isNil := elem.(NilT); isNil {
		panic(typeErrorf(e.Args[1].at(), "`array` cannot tell which record `nil` stands for"))
	}
	return &ArrayT{Elem: elem}
}

func (c *checker) lengthCall(e *CallExp) Type {
	c.arity(e, 1)
	arg := c.exp(e.Args[0])
	if _, isArray := arg.(*ArrayT); !isArray {
		panic(typeErrorf(e.Args[0].at(), "`length` wants an array, found `%v`", arg))
	}
	return tyInt
}

func (c *checker) recordLit(e *RecordLit) Type {
	ty := c.lookupType(e.TyName, e.Span)
	rec, ok := ty.(*RecordT)
	if !ok {
		panic(typeErrorf(e.Span, "`%s` is not a record type", e.TyName))
	}
	given := map[string]int{}
	for at, f := range e.Fields {
		if _, twice := given[f.Name]; twice {
			panic(typeErrorf(f.Span, "field `%s` is given twice", f.Name))
		}
		if rec.index(f.Name) < 0 {
			panic(typeErrorf(f.Span, "`%s` has no field `%s`", rec.Name, f.Name))
		}
		given[f.Name] = at
	}
	ordered := make([]FieldInit, 0, len(rec.Fields))
	for _, want := range rec.Fields {
		at, ok := given[want.Name]
		if !ok {
			panic(typeErrorf(e.Span, "field `%s` is missing", want.Name))
		}
		init := e.Fields[at]
		c.unify(want.Ty, c.exp(init.Value), init.Span, "in field `"+want.Name+"`")
		ordered = append(ordered, init)
	}
	e.Fields = ordered
	return rec
}

func (c *checker) index(e *IndexExp) Type {
	arr := c.exp(e.Array)
	a, ok := arr.(*ArrayT)
	if !ok {
		panic(typeErrorf(e.Span, "`%v` is not an array", arr))
	}
	c.unify(tyInt, c.exp(e.Index), e.Index.at(), "as an array index")
	return a.Elem
}

func (c *checker) field(e *FieldExp) Type {
	ty := c.exp(e.Record)
	rec, ok := ty.(*RecordT)
	if !ok {
		panic(typeErrorf(e.Span, "`%v` is not a record", ty))
	}
	got := rec.fieldType(e.Name)
	if got == nil {
		panic(typeErrorf(e.Span, "`%s` has no field `%s`", rec.Name, e.Name))
	}
	e.Offset = rec.index(e.Name)
	return got
}

func (c *checker) binop(e *BinExp) Type {
	lhs := c.exp(e.Lhs)
	rhs := c.exp(e.Rhs)
	switch {
	case arithmetic(e.Op):
		c.unify(tyInt, lhs, e.Lhs.at(), "on the left of `"+e.Op+"`")
		c.unify(tyInt, rhs, e.Rhs.at(), "on the right of `"+e.Op+"`")
		return tyInt
	case e.Op == "^":
		c.unify(tyString, lhs, e.Lhs.at(), "on the left of `^`")
		c.unify(tyString, rhs, e.Rhs.at(), "on the right of `^`")
		return tyString
	case ordering(e.Op):
		switch lhs.(type) {
		case IntT, StringT:
			c.unify(lhs, rhs, e.Rhs.at(), "on the right of `"+e.Op+"`")
			return tyBool
		}
		panic(typeErrorf(e.Span, "`%s` compares int or string, not `%v`", e.Op, lhs))
	case equality(e.Op):
		_, lhsUnit := lhs.(UnitT)
		_, rhsUnit := rhs.(UnitT)
		if lhsUnit || rhsUnit {
			panic(typeErrorf(e.Span, "`%s` cannot compare `unit`", e.Op))
		}
		if !compatible(lhs, rhs) {
			panic(typeErrorf(e.Span, "`%s` compares `%v` with `%v`", e.Op, lhs, rhs))
		}
		return tyBool
	}
	panic(typeErrorf(e.Span, "unknown operator `%s`", e.Op))
}

func (c *checker) assign(e *AssignExp) Type {
	target := c.exp(e.Target)
	if v, ok := e.Target.(*VarExp); ok && v.Sym != nil && !v.Sym.Mutable {
		panic(typeErrorf(e.Span, "`%s` is a `val`, so it cannot be assigned", v.Sym.Name))
	}
	c.unify(target, c.exp(e.Value), e.Value.at(), "in an assignment")
	return tyUnit
}

func (c *checker) ifExp(e *IfExp) Type {
	c.unify(tyBool, c.exp(e.Cond), e.Cond.at(), "as an `if` condition")
	then := c.exp(e.Then)
	if e.Else == nil {
		c.unify(tyUnit, then, e.Then.at(), "in an `if` with no `else`")
		return tyUnit
	}
	els := c.exp(e.Else)
	if !compatible(then, els) {
		panic(typeErrorf(e.Span, "the branches differ: `%v` and `%v`", then, els))
	}
	if _, isNil := then.(NilT); isNil {
		return els
	}
	return then
}

func (c *checker) forExp(e *ForExp) Type {
	c.unify(tyInt, c.exp(e.Lo), e.Lo.at(), "as a `for` bound")
	c.unify(tyInt, c.exp(e.Hi), e.Hi.at(), "as a `for` bound")
	e.Sym = newVar(e.Name, tyInt, false, c.depth)
	c.push()
	c.bindVal(e.Name, e.Sym)
	c.loops++
	c.unify(tyUnit, c.exp(e.Body), e.Body.at(), "in a `for` body")
	c.loops--
	c.pop()
	return tyUnit
}
