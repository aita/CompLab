package main

import (
	"fmt"
	"log"
	"os"
	"syscall"
	"unsafe"
)

func main() {
	pagesize := syscall.Getpagesize()
	buf, err := syscall.Mmap(-1, 0, pagesize, syscall.PROT_READ|syscall.PROT_WRITE|syscall.PROT_EXEC, syscall.MAP_ANONYMOUS|syscall.MAP_SHARED)
	if err != nil {
		log.Fatal(err)
	}
	defer func() {
		err := syscall.Munmap(buf)
		if err != nil {
			log.Fatal(err)
		}
	}()

	// r13 = jit.FP (&stack[fp]) を前提にする。
	// mov rax, [r13 + 0]  ; rax = stack[fp+0] = stack[0]
	// add rax, [r13 + 8]  ; rax += stack[fp+1] = stack[1]
	// ret                 ; rax = stack[0] + stack[1]
	//
	// r13(RBP系)は mod=00,rm=101 が RIP相対になるため disp8=0 を明示する。
	code := []byte{
		0x49, 0x8B, 0x45, 0x00,
		0x49, 0x03, 0x45, 0x08,
		0xC3,
	}
	copy(buf, code)

	err = syscall.Mprotect(buf, syscall.PROT_READ|syscall.PROT_EXEC)
	if err != nil {
		log.Fatal(err)
	}

	fptr := uintptr(unsafe.Pointer(&buf[0]))

	vm := newVM()
	vm.push(10)
	vm.push(20)
	result := vm.callJITFunc(fptr)
	fmt.Println("result:", result)

	os.Exit(0)
}
