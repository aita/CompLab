# 5. 期待型を下ろす — `check.cppm` ／ `check.ml`

型推論のない言語でも、`var small: byte = 200;` は書けなければ困ります。`200` は
どこから `byte` を知るのか。答えは、検査器の主関数の第二引数です。

```cpp
const Type* check(Expr* expr, const Type* expected);
```

**式を検査するとは、「ここに来てほしい型」を渡して、実際の型を受け取ることである。**
`expected` は `nullptr` でもよく、その場合は「何でもよい」を意味します。これだけで、
リテラルの型・空の配列・`null`・`&` の中身・`if` の両腕が決まります。

## 1. 期待型が効く場所は7つ

`checkUncached` の中で `expected` を読むのは次の枝だけです。

| 式 | 期待型がある | ない |
|---|---|---|
| 整数リテラル | 整数型ならそれ。範囲を検査 | `int` |
| 小数リテラル | 浮動小数点型ならそれ | `float64` |
| `null` | ポインタ型ならそれ | `NullPointer` |
| 配列リテラル | 配列型ならその要素型を要素へ下ろす | 最初の要素から決める |
| `&x` | ポインタ型ならその中身を `x` へ下ろす | `x` の型を包む |
| `+x` `-x` `~x` | そのまま `x` へ下ろす | — |
| 二項演算 | 両辺へ下ろす（3節） | — |
| `if` の値 | 両腕へ下ろす | 左腕の型を右腕の期待型にする |

ほかの枝は `expected` を無視します。`checkCall` は呼び出せる型かどうかを見るだけで、
**引数の期待型は関数の型から作ります**。

```cpp
for (std::size_t index = 0; index < expr.arguments.size(); ++index) {
    const Type* wanted = callee->parameters[index];
    const Type* actual = check(expr.arguments[index].get(), wanted);
    expect(actual, wanted, expr.arguments[index]->span, std::format("argument {}", index + 1));
}
```

**期待型は上から降ってくるだけでなく、その場で作られもします。** 変数宣言なら宣言された
型、`return` なら結果型、構造体リテラルならフィールドの型、代入なら左辺の型です。

## 2. リテラルは期待型を受け取り、その場で範囲を見る

```cpp
const Type* checkInteger(IntegerExpr& expr, const Type* expected) {
    const Type* type = expected != nullptr && isInteger(expected) ? expected : types_.intType();
    IntegerRange range = rangeOf(type);
    if (expr.value < range.low || expr.value > range.high) {
        throw CompileError(expr.span, std::format("{} does not fit in {}", expr.value,
                                                  describe(type)));
    }
    return type;
}
```

**期待型が整数型でなければ `int` に落ちます。** `var text: string = 200;` は `200` が
`int` になり、そのあと `expect` が「int だが string が要る」と言います。診断が
「200 is not a string」ではなく型の話になるのはこのためです。

```
$ ./interpreter/build/otter expect.otter
3
2
201 201
0
true
200
```

1行目は `1 + 2`。期待型がないので `int` です。2行目は `1.5 + 0.5` で `float64`。
どちらも `str.from_int` / `str.from_float` の引数型が期待型として降りているので、
**降りてこなかった場合の既定と一致していることが確かめられています**。

## 3. 裸の数は相手側から型をもらう

`x + 1` と `1 + x` を同じに読ませるための唯一の仕掛けです。

```cpp
// 裸の数は反対側から型を受け取るので、`1 + x` が `x + 1` と同じに読める。
const Type* left = nullptr;
const Type* right = nullptr;
if (isBareNumber(*expr.left) && !isBareNumber(*expr.right)) {
    right = check(expr.right.get(), expected);
    left = check(expr.left.get(), right);
} else {
    left = check(expr.left.get(), expected);
    right = check(expr.right.get(), left);
}
```

`isBareNumber` はリテラルそのものだけを見ます。

```cpp
static bool isBareNumber(const Expr& expr) {
    return expr.kind == ExprKind::Integer || expr.kind == ExprKind::Floating;
}
```

**`(1)` は裸の数です**（括弧は[1章](01-syntax.md)で消えるので）。**`1 + 0` は
裸の数ではありません。** 後者は二項演算なので、左から検査され、`int` になります。

```
$ cat expect.otter                     var small: byte = 200;
    var up: byte = small + 1;
    var down: byte = 1 + small;
$ ./interpreter/build/otter expect.otter
...
201 201
```

`small + 1` は左が裸でないので普通の道を通り、`1` が `byte` の期待型を受けます。
`1 + small` は左が裸なので右を先に検査し、その `byte` を左へ渡します。**どちらも
201 で、`byte` として折り返しています。**

順序を入れ替えるだけで済むのは、`&&` と `||` が既に別の枝で処理されていて、ここに
到達する演算子はすべて両辺が同じ型を要求するからです。

## 4. 空の配列と `null` — 期待型がないと決まらないもの

```cpp
if (expr.elements.empty()) {
    if (element == nullptr) {
        throw CompileError(expr.span,
            "an empty array literal has no element type to go on; give "
            "the variable a type, as in `var a: array<int> = [];`");
    }
    return types_.arrayOf(element);
}
```

```
$ cat noel.otter
module noel;

fun main() -> int {
    [];
    return 0;
}

$ ./interpreter/build/otter noel.otter
noel.otter:4:5: an empty array literal has no element type to go on; give the variable
a type, as in `var a: array<int> = [];`
$ ./ocaml/_build/default/bin/otter.exe noel.otter
noel.otter:4:5: an empty array literal has no element type to go on; give the variable
a type, as in `var a: array<int> = [];`
```

診断が**直し方を書いている**のは、この誤りが「型が足りない」以外の直し方を持たない
からです。

引数として渡せば期待型は来ます。

```
fun take(values: array<int>) -> int { return values.length; }
...
io.println(str.from_int(take([])));          // 通る
```

`null` も同じ形で、期待型がなければ `NullPointer` 型のままです。

```cpp
case ExprKind::Null:
    if (expected != nullptr && expected->kind == TypeKind::Pointer) { return expected; }
    return types_.nullType();
```

`NullPointer` が残ったまま `assignable` に届くと、[3章](03-types.md)の3行目が
拾います。`p == null` の比較が通るのもそこです。二項演算の側では、**どちらかが
`NullPointer` なら反対側を演算の型として採ります**。

```cpp
const Type* operand = left->kind == TypeKind::NullPointer ? right : left;
```

## 5. `&` は期待型の中身を下ろす

```cpp
case UnaryOp::AddressOf: {
    const Type* inner =
        expected != nullptr && expected->kind == TypeKind::Pointer ? expected->element : nullptr;
    const Type* operand = check(expr.operand.get(), inner);
    if (operand->kind == TypeKind::Void) {
        throw CompileError(expr.span, "there is no address of a void value");
    }
    return types_.pointerTo(operand);
}
```

これで `var seed: *byte = &200;` が通ります。`*byte` の中身 `byte` が `200` の
期待型として降り、`byte` の値ができ、`&` がそのアドレスを取ります。
`&` を一時に適用すると新しいセルができる（[6章](06-values.md)）ので、これは
「200 を持つセルを1つ作ってそのアドレス」という意味になります。

```
$ ./interpreter/build/otter expect.otter
...
200
```

## 6. `if` の両腕

```cpp
const Type* checkConditional(IfExpr& expr, const Type* expected) {
    requireBool(expr.condition.get(), "an if condition");

    const Type* consequent = checkValueBlock(*expr.consequent, expected);
    const Type* alternative =
        checkValueBlock(*expr.alternative, expected != nullptr ? expected : consequent);

    if (!assignable(consequent, alternative) && !assignable(alternative, consequent)) {
        throw CompileError(expr.span, "one arm of this if gives ... and the other gives ...");
    }
    if (consequent->kind == TypeKind::Void) { throw ...; }
    return consequent->kind == TypeKind::NullPointer ? alternative : consequent;
}
```

**期待型があれば両腕に同じものを下ろし、なければ左腕の結果を右腕の期待型にします。**

```
$ cat arms.otter
    var pick: byte = if (true) { 200 } else { 201 };
    io.println(str.from_bool(if (true) { 1 } else { 2 } == 1));
    var p: *int = if (true) { null } else { null };
$ ./interpreter/build/otter arms.otter
200
true
true
```

1つ目は `byte` が両腕に下りるので `200` も `201` も `byte`。2つ目は期待型がなく、
左腕が `int` になり、それが右腕の期待型になります。3つ目は両腕とも `NullPointer` で、
最後の行が `consequent` の代わりに `alternative` を返しますが、どちらも
`NullPointer` なので、外側の `expect` が `*int` への代入として受け取ります。

範囲の検査は腕ごとに起きます。

```
$ cat arms2.otter
    var pick: byte = if (true) { 200 } else { 300 };
$ ./interpreter/build/otter arms2.otter
arms2.otter:4:47: 300 does not fit in byte
```

桁 47 は右腕の `300` です。**期待型が下りているからこそ、`300` の位置で報告できます。**
両腕を先に検査してから突き合わせる設計だと、ここは「一方が byte で他方が int」に
なっていました。

## 7. `nullptr` を渡す3箇所

期待型を持たずに検査するのは、式文・`for` の歩進・そして「型を知りたいだけ」の
被作用側です。

```cpp
case StmtKind::Expression:
    check(static_cast<ExprStmt&>(statement).value.get(), nullptr);
```

```cpp
const Type* checkIndex(IndexExpr& expr) {
    const Type* subject = check(expr.subject.get(), nullptr);
    const Type* index = check(expr.index.get(), types_.intType());
```

添字は `int` を期待し、添字を取られる側は期待しません。**期待するものがないから
`nullptr`** であって、「何でもよい」という型があるわけではありません。

## 8. 一度検査したら書き込む

```cpp
const Type* check(Expr* expr, const Type* expected) {
    expr->type = checkUncached(expr, expected);
    return expr->type;
}
```

`type` は最後に検査したときの結果です。同じ式が二度検査されることはありません
（そういう道がありません）。評価器は `expr->type` を無条件に読めます。

`BinaryExpr` だけは2つ持ちます。

```cpp
// 両辺が揃えられた型。比較ではこれは式自身の型ではない。
const Type* operandType = nullptr;
```

`a < b` の `type` は `bool`、`operandType` は `a` と `b` の型です。評価器は
**どちらの数として比べるか**を `operandType` で、**結果をどう作るか**を `type` で
決めます（[7章](07-interp.md)）。

## していないこと

**双方向型検査の体系を名乗っていません。** ここにあるのは検査モード（checking）と
合成モード（synthesis）の区別に相当するものですが、規則として書かれてはおらず、
`expected` を読む枝と読まない枝があるだけです。どの枝が読むかは1節の表で全部です。

**期待型が単一化されません。** 下ろした期待型と実際の型が食い違ったら、その場で
診断になります。型変数がないので、後から決め直すことがありません。

**関数リテラルに期待型が下りません。** `var f: fun(int) -> int = fun(x: int) -> int {...}`
の引数の型は書かなければなりません。下ろせば省けますが、そうすると
「すべての引数が型を書く」という言語の判断に穴が空きます。

**`1 + 0` が裸の数ではありません。** 3節のとおり、定数式の畳み込みをしないので、
`var b: byte = small + (1 + 0);` は通りません。畳み込みを入れるなら、
`isBareNumber` ではなく「この式が定数か」を問うことになります。

## 参考文献

- J. Dunfield, N. Krishnaswami, [*Bidirectional Typing*][bidir], ACM Computing
  Surveys 54(5), 2021。checking と synthesis を分ける形の整理。この章の `check` は
  その2つを1つの関数の第二引数で切り替えたものです。
- B. Pierce, D. Turner, [*Local Type Inference*][lti], TOPLAS 22(1), 2000。
  型注釈を局所的に伝播させるだけでどこまで書かずに済むか、という問いの出どころ。
- Go 仕様の [*Constant expressions*][goconst]。型のない定数が文脈から型を得る規則。
  3節の裸の数はこれをリテラル1個に切り詰めたものです。

[bidir]: https://doi.org/10.1145/3450952
[lti]: https://doi.org/10.1145/345099.345100
[goconst]: https://go.dev/ref/spec#Constant_expressions

## 実装の地図

| C++ | |
|---|---|
| `check.cppm` 680行 | `check` — 検査して木に書き込む |
| `check.cppm` 685行 | `checkUncached` — 期待型を読む枝の一覧 |
| `check.cppm` 733行 | `checkInteger` — 期待型と範囲 |
| `check.cppm` 772行 | `checkArray` — 要素型を下ろす |
| `check.cppm` 870行 | `checkCall` — 引数の期待型を関数型から作る |
| `check.cppm` 1041行 | `AddressOf` — 期待型の中身を下ろす |
| `check.cppm` 1087–1093行 | 裸の数の入れ替え |
| `check.cppm` 1101行 | `NullPointer` なら反対側を演算の型に |
| `check.cppm` 1153行 | `isBareNumber` |
| `check.cppm` 1176行 | `checkConditional` — 両腕への期待型 |
| `check.cppm` 670行 | `expect` — 実際と期待の突き合わせ |

| OCaml | |
|---|---|
| `check.ml` 587行 | `check` |
| `check.ml` 592行 | `check_uncached` |
| `check.ml` 659行 | `check_array` |
| `check.ml` 746行 | `check_call` |
| `check.ml` 907行 | `check_binary` — 裸の数の入れ替え |
| `check.ml` 975行 | `check_conditional` |
| `check.ml` 161行 | `is_bare_number` |
| `check.ml` 141行 | `expect` |

---

[← 4. 検査の4つの相](04-check.md) ／ [目次](index.md) ／ [6. 値 →](06-values.md)
