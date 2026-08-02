# 2. テキスト形式 — 名前と省略記法

`.wat` はバイナリと同じ言語の別の綴りです。ただし2つ、バイナリには無いものがあります。
**名前**と**省略記法**です。この章はその2つを消す話で、消し終わったあとに残るのは1章と
同じ `Module` です。

Weasel がテキストパーサを持っている理由は rvemu がアセンブラを持っているのと同じで、
**読めるテストを書くため**です。そしてそれが同時に、バイナリデコーダの検査にもなります
（[README](../README.md)）。

## 2.1 字句 — 識別子とは何でないか

トークンは4種類しかありません。`(`、`)`、文字列、そして**識別子文字の並び**。
数もキーワードも命令名も、全部その「並び」です。

```cpp
bool is_idchar(char c) {
  if ((c >= '0' && c <= '9') || ... ) return true;
  switch (c) {
    case '!': case '#': case '$': case '%': ... case '~': return true;
```
（`text.cppm:40`）

`i32.add` も `offset=8` も `$my_func` も `0x1.8p3` も、全部1つのトークンです。
分類は構文解析のときにします。`$` で始まれば識別子、そうでなければキーワード
（`text.cppm:179`）。

コメントは `;;` が行末まで、`(; ... ;)` がブロックで、**入れ子になります**。

文字列リテラルは文字ではなく**バイト**を持ちます。`"\6a"` は1バイト、`"\u{3b1}"` は
UTF-8 の2バイト。データセグメントがこれで書かれるので、この区別は本質的です。

```wasm
(data (i32.const 0) "\08\00\00\00\0e\00\00\00")
```
これは8バイトで、リトルエンディアンの u32 が2つ — つまり手で書いた iovec です
（[9章](09-host.md)）。

## 2.2 名前 — 2つのパス

`(call $fib)` の `$fib` は、`$fib` の定義より**前**に書けます。前方参照があるので、
1回のパスでは添字にできません。

Weasel の答えは素朴です。**トークン列を全部作ってから2回歩く**。

1回目（`text.cppm:460`）は、トップレベルのフィールドの見出しだけを見て、中身は括弧の
対応で飛ばします。ここで `$名前 → 添字` の表が空間ごとに1つずつできます。

```cpp
void register_names() {
  const std::size_t save = p;
  while (is_lpar()) {
    const std::size_t field = p;
    bump();
    const std::string head = cur().text;
    ...
    p = field;
    skip_field();
  }
  p = save;
}
```

2回目が本番です。このとき `index(funcs, "function")` は必ず表を引けます。

ただし、1回目にはもう1つ決めることがあります。**その `(func ...)` が輸入かどうか**です。
輸入は添字空間の先頭を取るので、定義のあとに輸入が現れたら全部の添字がずれる。だから

```cpp
if (imported && seen_definition[slot]) {
  fail(std::format("an imported {} may not follow a defined one", kind));
```
（`text.cppm:514`）

と拒みます。そしてその判定は見た目ほど簡単ではありません。

```wasm
(func $log (export "log") (import "env" "log") (param i32))
```

輸入の印は、いくつでも並べられる `(export ...)` のうしろに隠れられます。だから
`lookahead_import` は `(export ...)` を読み飛ばしながら `(import` を探します
（`text.cppm:493`）。

局所変数とラベルだけは別です。これらは**入れ子になる**ので、表ではなくスタックで、
本体を読みながら解決します。ラベルは深さで参照されるので、スタックの上からの距離が
そのまま `br` の即値です。

```cpp
u32 label_index() {
  if (cur().kind == Tok::Id) {
    for (std::size_t i = labels.size(); i-- > 0;)
      if (labels[i] == cur().text)
        return static_cast<u32>(labels.size() - 1 - i);
```
（`text.cppm:989`）

同じ名前のラベルが入れ子になったら、内側が勝ちます。上から探しているので自動的にそうなる。

## 2.3 畳み込み — 規則は1つ

テキスト形式には命令の書き方が2つあります。素の並びと、S式です。

```wasm
local.get 0    local.get 1    i32.add        ;; 素
(i32.add (local.get 0) (local.get 1))        ;; 畳み込み
```

展開の規則は1つ、**オペランドを先に出してから演算子**。

```cpp
Inst in;
in.op = op;
immediates(in);                          // 即値は演算子のすぐ後ろ
while (is_lpar() && ok()) folded(out);   // 子はオペランド
out.push_back(std::move(in));            // 演算子は最後
expect_rpar();
```
（`text.cppm:1232`）

即値が子より先に読まれることに注意してください。`(i32.load offset=4 (i32.const 0))` の
`offset=4` は演算子に属します。

例外は `if` だけです。条件はオペランドですが、腕はオペランドではありません。

```cpp
while (is_lpar() && !is_field("then") && !is_field("else") && ok()) folded(out);
out.push_back(std::move(in));    // ここで `if` が出る
... (then ...) ... (else ...) ...
```

`(then ...)` に出会うまでに読んだものが条件で、そのあとに `if` を置き、腕がその中身に
なります。畳み込みでない `if ... else ... end` は素の並びの側で扱います
（`text.cppm:1179`）。

## 2.4 省略記法 — `(func (export "f") ...)` は3つのものだった

テキスト形式には省略が多く、そのすべてがここで展開されます。仕様の言い方では
「これは〜と等価である」という書き換えの並びです。

```wasm
(func $add (export "add") (param i32 i32) (result i32) ...)
```

は次の3つに展開されます。

1. 関数の定義
2. 輸出 `(export "add" (func $add))`
3. **型セクションへの追加**（同じ型がまだ無ければ）

3つめが厄介です。バイナリ形式では関数の型は必ず型セクションの添字ですが、テキストでは
その場に書けてしまう。仕様は「無ければ末尾に足す」と決めています（`text.cppm:577`）。

```cpp
for (u32 i = 0; i < m->types.size(); ++i)
  if (m->types[i] == inline_ft) return i;
m->types.push_back(inline_ft);
return static_cast<u32>(m->types.size() - 1);
```

そして「末尾に足す」の**末尾**が問題になります。`(type ...)` フィールドはファイルの
どこにでも書けるので、フィールド順に処理すると、明示された型と暗黙に足された型が
交互に並んでしまい、明示した型の添字がずれます。

だから Weasel はパス1と本番のあいだにもう1つ挟みます。

```cpp
// The `(type ...)` fields are read before anything else, because a typeuse
// that spells its signature out appends to the type section, and the spec puts
// those appended types after every written one.
void type_pass() { ... }
```
（`text.cppm:1301`）

これで明示された型が 0..n-1 を占め、暗黙のものはそのうしろに、テキストに現れた順で
並びます。**`wat2wasm` と同じ型セクションになる**のはこの順序のおかげで、それが
ダンプ一致テストの前提です。

ほかの省略も同じ場所で消えます。

| 書いたもの | 展開されたもの |
|---|---|
| `(memory (data "abc"))` | メモリ1個（サイズはデータをページに切り上げ）＋アクティブなデータセグメント |
| `(table funcref (elem $f $g))` | 表1個（サイズは要素数、最大も同じ）＋アクティブな要素セグメント |
| `(elem (i32.const 0) $f $g)` | 各要素が `ref.func $f` `end` の式である要素セグメント |
| `(func ... (import "m" "n") ...)` | 輸入。定義は作られない |

## 2.5 数 — 1つの綴りが2つの範囲を持つ

整数定数は、その幅の**符号つきの範囲でも符号なしの範囲でも**書けます。
`i32.const -1` と `i32.const 0xffffffff` は同じ命令です。

```cpp
const u64 limit = (bits == 64) ? ~u64{0} : ((u64{1} << bits) - 1);
const u64 neg_limit = (bits == 64) ? (u64{1} << 63) : (u64{1} << (bits - 1));
u64 v = 0;
if (!parse_uint(text, neg ? neg_limit : limit, v)) return false;
out = neg ? (~v + 1) : v;
```
（`text.cppm:243`）

負号があるときの上限だけが違います。`-2147483648` は書けるが `-4294967295` は書けない。

浮動小数点はもっと厄介で、4つの綴りがあります。10進、16進（`0x1.8p3`）、`inf`、そして
`nan` と `nan:0x...`。最後のものは**NaN のペイロードを名指し**しているので、値ではなく
ビットから組み立てます。

```cpp
if (t.starts_with("nan:")) {
  u64 payload = 0;
  if (!parse_uint(t.substr(4), ~u64{0}, payload)) return false;
  u32 bits = 0x7f800000u | (static_cast<u32>(payload) & 0x7fffffu);
  ...
```
（`text.cppm:257`）

16進の浮動小数点は `std::from_chars` に `chars_format::hex` を渡すと読めます。
`0x` を剥がして渡すのがこの標準ライブラリの作法です。

数字の途中の `_` はどこにでも書けるので、先に落とします。

## 2.6 曖昧なところ — 添字が省略できる命令

いくつかの命令は添字を省略できます。`table.get` は表0が既定、`table.init` は
`table.init $elem` とも `table.init $table $elem` とも書ける。

素の並びのなかでこれを読むと、次のトークンが**添字なのか次の命令なのか**が
分かりません。`table.get` のあとの `i32.add` を表の名前と読んではいけない。

```cpp
bool at_index() const {
  if (cur().kind == Tok::Id) return true;
  if (cur().kind != Tok::Keyword) return false;
  u64 v = 0;
  return parse_uint(cur().text, 0xffffffffu, v);
}
```
（`text.cppm:396`）

「試して失敗したら戻す」ではなく「先に訊く」ようにしてあります。`index()` は
見つからない名前を**エラーとして掛け金に latch する**ので、試して戻ってももう遅い。

`table.init` はさらに面倒で、**まず数える**しかありません。

```cpp
const std::size_t mark = p;
int n = 0;
while (at_index()) { bump(); ++n; }
p = mark;
in.b = (n >= 2) ? index(tables, "table") : 0;
in.a = index(elems, "elem segment");
```
（`text.cppm:1063` の `Imm::ElemTable`）

1つめの名前を表の空間で引いてみて駄目なら要素の空間、という順にすると、正しい
プログラムに対してエラーを出してしまいます。名前空間が分かれている以上、
**どちらの空間で引くかを先に決めなければならない**。

## 2.7 2つのフロントエンドが一致すること

この章とその前の章は、同じ `Module` を作る2つの道です。それが本当に同じかどうかは、
書いた側には分かりません。だからテストがこうなっています。

```
.wat ──[Weasel の text.cppm]──→ Module ──[dump_module]──→ 文字列 A
  │
  └──[wat2wasm]──→ .wasm ──[Weasel の binary.cppm]──→ Module ──[dump_module]──→ 文字列 B

A == B でなければ失敗
```

そのために `dump_module` は**2つが食い違いうるものを何も印字しません**。名前も、
ソース位置も、浮動小数点の10進表記も出さず、定数はビットパターンで出します
（`dump.cppm:56`）。

```
$ weasel dump tests/wat/05-globals.wat
(module
  (type 0 (func (result i32)))
  (global 0 mut i32
    i32.const 0x00000000
  end
  )
  (global 1 i32
    i32.const 0x00000064
  end
  )
  (global 2 i32
    i32.const 0x0000002a
  end
  )
  (export "answer" (global 2))
  (export "bump" (func 0))
  (export "base" (func 1))
  (func 0 (type 0)
    global.get 0
    i32.const 0x00000001
    i32.add
    global.set 0
    global.get 0
  end
  )
  ...
```

この形は人が読むために作られていません。**比較のために**作られています。人が読む
ほうのダンプは `weasel plan` で、そちらは定数を10進で出します（`dump.cppm:208`）。

---

## していないこと

- **`assert_return` などのスクリプト構文**。仕様のテストスイートは `.wast` という
  拡張された文法で書かれていますが、Weasel が読むのはモジュールだけです。期待値は
  `;;=` のコメントで書きます（[README](../README.md)）。
- **`(module binary "...")` / `(module quote "...")`**。同じ理由で入れていません。
- **名前セクションの出力**。テキストから読んだモジュールは名前を持ちません。名前を
  持つのは `name` セクションつきのバイナリを読んだときだけで、それはトレースの表示に
  しか使いません（`types.cppm:183`）。
- **エンコーダ**。テキストを読んでバイナリを書くことはできません。1章の
  「していないこと」と同じ話です。

## 参考文献

- **WebAssembly Core Specification**, Section 6 "Text Format"。省略記法は各項の
  末尾に "Abbreviations" として書かれていて、この章はそれを順に潰したものです。
- **wabt** (`wat2wasm`)。テキスト形式の事実上の基準実装。Weasel のパーサはこれと
  一致することをテストで要求されています。

## 実装の地図

| 場所 | 何があるか |
|---|---|
| `src/text.cppm:40` | `is_idchar` — 識別子文字の定義 |
| `src/text.cppm:53` | `Lexer` — 空白・コメント・文字列・トークン |
| `src/text.cppm:216` | `parse_uint` / `parse_int` — 2つの範囲を持つ整数 |
| `src/text.cppm:257` | `parse_float` — 16進浮動小数点と `nan:0x...` |
| `src/text.cppm:396` | `at_index` — 訊いてから読む |
| `src/text.cppm:460` | `register_names` — パス1 |
| `src/text.cppm:493` | `lookahead_import` — `(export)` の陰の `(import)` |
| `src/text.cppm:577` | `typeuse` — 探して、無ければ足す |
| `src/text.cppm:608` | `inline_extras` — インラインの輸出と輸入 |
| `src/text.cppm:1063` | `immediates` — 命令ごとの即値、1章の `switch` の鏡 |
| `src/text.cppm:1179` | `instructions` — 素の並び |
| `src/text.cppm:1232` | `folded` — 畳み込み |
| `src/text.cppm:1301` | `type_pass` — 明示された型を先に |
| `src/dump.cppm:118` | `dump_module` — 比較のためのダンプ |

---

[← 1. バイナリ形式](01-binary.md) · [3. 型検査 →](03-validate.md)
