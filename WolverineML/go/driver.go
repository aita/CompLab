// The pipeline, and the toolchain around it.
//
//	source ─lex─▶ tokens ─parse─▶ tree ─check─▶ typed tree ─lower─▶ CFG
//	       ─ssa─▶ SSA ─opt─▶ SSA ─select─▶ machine IR ─out of SSA─▶
//	       ─regalloc─▶ coloured ─emit─▶ ARMv8
//
// Assembling and linking is left to a cross `gcc`, and running to `qemu-aarch64`
// when the machine underneath is not itself an ARM.

package main

import (
	_ "embed"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

//go:embed runtime/runtime.c
var runtimeSource string

var stages = []string{"tokens", "ast", "ir", "ssa", "opt", "dag", "mach", "flat", "ra", "asm"}

type options struct {
	checks   bool
	optimise bool
	maxRegs  int // 0 for the whole machine
}

func defaultOptions() options { return options{checks: true, optimise: true} }

func (o options) registers() Registers {
	if o.maxRegs == 0 {
		return allRegisters()
	}
	return limitedRegisters(o.maxRegs)
}

func toIR(source string, opts options) (*Module, error) {
	prog, err := parse(source)
	if err != nil {
		return nil, err
	}
	if err := check(prog); err != nil {
		return nil, err
	}
	return lower(prog, lowerOptions{checks: opts.checks}), nil
}

// compileModule is the pipeline, stopped as soon as `upto` has something to show.
//
// There is one of these and not two: a dump is the pipeline halted, not a second
// description of it that has to be kept in step.
func compileModule(source string, opts options, upto string) (*Module, error) {
	mod, err := toIR(source, opts)
	if err != nil {
		return nil, err
	}
	if upto == "ir" {
		return mod, nil
	}
	constructSSAModule(mod)
	if upto == "ssa" {
		return mod, nil
	}
	if opts.optimise {
		optimise(mod)
	}
	if upto == "opt" {
		return mod, nil
	}
	for _, f := range mod.Funcs {
		splitCriticalEdges(f)
	}
	if upto == "dag" {
		return mod, nil // the DAGs are a view of this, taken without changing it
	}
	selectModule(mod)
	verifyMachModule(mod)
	if upto == "mach" {
		return mod, nil
	}
	destructModule(mod)
	if upto == "flat" {
		return mod, nil
	}
	if err := allocateModule(mod, opts.registers()); err != nil {
		return nil, err
	}
	return mod, nil
}

func compileToAsm(source string, opts options, make newEmitter) (string, error) {
	mod, err := compileModule(source, opts, "asm")
	if err != nil {
		return "", err
	}
	return emitModule(mod, make), nil
}

// stage runs the pipeline as far as `name`, and shows what it has by then.
func stage(source, name string, opts options) (string, error) {
	switch name {
	case "tokens":
		toks, err := lex(source)
		if err != nil {
			return "", err
		}
		lines := make([]string, len(toks))
		for at, t := range toks {
			lines[at] = fmt.Sprintf("%v\t%s\t%s", t.at, t.kind.name(), asText(t.text))
		}
		return strings.Join(lines, "\n"), nil
	case "ast":
		prog, err := parse(source)
		if err != nil {
			return "", err
		}
		if err := check(prog); err != nil {
			return "", err
		}
		return showProgram(prog), nil
	}
	mod, err := compileModule(source, opts, name)
	if err != nil {
		return "", err
	}
	switch name {
	case "dag":
		return showDags(mod), nil
	case "asm":
		return emitModule(mod, plainEmitter), nil
	}
	return showModule(mod), nil
}

func showDags(mod *Module) string {
	parts := make([]string, len(mod.Funcs))
	for at, f := range mod.Funcs {
		graphs := selectionGraphs(f)
		blocks := make([]string, len(graphs))
		for g, graph := range graphs {
			blocks[g] = f.Order[g] + ":\n" + showDag(graph)
		}
		parts[at] = "fun " + f.Label + "\n" + strings.Join(blocks, "\n")
	}
	return strings.Join(parts, "\n\n") + "\n"
}

// -- the toolchain ------------------------------------------------------------

var errNoToolchain = errors.New("no toolchain")

func toolchainError(format string, args ...any) error {
	return fmt.Errorf("%w: %s", errNoToolchain, fmt.Sprintf(format, args...))
}

func onArm() bool { return runtime.GOARCH == "arm64" }

func crossCC() (string, error) {
	if override := os.Getenv("WOLV_CC"); override != "" {
		return override, nil
	}
	for _, name := range []string{
		"aarch64-linux-gnu-gcc", "aarch64-linux-gnu-cc", "aarch64-none-linux-gnu-gcc",
	} {
		if found, err := exec.LookPath(name); err == nil {
			return found, nil
		}
	}
	if onArm() {
		for _, name := range []string{"cc", "gcc"} {
			if found, err := exec.LookPath(name); err == nil {
				return found, nil
			}
		}
	}
	return "", toolchainError("no ARM compiler found; install aarch64-linux-gnu-gcc or set WOLV_CC")
}

func emulator() ([]string, error) {
	if onArm() {
		return nil, nil
	}
	for _, name := range []string{"qemu-aarch64", "qemu-aarch64-static"} {
		if found, err := exec.LookPath(name); err == nil {
			return []string{found}, nil
		}
	}
	return nil, toolchainError("no qemu-aarch64 found, and this machine is not an ARM")
}

func buildBinary(source, out string, opts options, make newEmitter) error {
	asm, err := compileToAsm(source, opts, make)
	if err != nil {
		return err
	}
	cc, err := crossCC()
	if err != nil {
		return err
	}
	tmp, err := os.MkdirTemp("", "wolv")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)

	assembly := filepath.Join(tmp, "program.s")
	if err := os.WriteFile(assembly, []byte(asm), 0o644); err != nil {
		return err
	}
	// The run-time system travels in the binary and is unpacked to compile.
	csource := filepath.Join(tmp, "runtime.c")
	if err := os.WriteFile(csource, []byte(runtimeSource), 0o644); err != nil {
		return err
	}
	cmd := exec.Command(cc, "-static", "-O2", "-o", out, assembly, csource)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return toolchainError("the assembler refused it:\n%s", stderr.String())
	}
	return nil
}

type completed struct {
	exitCode int
	stdout   string
	stderr   string
}

// runProgram compiles, links and runs.  A stdin of nil hands the program the
// standard input this process was given.
func runProgram(source string, opts options, stdin *string, make newEmitter) (completed, error) {
	tmp, err := os.MkdirTemp("", "wolv")
	if err != nil {
		return completed{}, err
	}
	defer os.RemoveAll(tmp)

	binary := filepath.Join(tmp, "program")
	if err := buildBinary(source, binary, opts, make); err != nil {
		return completed{}, err
	}
	prefix, err := emulator()
	if err != nil {
		return completed{}, err
	}
	command := append(append([]string(nil), prefix...), binary)
	cmd := exec.Command(command[0], command[1:]...)
	if stdin != nil {
		cmd.Stdin = strings.NewReader(*stdin)
	} else {
		cmd.Stdin = os.Stdin
	}
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err = cmd.Run()
	code := 0
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			code = exit.ExitCode()
		} else {
			return completed{}, err
		}
	}
	return completed{exitCode: code, stdout: stdout.String(), stderr: stderr.String()}, nil
}
