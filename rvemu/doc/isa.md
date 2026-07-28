# 付録A. 対応表

何が書けて何が動くかの一覧です。実装のほうを正としていて、表はそこから起こしてあります。

## 1. 命令

RV64IMAFDC + Zicsr。デコーダは 157 個の `Op`（`Illegal` を含む）を持ち、アセンブラの表には
156 個のニーモニックがあります。

### RV64I

```
lui auipc jal jalr
beq bne blt bge bltu bgeu
lb lh lw ld lbu lhu lwu
sb sh sw sd
addi slti sltiu xori ori andi slli srli srai
add sub sll slt sltu xor srl sra or and
addiw slliw srliw sraiw
addw subw sllw srlw sraw
fence fence.i ecall ebreak
```

シフト量は RV64 の doubleword 系が6ビット、`*w` 系が5ビットです。

### M

```
mul mulh mulhsu mulhu div divu rem remu
mulw divw divuw remw remuw
```

0 除算も `INT64_MIN / -1` もトラップせず、仕様の定める値を返します
（[3章 §3](exec.md#3-整数命令--仕様の角を丸めない)）。

### A

```
lr.w  sc.w  amoswap.w amoadd.w amoxor.w amoand.w amoor.w amomin.w amomax.w amominu.w amomaxu.w
lr.d  sc.d  amoswap.d amoadd.d amoxor.d amoand.d amoor.d amomin.d amomax.d amominu.d amomaxu.d
```

`.aq` `.rl` `.aqrl` の接尾辞は受け付けて符号化しますが、hart が1つなので実行時の意味は
ありません。

### F / D

```
flw fsw fld fsd
fadd.s fsub.s fmul.s fdiv.s fsqrt.s        fadd.d fsub.d fmul.d fdiv.d fsqrt.d
fmadd.s fmsub.s fnmsub.s fnmadd.s          fmadd.d fmsub.d fnmsub.d fnmadd.d
fsgnj.s fsgnjn.s fsgnjx.s fmin.s fmax.s    fsgnj.d fsgnjn.d fsgnjx.d fmin.d fmax.d
feq.s flt.s fle.s fclass.s                 feq.d flt.d fle.d fclass.d
fmv.x.w fmv.w.x                            fmv.x.d fmv.d.x
fcvt.w.s fcvt.wu.s fcvt.l.s fcvt.lu.s      fcvt.w.d fcvt.wu.d fcvt.l.d fcvt.lu.d
fcvt.s.w fcvt.s.wu fcvt.s.l fcvt.s.lu      fcvt.d.w fcvt.d.wu fcvt.d.l fcvt.d.lu
fcvt.s.d fcvt.d.s
```

丸めモードの接尾辞は `rne` `rtz` `rdn` `rup` `rmm` `dyn`。省略すると `dyn`（`fcsr` の
`frm` に従う）ですが、丸めが起こり得ない `fcvt.d.s` / `fcvt.d.w` / `fcvt.d.wu` だけは
`rne` になります —— GNU as がそうするからです。

**RMM は算術命令では RNE になります**（変換命令は厳密）。[4章 §7](float.md#7-rmm--借りられなかったもの)。

### C

圧縮命令は 32 ビット形に展開してからデコードします。書く側で `c.` 付きのニーモニックを
指定することはできません（GNU as の `.option arch, +c` 相当がありません）。読む側 ——
ELF の実行と `-d` —— は完全に対応しています。

### Zicsr

```
csrrw csrrs csrrc csrrwi csrrsi csrrci
```

読み書きできる CSR:

| 名前 | 番号 | |
|---|---|---|
| `fflags` | 0x001 | 累積例外フラグ |
| `frm` | 0x002 | 丸めモード |
| `fcsr` | 0x003 | 上の2つ |
| `cycle` | 0xc00 | 読み出し専用。`instret` と同じ値 |
| `time` | 0xc01 | 読み出し専用。起動時のナノ秒 + `instret` |
| `instret` | 0xc02 | 読み出し専用。退役した命令数 |

それ以外の CSR に触ると `Illegal` です。

## 2. 擬似命令

```
nop  mv  not  neg  negw  sext.w  zext.b  seqz  snez  sltz  sgtz
beqz bnez blez bgez bltz bgtz  bgt ble bgtu bleu
j  jr  ret  call  tail  la  lla  li
fmv.s fneg.s fabs.s  fmv.d fneg.d fabs.d
csrr csrw csrs csrc csrwi csrsi csrci
rdcycle rdtime rdinstret
unimp
```

大きさは構文から決まります。`call` `tail` `la` `lla` は常に8バイト、`li` はリテラルから
展開した長さ、他は4バイト。**`li` の引数は絶対値でなければなりません**
（[7章 §1](assembler.md#1-リラクゼーションをしないという決定)）。

シンボルを直に取るロード・ストアの形も使えます。

```asm
        lw      a0, symbol              # auipc a0, %pcrel_hi ; lw a0, %pcrel_lo(a0)
        sw      a0, symbol, t0          # 第3オペランドがアドレスを持つ一時レジスタ
```

## 3. ディレクティブ

**中身を作るもの**

```
.byte  .half .short .2byte  .word .long .4byte  .dword .quad .8byte
.string .asciz .ascii  .zero .space .skip
```

**位置を決めるもの**

```
.text .data .rodata .bss .section
.align .p2align  .balign
.equ .set
```

`.align` と `.p2align` は 2^n、`.balign` は n バイト。セクションは最初に現れた順に
`0x10000` から各々ページ境界に置かれ、権限は名前で決まります（`.text` が RX、`.rodata` が
R、それ以外が RW）。`.rodata.str1.8` のような名前は `.rodata` に畳まれます。

**受理して無視するもの**（リンカ向けの情報で、リンカがいないため）

```
.globl .global .local .weak .hidden .type .size .comm
.file .ident .option .attribute .addrsig .addrsig_sym  .cfi_*
```

## 4. 式と再配置

```
+  -  *  /  %  <<  >>  &  |  ^  ~  ( )
```

C と同じ優先順位。10進・16進（`0x`）・8進（先頭 `0`）・2進（`0b`）、文字リテラル
（`'a'`、`'\n'`）、`.`（現在位置）、通常のシンボル、数字のローカルラベル（`1f` / `1b`）。

| | |
|---|---|
| `%hi(sym)` | 20 ビットの欄。`+0x800` 済み |
| `%lo(sym)` | 符号拡張した 12 ビット |
| `%pcrel_hi(sym)` | 同上、pc 相対 |
| `%pcrel_lo(label)` | 引数は**対になる `auipc` のラベル** |

## 5. システムコール

60 個。番号は asm-generic（RV64 Linux のもの）です。

| 分類 | |
|---|---|
| 入出力 | `read`(63) `write`(64) `readv`(65) `writev`(66) `pread64`(67) `pwrite64`(68) `openat`(56) `close`(57) `lseek`(62) `fcntl`(25) `getdents64`(61) `ioctl`(29) |
| ファイル | `fstat`(80) `newfstatat`(79) `statx`(291) `readlinkat`(78) `faccessat`(48) `unlinkat`(35) `chdir`(49) `getcwd`(17) |
| 多重化 | `ppoll`(73) `pselect6`(72) |
| メモリ | `brk`(214) `mmap`(222) `munmap`(215) `mprotect`(226) `madvise`(233) |
| 時刻 | `clock_gettime`(113) `clock_getres`(114) `clock_nanosleep`(115) `gettimeofday`(169) `times`(153) |
| 身元 | `getpid`(172) `getppid`(173) `gettid`(178) `getuid`(174) `geteuid`(175) `getgid`(176) `getegid`(177) `uname`(160) |
| 資源 | `prlimit64`(261) `sched_getaffinity`(123) `getrandom`(278) `getrusage`(165) `sysinfo`(179) |
| 終了 | `exit`(93) `exit_group`(94) `kill`(129) `tgkill`(131) |
| 受理して何もしない | `rt_sigaction`(134) `rt_sigprocmask`(135) `set_tid_address`(96) `set_robust_list`(99) `rseq`(293) `sched_yield`(124) |
| `-EAGAIN` / `-ENOMEM` | `futex`(98) `mremap`(216) |
| `-ENOSYS` | `clone`(220) `clone3`(435) `execve`(221)、および表にない番号すべて |

`ioctl` は端末の問い合わせ（`TCGETS` `TCSETS` `TCSETSW` `TCSETSF` `TIOCGWINSZ`）だけを
通し、それ以外は `-ENOTTY` を返します。

## 6. コマンドライン

```
rvemu [options] <program> [args...]
```

| | |
|---|---|
| `-g, --gdb PORT` | 127.0.0.1:PORT で gdb を待つ |
| `-a, --asm` | ELF に見えてもアセンブリとして読む |
| `-d, --disassemble` | 逆アセンブルして終わる |
| `-t, --trace` | 退役する命令を1つずつ出す |
| `-T, --trace-syscalls` | `ecall` とその結果を出す |
| `-n, --max-insns N` | N 命令で止める |
| `-s, --stats` | 命令数・syscall 数・ページ数を終了時に出す |
| `-e, --env NAME=VALUE` | 変数を1つ設定する（反復可）。環境を空から始める |
| `-h, --help` | 使い方 |

プログラム名より後ろはすべてゲストの `argv` です。`-e` を使わない限り、環境変数はホストの
ものをそのまま引き継ぎます。

## 7. 対応していないもの

| | |
|---|---|
| 動的リンク | `PT_INTERP` はエラー。静的 PIE は動く |
| V 拡張、Zfh、Q | `Illegal` |
| 特権モード、MMU、割り込み | ユーザモードのエミュレータなので範囲外 |
| 複数 hart、`clone` | `-ENOSYS` |
| シグナルハンドラ | 登録は受け付けるが配送しない |
| RMM 丸め（算術命令） | RNE になる |
| ウォッチポイント | gdb 側のソフトウェア実装に落ちる |
| `.macro` `.rept` `.if` | アセンブラにマクロプロセッサがない |
| オブジェクトファイルの出力 | メモリに貼るところまでしかしない |

---

[← 8. gdb スタブ](gdb.md) ／ [目次](index.md)
