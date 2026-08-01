// The command line.

package main

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

const usage = `usage: wolv <command> <file.wol> [options]

  build   compile and link an executable
  run     compile, link, and run it
  emit    dump one stage of the pipeline
  check   typecheck only

  -o, --out PATH    where ` + "`build`" + ` writes the executable
  -s, --stage NAME  which stage ` + "`emit`" + ` shows: %s
  --no-checks       leave out the nil, bounds and divide-by-zero checks
  --no-opt          do not optimise the SSA
  --max-regs N      pretend the machine has this many registers, to force spilling
`

type arguments struct {
	command  string
	file     string
	out      string
	stage    string
	noChecks bool
	noOpt    bool
	maxRegs  int
}

func parseArguments(argv []string) (arguments, error) {
	args := arguments{stage: "asm"}
	var positional []string
	value := func(at int, flag string) (string, error) {
		if at >= len(argv) {
			return "", fmt.Errorf("`%s` wants a value", flag)
		}
		return argv[at], nil
	}
	for at := 0; at < len(argv); at++ {
		arg := argv[at]
		var err error
		switch arg {
		case "-o", "--out":
			at++
			args.out, err = value(at, arg)
		case "-s", "--stage":
			at++
			args.stage, err = value(at, arg)
		case "--no-checks":
			args.noChecks = true
		case "--no-opt":
			args.noOpt = true
		case "--max-regs":
			at++
			var text string
			if text, err = value(at, arg); err == nil {
				if args.maxRegs, err = strconv.Atoi(text); err != nil {
					err = errors.New("`--max-regs` wants a number")
				}
			}
		case "-h", "--help":
			return args, errors.New("")
		default:
			if strings.HasPrefix(arg, "-") {
				err = fmt.Errorf("no such option as `%s`", arg)
			} else {
				positional = append(positional, arg)
			}
		}
		if err != nil {
			return args, err
		}
	}
	if len(positional) != 2 {
		return args, errors.New("a command and a file, and nothing else")
	}
	args.command, args.file = positional[0], positional[1]
	switch args.command {
	case "build", "run", "emit", "check":
	default:
		return args, fmt.Errorf("no such command as `%s`", args.command)
	}
	known := false
	for _, name := range stages {
		if name == args.stage {
			known = true
		}
	}
	if !known {
		return args, fmt.Errorf("no such stage as `%s`", args.stage)
	}
	return args, nil
}

func main() { os.Exit(wolv(os.Args[1:])) }

func wolv(argv []string) int {
	args, err := parseArguments(argv)
	if err != nil {
		fmt.Fprintf(os.Stderr, usage, strings.Join(stages, ", "))
		if err.Error() != "" {
			fmt.Fprintf(os.Stderr, "wolv: %v\n", err)
		}
		return 1
	}

	opts := options{
		checks:   !args.noChecks,
		optimise: !args.noOpt,
		maxRegs:  args.maxRegs,
	}
	source, err := os.ReadFile(args.file)
	if err != nil {
		fmt.Fprintf(os.Stderr, "wolv: %v\n", err)
		return 1
	}

	report := func(err error) int {
		var compile *wolvError
		if errors.As(err, &compile) {
			fmt.Fprintf(os.Stderr, "%s:%v\n", args.file, compile)
		} else {
			fmt.Fprintf(os.Stderr, "wolv: %v\n", err)
		}
		return 1
	}

	switch args.command {
	case "check":
		if _, err := toIR(string(source), opts); err != nil {
			return report(err)
		}
	case "emit":
		text, err := stage(string(source), args.stage, opts)
		if err != nil {
			return report(err)
		}
		fmt.Print(text)
	case "build":
		out := args.out
		if out == "" {
			out = strings.TrimSuffix(args.file, ".wol")
		}
		if err := buildBinary(string(source), out, opts, plainEmitter); err != nil {
			return report(err)
		}
	case "run":
		done, err := runProgram(string(source), opts, nil, plainEmitter)
		if err != nil {
			return report(err)
		}
		fmt.Print(done.stdout)
		fmt.Fprint(os.Stderr, done.stderr)
		return done.exitCode
	}
	return 0
}
