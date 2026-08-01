// Semantic types, and the symbols that carry them.
//
// Types are monomorphic.  Records are nominal — two record types with the same
// fields are different types — and everything else is structural, which for this
// language means arrays compare by their element type.

package main

// Type is what an expression has.  Only the seven below implement it.
type Type interface {
	String() string
	isType()
}

type IntT struct{}
type StringT struct{}
type BoolT struct{}
type UnitT struct{}

// NilT is the type of `nil` before it is known which record it stands for.
type NilT struct{}

func (IntT) String() string    { return "int" }
func (StringT) String() string { return "string" }
func (BoolT) String() string   { return "bool" }
func (UnitT) String() string   { return "unit" }
func (NilT) String() string    { return "nil" }

func (IntT) isType()    {}
func (StringT) isType() {}
func (BoolT) isType()   {}
func (UnitT) isType()   {}
func (NilT) isType()    {}

// The atoms carry nothing, so one value of each is all there is.
var (
	tyInt    Type = IntT{}
	tyString Type = StringT{}
	tyBool   Type = BoolT{}
	tyUnit   Type = UnitT{}
	tyNil    Type = NilT{}
)

// RecordField is one field of a record, in the order it was declared.
type RecordField struct {
	Name string
	Ty   Type
}

// RecordT is nominal, so it is always held by pointer and compared by identity.
type RecordT struct {
	Name   string
	Fields []RecordField
}

func (r *RecordT) String() string { return r.Name }
func (*RecordT) isType()          {}

func (r *RecordT) index(name string) int {
	for i, f := range r.Fields {
		if f.Name == name {
			return i
		}
	}
	return -1
}

func (r *RecordT) fieldType(name string) Type {
	if i := r.index(name); i >= 0 {
		return r.Fields[i].Ty
	}
	return nil
}

type ArrayT struct{ Elem Type }

func (a *ArrayT) String() string { return a.Elem.String() + " array" }
func (*ArrayT) isType()          {}

// sameType is type equality: nominal for records, structural for arrays.
func sameType(a, b Type) bool {
	switch a := a.(type) {
	case *RecordT:
		b, ok := b.(*RecordT)
		return ok && a == b
	case *ArrayT:
		b, ok := b.(*ArrayT)
		return ok && sameType(a.Elem, b.Elem)
	default:
		switch b.(type) {
		case *RecordT, *ArrayT:
			return false
		}
		return a == b
	}
}

// compatible is equality, but `nil` stands in for any record.
func compatible(a, b Type) bool {
	_, aNil := a.(NilT)
	_, bNil := b.(NilT)
	_, aRec := a.(*RecordT)
	_, bRec := b.(*RecordT)
	switch {
	case aNil && (bRec || bNil):
		return true
	case (aRec || aNil) && bNil:
		return true
	default:
		return sameType(a, b)
	}
}

// -- symbols -----------------------------------------------------------------

// Sym is what a name can be bound to: a variable, or a function.
type Sym interface{ isSym() }

func (*VarSym) isSym() {}
func (*FunSym) isSym() {}

// VarSym is one binding occurrence of a variable.
//
// Depth is the static nesting depth of the function that binds it.  A variable
// read from a deeper function escapes, and then it lives in a frame slot instead
// of a register.
type VarSym struct {
	Name    string
	Ty      Type
	Mutable bool
	Depth   int
	Escapes bool
	Slot    int
	Reg     Reg
}

func newVar(name string, ty Type, mutable bool, depth int) *VarSym {
	return &VarSym{Name: name, Ty: ty, Mutable: mutable, Depth: depth, Slot: -1, Reg: noReg}
}

func (v *VarSym) String() string { return v.Name }

// FunSym is a function.  Functions are not values, so there is no function type.
type FunSym struct {
	Name    string
	Label   string
	Params  []*VarSym
	Result  Type
	Depth   int
	Builtin string // "" unless it is one of the prelude's
}

func (f *FunSym) String() string { return f.Name }
