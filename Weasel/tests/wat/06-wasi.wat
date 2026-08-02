;; A WASI program, written out by hand: one `fd_write` with one iovec.
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)
  ;; 0..7 is the iovec: a pointer and a length. 8.. is the text.
  (data (i32.const 0) "\08\00\00\00\0e\00\00\00")
  (data (i32.const 8) "hello, weasel\n")

  (func (export "_start")
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 100))))
)

;;= invoke _start =>
;;= stdout hello, weasel
