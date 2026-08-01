// The syntax tree.
//
// The tree the parser builds is untyped; the checker fills in the Ty and Sym
// fields as it goes, and everything after it reads them.
//
// The nodes carry an `Exp` suffix where the three-address IR wants the plain
// name for an instruction of its own: `BinExp` here, `Bin` in ir.go.

package main

// -- types as they are written -----------------------------------------------

// TyExp is a type as it was written down.  Only the three below implement it.
type TyExp interface {
	at() span
	isTyExp()
}

type TyName struct {
	Span span
	Name string
}

type TyArray struct {
	Span span
	Elem TyExp
}

type TyField struct {
	Name string
	Ty   TyExp
	Span span
}

type TyRecord struct {
	Span   span
	Fields []TyField
}

func (t *TyName) at() span   { return t.Span }
func (t *TyArray) at() span  { return t.Span }
func (t *TyRecord) at() span { return t.Span }

func (*TyName) isTyExp()   {}
func (*TyArray) isTyExp()  {}
func (*TyRecord) isTyExp() {}

// -- expressions -------------------------------------------------------------

// Exp is an expression.  Only the types in this file implement it.
type Exp interface {
	at() span
	ty() Type
	setTy(Type)
	isExp()
}

// ExpNode is what every expression carries: where it was written, and what the
// checker decided it is.
type ExpNode struct {
	Span span
	Ty   Type
}

// at builds the node of an expression at `s`, so a constructor reads as one line.
func node(s span) ExpNode { return ExpNode{Span: s} }

func (n *ExpNode) at() span     { return n.Span }
func (n *ExpNode) ty() Type     { return n.Ty }
func (n *ExpNode) setTy(t Type) { n.Ty = t }
func (n *ExpNode) isExp()       {}

type IntLit struct {
	ExpNode
	Value int64
}

type StrLit struct {
	ExpNode
	Value string
}

type BoolLit struct {
	ExpNode
	Value bool
}

type NilLit struct{ ExpNode }

type UnitLit struct{ ExpNode }

type VarExp struct {
	ExpNode
	Name string
	Sym  *VarSym
}

type CallExp struct {
	ExpNode
	Name string
	Args []Exp
	Sym  *FunSym
}

type FieldInit struct {
	Name  string
	Value Exp
	Span  span
}

type RecordLit struct {
	ExpNode
	TyName string
	Fields []FieldInit
}

type IndexExp struct {
	ExpNode
	Array Exp
	Index Exp
}

type FieldExp struct {
	ExpNode
	Record Exp
	Name   string
	Offset int
}

type NegExp struct {
	ExpNode
	Operand Exp
}

type BinExp struct {
	ExpNode
	Op  string
	Lhs Exp
	Rhs Exp
}

// LogicExp is `andalso` and `orelse`, which are control flow, not operators.
type LogicExp struct {
	ExpNode
	Op  string
	Lhs Exp
	Rhs Exp
}

type AssignExp struct {
	ExpNode
	Target Exp
	Value  Exp
}

type IfExp struct {
	ExpNode
	Cond Exp
	Then Exp
	Else Exp // nil when there is none
}

type WhileExp struct {
	ExpNode
	Cond Exp
	Body Exp
}

type ForExp struct {
	ExpNode
	Name string
	Lo   Exp
	Hi   Exp
	Body Exp
	Sym  *VarSym
}

type BreakExp struct{ ExpNode }

type SeqExp struct {
	ExpNode
	Items []Exp
}

type LetExp struct {
	ExpNode
	Decls []Decl
	Body  Exp
}

// -- declarations ------------------------------------------------------------

// Decl is a declaration.  Only the three below implement it.
type Decl interface {
	at() span
	isDecl()
}

type TypeBind struct {
	Name string
	Ty   TyExp
	Span span
}

type TypeDecl struct {
	Span  span
	Binds []TypeBind
}

type ValDecl struct {
	Span    span
	Name    string // "" for `val () =`, which a name can never be
	Ty      TyExp
	Init    Exp
	Mutable bool
	Sym     *VarSym
}

type Param struct {
	Name string
	Ty   TyExp
	Span span
	Sym  *VarSym
}

type FunBind struct {
	Name   string
	Params []Param
	Result TyExp // nil for a procedure
	Body   Exp
	Span   span
	Sym    *FunSym
}

type FunDecl struct {
	Span  span
	Binds []FunBind
}

func (d *TypeDecl) at() span { return d.Span }
func (d *ValDecl) at() span  { return d.Span }
func (d *FunDecl) at() span  { return d.Span }

func (*TypeDecl) isDecl() {}
func (*ValDecl) isDecl()  {}
func (*FunDecl) isDecl()  {}

type Program struct{ Decls []Decl }
