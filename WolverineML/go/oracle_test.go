// Random programs whose answer is known before they are compiled.
//
// The other tests say what the compiler should do; these say what the program
// should print, which is the only thing a user cares about.  A program is built at
// random, worked out here in Go with the language's arithmetic, and then compiled —
// so any disagreement is a bug in the compiler and not in a comparison between two
// of its own configurations.

package main

import (
	"fmt"
	"math/rand"
	"strconv"
	"strings"
	"testing"
)

const arraySize = 16

var (
	oracleVars      = []string{"v0", "v1", "v2", "v3"}
	oracleConstants = []int64{0, 1, 2, 3, 7, 8, 15, 16, 100, 4095, 4096, 65536, -1, -8, 1 << 40}
	oracleArguments = [][3]int64{
		{0, 0, 0}, {1, 2, 3}, {-1, 7, -13}, {1<<63 - 1, -1 << 63, 2},
	}
	oracleComparisons = []string{"=", "<>", "<", "<=", ">", ">="}
)

// literal writes a value the way the language does.  The most negative one is the
// one that has to be written as its own unsigned magnitude.
func literal(value int64) string {
	if value < 0 {
		return "~" + strconv.FormatUint(uint64(-value), 10)
	}
	return strconv.FormatInt(value, 10)
}

func compareValues(op string, a, b int64) bool {
	switch op {
	case "=":
		return a == b
	case "<>":
		return a != b
	case "<":
		return a < b
	case "<=":
		return a <= b
	case ">":
		return a > b
	default:
		return a >= b
	}
}

// -- expressions ---------------------------------------------------------------

type oracleNode interface{ isOracleNode() }

type oNum struct{ value int64 }
type oRead struct{ name string }
type oBin struct {
	op   string
	l, r oracleNode
}
type oChoose struct {
	op                 string
	x, y, then, orElse oracleNode
}

// oGet is `xs[index (e)]`, which only the imperative programs have.
type oGet struct{ where oracleNode }

func (oNum) isOracleNode()    {}
func (oRead) isOracleNode()   {}
func (oBin) isOracleNode()    {}
func (oChoose) isOracleNode() {}
func (oGet) isOracleNode()    {}

var errDividedByZero = fmt.Errorf("divided by zero")

func expression(rng *rand.Rand, depth int) oracleNode {
	if depth == 0 || rng.Float64() < 0.25 {
		if rng.Float64() < 0.5 {
			return oRead{name: []string{"a", "b", "c"}[rng.Intn(3)]}
		}
		return oNum{value: oracleConstants[rng.Intn(len(oracleConstants))]}
	}
	if rng.Float64() < 0.1 {
		return oChoose{
			op:     oracleComparisons[rng.Intn(len(oracleComparisons))],
			x:      expression(rng, depth-1),
			y:      expression(rng, depth-1),
			then:   expression(rng, depth-1),
			orElse: expression(rng, depth-1),
		}
	}
	return oBin{op: weightedOp(rng), l: expression(rng, depth-1), r: expression(rng, depth-1)}
}

// weightedOp picks `+` four times as often as `/`, so a program is mostly
// arithmetic rather than mostly divide-by-zero.
func weightedOp(rng *rand.Rand) string {
	ops := []struct {
		op     string
		weight int
	}{{"+", 4}, {"-", 3}, {"*", 3}, {"/", 1}, {"mod", 1}}
	total := 0
	for _, o := range ops {
		total += o.weight
	}
	roll := rng.Intn(total)
	for _, o := range ops {
		roll -= o.weight
		if roll < 0 {
			return o.op
		}
	}
	return "+"
}

func evaluate(node oracleNode, env map[string]int64) (int64, error) {
	switch n := node.(type) {
	case oRead:
		return env[n.name], nil
	case oNum:
		return n.value, nil
	case oChoose:
		x, err := evaluate(n.x, env)
		if err != nil {
			return 0, err
		}
		y, err := evaluate(n.y, env)
		if err != nil {
			return 0, err
		}
		if compareValues(n.op, x, y) {
			return evaluate(n.then, env)
		}
		return evaluate(n.orElse, env)
	case oBin:
		a, err := evaluate(n.l, env)
		if err != nil {
			return 0, err
		}
		b, err := evaluate(n.r, env)
		if err != nil {
			return 0, err
		}
		switch n.op {
		case "+":
			return a + b, nil
		case "-":
			return a - b, nil
		case "*":
			return a * b, nil
		}
		if b == 0 {
			return 0, errDividedByZero
		}
		if n.op == "/" {
			return a / b, nil
		}
		return a % b, nil
	}
	panic(fmt.Sprintf("%T has no value here", node))
}

func showNode(node oracleNode) string {
	switch n := node.(type) {
	case oRead:
		return n.name
	case oNum:
		return literal(n.value)
	case oChoose:
		return fmt.Sprintf("(if %s %s %s then %s else %s)",
			showNode(n.x), n.op, showNode(n.y), showNode(n.then), showNode(n.orElse))
	case oBin:
		return "(" + showNode(n.l) + " " + n.op + " " + showNode(n.r) + ")"
	case oGet:
		return "xs[index (" + showNode(n.where) + ")]"
	}
	panic(fmt.Sprintf("unknown %T", node))
}

// arithmeticProgram is `count` functions of three arguments, and what they print.
func arithmeticProgram(seed int64, count int) (string, string) {
	rng := rand.New(rand.NewSource(seed))
	var definitions, calls, expected []string
	for made := 0; made < count; {
		tree := expression(rng, 1+rng.Intn(5))
		values := make([]int64, len(oracleArguments))
		failed := false
		for at, args := range oracleArguments {
			env := map[string]int64{"a": args[0], "b": args[1], "c": args[2]}
			value, err := evaluate(tree, env)
			if err != nil {
				failed = true
				break
			}
			values[at] = value
		}
		if failed {
			continue
		}
		definitions = append(definitions,
			fmt.Sprintf("fun f%d (a : int, b : int, c : int) : int = %s", made, showNode(tree)))
		for at, args := range oracleArguments {
			written := []string{literal(args[0]), literal(args[1]), literal(args[2])}
			calls = append(calls, fmt.Sprintf(
				`val () = (printInt (f%d (%s)); print ("\n"))`, made, strings.Join(written, ", ")))
			expected = append(expected, strconv.FormatInt(values[at], 10))
		}
		made++
	}
	source := strings.Join(append(definitions, calls...), "\n") + "\n"
	return source, strings.Join(expected, "\n") + "\n"
}

// -- statements -----------------------------------------------------------------

type oracleStmt interface{ isOracleStmt() }

type sSet struct {
	name  string
	value oracleNode
}
type sPut struct{ where, value oracleNode }
type sSeq struct{ items []oracleStmt }
type sIf struct {
	op          string
	x, y        oracleNode
	then, else_ oracleStmt
}
type sFor struct {
	name   string
	lo, hi int
	body   oracleStmt
}

func (sSet) isOracleStmt() {}
func (sPut) isOracleStmt() {}
func (sSeq) isOracleStmt() {}
func (sIf) isOracleStmt()  {}
func (sFor) isOracleStmt() {}

func statement(rng *rand.Rand, depth int, scope []string, fresh *int) oracleStmt {
	roll := rng.Float64()
	switch {
	case depth > 0 && roll < 0.2:
		return sIf{
			op:    oracleComparisons[rng.Intn(len(oracleComparisons))],
			x:     place(rng, scope),
			y:     place(rng, scope),
			then:  statement(rng, depth-1, scope, fresh),
			else_: statement(rng, depth-1, scope, fresh),
		}
	case depth > 0 && roll < 0.45:
		*fresh++
		name := fmt.Sprintf("i%d", *fresh)
		return sFor{
			name: name, lo: rng.Intn(3), hi: 2 + rng.Intn(4),
			body: statement(rng, depth-1, append(append([]string{}, scope...), name), fresh),
		}
	case depth > 0 && roll < 0.55:
		return sSeq{items: []oracleStmt{
			statement(rng, depth-1, scope, fresh),
			statement(rng, depth-1, scope, fresh),
		}}
	case roll < 0.8:
		return sSet{name: oracleVars[rng.Intn(len(oracleVars))], value: place(rng, scope)}
	}
	return sPut{where: place(rng, scope), value: place(rng, scope)}
}

// place is an expression over the variables in scope and the array.
func place(rng *rand.Rand, scope []string) oracleNode {
	roll := rng.Float64()
	switch {
	case roll < 0.35:
		return oRead{name: scope[rng.Intn(len(scope))]}
	case roll < 0.5:
		return oNum{value: oracleConstants[rng.Intn(len(oracleConstants))]}
	case roll < 0.65:
		return oGet{where: place(rng, scope)}
	}
	return oBin{op: []string{"+", "-", "*"}[rng.Intn(3)], l: place(rng, scope), r: place(rng, scope)}
}

// cell is `index` in the generated program: the remainder, made positive.
func cell(value int64) int { return int(((value % arraySize) + arraySize) % arraySize) }

func runPlace(node oracleNode, env map[string]int64, array []int64) int64 {
	switch n := node.(type) {
	case oRead:
		return env[n.name]
	case oNum:
		return n.value
	case oGet:
		return array[cell(runPlace(n.where, env, array))]
	case oBin:
		a := runPlace(n.l, env, array)
		b := runPlace(n.r, env, array)
		switch n.op {
		case "+":
			return a + b
		case "-":
			return a - b
		}
		return a * b
	}
	panic(fmt.Sprintf("%T is not a place", node))
}

func runStatement(node oracleStmt, env map[string]int64, array []int64) {
	switch n := node.(type) {
	case sSet:
		env[n.name] = runPlace(n.value, env, array)
	case sPut:
		array[cell(runPlace(n.where, env, array))] = runPlace(n.value, env, array)
	case sSeq:
		for _, item := range n.items {
			runStatement(item, env, array)
		}
	case sIf:
		a := runPlace(n.x, env, array)
		b := runPlace(n.y, env, array)
		if compareValues(n.op, a, b) {
			runStatement(n.then, env, array)
		} else {
			runStatement(n.else_, env, array)
		}
	case sFor:
		for i := n.lo; i <= n.hi; i++ {
			env[n.name] = int64(i)
			runStatement(n.body, env, array)
		}
	}
}

func showStatement(node oracleStmt, indent string) string {
	switch n := node.(type) {
	case sSet:
		return indent + n.name + " := " + showNode(n.value)
	case sPut:
		return indent + "xs[index (" + showNode(n.where) + ")] := " + showNode(n.value)
	case sSeq:
		inner := make([]string, len(n.items))
		for at, item := range n.items {
			inner[at] = showStatement(item, indent+"  ")
		}
		return indent + "(\n" + strings.Join(inner, ";\n") + "\n" + indent + ")"
	case sIf:
		return fmt.Sprintf("%sif %s %s %s then\n%s\n%selse\n%s",
			indent, showNode(n.x), n.op, showNode(n.y),
			showStatement(n.then, indent+"  "), indent, showStatement(n.else_, indent+"  "))
	case sFor:
		return fmt.Sprintf("%sfor %s = %d to %d do\n%s",
			indent, n.name, n.lo, n.hi, showStatement(n.body, indent+"  "))
	}
	panic(fmt.Sprintf("unknown %T", node))
}

const oraclePreamble = `val xs = array (16, 0)
fun index (n : int) : int =
  let val r = n - n / 16 * 16 in
    if r < 0 then r + 16 else r
  end`

// imperativeProgram is a program of assignments, loops and branches over an array.
func imperativeProgram(seed int64, count int) (string, string) {
	rng := rand.New(rand.NewSource(seed))
	fresh := 0
	body := make([]oracleStmt, count)
	for at := range body {
		body[at] = statement(rng, 3, oracleVars, &fresh)
	}
	env := map[string]int64{}
	for _, name := range oracleVars {
		env[name] = 0
	}
	array := make([]int64, arraySize)
	for _, item := range body {
		runStatement(item, env, array)
	}

	var expected []string
	for _, name := range oracleVars {
		expected = append(expected, strconv.FormatInt(env[name], 10))
	}
	for _, v := range array {
		expected = append(expected, strconv.FormatInt(v, 10))
	}

	lines := []string{oraclePreamble}
	for _, name := range oracleVars {
		lines = append(lines, "var "+name+" = 0")
	}
	lines = append(lines, "val () = (")
	statements := make([]string, len(body))
	for at, item := range body {
		statements[at] = showStatement(item, "  ")
	}
	lines = append(lines, strings.Join(statements, ";\n"), ")")
	for _, name := range oracleVars {
		lines = append(lines, `val () = (printInt (`+name+`); print ("\n"))`)
	}
	lines = append(lines, `val () = for k = 0 to 15 do (printInt (xs[k]); print ("\n"))`)
	return strings.Join(lines, "\n") + "\n", strings.Join(expected, "\n") + "\n"
}

// -- the tests ------------------------------------------------------------------

var oracleConfigurations = []struct {
	name string
	opts options
}{
	{"default", defaultOptions()},
	{"no-opt", options{checks: true}},
	{"no-checks", options{optimise: true}},
	{"spilling", options{checks: true, optimise: true, maxRegs: 10}},
}

func checkAgainstOracle(t *testing.T, source, expected string, opts options) {
	t.Helper()
	done, err := runProgram(source, opts, nil, plainEmitter)
	if err != nil {
		t.Fatal(err)
	}
	if done.exitCode != 0 {
		t.Fatalf("exit %d: %s", done.exitCode, done.stderr)
	}
	if done.stdout == expected {
		return
	}
	got, want := strings.Split(done.stdout, "\n"), strings.Split(expected, "\n")
	for at := 0; at < len(got) && at < len(want); at++ {
		if got[at] != want[at] {
			t.Fatalf("line %d: got %s, want %s", at, got[at], want[at])
		}
	}
	t.Fatalf("%d lines, want %d", len(got), len(want))
}

func TestOracleArithmetic(t *testing.T) {
	needsToolchain(t)
	for _, seed := range []int64{1, 2} {
		source, expected := arithmeticProgram(seed, 25)
		for _, c := range oracleConfigurations {
			t.Run(fmt.Sprintf("seed%d/%s", seed, c.name), func(t *testing.T) {
				t.Parallel()
				checkAgainstOracle(t, source, expected, c.opts)
			})
		}
	}
}

func TestOracleArraysLoopsAndBranches(t *testing.T) {
	needsToolchain(t)
	for _, seed := range []int64{1, 2} {
		source, expected := imperativeProgram(seed, 8)
		for _, c := range oracleConfigurations {
			t.Run(fmt.Sprintf("seed%d/%s", seed, c.name), func(t *testing.T) {
				t.Parallel()
				checkAgainstOracle(t, source, expected, c.opts)
			})
		}
	}
}

// TestACycleOfCopiesNeedsNoScratchRegister forces the swap: the borrowed register
// is what usually hides that path.
func TestACycleOfCopiesNeedsNoScratchRegister(t *testing.T) {
	needsToolchain(t)
	source := "fun swap (a : int, b : int) : int =\n" +
		"  if a > b then swap (b, a) else b * 10 + a\n" +
		`val () = (printInt (swap (1, 2)); print (" "); printInt (swap (7, 3)))` + "\n"
	if got := mustRun(t, source, defaultOptions(), nil); got != "21 73" {
		t.Fatalf("got %q", got)
	}
	asm, err := compileToAsm(source, defaultOptions(), swappingEmitter)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(asm, "eor x") {
		t.Error("no swap was written")
	}
	done, err := runProgram(source, defaultOptions(), nil, swappingEmitter)
	if err != nil {
		t.Fatal(err)
	}
	if done.stdout != "21 73" {
		t.Errorf("with swaps: got %q", done.stdout)
	}
}
