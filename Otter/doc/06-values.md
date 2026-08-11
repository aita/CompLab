# 6. 値 — 写すものと分かち合うもの — `value.cppm` ／ `value.ml`

言語仕様が「struct は写され、array は分かち合われる」と言うとき、それを実現している
のは1つの関数と、評価器の**第二の読み方**です。この章はその2つの話です。

## 1. 値は13種類

```cpp
using Storage =
    std::variant<Unit, bool, std::int64_t, std::uint8_t, char32_t, float, double,
                 StringObject*, ArrayObject*, StructValue, Pointer, Closure*,
                 const NativeEntry*>;
```

```ocaml
type value =
  | Unit
  | Bool of bool | Int of int64 | Byte of int | Char of int
  | Float32 of float | Float64 of float
  | Text of string
  | Array of array_object
  | Struct of struct_object
  | Pointer of pointer
  | Function of closure
```

`byte` と `char` が `int` と別なのは、算術が折り返す幅がそれぞれ違うからです。
`float32` が `double` と別なのも同じ理由で、OCaml 側は `float` を1つしか持たないので
**演算のたびに単精度へ丸め直します**。

```ocaml
(* この数にいちばん近い単精度の数。float32 はすべてここを通るので、float32 の
   算術が float32 の算術になる。 *)
let narrow value = Int32.float_of_bits (Int32.bits_of_float value)
```

```
$ ./interpreter/build/otter examples/tour.otter | sed -n '5,7p'
float64 0.3333333333333333
float32 0.3333333432674408
```

## 2. 写すのは `copyOf` 1つだけ

```cpp
// 代入がするとおりに値を写す。struct はフィールド1つずつ、それ以外は同じ
// オブジェクトをもう一度名指すだけ。
Value copyOf(Heap& heap, const Value& value) {
    const auto* structure = std::get_if<StructValue>(&value.storage);
    if (structure == nullptr) { return value; }
    ...
    for (std::size_t index = 0; index < fields.size(); ++index) {
        held->fields.push_back(copyOf(heap, fields[index]));
    }
    return Value(StructValue{source.get().as<StructValue>().info, held.get()});
}
```

```ocaml
let rec copy_of value =
  match value with
  | Struct object_ -> struct_object object_.structure (Array.map copy_of object_.fields)
  | _ -> value
```

**分岐は1つ、`Struct` かどうかだけです。** 再帰するので、struct の中の struct も
奥まで写ります。struct の中の配列は写りません（`Array` の枝がないので）。

呼ばれるのは6箇所です。変数宣言、代入、引数の束縛、`return`、配列リテラルの要素、
構造体リテラルのフィールド。**言語仕様が「代入・引数渡し・フィールドや要素への格納」と
言っている場所と同じ6箇所**です。

```
$ ./interpreter/build/otter vals.otter
copied  3 99
nested  4 77
shared  99
through 42
field   7
temp    5
struct= true
array=  true false
string= true
```

1行目が写し、2行目が奥まで写ること、3行目が分かち合いです。

文字列が写らないのに「写したのと区別がつかない」のは、書き換える手段がないからです。

```
$ ./interpreter/build/otter string_is_immutable.otter
string_is_immutable.otter:5:5: strings cannot be changed in place
```

## 3. 第二の読み方 — `place`

`&x` と `x = ...` は、`x` の**値**ではなく**場所**を要る。だから評価器には
`evaluate` のほかに `place` があります。

```cpp
// 式が名指す枠。書き込んだり、アドレスを取ったりできるように。枠でないものには
// 新しいセルを与える。これが一時に & を適用したときにすべきことである。
Pointer place(Expr& expr, Environment& scope) {
    switch (expr.kind) {
        case ExprKind::Name:  /* Local なら scope の cell、Global なら globals_ の cell */
        case ExprKind::Field: /* ModuleGlobal なら cell、StructField なら object のフィールド */
        case ExprKind::Index: /* 配列なら要素。文字列はここに来ない */
        case ExprKind::Unary: /* Dereference ならポインタそのもの */
        default: break;
    }
    Root value(heap_, evaluate(expr, scope));
    Cell* cell = makeCell(value.get());
    return Pointer{cell, &cell->value};
}
```

**最後の3行が言語仕様の「それ以外に `&` を適用すると新しいセルができる」です。**
これがあるので、リンク構造が `&new Node { ... }` で伸ばせます。

```
    // 一時に & を取ると新しいセルができる
    var made: *int = &(1 + 1);
    *made = 5;
...
temp    5
```

`place` に来られる式の種類は、検査器の `requireAssignable` が許した4つと一致して
います。**片方が許してもう片方が扱わない形はありません。**

```cpp
case ExprKind::Index: {
    const auto& index = static_cast<const IndexExpr&>(target);
    if (index.subject->type->kind == TypeKind::String) {
        throw CompileError(target.span, "strings cannot be changed in place");
    }
    return;
}
```

## 4. `isStorage` — 写しに書き込まないために

`a.b.c = 1` を考えます。`a.b` を**値として**評価すると、`a` の中の struct を
名指す `StructValue` が返ってきます。この `StructValue` はコピーではないので
それでよいのですが、`f().b = 1` のように**枠でないもの**から来た struct に
書き込んでも意味がありません。

```cpp
// フィールドアクセスが読む struct を、直接届いたのかポインタ越しかで分けて返す。
StructValue structureOf(FieldExpr& field, Environment& scope) {
    if (field.throughPointer) { ... }
    if (isStorage(*field.subject)) {
        return place(*field.subject, scope).slot->as<StructValue>();
    }
    return evaluate(*field.subject, scope).as<StructValue>();
}
```

`isStorage` は `place` が特別扱いする形と同じ集合です。

```cpp
case ExprKind::Index:
    // 文字列は枠ではない。バイトに書き込めない。
    return static_cast<const IndexExpr&>(expr).subject->type->kind == TypeKind::Array;
```

**`place` の `switch` と `isStorage` の `switch` が同じ形をしている**のは偶然では
なく、片方が「新しいセルを作る場合」を答え、もう片方が「作らずに済む場合」を答えて
いるからです。

## 5. ポインタの表し方 — 二度書いて別物になった

C++ 側のポインタは**オブジェクトの中の枠を直接指します**。

```cpp
// ポインタはヒープ上のオブジェクトの中の枠を名指す。枠を到達可能に保つのは
// オブジェクトのほうで、枠そのものは内部ポインタだが、このヒープでは何も動かない
// ので健全である。
struct Pointer {
    GcObject* owner = nullptr;
    Value* slot = nullptr;
};
```

`owner` は収集器のためだけにあります。`slot` を辿っても持ち主には戻れないので、
**マークすべきものを別に持ち歩いています**（[8章](08-gc.md)）。

OCaml 側は内部ポインタを持てないので、代数的データ型で「どこか」を表します。

```ocaml
and pointer =
  | Null
  | Cell_at of cell
  | Field_at of struct_object * int
  | Element_at of array_object * int
```

読み書きは4通りの分岐です。

```ocaml
let load = function
  | Null -> invalid_arg "load"
  | Cell_at cell -> cell.held
  | Field_at (object_, index) -> object_.fields.(index)
  | Element_at (array, index) -> array.items.(index)
```

**同じ言語仕様が、片方では2語の構造体に、もう片方では4つのコンストラクタになりました。**
どちらも「持ち主のオブジェクトが生きているかぎり枠は有効」を守っていて、守り方が
違います。C++ 側は `owner` を明示して収集器に渡し、OCaml 側はオブジェクトを値として
持っているので何もしなくてよい。

`null` の表し方も割れました。C++ は `Pointer{nullptr, nullptr}`、OCaml は `Null` という
コンストラクタです。

## 6. 変数がセルに住む理由

```cpp
// 1つの変数の置き場所。変数がスコープの表ではなくセルに住むのは、表が伸びても
// アドレスが生き残るようにするため。
struct Cell : GcObject { Value value; };

// 名前つきセルの塊。探索は外へ向かうので、閉包の本体が、それを作った関数の変数に
// 届く。
struct Environment : GcObject {
    Environment* parent = nullptr;
    std::unordered_map<std::string, Cell*> slots;
};
```

`std::unordered_map` の値を直接指すと、表が伸びたときにアドレスが変わります。
セルを1段挟むと、**変数へのポインタが、その変数を持つスコープに新しい変数が増えても
生き続けます**。

OCaml 側も同じ理由で同じ形です。

```ocaml
and cell = { mutable held : value }
and environment = { parent : environment option; slots : (string, cell) Hashtbl.t }
```

セルは閉包にも要ります。閉包が捉えるのは値のスナップショットではなく**変数そのもの**
なので、捉えた側と捉えられた側が同じセルを見ます（[7章](07-interp.md)）。

## 7. `==` の意味は型ごとに違う

```cpp
// 同じ型の2つの値を比べる。文字列は内容、struct はフィールドごと。配列と閉包と
// ポインタは同一性で比べる。
bool equalValues(const Value& left, const Value& right) {
    if (left.storage.index() != right.storage.index()) { return false; }
    if (const auto* text = std::get_if<StringObject*>(&left.storage)) {
        return (*text)->text == std::get<StringObject*>(right.storage)->text;
    }
    if (const auto* structure = std::get_if<StructValue>(&left.storage)) {
        /* フィールドごとに再帰 */
    }
    return left.storage == right.storage;
}
```

最後の1行が効くのは、`std::variant` の `operator==` が中身のポインタを比べるからです。
配列も閉包も**同じオブジェクトかどうか**になります。

```
struct= true         フィールドが同じなら同じ
array=  true false   同じ配列なら同じ、中身が同じでも別なら違う
string= true         内容が同じなら同じ
```

関数の比較は検査器が拒みます。

```cpp
case BinaryOp::Equal:
case BinaryOp::NotEqual:
    if (operand->kind == TypeKind::Function) {
        throw CompileError(expr.span, "functions cannot be compared");
    }
```

OCaml 側は `equal_values` が同じ表を作りますが、**`Array left, Array right -> left == right`**
と物理等価を明示的に書く必要があります。OCaml の `=` は構造比較なので、書かないと
中身の同じ別の配列が等しくなってしまいます。

## 8. `zeroOf` が要るのは1箇所だけ

```cpp
// この型の値が最初に何であるか。言語に未初期化の変数がないので、配列の要素だけが
// これを要る。
Value zeroOf(const Type* type) { ... }
```

`[value; count]` は種を写して埋めるので、実は `zeroOf` を通りません。通るのは
構造体リテラルが**フィールドを埋める前の初期状態**です。

```cpp
held->fields.resize(expr.structure->fields.size());
```

`resize` は既定構築の `Value`（つまり `Unit`）で埋めます。検査器がすべてのフィールドの
初期化子を要求しているので、この `Unit` は必ず上書きされます。**上書きされる前に
収集が起きても、`Unit` は何も指さないので安全です。**

## していないこと

**値の表現を型ごとに最適化していません。** `int` も閉包も同じ `variant` に入ります。
タグ付きポインタも NaN ボクシングもありません。

**文字列を共有していません。** 同じ内容のリテラルを2回書けば、実行時にオブジェクトが
2つできます。インターンすれば減りますが、内容比較が同一性比較になるわけではありません
（そう変えると `+` で作った文字列が別扱いになるので）。

**構造体を平坦に持っていません。** `Box { at: Point }` は `Box` のオブジェクトの中に
`Point` を名指す値が入っており、`Point` のオブジェクトは別にあります。写すときに
奥まで再帰するのはそのためで、平坦に持てば `memcpy` 1回で済みます。

**配列の要素型を実行時に使っていません。** `ArrayObject::element` は持っていますが、
読むのは `zeroOf` を呼ぶ道だけです。型は検査で決まっているので、実行時に問う必要が
ありません。

## 参考文献

- R. Nystrom, [*Crafting Interpreters*][ci] の "Closures"。変数をセル（upvalue）に
  逃がす理由と、値のスナップショットではなく変数そのものを捉えるという判断。
- Go 仕様の [*Assignability*][goassign] と、構造体が値型・スライスが参照型である
  という区別。2節の6箇所はこの区別を実装したものです。
- ISO/IEC 14882 の `std::variant`。7節の最後の1行が同一性比較になるのは、
  `operator==` が代替ごとの `==` に委ねるからです。

[ci]: https://craftinginterpreters.com/closures.html
[goassign]: https://go.dev/ref/spec#Assignability

## 実装の地図

| C++ | |
|---|---|
| `value.cppm` 30行 | `StructValue` — 写される側 |
| `value.cppm` 40行 | `Pointer` — 内部ポインタと持ち主 |
| `value.cppm` 47行 | `Value` |
| `value.cppm` 117行 | `Cell` — 表が伸びても生きるアドレス |
| `value.cppm` 125行 | `Environment` |
| `value.cppm` 415行 | `copyOf` |
| `value.cppm` 435行 | `zeroOf` |
| `value.cppm` 458行 | `equalValues` |
| `interp.cppm` 269行 | `place` — 第二の読み方 |
| `interp.cppm` 334行 | `structureOf` |
| `interp.cppm` 348行 | `isStorage` |
| `check.cppm` 1218行 | `requireAssignable` — `place` と同じ4つ |

| OCaml | |
|---|---|
| `value.ml` 9行 | `value` |
| `value.ml` 34行 | `pointer` — 4つのコンストラクタ |
| `value.ml` 42行 | `cell` |
| `value.ml` 46行 | `environment` |
| `value.ml` 142・148行 | `load`・`store` |
| `value.ml` 157行 | `copy_of` |
| `value.ml` 173行 | `equal_values` — 物理等価を明示する |
| `value.ml` 197行 | `narrow` — float32 の丸め |
| `interp.ml` 212行 | `place` |
| `interp.ml` 258行 | `is_storage` |

---

[← 5. 期待型を下ろす](05-expected.md) ／ [目次](index.md) ／ [7. 木を歩く →](07-interp.md)
