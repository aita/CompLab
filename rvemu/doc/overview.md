# 0. ファイルからプロセスへ

`rvemu ./hello` と打ってから `hello` が終わるまでに、何がどの順で起きるかを部品1つずつ
追います。以降の章はここに出てくる箱をそれぞれ開けたものです。

## 1. 入口を選ぶ — `main.cpp`

プログラム名より後ろの引数はすべてゲストのものになります。`env` や `qemu-user` と同じで、
誰宛のオプションかで迷う余地をなくすためです。

ファイルの先頭4バイトを読んで、`\x7fELF` ならローダへ、そうでなければアセンブラへ渡します。
拡張子は見ません（`-a` で強制できます）。どちらの経路も同じ `Image` を返すので、この先は
出どころを区別しません。

```
Image { entry, brk, phdr/phent/phnum, load_bias, path, symbols, text }
```

`entry` は最初の pc、`brk` はヒープの底、`phdr` 三点は auxv に載せる値、`symbols` はトレース
とフォールト報告のためのもの、`text` は `-d` が歩く範囲です。

## 2. メモリに貼る — `elf.cppm` / `assembler.cppm`

ELF なら PT_LOAD をページに貼ります。ここはリンカではなくカーネルの仕事をする場所で、
やることは「セグメントを写して、権限を付けて、bss は触らない」だけです。ページは生まれた
ときに 0 なので、bss にすることはありません。`PT_INTERP` があれば、そこで諦めて
「`-static` で作り直せ」と言います（[5章](process.md)）。

アセンブリなら、その場でアセンブルして同じようにページに貼ります。セクションは
`0x10000` から順に、各々ページ境界に置かれます（[7章](assembler.md)）。

どちらも書き込みには `poke` を使います。テキストはこのあと読み取り専用になりますが、貼って
いるのはゲストではなくローダなので、権限検査の外側を通ります（[1章](memory.md)）。

## 3. プロセスの形を作る — `machine.cppm`

2^47 の直下に 8 MiB のスタックを貼り、その一番上に文字列を積み、下に向かって
argc / argv / NULL / envp / NULL / auxv を並べます。sp はその塊の底を指します。

```
$ rvemu -g 1234 ./hello        # 別端末の gdb から見た、走り出す直前
sp = 0x7fffffffdb30
0x7fffffffdb30:	0x0000000000000001	0x00007fffffffeff2
0x7fffffffdb40:	0x0000000000000000	0x00007fffffffefdf
0x7fffffffdb50:	0x00007fffffffefce	0x00007fffffffef4d
```

argc が 1、argv[0] が文字列領域を指し、NULL が来て、そこから envp が続きます。この形が
1バイトでもずれると、C ランタイムは自分の TLS を作る途中で理由の分からない死に方をします。
auxv がなぜ効くのかは[5章 §3](process.md#3-auxv--c-ランタイムが本当に読むもの)です。

## 4. 1命令ずつ — `exec.cppm`

pc の指す 16 ビットを読み、下位2ビットが `11` でなければ圧縮命令なので 32 ビット形へ展開し、
そうでなければもう 16 ビット読んで繋げます。展開してからデコードするので、**正しく書くべき
デコーダは1本だけ**です（[2章](decode.md)）。

デコードした `Inst` を大きな switch に通します。`Cpu` が知っているのは「1命令を fetch して
decode して retire する」ことだけで、システムコールもデバッガも知りません。`ecall` に
当たったら止まって理由を返します。

```
None     普通に進んだ
Ecall    環境呼び出し。pc は既にその先
Ebreak   ブレークポイント。pc はその上のまま
Illegal  デコードできない
Fault    メモリ保護違反
```

この境界があるおかげで、gdb は `write()` の途中のゲストをシングルステップできます
（[3章 §5](exec.md#5-トラップの境界)）。

## 5. `ecall` を Linux に中継する — `syscall.cppm`

止まった理由が `Ecall` なら、`a7` を番号、`a0`–`a5` を引数として asm-generic の表を引き、
ホストの Linux に渡します。ゲストのファイルディスクリプタは**ホストのそれそのもの**なので、
ゲストの標準出力は本当にエミュレータの標準出力です。

```
$ rvemu -T ./hello
[syscall] 258(0x7fffffffdaa0, 0x1, 0x0) = -38
[syscall] 214(0x0, 0xb00, 0x7bd10) = 528384
[syscall] 96(0x810f0, 0x0, 0x0) = 1081521
...
[syscall] 64(0x1, 0x82100, 0x9) = 9
hello 42
[syscall] 94(0x0, 0x0, 0x0) = 0
```

258 は RISC-V 固有の `riscv_hwprobe` で、実装していないので `-38`（`ENOSYS`）を返します。
glibc は古いカーネルとして扱って先に進みます —— **実装していないことを正直に言うほうが、
それらしい嘘をつくより安全**です（[6章](syscall.md)）。214 は `brk`、96 は
`set_tid_address`、64 が `write`、94 が `exit_group` です。

## 6. 終わる

`exit` / `exit_group` を見たら `Kernel::exited` を立て、実行ループが抜けます。終了コードは
そのままエミュレータの終了コードになります。フォールトなら 139（`128 + SIGSEGV`）で、
どこで何をしくじったかを出します。

```
$ rvemu fault.s
rvemu: load fault at 0x40 (pc 0x10004 <_start+0x4>)
pc  0x10004 <_start+0x4>
zero 0000000000000000    ra 0000000000000000    sp 00007fffffffdb30    gp 0000000000000000
  tp 0000000000000000    t0 0000000000000040    t1 0000000000000000    t2 0000000000000000
```

pc は**しくじった命令を指したまま**です。デバッガが見せたいのはそこだからで、
`ecall` だけがこの規則の例外です。

## 7. 全体の値段

`-s` が命令数・システムコール数・ページ数を出します。

```
$ rvemu -s ./hello
hello 42
rvemu: 143427 instructions, 17 syscalls, 2195 pages (8780 KiB), 0.005 s, 31.1M inst/s
```

`printf` を1回呼ぶだけで **14 万命令**かかるのは、静的リンクした glibc が起動時に TLS と
ロケールと stdio を組み立てるからです。素の `write` で済ませれば[9命令](../examples/hello.s)
で終わります。

```
$ rvemu -s examples/hello.s
hello from rvemu
rvemu: 9 instructions, 2 syscalls, 2050 pages (8200 KiB), 0.000 s, 0.2M inst/s
```

ページ数の 2050 のうち **2048 はスタック**です。8 MiB を起動時にまとめて貼っているので、
どんなに小さいプログラムでもここは変わりません（[1章 §5](memory.md#5-していないこと)）。

速度は 30M 命令/秒前後で、素朴なインタプリタとしては妥当なところです。

| プログラム | 命令数 | syscall | ページ | 秒 |
|---|---:|---:|---:|---:|
| `examples/hello.s` | 9 | 2 | 2050 | 0.000 |
| `examples/fib.s` | 339,434 | 6 | 2051 | 0.012 |
| C の hello（静的 glibc） | 143,427 | 17 | 2195 | 0.005 |
| C の malloc/qsort/math | 10,158,525 | 25 | 2196 | 0.299 |
| MartenML の queens | 9,356,163 | 18 | 67,749 | 0.433 |

最後の1行のページ数が飛び抜けているのは、[MartenML](../../MartenML) のランタイムが
バンプアロケータで解放をしないからです。271 MiB を貼ったまま終わります。

## 実装の地図

| | |
|---|---|
| `src/main.cpp` 74–181行 | 引数の切り分け、ELF かアセンブリかの判定、`--gdb` の分岐 |
| `src/elf.cppm` 128–285行 | `load_elf` — PT_LOAD、静的 PIE の再配置、シンボル表 |
| `src/machine.cppm` 105–183行 | `start` — スタックと argv/envp/auxv |
| `src/machine.cppm` 186–230行 | `resume` — 実行ループとブレークポイントの照合 |
| `src/exec.cppm` 75–91行 | `step` — 1命令 |
| `src/syscall.cppm` 148–164行 | `handle` — `ecall` の入口 |
| `src/machine.cppm` 232–243行 | `report_stats` — `-s` の中身 |

---

[目次](index.md) ／ [1. アドレス空間 →](memory.md)
