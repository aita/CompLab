# 5. インスタンス化 — 説明が状態になる

計画ができても、まだ何も動きません。`(memory 1 2)` と書いてあるのは**メモリの説明**で
あって、メモリではないからです。

この章はその境目の話です。仕様が3つの概念を分けている理由と、ここでしか起きない
第三種のエラーの話。

## 5.1 モジュール・ストア・インスタンス

仕様は3つを分けます。

| | 何か | 変わるか |
|---|---|---|
| **モジュール** | 読んだもの。型、関数の本体、セグメントの中身 | 不変 |
| **ストア** | 走っている世界。メモリのバイト、表の要素、大域変数の値 | 変わる |
| **インスタンス** | その間の対応表 | 作られたら不変 |

```cpp
struct Instance {
  const Module* module = nullptr;
  const std::vector<Code>* codes = nullptr;
  std::vector<u32> funcs;    // モジュールの添字 → ストアの番地
  std::vector<u32> tables;
  std::vector<u32> mems;
  std::vector<u32> globals;
  ...
```
（`store.cppm:83`）

だから命令の中の添字は**2回引かれます**。`call 3` の 3 はモジュールの関数添字で、
`f->inst->funcs[3]` がストアの番地です。

なぜ分けるのか。同じモジュールを2回インスタンス化すればメモリは2つできて、互いに
干渉しない。逆に、2つのモジュールが同じ表を輸入すれば、ストアの同じ1つを共有する。
この2つを同時に成り立たせるには、間に対応表が要ります。

そしてこの分割が、値の表現を決めています。**`funcref` はモジュールの関数添字ではなく
ストアの番地**です。

```cpp
case Op::RefFunc:
  push(Value::of_ref(f->inst->funcs[in.a]));
```
（`exec.cppm:401`）

そうでなければ、関数参照を別のインスタンスに渡した瞬間に意味が変わってしまいます。

`Value` の表現もここから来ます。

```cpp
static Value null_ref() { return Value{0}; }
static Value of_ref(u32 addr) { return Value{u64{addr} + 1}; }
```
（`common.cppm:96`）

番地に 1 を足して持つので、**空参照はゼロ**です。だから新しく作った表も、
0で初期化した局所変数も、そのまま「空参照でいっぱい」になります。

## 5.2 輸入の解決 — 「少なくとも求めたもの」

輸入は名前2つ（名前空間と名前）で解決されます。Weasel はそれを `Linker` に持ちます
（`store.cppm:167`）。ホストが提供するものも、先にインスタンス化した wasm モジュールの
輸出も、同じ表に入ります。

```cpp
void publish(const std::string& ns, const Instance& inst) {
  for (const Export& ex : inst.module->exports) { ... define(ns, ex.name, e); }
}
```

見つかったものが、求められたものと合うかを見ます。関数は型が完全に一致すること。
大域変数は型と可変性が一致すること。limits については**片側だけ**です。

```cpp
bool limits_match(const Limits& have, const Limits& want) {
  if (have.min < want.min) return false;
  if (!want.has_max) return true;
  if (!have.has_max) return false;
  return have.max <= want.max;
}
```
（`instantiate.cppm:70`）

「下限は求めた以上、上限は求めた以下」。この向きでなければならないのは、
**モジュールが検証されたときに前提にした境界検査が、そのまま成り立ち続ける**
必要があるからです。1ページ以上を求めたモジュールに1ページ未満を渡してはいけないし、
上限2ページを前提にしたモジュールに無制限のメモリを渡してもいけない。

## 5.3 順序 — 関数が先

このモジュール自身の定義を作る順序には理由があります。

```cpp
// Functions first: a global initialiser or an element segment may hold
// `ref.func`, and a reference has to point at something that exists.
for (u32 i = 0; i < m.funcs.size(); ++i) { ... }
for (const TableType& tt : m.tables) { ... }
for (const MemType& mt : m.mems) { ... }
for (const Global& g : m.globals) {
  Value v{};
  if (!eval_const(g.init, store, *inst, v, d)) return nullptr;
  ...
}
```
（`instantiate.cppm:83` の中）

関数が最初なのは、大域変数の初期化式や要素セグメントが `ref.func` を含みうるからです。
参照は指す先が先に存在していなければ作れません。

大域変数は最後です。初期化式が読めるのは**輸入された**大域変数だけ（[3章](03-validate.md)）
なので、このモジュール自身の大域変数を順に作っていく途中で困ることはありません。

## 5.4 定数式は10行で走る

3章で命令を5種類に絞ったので、ここでの「実行」はループ1つです。

```cpp
bool eval_const(const Expr& e, Store& store, const Instance& inst, Value& out, Diag& d) {
  Value v{};
  for (const Inst& in : e) {
    switch (in.op) {
      case Op::I32Const: ... case Op::F64Const: v = Value{in.imm}; break;
      case Op::RefNull: v = Value::null_ref(); break;
      case Op::RefFunc: v = Value::of_ref(inst.funcs[in.a]); break;
      case Op::GlobalGet: v = store.globals[inst.globals[in.a]].value; break;
      case Op::End: break;
      default: d.fail(...); return false;
    }
  }
  out = v;
  return true;
}
```
（`instantiate.cppm:37`）

スタックすら要りません。値が1つしか生き残らないことは検証が保証済みなので、
最後に見た値がその式の値です。

制限をきつくすると実装が小さくなる、という交換がここにあります。もし定数式に
`i32.add` を許したら（"extended const" 提案がまさにそれです）、ここに小さな
評価器が要ります。

## 5.5 セグメント — 失敗しても遅い

アクティブなセグメントは、インスタンス化のときにメモリや表へ写されます。
写し先が足りなければ失敗です。

```
$ echo '(module (memory 1) (data (i32.const 65534) "abcd") (func (export "f")))' > o.wat
$ weasel run o.wat --invoke f
weasel: o.wat: data segment 0 does not fit memory 0
```

これは検証では捕まりません。オフセットは定数式なので、輸入された大域変数から
来ることがあり、そのときの値はインスタンス化のときまで分かりません。

だから**エラーが3種類**あります。

1. 検証が拒む — モジュール自身の誤り。いつでも同じ判定になる
2. インスタンス化が失敗する — モジュールの誤りだが、輸入が決まるまで分からない
3. トラップ — 走ってからの、入力に依存する失敗

仕様は2について、書き込みの途中で失敗してもよいと言っています。Weasel はそうしません。
**全部のオフセットを検査してから、全部を写します**。

```cpp
// Every segment's contents are computed first, and every active segment's
// bounds are checked, before a single byte is written.
```
（`instantiate.cppm:180`）

半端に書き込まれたメモリを持つストアを、あとで誰かが見ることになる — その状態を
作らないほうが説明しやすい、というだけの選択です。

写し終わったアクティブなセグメントは、その場で捨てられます。宣言的セグメントも同じ
（[3章](03-validate.md)のとおり、あれは検証器への申告書でしかない）。残るのは
パッシブなものだけで、それを `memory.init` と `table.init` が使います。

```cpp
if (m.elems[i].mode != SegMode::Passive) {
  inst->elems[i].clear();
  inst->elem_dropped[i] = true;
}
```

「捨てる」は要素を空にすることであって、消すことではありません。添字は命令に
焼き込まれているので、番号は残さなければならない。

## 5.6 `start`

`start` があれば、すべてが整ったあとに呼びます。引数も結果も持ちません
（検証がそれを確かめています）。

```cpp
if (m.start) {
  Machine machine(store);
  std::vector<Value> results;
  if (!machine.invoke(inst->funcs[*m.start], {}, results)) {
    d.fail(std::format("the start function trapped: {}", machine.trap_text()));
    return nullptr;
  }
}
```
（`instantiate.cppm:249`）

`start` の中でトラップすると、インスタンス化そのものが失敗します。ただしそのときには
メモリも表もできあがっていて、`start` が書き換えたものもそのまま残ります。
インスタンス化の失敗のうち、これだけは後片づけできません。

## 5.7 メモリと表は同じ形をしている

```cpp
struct MemInst {
  std::vector<u8> bytes;
  u32 max_pages = kMaxPages;
  bool has_max = false;
  i32 grow(u32 delta) { ... }
};

struct TableInst {
  std::vector<Value> elems;
  ValType type = ValType::FuncRef;
  u32 max = 0xffffffffu;
  bool has_max = false;
  i32 grow(u32 delta, Value fill) { ... }
};
```
（`store.cppm:26`, `store.cppm:46`）

どちらも「連続した領域、上限つき、伸ばせる」。違いは単位（バイトとページ／要素）と、
表には型があることだけです。`memory.grow` と `table.grow` が**失敗を値で返す**のも
共通です。

```cpp
i32 grow(u32 delta) {
  const u32 old = pages();
  const u64 want = u64{old} + delta;
  const u32 ceiling = has_max ? max_pages : kMaxPages;
  if (want > ceiling) return -1;
  bytes.resize(static_cast<std::size_t>(want) * kPageSize, 0);
  return static_cast<i32>(old);
}
```

-1 はトラップではありません。**プログラムが対処することを期待されている唯一の失敗**です
（[7章](07-memory.md)）。

## 5.8 ホスト関数も同じ表に入る

`FuncInst` は wasm の関数とホストの関数を1つの型で持ちます。

```cpp
struct FuncInst {
  FuncType type;
  Instance* instance = nullptr;  // null for a host function
  const Code* code = nullptr;
  u32 module_index = 0;
  HostFn host;
  std::string host_name;
  bool is_host() const { return instance == nullptr; }
};
```
（`store.cppm:72`）

分けないのは、**`call_indirect` と `funcref` が区別できてはいけない**からです。
表に入ったホスト関数は、wasm の関数と同じように間接呼び出しできなければなりません。
区別は呼ぶ直前の1回の分岐だけです（[6章](06-exec.md)）。

---

## していないこと

- **後片づけ**。失敗したインスタンス化は `Store` にゴミを残します（作った関数、
  作ったメモリ）。1つのモジュールを1回動かすだけの処理系なので、そこまでしていません。
- **インスタンスの破棄**。`Store` は `std::unique_ptr<Instance>` を貯めるだけで、
  減りません。GC も参照カウントもありません。
- **循環する輸入**。`Linker` は名前を先に登録しなければならないので、A が B を、
  B が A を輸入するモジュールの組は作れません。仕様も同じです。
- **複数メモリ**。検証が1つを超えたら断ります（`validate.cppm:803`）。

## 参考文献

- **WebAssembly Core Specification**, Section 4.5 "Modules"。`allocmodule` と
  `instantiate` の擬似コードが、この章の実装そのものです。
- **WebAssembly JS API**。`WebAssembly.Instance` と `WebAssembly.Memory` が
  ストアとインスタンスの分割を JavaScript 側に見せている例。

## 実装の地図

| 場所 | 何があるか |
|---|---|
| `src/common.cppm:96` | `Value` — 参照は番地+1、空参照はゼロ |
| `src/store.cppm:26` | `MemInst` — バイトと上限と `grow` |
| `src/store.cppm:46` | `TableInst` — 同じ形 |
| `src/store.cppm:72` | `FuncInst` — wasm とホストを1つの型で |
| `src/store.cppm:83` | `Instance` — 添字から番地への4本の表 |
| `src/store.cppm:139` | `Caller` — ホスト関数に渡るもの |
| `src/store.cppm:167` | `Linker` — 名前空間と名前 |
| `src/instantiate.cppm:37` | `eval_const` — 定数式の評価器 |
| `src/instantiate.cppm:70` | `limits_match` — 片側だけの一致 |
| `src/instantiate.cppm:83` | `instantiate` — 輸入・定義・セグメント・start |

---

[← 4. 検証が残すもの](04-plan.md) · [6. 実行ループ →](06-exec.md)
