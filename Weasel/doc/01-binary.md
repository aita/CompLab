# 1. バイナリ形式 — 1つの規則の繰り返し

`.wasm` の形式は、覚えることがほとんどありません。**ベクタは個数のあとにその個数だけ
並んだもの**、**セクションは id と長さとベクタ**。この2つだけで、あとは何がどのベクタに
入るかの表です。

この章はその表と、そこに1つだけある工夫 — 長さが書いてあること — の話です。

## 1.1 LEB128 と、長さまで決まっている整数

すべての整数は LEB128 で書かれます。7ビットずつ下から並べ、まだ続くなら最上位ビットを
立てる。

```
624485 = 0x98765
       = 0b10011000011101100101
7ビットずつ下から: 1100101 1101100 0100110
継続ビットを付ける: 11100101 10001110 00100110
                  = e5 8e 26
```

符号つきのほうは、最後のバイトの第6ビットを符号として全体を符号拡張します。

ここまでは普通の LEB128 ですが、wasm の仕様は**符号化の長さも規定しています**。u32 は
5バイトを超えてはいけないし、5バイト目に u32 に収まらないビットが立っていてもいけません。

```cpp
if (shift >= max_bits || (shift + 7 > max_bits && (low >> (max_bits - shift)) != 0)) {
  fail("integer too large");
```
（`common.cppm:162`）

なぜそこまで決めるのか。**同じ値の綴りが1つになる**からです。冗長な `80 80 80 00` を
許すと、バイト列とモジュールの対応が1対1でなくなり、「このモジュールのハッシュ」のような
ものが意味を失います。それに、長さを縛らないデコーダは無限に読み続けられてしまいます。

テストがこの端を1つずつ突きます（`tests/test_weasel.cpp:342`）。

```cpp
const std::vector<u8> b{0xff, 0xff, 0xff, 0xff, 0x7f};
r.uleb(32);
expect(d.failed, "leb", "an over-wide u32 must be rejected");
```

## 1.2 セクションと、長さがくれるもの

モジュールは `\0asm` とバージョン `01 00 00 00` のあと、セクションの列です。
1つのセクションは **id が1バイト、長さが LEB128、中身がその長さ**。

```
0107 0160 027f 7f01 7f
 │ │  │    │  │  │  └── 結果 i32
 │ │  │    │  └──┴───── 引数 i32 i32
 │ │  │    └─────────── 引数2個
 │ │  └──────────────── 関数型 (0x60)
 │ └─────────────────── 1個
 └───────────────────── 型セクション(1)、7バイト
```

長さがあることで2つが可能になります。1つは**知らないセクションを飛ばせる**こと。もう1つ、
実装にとって重要なのは、**各セクションを独立したリーダで読める**ことです。

```cpp
Decoder sub{Reader{body, 0, &d}, &out, {}};
...
if (!sub.r.eof()) {
  d.fail(std::format("{} section has {} bytes left over", section_name(id), sub.r.left()));
```
（`binary.cppm:514`, `binary.cppm:575`）

長さについて嘘をついているセクションは、**そのセクションの終わりで**捕まります。次の
セクションの途中まで読み進んでから「なんだかおかしい」と気づくのではありません。
エラーの位置が意味を持つのはこれのおかげです。

## 1.3 セクションの順番と、id が順番でないところ

セクションは決まった順に現れなければなりません。カスタムセクション（id 0）だけはどこにでも
置けます。順序の検査は「最後に見た id より大きいか」で済む — はずでした。

```cpp
int section_rank(u8 id) {
  if (id == static_cast<u8>(SectionId::DataCount)) return 10;
  if (id == static_cast<u8>(SectionId::Code)) return 11;
  if (id == static_cast<u8>(SectionId::Data)) return 12;
  return id;
}
```
（`binary.cppm:32`）

データカウントセクションは id が 12 なのに、置き場所はコードセクション（10）の**前**です。
あとから追加された機能だから id は末尾を取り、しかし役目のせいで前に置くしかなかった。

役目のほうがこの位置を決めています。`memory.init 3` という命令はデータセグメント3番を
指しますが、データセクションはコードセクションのうしろにあります。デコーダはコードを
読んでいる時点でセグメントが何個あるか知らない。**「これから何個ある」とだけ先に言う
セクション**が要る。それがデータカウントです。

（テキスト形式にはこの問題がありません。だから Weasel のテキストパーサは、データセグメントが
あれば黙ってこの数を埋めます — `text.cppm:1352`。ダンプがこの数を印字しないのはそのためです。）

## 1.4 インデックス空間 — 輸入が先

関数・表・メモリ・大域変数には、それぞれ**1つの添字空間**があります。そして
**輸入されたものが先に番号を取ります**。

```
(import "env" "log" (func ...))   → func 0
(import "env" "now" (func ...))   → func 1
(func ...)                        → func 2   ← このモジュールが定義した最初の関数
```

`Module` はこれを、輸入と定義を別々のベクタで持ち、輸入の個数を覚えることで表します
（`types.cppm:189`）。

```cpp
u32 func_type_index(u32 idx) const {
  if (idx < imported_funcs) { ... 輸入を数えて探す ... }
  return funcs[idx - imported_funcs].type;
}
```

Ferret が吐いたモジュールで見るとこうなります。

```
$ weasel dump /tmp/pi.wasm | head -12
(module
  (type 0 (func (param f64)))
  (type 1 (func (result f64)))
  (type 2 (func (param i32 f64) (result f64)))
  (type 3 (func (result f64)))
  (type 4 (func (param i32 i32)))
  (import "env" "log" (func 0 (type 0)))
  (import "env" "random" (func 1 (type 1)))
  (import "env" "watch" (func 2 (type 2)))
  (import "env" "now" (func 3 (type 1)))
  (import "env" "say" (func 4 (type 4)))
```

輸入5つが 0〜4 を取り、`(export "main" (func 5))` の 5 はこのモジュールが定義した最初の
関数です。

型セクションに `(func (result f64))` が2つ（type 1 と type 3）あることに注目してください。
バイナリ形式は重複した型を禁じません。テキスト形式のパーサは重複を作らないよう探しますが
（[2章](02-text.md)）、バイナリは書いてあるとおりに読みます。**同じものを違う綴りで書ける
ところは、ダンプが一致しなくなる場所**なので、Weasel はここでは何も正規化しません。

## 1.5 ブロック型が s33 であること

`block` `loop` `if` のあとには型が1つ来ます。ところがこの位置には3種類のものが来ます —
「無」、値型1つ、そして型セクションへの添字です。

仕様の答えは、**符号つき33ビット整数として読む**ことです。

```cpp
const i64 v = r.sleb(33);
if (v >= 0) { in.a = 2; in.b = static_cast<u32>(v); return; }   // 型添字
const u8 b = static_cast<u8>(v & 0x7f);
if (b == 0x40) { in.a = 0; return; }                            // 無
in.a = 1; in.b = b;                                             // 値型
```
（`binary.cppm:96`）

値型のバイト（i32 = `0x7f`、i64 = `0x7e`、…）はすべて負の sleb であり、「無」の `0x40` も
負です。型添字は 0 以上。1つの整数が3つの役を兼ねられるのは、値型が**もともと負の数として
符号化されている**からです。Weasel の `ValType` の値が `0x7f` のようなバイトなのは、この
符号化をそのまま持っているためです（`types.cppm:22`）。

## 1.6 命令 — オペコードが列挙子の値である

命令の表は `opcode.cppm` に1枚だけあります。**列挙子の値がオペコードのバイトそのもの**です。

```cpp
X(I32Add,           0x6a, "i32.add",              None,        0)
X(MemoryCopy,       0x10a,"memory.copy",          MemMem,      0)
```

1バイト命令はそのバイト、`0xfc` 接頭の族は `0x100 + n`。だからデコードはキャストで済み、
テーブル引きが要りません（`binary.cppm:118`）。

同じ表が3か所から読まれます — バイナリのデコーダ、テキストのパーサ、ダンプ。命令を1つ
足すのは、この表に1行と、実行ループに1つの `case` だけです。

即値の形も同じ行に書いてあります。`Imm::MemArg` なら align と offset、`Imm::LabelTable`
なら分岐先のベクタ、といった具合で、デコーダの `switch` はその `Imm` で分かれます。

そして「計画が使う2つの命令」— `if.false` と `jump` — も同じ表にいます。ただし
`0x180` 以上で、`op_by_name` はそれを飛ばします（`opcode.cppm:299`）。

```cpp
inline constexpr u16 kFirstInternal = 0x180;
inline bool is_internal(Op op) { return static_cast<u16>(op) >= kFirstInternal; }
```

**言語には無いが機械にはある命令**を、名前だけもらって、書けなくしてある。名前があるので
`weasel plan` の出力に出てきます（[4章](04-plan.md)）。

## 1.7 式は `end` まで、`end` も含めて

関数の本体も、大域変数の初期化式も、セグメントのオフセットも、すべて「命令の列と `end`」
です。Weasel はこの `end` を**捨てずに持ちます**。

```cpp
case Op::End:
  if (depth == 0) { e.push_back(std::move(in)); return e; }
```
（`binary.cppm:223`）

こうすると、関数の本体の終わりと `block` の終わりが同じ形になります。検証器はそれを
1つの規則で扱えます — 関数そのものが一番外側のラベルだ、という扱いです（[3章](03-validate.md)）。

## 1.8 要素セグメントの8つの形

セグメントの符号化はこの形式でいちばん込み入っています。要素セグメントには**フラグ3ビットで
8つの形**があります。

- bit 0 — 表0のアクティブではない
- bit 1 — 宣言的、または表を明示する
- bit 2 — 要素が関数添字ではなく式である

```cpp
switch (flags & 3) {
  case 0: seg.mode = Active; seg.table = 0; seg.offset = expr(); break;
  case 1: seg.mode = Passive; break;
  case 2: seg.mode = Active; seg.table = r.u32leb(); seg.offset = expr(); break;
  case 3: seg.mode = Declarative; break;
}
```
（`binary.cppm:352`）

形0と形4だけは型のフィールドを持ちません（`funcref` と決まっている）。ほかは持ちますが、
関数添字の並びなら「要素種別」の1バイト（つねに `0x00`）、式の並びなら参照型そのもの、と
綴りが違います。

Weasel はこれを読んだ側で1つに均します。**どの形も `mode` と `type` と「式の並び」**に
なる。形0で `$f` と書かれた添字は、`ref.func $f` と `end` の2命令の式に変換されます。
そうすると `instantiate` も検証器も1つの道しか要りません。

```
$ weasel dump tests/wat/04-tables.wat | sed -n '/elem 2/,/^  )/p'
  (elem 2 declarative funcref count=1
    item
      ref.func 3
    end
  )
```

## 1.9 カスタムセクション — 壊れていてもよい

`name` セクションは関数と局所変数の名前を持ちますが、**カスタムセクション**なので
「不正であってはならない」という縛りがありません。気に入らない読み手は無視しなければ
ならず、拒んではいけない。

```cpp
void name_section(std::span<const u8> body) {
  Diag scratch;                    // 本体の Diag ではない
  Reader nr{body, 0, &scratch};
  ...
```
（`binary.cppm:482`）

失敗を専用の `Diag` に流し込んで捨てています。読めたところまでの名前は残り、モジュールは
そのまま通る。**エラーを握りつぶすのが正しい**という珍しい場所です。

---

## していないこと

- **メモリ64**。`memarg` の align フィールドの bit 6 は「メモリ添字が続く」という
  マルチメモリの印で、Weasel はここで拒みます（`binary.cppm:185`）。
- **SIMD（`0xfd`）とアトミック（`0xfe`）**。どちらも接頭バイトで判別し、名指しで
  断ります。「知らない命令」ではなく「これは対応していない」と言えるほうが親切です。
- **符号化のやり直し**。Weasel にエンコーダはありません。読むだけです。だから
  「テキストを読んでバイナリを書き、また読んでも同じか」という往復テストはできず、
  代わりに `wat2wasm` を通したものと比べています（[README](../README.md)）。

## 参考文献

- **WebAssembly Core Specification**, Section 5 "Binary Format". この章はここの要約です。
- **The Bulk Memory Operations proposal**。データカウントセクションが要る理由が
  提案文書の側から書かれています。
- [`Ferret/doc/emit.md`](../../Ferret/doc/emit.md) — 同じ形式を**書く**側から見た章。
  Ferret は OCaml でこのバイト列を手で組み立てます。

## 実装の地図

| 場所 | 何があるか |
|---|---|
| `src/common.cppm:125` | `Reader` — 境界検査つきのバイトカーソル |
| `src/common.cppm:162` | `uleb` — 長さの上限まで見る符号なし LEB128 |
| `src/common.cppm:182` | `sleb` — 符号つき。末尾バイトの余りビットも検査する |
| `src/binary.cppm:32` | `section_rank` — id ではなく置き場所の順 |
| `src/binary.cppm:96` | `blocktype` — s33 が3つの役を兼ねる |
| `src/binary.cppm:118` | `instruction` — オペコード1つと、その即値 |
| `src/binary.cppm:223` | `expr` — `end` まで、`end` を含めて |
| `src/binary.cppm:352` | `element_section` — 8つの形を1つに均す |
| `src/binary.cppm:414` | `code_section` — 局所変数の連長を展開する |
| `src/binary.cppm:482` | `name_section` — 失敗を捨てる |
| `src/binary.cppm:514` | `decode_module` — マジックとセクションの列 |
| `src/opcode.cppm:44` | 命令表 |

---

[← 0. 概観](00-overview.md) · [2. テキスト形式 →](02-text.md)
