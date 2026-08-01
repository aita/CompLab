// Source positions, and the one error every pass raises.

package main

import "fmt"

// span is a position in the source, counted from one.
type span struct {
	line int
	col  int
}

func (s span) String() string { return fmt.Sprintf("%d:%d", s.line, s.col) }

// errKind says which pass raised an error, so a test can ask for the one it means.
type errKind int

const (
	lexErr errKind = iota
	parseErr
	typeErr
)

// wolvError is a user-facing compile error, carrying where it happened.
type wolvError struct {
	kind errKind
	at   span
	msg  string
}

func (e *wolvError) Error() string { return fmt.Sprintf("%v: %s", e.at, e.msg) }

// The three below build the error; every call site panics with what they return,
// so that the panic is visible where it happens and the compiler can see that
// the line does not fall through.
func errorf(kind errKind, at span, format string, args ...any) *wolvError {
	return &wolvError{kind: kind, at: at, msg: fmt.Sprintf(format, args...)}
}

func lexErrorf(at span, format string, args ...any) *wolvError {
	return errorf(lexErr, at, format, args...)
}

func parseErrorf(at span, format string, args ...any) *wolvError {
	return errorf(parseErr, at, format, args...)
}

func typeErrorf(at span, format string, args ...any) *wolvError {
	return errorf(typeErr, at, format, args...)
}

// catch turns a panic carrying a *wolvError back into a returned error, and lets
// every other panic through.
//
// The scanner, the parser and the checker are recursive and every step of them
// can fail, so they say so by panicking and the entry point of each catches it.
// Threading an error return through a Pratt parser would say the same thing
// three times a line.  Nothing outside those three sees a panic.
func catch(err *error) {
	r := recover()
	if r == nil {
		return
	}
	if e, ok := r.(*wolvError); ok {
		*err = e
		return
	}
	panic(r)
}
