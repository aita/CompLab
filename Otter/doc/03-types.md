# 3. 型 — インターンと同一性 — `types.cppm` ／ `types.ml`

型は12種類しかなく、多相もありません。それでも「2つの型が同じか」という問いには
二度とも違う答え方をしました。**C++ 側はポインタ比較にし、OCaml 側は再帰的な述語に
しました。** その選択が両方の実装の細部に効いています。

## 1. 12個

```cpp
enum class TypeKind {
    Void, Bool, Int, Byte, Char, Float32, Float64, String,
    Array, Pointer, Struct, Function,
    // `null` リテラル単体の型。どのポインタにもなり、宣言には現れない。
    NullPointer,
};
```

引数を取るのは `Array`（1つ）、`Pointer`（1つ）、`Function`（並びと結果）、
`Struct`（宣言そのもの）だけです。

`NullPointer` は13番目で、**ソースには書けません**。`null` と書いた式が単独で持つ型で、
`assignable` が「どのポインタ型にも渡せる」と言うためだけに存在します。

```cpp
bool assignable(const Type* from, const Type* to) {
    if (from == to) { return true; }
    return from->kind == TypeKind::NullPointer && to->kind == TypeKind::Pointer;
}
```

**これが「暗黙の変換がない」という言語の判断の全文です。** 3行しかありません。数値の
昇格も、部分型も、`bool` への変換もここに書かれていないので、存在しません。

## 2. C++ — 同じ型はポインタも同じ

`TypeArena` が全部の型を所有し、**同じ型には同じポインタを返します**。

```cpp
const Type* arrayOf(const Type* element) {
    auto [entry, inserted] = arrays_.try_emplace(element, nullptr);
    if (inserted) {
        Type* type = allocate();
        type->kind = TypeKind::Array;
        type->element = element;
        entry->second = type;
    }
    return entry->second;
}
```

`array<int>` を10箇所で書いても `Type*` は1つです。関数型は引数の並びと結果を鍵に
した `std::map` で、鍵の比較は `operator<=>` の既定です。

```cpp
struct FunctionKey {
    std::vector<const Type*> parameters;
    const Type* result;
    auto operator<=>(const FunctionKey&) const = default;
};
```

**要素がすでにインターンされているので、鍵の比較はポインタの並びの比較で済みます。**
`array<array<int>>` を作るときには内側の `array<int>` が先にインターンされていて、
その1つのポインタが鍵になります。

置き場所が `std::deque` なのは、あとから型が増えても既に配った `Type*` が生き続ける
必要があるからです。

```cpp
// あとから型が増えても、配ったポインタが生き続けるように deque。
std::deque<Type> storage_;
```

これで、検査器のいたるところにある型の比較が `==` 1つになります。

```cpp
if (index != types_.intType()) { ... }
if (operand != types_.boolType()) { ... }
```

## 3. OCaml — 同じ型は `equal` が言う

OCaml 側は代数的データ型なので、型はただの値です。インターンはしません。

```ocaml
type t =
  | Void | Bool | Int | Byte | Char | Float32 | Float64 | String
  | Array of t
  | Pointer of t
  | Struct of structure
  | Function of t list * t
  | Null_pointer
```

比較は再帰的な述語です。

```ocaml
let rec equal left right =
  match (left, right) with
  | Void, Void | Bool, Bool | ... -> true
  | Array left, Array right | Pointer left, Pointer right -> equal left right
  | Struct left, Struct right -> left.id = right.id
  | (Function (lp, lr), Function (rp, rr)) ->
      List.length lp = List.length rp
      && List.for_all2 equal lp rp
      && equal lr rr
  | _ -> false
```

**OCaml の `=` を使わないのには理由が2つあります。** 1つは構造体が nominal なこと
（次節）。もう1つは、構造体がポインタ経由で自分自身に届くと `fields` が循環した値に
なることで、`=` はそれを永久に歩きます。`Struct` の枝が `id` で止まるので、この
`equal` は必ず終わります。

## 4. 構造体は nominal — 同じ形でも別の型

```cpp
// 構造体は nominal。同じフィールドを持つ2つの宣言はやはり別の型なので、
// この記録の同一性が型の同一性である。
struct StructInfo {
    std::string moduleName;
    std::string name;
    std::vector<Field> fields;
    bool complete = false;
};
```

```
$ cat nominal.otter
module nominal;

struct A { x: int; }
struct B { x: int; }

fun main() -> int {
    var a: A = new A { x: 1 };
    var b: B = a;
    return 0;
}

$ ./interpreter/build/otter nominal.otter
nominal.otter:8:16: this initial value is nominal.A, but nominal.B was expected
$ ./ocaml/_build/default/bin/otter.exe nominal.otter
nominal.otter:8:16: this initial value is nominal.A, but nominal.B was expected
```

診断が `nominal.A` と修飾名で出るのは `describe` が `qualifiedName()` を使うからで、
**別のモジュールに同じ名前の struct があるときに読めるようにするため**です。

構造体だけはインターンされません。

```cpp
// 構造体はインターンではなく生成される。宣言ごとに固有の型を持ち、フィールドは
// あとから埋めるので、自分自身を指すことができる。
std::pair<const Type*, StructInfo*> declareStruct(std::string moduleName, std::string name) {
```

OCaml 側は連番の `id` を持たせて同じことをします。

```ocaml
let next_id = ref 0

let declare_struct ~module_name ~name =
  incr next_id;
  { id = !next_id; module_name; name; fields = []; complete = false }
```

**フィールドを空で作って後から埋める**のは[4章](04-check.md)の相1と相2の分割そのもの
で、`struct Node { value: int; next: *Node; }` が書けるのはこのためです。

## 5. 別名は名前でしかない

`type UserId = int;` は新しい型を作りません。**`UserId` は `int` そのもの**です。

```
$ cat alias.otter
module alias;

type UserId = int;

fun main() -> int {
    var id: UserId = 7;
    var text: string = id;
    return 0;
}

$ ./interpreter/build/otter alias.otter
alias.otter:7:24: this initial value is int, but string was expected
```

診断に `UserId` が出ないのは、型オブジェクトが `int` のものだからです。診断を読む側
から見ると情報が減っていますが、**別名が透過であるという言語の判断を裏切らない**ほうを
選んでいます。

別名は要求されたときに解決されます。

```cpp
const Type* resolveAlias(TypeAliasDecl* declaration) {
    if (declaration->resolved != nullptr) { return declaration->resolved; }
    if (declaration->resolving) {
        throw CompileError(declaration->span,
            std::format("type `{}` is defined in terms of itself", declaration->name));
    }
    declaration->resolving = true;
    ModuleAst* saved = std::exchange(module_, declaration->owner);
    declaration->resolved = resolveType(declaration->target.get());
    module_ = saved;
    declaration->resolving = false;
    return declaration->resolved;
}
```

`resolving` の旗が環の検出です。遅延しているので**別名は好きな順に書けます**。
`module_` を差し替えて戻すのは、別名の右辺が書かれたモジュールで名前を解決するためで、
これがないと import 越しに使われた別名が使う側のモジュールで解決されてしまいます。

```
$ ./interpreter/build/otter alias_cycle.otter
alias_cycle.otter:3:1: type `Left` is defined in terms of itself
```

遅延の代償が1つあります。**誰も使わない環は診断されません。**

```
$ cat aliasc.otter                 alias_cycle.otter から使用箇所を抜いたもの
module aliasc;

type Left = Right;
type Right = Left;

fun main() -> int { return 0; }

$ ./interpreter/build/otter aliasc.otter; echo "exit=$?"
exit=0
```

## 6. 整数リテラルの範囲は型が持つ

```cpp
IntegerRange rangeOf(const Type* type) {
    switch (type->kind) {
        case TypeKind::Byte: return {0, 255};
        case TypeKind::Char: return {0, 0x10FFFF};
        default: return {min<int64>, max<int64>};
    }
}
```

`char` の上限が `0x10FFFF` なのは Unicode のスカラ値の範囲だからです。これを使うのは
[5章](05-expected.md)の `checkInteger` 1箇所だけで、**リテラルとして書けるか**を決めます。
実行時の算術はどちらの型も巻き戻る（wrap する）ので、この範囲は検査時にしか効きません。

```
$ ./interpreter/build/otter literal_out_of_range.otter
literal_out_of_range.otter:4:23: 256 does not fit in byte
```

しかし `tour.otter` は 255 に1を足して 0 になります。

```
== numbers
byte    255
...
wrapped 0
```

## 7. `describe` は診断の言葉

型が診断に現れるときの綴りは1箇所で決まります。

```cpp
case TypeKind::Array:    return std::format("array<{}>", describe(type->element));
case TypeKind::Pointer:  return std::format("*{}", describe(type->element));
case TypeKind::Struct:   return type->structure->qualifiedName();
case TypeKind::Function: /* fun(A, B) -> R */
```

OCaml 側の `describe` は1行ずつ同じ文字列を作ります。**この関数が一致していることが、
[10章](10-errors.md)で診断が22本中21本まで一致する理由の半分**です（もう半分は
診断の文面そのものが同じであること）。

```
$ ./interpreter/build/otter nested2.otter
nested2.otter:9:35: this initial value is fun(int, int) -> bool, but fun(int, int) -> int was expected
$ ./ocaml/_build/default/bin/otter.exe nested2.otter
nested2.otter:9:35: this initial value is fun(int, int) -> bool, but fun(int, int) -> int was expected
```

`describe` は[2章](02-modules.md)の `writtenType` でも使われていて、そちらでは
**診断のための文字列ではなく、型式の `path` として**使われます。組み込みモジュールの
引数の型がソースに書かれていたことにするための綴りです。

## していないこと

**多相がありません。** `array` だけが引数を取り、それも1つです。ユーザが引数付きの型を
宣言する構文はありません。

**部分型がありません。** `assignable` は `null` を除いて等しさなので、継承も
インタフェースも、`byte` から `int` への暗黙の拡大もありません。

**型推論がありません。** すべての変数、引数、結果が型を書きます。リテラルだけが
文脈から型を受け取り、その仕組みが[5章](05-expected.md)です。

**未使用の別名を検査しません。** 5節のとおり、誰も使わない別名の環は通ります。全部を
先に解決すれば捕まりますが、そうすると「別名を好きな順に書ける」性質を別の方法で
作り直すことになります。

**型の等価性に別名を残していません。** `UserId` と `int` が診断で区別できないのは
この判断の帰結です。区別したければ別名を透過でなくする、つまり別の型にすることに
なります。

## 参考文献

- B. Pierce, *Types and Programming Languages*, MIT Press, 2002。19.3節が
  nominal と structural の対比、11.4節が型の別名（type abbreviation）が透過である
  ということ。この章の判断は両方ともそこで言われている素直なほうです。
- L. Cardelli, [*Type Systems*][cardelli], ACM Computing Surveys 28(1), 1996。
  型の同一性を「宣言の同一性」に置く選択の整理。
- The Unicode Standard, D76（Unicode scalar value）。6節の `0x10FFFF`。

[cardelli]: https://doi.org/10.1145/234313.234418

## 実装の地図

| C++ | |
|---|---|
| `types.cppm` 7行 | `TypeKind` — 13個 |
| `types.cppm` 34行 | `StructInfo` — 宣言の同一性が型の同一性 |
| `types.cppm` 75–90行 | `isInteger`・`isFloating`・`isNumeric` |
| `types.cppm` 98行 | `rangeOf` |
| `types.cppm` 110行 | `describe` — 診断の綴り |
| `types.cppm` 152行 | `TypeArena` |
| `types.cppm` 190・201・212行 | `arrayOf`・`pointerTo`・`functionOf` — インターン |
| `types.cppm` 227行 | `declareStruct` — ここだけインターンしない |
| `types.cppm` 257行 | `storage_` が `deque` である理由 |
| `types.cppm` 277行 | `assignable` — 暗黙変換がないことの全文 |
| `check.cppm` 177行 | `resolveAlias` — 遅延と `resolving` の旗 |

| OCaml | |
|---|---|
| `types.ml` 8行 | `t` |
| `types.ml` 25行 | `structure` — `id` が同一性 |
| `types.ml` 37行 | `declare_struct` |
| `types.ml` 56行 | `equal` — `Struct` の枝で止まるので終わる |
| `types.ml` 82行 | `range_of` |
| `types.ml` 87行 | `describe` |
| `types.ml` 108行 | `assignable` |
| `check.ml` 278行 | `resolve_alias` |

---

[← 2. モジュールを集める](02-modules.md) ／ [目次](index.md) ／ [4. 検査の4つの相 →](04-check.md)
