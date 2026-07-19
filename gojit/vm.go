package main

import "unsafe"

type ObjectKind uint8

const (
	KindNil ObjectKind = iota
	KindObject
)

type Object struct {
	Kind    ObjectKind
	Pointer unsafe.Pointer
}

type Value uint64

type VM struct {
	globals []Value
	stack   []Value
	sp      uint
	fp      uint

	objects []Object

	jit JITContext
}

type JITContext struct {
	Stack    *Value
	SP       uintptr
	FP       uintptr
	StackCap uintptr

	Globals    *Value
	NumGlobals uintptr
}

func newVM() *VM {
	return &VM{
		globals: make([]Value, 10, 10),
		stack:   make([]Value, 10, 10),
		sp:      0,
		fp:      0,
		jit:     JITContext{},
	}
}

func (vm *VM) push(val Value) {
	vm.stack[vm.sp] = val
	vm.sp++
}

func (vm *VM) pop() Value {
	vm.sp--
	return vm.stack[vm.sp]
}

func (vm *VM) syncJITContext() {
	vm.jit.Stack = &vm.stack[0]
	vm.jit.StackCap = uintptr(len(vm.stack))
	vm.jit.SP = uintptr(unsafe.Pointer(&vm.stack[vm.sp]))
	vm.jit.FP = uintptr(unsafe.Pointer(&vm.stack[vm.fp]))
	vm.jit.Globals = &vm.globals[0]
	vm.jit.NumGlobals = uintptr(len(vm.globals))
}

func (vm *VM) callJITFunc(entry uintptr) Value {
	vm.syncJITContext()

	result := callJIT(entry, &vm.jit)
	return Value(result)
}
