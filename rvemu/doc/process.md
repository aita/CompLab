# 5. プロセスの起動 — `elf.cppm`, `machine.cppm`

ファイルの中身をアドレス空間に貼り、C ランタイムが期待する形をスタックに積むまでです。
ここはリンカの仕事ではなく**カーネルの仕事**をする場所で、それが範囲を決めています。

## 1. ELF64 を、構造体を使わずに読む

`Elf64_Ehdr` を宣言して `memcpy` する代わりに、オフセットを直に指定して読みます。

```cpp
inline u16 rd16(std::span<const u8> b, u64 off) { return u16(b[off]) | u16(b[off+1]) << 8; }
inline u32 rd32(std::span<const u8> b, u64 off) { ... }
inline u64 rd64(std::span<const u8> b, u64 off) { ... }

const u64 e_entry = rd64(b, 24);
const u64 e_phoff = rd64(b, 32);
```

**ホストの構造体のレイアウトにも詰め物にも依存しなくなります。** ELF はリトルエンディアン
固定で、フィールドの位置は仕様が決めているので、そこを直接書くのが一番短くて一番壊れません。

入口で断る条件は4つです。ELF64 でない、リトルエンディアンでない、`e_machine` が RISC-V
（243）でない、実行ファイルでない。どれも**メッセージで理由を言います** —— 「動かない」と
だけ言われて調べる羽目になるのが一番高くつくからです。

## 2. PT_LOAD を貼る

セグメントを1つずつ、ページに写します。

```cpp
u8 perm = 0;
if (p_flags & PF_R) perm |= PermR;
if (p_flags & PF_W) perm |= PermW;
if (p_flags & PF_X) perm |= PermX;
mem.map_merge(p_vaddr, p_memsz, perm);
if (p_filesz && !mem.poke(p_vaddr, b.data() + p_offset, p_filesz)) { ... }
```

2つ、意図のある選択があります。

**`map` ではなく `map_merge` を使います。** 権限を上書きするのではなく OR します。
読み取り実行のテキストの末尾と、読み書きのデータの先頭が**同じページに乗る**ことがあり、
そのページは両方を満たさなければならないからです。実際の hello を見ると:

```
LOAD  0x000000 0x0000000000010000 ... 0x065e24 0x065e24 R E 0x1000
LOAD  0x066310 0x0000000000076310 ... 0x005598 0x00a9e8 RW  0x1000
```

この2本は別ページに落ちますが、リンカの設定次第で重なります。重なったときに黙って権限を
落とすほうが怖いので、常に OR します。

**`write` ではなく `poke` を使います。** テキストはこのあと読み取り実行になりますが、貼って
いるのはゲストではなくローダです。権限検査を通さない入口を使うことで、コードを読んだときに
「これはローダの書き込みだ」と分かります（[1章 §3](memory.md#3-権限とその裏口)）。

bss は何もしません。`p_memsz > p_filesz` のぶんは、**ページが生まれたときから 0** なので
すでに正しい状態です。

`brk` の開始位置は、いちばん高い PT_LOAD の終わりをページ境界に丸めたものです。

## 3. auxv — C ランタイムが本当に読むもの

スタックの形はこうです。上から文字列、下に向かってポインタの塊、sp はその底。

```
高位  [ argv/envp の文字列、AT_EXECFN の文字列、"riscv64" ]
      [ AT_RANDOM 用の 16 バイト ]
      [ auxv: キーと値の対、AT_NULL で終端 ]
      [ NULL ]
      [ envp[0..] ]
      [ NULL ]
      [ argv[0..argc-1] ]
sp -> [ argc ]
```

走り出す直前を gdb から見たものです。

```
$ rvemu -g 1234 ./hello
(gdb) x/6gx $sp
0x7fffffffdb30:	0x0000000000000001	0x00007fffffffeff2
0x7fffffffdb40:	0x0000000000000000	0x00007fffffffefdf
0x7fffffffdb50:	0x00007fffffffefce	0x00007fffffffef4d
```

argc が 1、argv[0]、NULL、そこから envp です。sp は 16 バイト境界に揃っています。

この章でいちばん詰まるのが auxv です。**静的リンクした glibc は、自分の TLS を
`AT_PHDR` から作ります。** 渡された番地からプログラムヘッダを読み、PT_TLS を探し、その
イメージをコピーして `tp` を立てる。だから `AT_PHDR` がずれていると、**症状は数千命令
あとに `__libc_setup_tls` の中で出て**、原因を指すものが何もありません。

値の求め方は2通りです。PT_PHDR があればそれ。無ければ、**ELF ヘッダ自身を含む PT_LOAD**
を探して、そこからのオフセットで計算します。

```cpp
if (!phdr_vaddr && p_offset <= e_phoff && e_phoff < p_offset + p_filesz) {
  phdr_vaddr = p_vaddr + (e_phoff - p_offset);
}
```

上の hello だと1本目の PT_LOAD が `p_offset = 0` から始まっているので、`e_phoff = 64` が
そのまま `0x10000 + 64` になります。

積んでいるのは18個です。

| | |
|---|---|
| `AT_PHDR` `AT_PHENT` `AT_PHNUM` | プログラムヘッダの場所。TLS がここから作られる |
| `AT_ENTRY` `AT_BASE` `AT_FLAGS` | 入口と、インタプリタのベース（0） |
| `AT_PAGESZ` | 4096 |
| `AT_RANDOM` | 16 バイトへのポインタ。スタックカナリアの種になる |
| `AT_HWCAP` | 拡張の文字をビットにしたもの |
| `AT_UID` `AT_EUID` `AT_GID` `AT_EGID` `AT_SECURE` | 0 |
| `AT_CLKTCK` | 100 |
| `AT_PLATFORM` `AT_EXECFN` | `"riscv64"` と、argv[0] の文字列 |

`AT_RANDOM` には本物の乱数を入れます。ゲストがそれを表示したときに、それらしく見えるのが
正しいからです。

`AT_HWCAP` は RISC-V では**拡張の文字のビットマップ**です。`'a' - 'a'` が 0 ビット目、
`'m' - 'a'` が 12 ビット目、という具合。

```cpp
inline constexpr u64 kHwcap = (u64{1} << ('a' - 'a')) | (u64{1} << ('c' - 'a')) |
                              (u64{1} << ('d' - 'a')) | (u64{1} << ('f' - 'a')) |
                              (u64{1} << ('i' - 'a')) | (u64{1} << ('m' - 'a'));
```

I / M / A / F / D / C を立てています。ここに嘘を書くと、glibc が使えない命令で書かれた
`memcpy` を選びます。

## 4. 静的 PIE

`ET_DYN` なのに `PT_INTERP` が無い実行ファイル —— 静的 PIE —— は動きます。位置独立なので
どこにでも置けますが、**誰も再配置を適用していない**状態で渡されます。ふつうはそれを
ld.so がやります。

やることは1種類だけです。`PT_DYNAMIC` から RELA 表を見つけ、`R_RISCV_RELATIVE` の項目に
ついて「その番地に、ベース + 加数を書く」。

```cpp
if (u32(r_info) != R_RISCV_RELATIVE) continue;  // 解決すべきシンボルは無い
const u64 value = bias + r_addend;
mem.poke(r_offset + bias, &value, 8);
```

静的 PIE には解決すべき外部シンボルがないので、これで足ります。置き場所は `0x4000'0000`
固定で、`0x10000` に置かれる非 PIE とも、上の mmap 領域とも離れています。

## 5. シンボル表 — 拾い方に2つ罠がある

シンボルはトレースとフォールト報告のためだけに読みます（gdb は自分でファイルを読みます）。
拾い方に2か所、実際に踏んだ罠があります。

**`STT_NOTYPE` を捨ててはいけません。** 手で書いたアセンブリの `_start:` は、`.type` を
書かない限り NOTYPE です。`STT_FUNC` と `STT_OBJECT` だけ拾うと、**手書きアセンブリの
ラベルが1つも出てきません**。

**`$` で始まる名前は捨てなければいけません。** RISC-V の binutils は ISA を記述する
**マッピングシンボル**を置きます。

```
   Num:    Value          Size Type    Bind   Vis      Ndx Name
     4: 0000000000010000     0 NOTYPE  LOCAL  DEFAULT    1 $xrv64i2p1_m2p0_a2p1_f2p2_d2p2_...
     8: 0000000000010000     0 NOTYPE  GLOBAL DEFAULT    1 _start
```

同じ番地に2つ載っていて、拾い方によっては `<$xrv64i2p1_m2p0_...>` のほうが勝ちます。
名前の頭で捨てます。

引き当ては、**アドレス以下で最も近いシンボル**です。サイズを持つシンボルがその範囲に届いて
いなければ「関数と関数のあいだ」なので、名前を付けません。手書きアセンブリのラベルは
サイズが 0 なので、この規則がないと `_start` の1行目しか名前が付きません。

```cpp
auto it = std::ranges::upper_bound(symbols, addr, {}, &Sym::addr);
if (it == symbols.begin()) return {};
--it;
if (it->size && addr >= it->addr + it->size) return {};
```

`--trace` が1命令ごとに呼ぶので、表はソートしたままにして二分探索します。

## していないこと

**動的リンクはしません。** `PT_INTERP` を見つけたら、そこで止めて理由を言います。

```
rvemu: ./prog: dynamically linked (needs /lib/ld-linux-riscv64-lp64d.so.1).
rvemu has no dynamic loader -- rebuild with -static.
```

ld.so を動かすには、それ自体をロードして、シンボル解決と PLT と TLS モデルを実装することに
なります。**それはこのエミュレータが取り組んでいる主題とは別のプロジェクト**です。静的
リンクで困る場面に当たっていません。

**スタックを遅延して伸ばしません。** 8 MiB を最初に貼ります（[1章 §5](memory.md#5-していないこと)）。

**`GNU_STACK` も `GNU_RELRO` も見ません。** 前者はスタックを実行可能にするかどうかですが、
このエミュレータのスタックは常に RW です。後者は起動後に読み取り専用へ落とす範囲で、
落とさなくてもゲストの動作は変わりません。

## 参考文献

- [RISC-V ELF psABI][psabi]。`R_RISCV_RELATIVE`（型 3）の定義と、`AT_HWCAP` のビット割り当て。
- [System V ABI, Chapter 5: Program Loading and Dynamic Linking][sysv]。
  初期スタックの形と auxv。

[psabi]: https://github.com/riscv-non-isa/riscv-elf-psabi-doc
[sysv]: https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.intro.html

## 実装の地図

| | |
|---|---|
| `elf.cppm` 36–66行 | `Image` — 両フロントエンドの共通出力と `describe` |
| `elf.cppm` 84–92行 | `rd16` / `rd32` / `rd64` — 直に読む |
| `elf.cppm` 128–180行 | `load_elf` の入口の検査 |
| `elf.cppm` 181–233行 | PT_LOAD の貼り付けと AT_PHDR の導出 |
| `elf.cppm` 249–284行 | シンボル表。NOTYPE を拾い、`$` を捨てる |
| `elf.cppm` 289–321行 | `apply_relative_relocs` — 静的 PIE |
| `machine.cppm` 56–70行 | `Auxv` と `kHwcap` |
| `machine.cppm` 105–183行 | `start` — スタックと argv/envp/auxv |

---

[← 4. 浮動小数点](float.md) ／ [目次](index.md) ／ [6. システムコール →](syscall.md)
