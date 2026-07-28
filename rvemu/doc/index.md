# rvemu — RISC-V が動くまで

RV64GC のユーザモード・エミュレータの解説です。1章が1つの部品に対応し、どの章も**実際に
動かした出力**を載せています。ダンプも数値も、手で書いたものはありません。

使い方と対応範囲は[README](../README.md) にまとまっています。ここはその中身の話です。

## 目次

**[0. ファイルからプロセスへ](overview.md)** — ELF なりアセンブリなりが、命令を1つずつ実行
されるところまで行く道筋を、部品1つずつ1段落で追います。まずここを読むと、以降の章がどこの
話か分かります。

### 前半 — 機械

| | | |
|---|---|---|
| 1 | [アドレス空間](memory.md) | `memory.cppm`。64ビットの空間を、ハッシュマップと 256 個の TLB で持つ |
| 2 | [デコードとエンコード](decode.md) | `decode.cppm`。C 拡張を展開してデコーダを1本にし、逆向きの表をアセンブラに貸す |
| 3 | [インタプリタ](exec.md) | `exec.cppm`・`cpu.cppm`。1命令を fetch して retire するまでと、トラップの境界 |
| 4 | [浮動小数点](float.md) | `cpu.cppm`・`exec.cppm`。soft-float を持たず、ホスト FPU との差分だけを書く |

### 後半 — 環境

| | | |
|---|---|---|
| 5 | [プロセスの起動](process.md) | `elf.cppm`・`machine.cppm`。PT_LOAD を貼り、argv/envp/auxv を積む |
| 6 | [システムコール](syscall.md) | `syscall.cppm`。`ecall` をホストの Linux に中継する |
| 7 | [アセンブラ](assembler.md) | `assembler.cppm`。リラクゼーションなしの3パス |
| 8 | [gdb スタブ](gdb.md) | `gdbstub.cppm`。リモートシリアルプロトコルと、テキストを汚さないブレークポイント |

### 付録

| | | |
|---|---|---|
| A | [対応表](isa.md) | 命令・擬似命令・ディレクティブ・システムコールの一覧 |

## 読み方

**動かし方だけ知りたいなら** [README](../README.md) です。この本は中身の話しかしません。

**通して読むなら** 0章から順に。前半（1〜4章）は「RISC-V の機械をどう作るか」、後半
（5〜8章）は「その機械をどう Linux のプロセスに見せ、どう外から覗くか」の話で、境目は
`ecall` です。

**1つだけ読むなら** [4章の浮動小数点](float.md)です。他の章は「仕様どおりに作る」話ですが、
4章だけは**ホストの FPU を借りたときにどこがずれるか**という別種の問題を扱っていて、
借りられないものが1つ残っています。

**手元で確かめるなら** 各章のダンプは次のコマンドで再現できます。

```sh
cmake -G Ninja -B build -DCMAKE_BUILD_TYPE=Release && ninja -C build

./build/rvemu -d examples/fib.s      # 逆アセンブル（2章・7章）
./build/rvemu -t examples/fib.s      # 命令トレース（3章）
./build/rvemu -T ./hello             # システムコールのトレース（6章）
./build/rvemu -s ./hello             # 命令数・syscall 数・ページ数（0章）
./build/rvemu -g 1234 ./hello        # gdb を待って止まる（8章）

ctest --test-dir build               # ユニットテスト 197 項目
tests/compare-with-gnu-as.sh         # GNU as と符号化を突き合わせる（7章）
```

`./hello` は静的リンクした RISC-V の実行ファイルです。手元にないなら:

```sh
riscv64-linux-gnu-gcc -static -O2 hello.c -o hello
```

## 各章の作り

どの章も同じ並びです。

- 本文（節番号つき）
- **していないこと** — 入れていない機能と、その理由（ある章だけ）
- **参考文献** — その章が拠っている仕様
- **実装の地図** — どのファイルの何行目に何があるか

---

[0. ファイルからプロセスへ →](overview.md)
