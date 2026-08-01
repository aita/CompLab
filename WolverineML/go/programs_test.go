// End to end: compile to ARMv8, assemble, link, and run it.
//
// These are the only tests that need a toolchain.  Without a cross `gcc` and
// `qemu-aarch64` they skip rather than fail, so the rest of the suite still runs on
// a machine that has neither.

package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var configurations = []struct {
	name string
	opts options
}{
	{"default", defaultOptions()},
	{"no-opt", options{checks: true}},
	{"no-checks", options{optimise: true}},
	{"spilling", options{checks: true, optimise: true, maxRegs: 12}},
	{"spilling-no-opt", options{checks: true, maxRegs: 12}},
}

func needsToolchain(t *testing.T) {
	t.Helper()
	if _, err := crossCC(); err != nil {
		t.Skip(err)
	}
	if _, err := emulator(); err != nil {
		t.Skip(err)
	}
}

func wolFiles(t *testing.T, dir string) []string {
	t.Helper()
	names, err := filepath.Glob(filepath.Join(dir, "*.wol"))
	if err != nil || len(names) == 0 {
		t.Fatalf("no programs in %s: %v", dir, err)
	}
	return names
}

func mustRun(t *testing.T, source string, opts options, stdin *string) string {
	t.Helper()
	done, err := runProgram(source, opts, stdin, plainEmitter)
	if err != nil {
		t.Fatal(err)
	}
	if done.exitCode != 0 {
		t.Fatalf("exit %d: %s", done.exitCode, done.stderr)
	}
	return done.stdout
}

// TestPrograms: every option gives the same answer; only the code differs.
func TestPrograms(t *testing.T) {
	needsToolchain(t)
	for _, program := range wolFiles(t, "testdata/programs") {
		name := strings.TrimSuffix(filepath.Base(program), ".wol")
		source, err := os.ReadFile(program)
		if err != nil {
			t.Fatal(err)
		}
		expected, err := os.ReadFile(strings.TrimSuffix(program, ".wol") + ".out")
		if err != nil {
			t.Fatal(err)
		}
		for _, c := range configurations {
			t.Run(name+"/"+c.name, func(t *testing.T) {
				t.Parallel()
				if got := mustRun(t, string(source), c.opts, nil); got != string(expected) {
					t.Errorf("got:\n%s\nwant:\n%s", got, expected)
				}
			})
		}
	}
}

// TestExamplesAgreeWithThemselves: no expected output on file: what matters is
// that the stages agree.
func TestExamplesAgreeWithThemselves(t *testing.T) {
	needsToolchain(t)
	for _, example := range wolFiles(t, "examples") {
		name := strings.TrimSuffix(filepath.Base(example), ".wol")
		source, err := os.ReadFile(example)
		if err != nil {
			t.Fatal(err)
		}
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			baseline := mustRun(t, string(source), defaultOptions(), nil)
			if baseline == "" {
				t.Fatal("the example printed nothing")
			}
			for _, c := range configurations[1:] {
				if got := mustRun(t, string(source), c.opts, nil); got != baseline {
					t.Errorf("%s differs from the default", c.name)
				}
			}
		})
	}
}

func TestTheChecksCatchWhatTheyAreFor(t *testing.T) {
	needsToolchain(t)
	cases := []struct{ source, message string }{
		{"val a = array (3, 0)\nval () = printInt (a[5])", "outside an array"},
		{"type t = { x : int }\nval n : t = nil\nval () = printInt (n.x)", "field of nil"},
		{"var z = 0\nval () = printInt (7 / z)", "division by zero"},
	}
	for _, c := range cases {
		done, err := runProgram(c.source, defaultOptions(), nil, plainEmitter)
		if err != nil {
			t.Fatal(err)
		}
		if done.exitCode != 1 {
			t.Errorf("exit %d, want 1", done.exitCode)
		}
		if !strings.Contains(done.stderr, c.message) {
			t.Errorf("stderr is %q, want %q in it", done.stderr, c.message)
		}
	}
}

func TestACheckCanBeTurnedOff(t *testing.T) {
	needsToolchain(t)
	source := "val a = array (3, 0)\nval () = printInt (a[1])\n"
	if got := mustRun(t, source, options{optimise: true}, nil); got != "0" {
		t.Errorf("got %q", got)
	}
}

func TestStandardInput(t *testing.T) {
	needsToolchain(t)
	source := `
var line = ""
var c = getChar ()
val () = while c <> "" andalso c <> "\n" do (line := line ^ c; c := getChar ())
val () = print ("read: " ^ line ^ " (" ^ intToString (size (line)) ^ ")\n")
`
	stdin := "hello\n"
	if got := mustRun(t, source, defaultOptions(), &stdin); got != "read: hello (5)\n" {
		t.Errorf("got %q", got)
	}
}

func TestExitCode(t *testing.T) {
	needsToolchain(t)
	done, err := runProgram(`val () = (print ("bye\n"); exit (3))`, defaultOptions(), nil, plainEmitter)
	if err != nil {
		t.Fatal(err)
	}
	if done.exitCode != 3 {
		t.Errorf("exit %d, want 3", done.exitCode)
	}
	if done.stdout != "bye\n" {
		t.Errorf("got %q", done.stdout)
	}
}

func TestAToolchainErrorIsRecognisable(t *testing.T) {
	// The skip above relies on this, so it is worth one line.
	if !errors.Is(toolchainError("nothing here"), errNoToolchain) {
		t.Error("a toolchain error does not say so")
	}
}
