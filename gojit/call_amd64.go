//go:build linux && amd64

package main

func callNativeRaw(entry uintptr, frame *CallFrame)

func callJITRaw(entry uintptr, jit *JITContext) uintptr
