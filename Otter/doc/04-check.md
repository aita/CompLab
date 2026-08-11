# 4. 検査の4つの相 — `check.cppm` ／ `check.ml`

検査器は1276行と1138行あって、この処理系でいちばん大きい部品です。しかしその骨は
4行で書けます。

```cpp
declareStructs();        // 相1: すべての struct に型を与える。フィールドは見ない
resolveStructFields();   // 相2: フィールドの型を解決する。自分自身を指してよい
rejectStructCycles();    // 相2の後始末: 値として自分を含む struct を拒む
declareSignatures();     // 相3: すべてのシグネチャを登録する。本体は見ない
checkBodies();           // 相4: 本体
```

**この分割が、言語仕様の「モジュールの中では宣言の順序が問題にならない」の全文です。**

## 1. 順序が問題にならないということ

```
$ cat order2.otter
module order2;
...
// 後ろで宣言される struct を先に使う
fun origin() -> Point {
    return new Point { x: 0, y: 0 };
}

struct Point { x: int; y: int; }

// 相互再帰。前方宣言はない
fun even(n: int) -> bool { if (n == 0) { return true; } return odd(n - 1); }
fun odd(n: int) -> bool  { if (n == 0) { return false; } return even(n - 1); }

fun tally(values: array<int>) -> int {
    var seen: int = 0;
    // 下で宣言される入れ子関数を先に呼ぶ
    for (var i: int = 0; i < values.length; i = i + 1) { record(values[i]); }
    fun record(value: int) -> void { seen = seen + value; return; }
    return seen;
}

$ ./interpreter/build/otter order2.otter
0
true
10
$ ./ocaml/_build/default/bin/otter.exe order2.otter
0
true
10
```

3つとも別の相が支えています。`origin` が `Point` を返せるのは相1が全部の struct に
先に型を与えたから、`even` が `odd` を呼べるのは相3が全部のシグネチャを先に登録した
から、`tally` が `record` を先に呼べるのは**ブロックに入るときに入れ子関数を登録する**
からです（6節）。

## 2. 相1 — 型だけ作る

```cpp
void declareStructs() {
    for (ModuleAst* module : program_.order()) {
        std::set<std::string> seen;
        for (const auto& declaration : module->structs) {
            if (!seen.insert(declaration->name).second) { throw ...; }
            auto [type, info] = types_.declareStruct(module->name, declaration->name);
            declaration->type = type;
            declaration->structure = info;
        }
        for (const auto& declaration : module->aliases) {
            if (!seen.insert(declaration->name).second) { throw ...; }
        }
    }
}
```

**フィールドを1つも見ていません。** 見ないので、フィールドの型が後ろの struct でも、
自分自身でも構いません。`seen` を struct と別名で共有しているので、型の名前空間は
1つです。

```
$ ./interpreter/build/otter type_name_taken.otter
type_name_taken.otter:7:1: module `type_name_taken` already declares a type named `Thing`
```

## 3. 相2 — フィールド、そして「大きさのない型」を拒む

```cpp
const Type* type = resolveType(declaration->fieldTypes[index].get());
if (type->kind == TypeKind::Void) {
    throw CompileError(declaration->fieldSpans[index], "a field cannot be void");
}
declaration->structure->fields.push_back(Field{name, type});
```

このとき `*Node` を解決すると、相1で作られた `Node` の型が既にあるので `pointerTo` が
それを包みます。**自分自身を指す型が、前方宣言なしで作れます。**

値として自分を含む場合だけは大きさが決まらないので拒みます。相2が終わってから、
別の走査で見ます。

```cpp
bool containsItself(const StructInfo* target, const StructInfo* current,
                    std::set<const StructInfo*>& visiting) {
    if (!visiting.insert(current).second) { return false; }
    for (const Field& field : current->fields) {
        if (field.type->kind != TypeKind::Struct) { continue; }
        if (field.type->structure == target ||
            containsItself(target, field.type->structure, visiting)) { return true; }
    }
    return false;
}
```

`field.type->kind != TypeKind::Struct` で降りるのをやめるので、**ポインタも配列も
関数型も辿りません。** `*Node` は「大きさが決まっている」ので通り、`Node` は通りません。
`visiting` があるので、無関係な環があっても止まります。

```
$ ./interpreter/build/otter struct_holds_itself.otter
struct_holds_itself.otter:3:1: struct `Node` contains itself by value, which has no size;
hold it through a pointer instead
```

## 4. 相3 — シグネチャだけ

```cpp
for (const auto& declaration : module->functions) {
    FunctionDefinition& definition = *declaration->definition;
    if (!seen.insert(definition.name).second) { throw ...; }
    resolveSignature(definition);
    // 本体がない関数はホストが提供するものなので、名前はホストが知っているもので
    // なければならない。
    if (definition.body == nullptr && findNative(definition.hostName) == nullptr) {
        throw CompileError(definition.span, ...);
    }
}
```

大域変数と関数が同じ `seen` を共有しているので、値の名前空間も1つです。大域変数が先に
処理されるのは、**大域変数の型が関数のシグネチャに現れうる**からではなく（型は struct と
別名からしか来ません）、単に名前の衝突を1回の走査で見るためです。

`resolveSignature` は先頭で自分自身を止めます。

```cpp
// 入れ子関数はブロックを歩く前にシグネチャが登録されるので、2度目の要求はここで
// 返る。
if (definition.type != nullptr) { return; }
```

ホスト関数の存在確認が**実行時ではなく検査時**にあることが、[9章](09-host.md)の
「本体のない関数は普通の関数である」を成り立たせています。

## 5. 相4 — 本体、そして誤りを集める

相1〜3は最初の1件で諦めます。

```cpp
try {
    declareStructs();
    resolveStructFields();
    rejectStructCycles();
    declareSignatures();
} catch (const CompileError& error) {
    // プログラムの形が壊れている以上、この先は信用できない。検査器が諦めるのはここ。
    errors_.push_back(error);
    return errors_;
}

checkBodies();
checkEntryPoint();
```

相4は宣言ごとに囲って続けます。

```cpp
template <typename Body>
void guard(const Span& span, Body&& body) {
    try { body(); }
    catch (const CompileError& error) { errors_.push_back(error); }
    catch (const std::exception& error) { errors_.emplace_back(span, error.what()); }
}
```

**結果として、型エラーは関数ごとに1件まで、宣言の形の誤りは全体で1件だけ出ます。**

```
$ cat many.otter                  3つの関数にそれぞれ1つずつ誤り
$ ./interpreter/build/otter many.otter
many.otter:4:18: this initial value is string, but int was expected
many.otter:9:19: this initial value is int, but bool was expected
many.otter:14:12: there is nothing named `missing` here

$ cat giveup.otter                struct が自分を値で含み、加えて型エラーが2つ
$ ./interpreter/build/otter giveup.otter
giveup.otter:3:1: struct `Node` contains itself by value, which has no size;
hold it through a pointer instead
```

OCaml 側の `guard` は例外を握るだけで同じことをします。

```ocaml
let guard state span body =
  try body () with
  | Compile_error (span, message) -> state.errors <- (span, message) :: state.errors
  | Failure message -> state.errors <- (span, message) :: state.errors
```

## 6. ブロックに入るとき、入れ子関数を先に登録する

相3が「モジュールの中で順序を無意味にする」なら、これは「ブロックの中で無意味にする」
仕組みです。

```cpp
void checkBlock(Block& block, bool ownScope = true) {
    if (ownScope) { scopes_.emplace_back(); }
    declareNestedFunctions(block.statements);
    for (const StmtPtr& statement : block.statements) { checkStatement(*statement); }
    if (ownScope) { scopes_.pop_back(); }
}

// ブロックの中で宣言された関数はブロック全体で見えるので、2つが互いを呼べるし、
// 書かれた場所より上で使える。
void declareNestedFunctions(const std::vector<StmtPtr>& statements) {
    for (const StmtPtr& statement : statements) {
        if (statement->kind != StmtKind::NestedFunction) { continue; }
        FunctionDefinition& definition = *static_cast<NestedFunctionStmt&>(*statement).definition;
        resolveSignature(definition);
        if (scopes_.back().contains(definition.name)) { throw ...; }
        scopes_.back()[definition.name] = definition.type;
    }
}
```

評価器にも同じ形の関数があり、**そちらは型ではなく閉包を先に作ります**
（[7章](07-interp.md)）。検査と実行で「先に登録する」タイミングを揃えているので、
上で呼んでも名前が見つかり、値も見つかります。

`ownScope` が偽になるのは関数の本体だけです。引数を入れたスコープをそのまま本体の
スコープにするためで、これで `fun f(x: int) -> int { var x: int = 1; ... }` が
「このブロックで既に宣言されている」で弾かれます。

```
$ ./interpreter/build/otter duplicate_nested_function.otter
duplicate_nested_function.otter:7:5: `helper` is already declared in this block
```

## 7. 検査器が木に書き込むもの

検査は判定ではなく**注釈**です。走ったあとの木には次のものが埋まっています。

| 書かれる場所 | 何が |
|---|---|
| `Expr::type` | すべての式の型 |
| `NameExpr::resolution` | `Local` / `Global` / `Function` / `Module` |
| `NameExpr::function`・`global`・`module` | 宣言そのものへのポインタ |
| `FieldExpr::resolution` | `StructField` / `Length` / `ModuleFunction` / `ModuleGlobal` |
| `FieldExpr::index` | 構造体の何番目のフィールドか |
| `FieldExpr::throughPointer` | ポインタ越しに届いたか |
| `FieldInit::index` | `new` の初期化子が何番目のフィールドか |
| `BinaryExpr::operandType` | 両辺が揃えられた型（比較では式自身の型と違う） |
| `TypeExpr::resolved` | 型式が指す `Type*` |
| `FunctionDefinition::type`・`resultType` | シグネチャ |
| `StructLiteralExpr::structure` | どの struct か |

**このおかげで評価器には表引きがありません。** フィールドは名前ではなく添字で読み、
名前は文字列ではなく `resolution` の分岐で読みます。文字列で引くのはローカル変数だけで、
それは環境が名前つきの表だからです（[7章](07-interp.md)の「していないこと」）。

## 8. 到達しない `return` を要求しない

結果が `void` でない関数は、本体のすべての経路で返らなければなりません。

```cpp
bool alwaysReturns(const Stmt* statement) {
    switch (statement->kind) {
        case StmtKind::Return: return true;
        case StmtKind::Block: /* どれか1つが返れば返る */
        case StmtKind::If:
            return branch->alternative != nullptr &&
                   alwaysReturns(branch->consequent.get()) &&
                   alwaysReturns(branch->alternative.get());
        case StmtKind::While: {
            // 自分では終わらないループは、返ることでしか出られない。
            const auto* loop = static_cast<const WhileStmt*>(statement);
            return isAlwaysTrue(loop->condition.get()) && !breaksOutOfLoop(loop->body.get());
        }
        case StmtKind::For: {
            bool endless = loop->condition == nullptr || isAlwaysTrue(loop->condition.get());
            return endless && !breaksOutOfLoop(loop->body.get());
        }
        default: return false;
    }
}
```

`while (true)` と `for (;;)` が「返る」と数えられるので、その後ろに届かない
`return` を書かされません。`breaksOutOfLoop` は**内側のループで止まります**。
内側の `break` は内側のものだからです。

```cpp
case StmtKind::Break: return true;
case StmtKind::Block: /* 中の文を見る */
case StmtKind::If:    /* 両腕を見る */
default: return false;      // ← While も For もここ
```

`isAlwaysTrue` はリテラルの `true` しか見ません。定数畳み込みはしないので、
`var t: bool = true; while (t) {...}` は「返る」と数えられません。

```
$ ./interpreter/build/otter missing_return.otter
missing_return.otter:3:1: `largest` returns int, but control can reach the end of its
body without a return
```

## 9. 値ブロックからは飛び出せない

`if` を値として使ったとき、その腕は文を走らせてから式を1つ差し出します。
**差し出す前に外へ飛ぶ道があってはいけません。**

```cpp
void rejectJumps(const Stmt& statement, bool insideLoop) {
    switch (statement.kind) {
        case StmtKind::Return:
            throw CompileError(statement.span,
                "this block stands for a value, so it cannot return from the function around it");
        case StmtKind::Break:
        case StmtKind::Continue:
            if (!insideLoop) { throw CompileError(statement.span,
                "this block stands for a value, so there is no loop here to leave"); }
            return;
        case StmtKind::While: rejectJumps(*...->body, true); return;
        case StmtKind::For:   rejectJumps(*...->body, true); return;
        ...
    }
}
```

`insideLoop` を持っているので、**腕の中に書かれたループはその中で `break` してよい**
という区別がつきます。`value_blocks.otter` の最後の例がそれです。

```
$ ./interpreter/build/otter jump_out_of_value_block.otter
jump_out_of_value_block.otter:5:9: this block stands for a value, so it cannot return
from the function around it
```

この判定があるから、評価器の値ブロックは分岐を持ちません。

```cpp
// 値ブロックからは飛び出せないので、文は最後まで走り、ブロックの式が答えになる。
for (const StmtPtr& entry : arm.statements) { execute(*entry, *held.get()); }
return evaluate(*arm.value, *held.get());
```

`execute` の戻り値を無視しているのは、**`Normal` 以外が返らないことが検査で保証されて
いる**からです。

## 10. 入口の確認

```cpp
void checkEntryPoint() {
    ModuleAst* entry = program_.entry();
    const FunctionDecl* main = entry->findFunction("main");
    if (main == nullptr) { errors_.emplace_back(entry->span, ...); return; }
    if (!definition.parameters.empty()) { errors_.emplace_back(..., "`main` takes no arguments"); }
    if (definition.resultType != types_.intType() &&
        definition.resultType->kind != TypeKind::Void) { ... }
}
```

**`errors_` に直接足していて投げません。** 相4の後なので、本体の型エラーと一緒に
報告されます。

```
$ ./interpreter/build/otter no_main.otter
no_main.otter:1:1: module `no_main` is the entry point, so it needs a `fun main() -> int`
```

## していないこと

**未使用の変数も未使用の関数も報告しません。** 使われていないことは誤りではないと
しています。

**到達しないコードを報告しません。** `return` の後ろに文があっても通り、評価器はそこに
届きません。

**定数畳み込みをしません。** 8節のとおり `while (true)` だけが「終わらないループ」です。

**関数ごとに誤りは1件までです。** `guard` が宣言単位なので、1つの関数に3つ型エラーが
あっても最初の1つで抜けます。式ごとに続ける設計にすると、型の欄が空のまま先へ進む
ノードが出てくるので、評価器が `type` を無条件に読める前提が崩れます。

**警告というものがありません。** 診断は誤りだけで、通るか通らないかです。

## 参考文献

- R. Nystrom, [*Crafting Interpreters*][ci] "Resolving and Binding"。名前解決を
  独立した走査にして木に書き込む形。7節の表がそれです。
- A. Appel, *Modern Compiler Implementation in ML*, 5章。宣言の相互再帰を、
  「ヘッダを先に集めてから本体を検査する」2段階で扱う書き方。相3がそれです。
- ISO/IEC 9899（C）の6.7.2.1 と、Go 仕様の
  [*Declarations and scope*][godecl]。「同じブロックの宣言が互いに見える」範囲を
  どこで切るかの2つの選択。この言語は Go 側（ブロック全体）を採っています。

[ci]: https://craftinginterpreters.com/resolving-and-binding.html
[godecl]: https://go.dev/ref/spec#Declarations_and_scope

## 実装の地図

| C++ | |
|---|---|
| `check.cppm` 17行 | `breaksOutOfLoop` — 内側のループで止まる |
| `check.cppm` 47行 | `alwaysReturns` |
| `check.cppm` 84行 | `rejectJumps` |
| `check.cppm` 130行 | `run` — 4つの相と、諦める場所 |
| `check.cppm` 151行 | 相1 `declareStructs` |
| `check.cppm` 197行 | 相2 `resolveStructFields` |
| `check.cppm` 226行 | `rejectStructCycles` |
| `check.cppm` 260行 | 相3 `declareSignatures` |
| `check.cppm` 299行 | `resolveSignature` |
| `check.cppm` 327行 | 相4 `checkBodies` |
| `check.cppm` 377行 | `checkEntryPoint` |
| `check.cppm` 397行 | `guard` |
| `check.cppm` 520行 | `checkBlock` |
| `check.cppm` 535行 | `declareNestedFunctions` |

| OCaml | |
|---|---|
| `check.ml` 20行 | `breaks_out_of` |
| `check.ml` 38行 | `always_returns` |
| `check.ml` 68行 | `reject_jumps` |
| `check.ml` 296行 | 相1 `declare_structs` |
| `check.ml` 326行 | 相2 `resolve_struct_fields` |
| `check.ml` 357行 | `reject_struct_cycles` |
| `check.ml` 386行 | `resolve_signature` |
| `check.ml` 412行 | 相3 `declare_signatures` |
| `check.ml` 492行 | `declare_nested_functions` |
| `check.ml` 1052行 | `guard` |
| `check.ml` 1065行 | 相4 `check_bodies` |
| `check.ml` 1087行 | `check_entry_point` |
| `check.ml` 1112行 | `check_program` — 相の並び |

---

[← 3. 型](03-types.md) ／ [目次](index.md) ／ [5. 期待型を下ろす →](05-expected.md)
