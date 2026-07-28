# rvemu

**RV64GC のユーザモード・エミュレータ**。静的リンクされた RISC-V の ELF と、アセンブリ（`.s`）の両方を読み込んで実行する。**gdb リモートシリアルプロトコル**を喋るので、`target remote` でブレークポイント・シングルステップ・バックトレースがそのまま使える。

姉妹プロジェクト `minpython-cpp` / `Smalltalk/cpp` と同様、**C++23 モジュール**（`rvemu` を partition に分割）で構成し、clang++ / CMake / ninja でビルドする。標準ライブラリは **`import std;`**（`#include` は POSIX ヘッダとマクロだけ）。**例外は使わない**（`-fno-exceptions -fno-rtti`）—— エラーはラッチ `Diag` で伝播する。

同じリポジトリの [`MartenML/`](../MartenML) が吐く RISC-V バイナリを、`qemu-riscv64` の代わりにそのまま走らせられる。

中身の解説は [`doc/index.md`](doc/index.md) にある（1章が1つの部品、日本語）。この README は使い方と対応範囲だけを扱う。

```sh
$ ./build/rvemu examples/fib.s
fib(20) = 6765
```

## ビルドと実行

```sh
cmake -G Ninja -B build -DCMAKE_BUILD_TYPE=Release
ninja -C build
ctest --test-dir build                    # ユニットテスト

./build/rvemu ./hello                     # 静的 ELF を実行
./build/rvemu examples/hello.s            # アセンブルして実行
./build/rvemu -d examples/fib.s           # 逆アセンブル
./build/rvemu -t examples/fib.s           # 命令トレース
./build/rvemu -T ./hello                  # syscall トレース
./build/rvemu -s ./hello                  # 命令数・syscall 数・ページ数
./build/rvemu -g 1234 ./hello             # gdb を待って停止
```

> `import std;` は CMake の実験的機能。`CMAKE_EXPERIMENTAL_CXX_IMPORT_STD` の UUID は CMake のバージョン依存なので、CMake を更新して怒られたら `CMakeLists.txt` の UUID を差し替える。clang++ ＋ libstdc++ で検証済み。

プログラム名より後ろの引数はすべてゲストの `argv` に渡る（`env` や `qemu-user` と同じ）。環境変数も既定でホストからそのまま引き継ぐ。

```sh
$ ./build/rvemu examples/echo.s one two three
examples/echo.s one two three
```

## 対応範囲

### 命令セット —— RV64IMAFDC + Zicsr

| | |
|---|---|
| **I** | RV64I 基本整数命令（`lwu`/`ld`/`sd`、`*w` 系を含む） |
| **M** | 乗除算。0 除算・`INT64_MIN / -1` はトラップせず仕様どおりの値を返す |
| **A** | `lr`/`sc` と 9 種の AMO を .w/.d 両方。1 hart なので `aq`/`rl` は素通し |
| **F/D** | 単精度・倍精度の全命令。丸めモード、`fflags`、NaN boxing、`fclass` |
| **C** | 圧縮命令。32 ビット形へ展開してから 1 つのデコーダに通す |
| **Zicsr** | `fflags` / `frm` / `fcsr` / `cycle` / `time` / `instret` |

### 実行環境 —— Linux/RV64 ユーザモード

`ecall` は asm-generic の syscall 表として解釈し、ホストへ中継する。ゲストのファイルディスクリプタはホストのそれそのものなので、ゲストの標準出力は本当にエミュレータの標準出力になる。

- 入出力: `read` `write` `readv` `writev` `pread64` `pwrite64` `openat` `close` `lseek` `fcntl` `getdents64` `ioctl`（端末問い合わせのみ）
- ファイル: `fstat` `newfstatat` `statx` `readlinkat` `faccessat` `unlinkat` `chdir` `getcwd`
- 多重化: `ppoll` `pselect6`
- メモリ: `brk` `mmap` `munmap` `mprotect` `madvise`
- 時刻: `clock_gettime` `clock_getres` `clock_nanosleep` `gettimeofday` `times`
- その他: `uname` `getpid` `getuid` 系 `prlimit64` `sched_getaffinity` `getrandom` `exit` `exit_group` `kill`/`tgkill`（自プロセス宛は終了）
- シグナル・スレッド系（`rt_sigaction`、`set_robust_list`、`rseq` …）は成功を返して何もしない。`clone` / `execve` は `ENOSYS`

これで **静的リンクした glibc の C プログラム**が動く。`printf` も `malloc` も `qsort` も `fopen` も、浮動小数点も含めて `qemu-riscv64` と同じ出力になる。

```sh
$ riscv64-linux-gnu-gcc -static -O2 hello.c -o hello -lm
$ ./build/rvemu ./hello
```

## 内蔵アセンブラ

`.s` を渡すとその場でアセンブルして実行する。外部ツールチェーンは要らない。GNU as の方言を受け付ける。

- **命令**: RV64GC の全ニーモニックと、擬似命令（`li` `la` `lla` `call` `tail` `mv` `not` `neg` `negw` `sext.w` `seqz` `snez` `sltz` `sgtz` `beqz` `bnez` `blez` `bgez` `bltz` `bgtz` `bgt` `ble` `bgtu` `bleu` `j` `jr` `ret` `nop` `fmv.s/d` `fneg.s/d` `fabs.s/d` `csrr` `csrw` `csrs` `csrc` `csrwi` `csrsi` `csrci` `rdcycle` `rdtime` `rdinstret`）
- **ディレクティブ**: `.text` `.data` `.rodata` `.bss` `.section` `.byte` `.half` `.word` `.dword`（別名込み）`.string` `.asciz` `.ascii` `.zero` `.space` `.align` `.balign` `.p2align` `.equ` `.set`。`.globl` `.type` `.size` `.cfi_*` などリンカ向けのものは受理して無視する
- **式**: `+ - * / % << >> & | ^ ~ ()`、10/16/8/2 進数、文字リテラル、`.`（現在位置）、`%hi` `%lo` `%pcrel_hi` `%pcrel_lo`
- **ラベル**: 通常のラベルと、数字のローカルラベル（`1:` に対する `1f` / `1b`）

[`tests/isa.s`](tests/isa.s)（164 行のニーモニックが 172 命令に展開される）を GNU as でアセンブル・リンクしたものと、内蔵アセンブラの出力とで、**逆アセンブル結果が完全に一致する**ことを [`tests/compare-with-gnu-as.sh`](tests/compare-with-gnu-as.sh) で確認できる。`MartenML` が吐くアセンブリもそのまま通る。

セクションは `0x10000` から順に、各々ページ境界に置かれる。エントリポイントは `_start`、無ければ `main`、それも無ければ `.text` の先頭。

## gdb

`-g PORT` で待ち受け、gdb が繋がるまで止まる。

```sh
$ ./build/rvemu -g 1234 ./prog
rvemu: waiting for gdb on 127.0.0.1:1234
rvemu: (gdb) target remote :1234
```

別の端末で:

```sh
$ gdb -q ./prog
(gdb) target remote :1234
(gdb) break main
(gdb) continue
(gdb) bt
(gdb) print n
(gdb) stepi
(gdb) x/4i $pc
(gdb) info registers
```

ホストの `gdb` が `riscv:rv64` を扱えればそれで足りる（`gdb -ex 'set architecture riscv:rv64'` で確認できる）。扱えなければ `riscv64-unknown-elf-gdb` などを使う。

対応しているのは: `qSupported` / `QStartNoAckMode`、レジスタの一括・個別読み書き（`g` `G` `p` `P`）、メモリの読み書き（`m` `M` `X`）、`c` `s` `vCont`、ソフトウェアブレークポイント（`Z0`/`z0`）、`qXfer:features:read:target.xml` によるレジスタ定義の提供、実行中の ^C 割り込み、`D`（デタッチして走らせ切る）と `k`。

ウォッチポイント（`Z2`〜`Z4`）は未対応 —— gdb はソフトウェアウォッチポイント（シングルステップ）に自動的に落ちるので、動くには動く（遅い）。

## 設計

詳しくは [`doc/index.md`](doc/index.md)。要点だけ挙げると:

- **アドレス空間**は 4 KiB ページのハッシュマップ ＋ 256 エントリの TLB。権限はゲストのアクセスごとに検査し、ローダとデバッガだけが `peek`/`poke` の裏口を通る（[1章](doc/memory.md)）
- **C 拡張**は 32 ビット形に展開してから1本のデコーダに通す。正しく保つデコーダが1つで済む（[2章](doc/decode.md)）
- **浮動小数点**は soft-float を持たず、ホスト FPU との差分 —— NaN の正規化、`fmin`/`fmax`、`fcvt` の飽和 —— だけを書く。埋まっていないのは RMM 丸めが算術命令で RNE に落ちることだけで、`qemu-riscv64` との差分として測ってある（[4章](doc/float.md)）
- **アセンブラ**はリラクゼーションをしない。どの命令の大きさも構文から決まるので、シンボルの値が分かる前にレイアウトが確定する（[7章](doc/assembler.md)）
- **ブレークポイント**はゲストのテキストを書き換えない。圧縮命令は 2 バイトしかなく、4 バイトの `ebreak` を埋める方式は隣を潰す（[8章](doc/gdb.md)）
- **トラップの境界**は `Cpu` の外。`ecall` に当たったら止まって理由を返すだけなので、gdb は `write()` の途中のゲストをシングルステップできる（[3章](doc/exec.md)）

## ファイル

| | |
|---|---|
| `src/common.cppm` | 整数の別名、ラッチ `Diag`、符号拡張 |
| `src/memory.cppm` | ゲストのアドレス空間（スパースなページ表 + TLB + 権限） |
| `src/cpu.cppm` | hart の状態と、ホスト FPU との橋渡し |
| `src/decode.cppm` | デコーダ、C 拡張の展開、そしてエンコーダ |
| `src/disasm.cppm` | `Inst` → テキスト |
| `src/exec.cppm` | インタプリタ本体 |
| `src/elf.cppm` | ELF64 のロードと、`Image`（両フロントエンドの共通出力） |
| `src/syscall.cppm` | `ecall` の実装 |
| `src/assembler.cppm` | アセンブラ |
| `src/machine.cppm` | プロセスの起動（argv/envp/auxv）と実行ループ |
| `src/gdbstub.cppm` | gdb リモートシリアルプロトコル |
| `src/main.cpp` | コマンドライン |
| `doc/` | 解説（[目次](doc/index.md)） |
| `tests/compare-with-gnu-as.sh` | 内蔵アセンブラを GNU as と突き合わせる |

## 制限

- **動的リンクは扱わない**。`PT_INTERP` を持つ ELF はエラーになる（`-static` で作り直せ、というメッセージを出す）。インタプリタを持たない static PIE は、`R_RISCV_RELATIVE` を自前で適用して動く。
- **1 hart のみ**。`clone` は `ENOSYS` を返し、`futex` の `FUTEX_WAIT` は `EAGAIN` を返す。
- **シグナルハンドラは走らない**。自プロセス宛の `kill`/`tgkill` は `128 + signo` で終了する（`abort()` はこれで期待どおりに死ぬ）。
- **RMM 丸めは算術命令では RNE になる**（変換命令は厳密）。
- **ウォッチポイントはハードウェア支援なし**（gdb 側のソフトウェア実装に落ちる）。
- **V 拡張・特権モード・MMU はない**。ここはユーザモードのエミュレータで、そこから先は別の道具の仕事になる。
