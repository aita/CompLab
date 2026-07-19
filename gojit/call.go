package main

import "runtime"

type CallFrame struct {
	Args   [6]uintptr
	Floats [8]uintptr

	IntResult   uintptr
	FloatResult uintptr
}

func callNative(entry uintptr, frame *CallFrame) {
	if entry == 0 {
		panic("native entry is nil")
	}
	if frame == nil {
		panic("frame is nil")
	}

	callNativeRaw(entry, frame)

	runtime.KeepAlive(frame)
}

func callJIT(entry uintptr, jit *JITContext) uintptr {
	if entry == 0 {
		panic("jit entry is nil")
	}
	if jit == nil {
		panic("jit is nil")
	}

	result := callJITRaw(entry, jit)

	runtime.KeepAlive(jit)
	runtime.KeepAlive(jit.Stack)
	runtime.KeepAlive(jit.Globals)

	return result
}
