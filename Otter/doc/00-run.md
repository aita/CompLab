# 0. プログラムが走るまで

この章は道案内です。8行のプログラムが処理系を通り抜ける道筋を、部品1つずつ1段落で追い
ます。細部はすべて以降の章にあります。

```
$ cat interpreter/examples/hello.otter
module hello;

import io;

fun main() -> int {
    io.println("hello, otter");
    return 0;
}

$ ./interpreter/build/otter interpreter/examples/hello.otter
hello, otter
$ echo $?
0
```

## 1. 入口 — 3回だけ呼ぶ

`main.cpp` がすることは3つです。読む、検査する、走らせる。

```cpp
otter::Program program(path.parent_path());
program.loadEntry(path);

std::vector<otter::CompileError> errors = otter::checkProgram(program);
if (!errors.empty()) { ... return 1; }

return otter::runProgram(program);
```

OCaml 側も同じ3つです。

```ocaml
Program.load_entry program path;
match Check.check_program program with
| [] -> exit (Interp.run_program program)
| errors -> ... exit 1
```

**この3つの境目が、この本の前半・中盤・後半の境目です。** `loadEntry` を抜けた時点で
木はあり型はない。`checkProgram` を抜けた時点で型はあり値はない。`runProgram` の中で
初めて値ができます。

`Program` に渡すのは**入口ファイルの置かれているディレクトリ**です。モジュールはそこ
から探されます（[2章](02-modules.md)）。

## 2. 読む — 生成器が2つ

`hello.otter` のテキストが `parseModule` に入り、構文木が1つ出てきます。

C++ 側は ANTLR です。`grammar/Otter.g4` から字句解析器と構文解析器が生成され、その
**解析木**（parse tree）が `Lowering` によって小さな AST に下ろされます。2つの木が
あるのは、ANTLR の木が文法の形をしているからで、検査器が注釈を書き込みたいのは
別の形の木だからです。

OCaml 側は ocamllex と menhir です。木は解析器の動作（action）の中で直接組まれるので、
下ろす段はありません。

どちらも**最初の1件で止まります**。誤り回復で継ぎ接ぎされた木を検査しても、出てくる
のは実在しない誤りだからです。

```
$ ./interpreter/build/otter interpreter/tests/errors/syntax_error.otter
syntax_error.otter:4:22: mismatched input ';' expecting {'(', '*', '[', ... }
$ ./ocaml/_build/default/bin/otter.exe ocaml/tests/errors/syntax_error.otter
syntax_error.otter:4:22: `;` is not what was expected here
```

**行と桁は一致し、文面は一致しません。** 構文エラーの文面だけは生成器のものであって、
処理系のものではないからです。ここが二度書いて揃わなかった1箇所目です
（[1章](01-syntax.md)、[11章](11-twice.md)）。

## 3. 集める — import を辿る

`hello` は `io` を import しています。`resolveImports` が `io` を要求し、`io` は
**組み込みモジュール**なので、ファイルを探す前に `builtins` の表から作られます。

```cpp
if (const BuiltinModule* builtin = findBuiltinModule(name)) {
    parsed = buildBuiltinModule(*builtin);
} else {
    std::filesystem::path path = directory_ / (name + std::string(sourceExtension));
    ...
}
```

`buildBuiltinModule` が作るのは特別なものではなく、**本体のない関数を3つ持つ普通の
モジュール**です。本体のない関数はどこに書かれていても「ホストが提供する関数」なので
（[9章](09-host.md)）、ここから下流は `io` が組み込みであることを知りません。

読み終わると `order()` が並びます。**依存が先**です。

```
io, hello
```

## 4. 検査する — 空欄を埋める

`checkProgram` が4つの相を回します（[4章](04-check.md)）。

1. すべての struct に型を与える（フィールドは見ない）
2. フィールドの型を解決する（自分自身を指してよい）
3. すべてのシグネチャを登録する（本体は見ない）
4. 本体を検査する

`hello` にあるのは相4だけです。`io.println("hello, otter")` を検査するとき、
`checkFieldAccess` はまず**`io` が import されたモジュール名かどうか**を見ます。
そうなら、これはフィールドアクセスではなくモジュールメンバの参照です。

```cpp
if (expr.subject->kind == ExprKind::Name) {
    auto& name = static_cast<NameExpr&>(*expr.subject);
    if (!isBound(name.name)) {
        if (const Import* entry = module_->findImport(name.name)) {
            ...
            return checkModuleMember(expr, entry->target, name.name);
```

`isBound` が先に来るので、`io` という名前のローカル変数があればそちらが勝ちます。

検査が書き込むのは木の空欄です。この式の場合、

- `FieldExpr::resolution` に `ModuleFunction`
- `FieldExpr::function` に `io.println` の宣言
- 式の `type` に `fun(string) -> void`
- 呼び出し式の `type` に `void`
- 文字列リテラルの `type` に `string`

**この時点で「名前」という概念は木から消えています。** 残っているのは宣言への
ポインタと型だけです。

## 5. 走らせる — 大域変数、そして `main`

`runProgram` はまず `order()` の順に大域変数を初期化します。依存が先に並んでいるので、
import 先の大域変数は自分のものより先に値を持ちます。`hello` には大域変数がないので、
ここは空回りです。

次に入口モジュールの `main` を探し、閉包（closure）を作って呼びます。

```cpp
const FunctionDecl* main = program_.entry()->findFunction("main");
Root callee(heap_, functionValue(main));
std::vector<Value> noArguments;
Root result(heap_, call(callee.get(), noArguments, main->definition->span));
```

`Root` が2つ出てきます。これは[8章](08-gc.md)の話で、**C++ のローカル変数に置いた値は
収集器から見えない**ので、割り付けをまたいで持つものは影スタックに登録する、という規則
です。OCaml 側にはこの規則がなく、同じ処理は次の1行です。

```ocaml
let result = call state (function_value state main) [||] main.fn_definition.fd_span in
```

## 6. 呼ぶ — フレームは環境オブジェクト

`call` は本体の有無を見ます。無ければホスト関数（[9章](09-host.md)）、有れば

1. 深さを1つ増やす（2000を超えたら実行時エラー）
2. **閉包が持っている環境を親とする**新しい環境を作る
3. 引数を写して束縛する（[6章](06-values.md)）
4. 本体を実行する

`main` の閉包は親を持たないので、`main` の中から見える名前はローカルと大域だけです。
入れ子関数と無名関数だけが親を持ちます（[7章](07-interp.md)）。

## 7. 出力する — ホスト関数まで降りる

`io.println("hello, otter")` の評価は次の順です。

```
evaluateCall
 ├ evaluate(callee)      FieldKind::ModuleFunction → println の閉包
 ├ evaluate(引数)         文字列リテラル → ヒープに StringObject を1つ
 └ call
     └ 本体が無い → callNative
         └ findNative("otter_io_println")
             └ std::println("{}", text)
```

`otter_io_println` という名前は、**検査のときに存在が確かめられています**。
実行時に見つからないことはありません。

```
$ ./interpreter/build/otter interpreter/tests/errors/unknown_host_function.otter
unknown_host_function.otter:4:1: `otter_io_shout` has no body, so it has to be a
function this implementation provides, and there is none by that name
```

## 8. 終わる — `main` の返り値が終了状態

```cpp
if (main->definition->resultType->kind == TypeKind::Int) {
    return static_cast<int>(result.get().as<std::int64_t>());
}
return 0;
```

`-> void` の `main` も受け付けて、その場合は 0 です。

## 9. 全体をもう一度

```
hello.otter のテキスト
  │  parseModule          ANTLR ／ menhir。1件目で止まる
  ▼
ModuleAst（型の欄は空）
  │  resolveImports       io は組み込み。ファイルを探さない
  ▼
order() = [io, hello]
  │  checkProgram         相1〜3は空回り、相4で本体
  ▼
注釈のついた木            io.println → ModuleFunction、型は fun(string) -> void
  │  runProgram           大域なし → main の閉包 → call
  ▼
"hello, otter" と 0
```

これが全部です。以降の章は、この図のどこか1箇所を拡大します。

## していないこと

**中間表現がありません。** 木を注釈して、その木を歩きます。バイトコードにも三番地
コードにも落としません（[12章](12-next.md)）。

**キャッシュがありません。** 同じプログラムを2回走らせれば、2回読み、2回検査します。
分離コンパイルの単位がないので、モジュールを1つ変えれば全部読み直しです。

## 参考文献

- R. Nystrom, [*Crafting Interpreters*][ci]。木を歩く処理系の作り方と、名前解決を
  実行時から検査時へ動かす話（"Resolving and Binding"）。この処理系の
  `NameExpr::resolution` はその判断そのものです。
- A. Appel, *Modern Compiler Implementation in ML*, Cambridge University Press,
  1998。「1つの関心につき1つのパス」という切り方の出どころ。

[ci]: https://craftinginterpreters.com/

## 実装の地図

| C++ | |
|---|---|
| `main.cpp` 30–42行 | 読む・検査する・走らせるの3つ |
| `program.cppm` 37行 | `loadEntry` |
| `check.cppm` 1271行 | `checkProgram` |
| `interp.cppm` 818行 | `runProgram` |
| `interp.cppm` 44行 | 大域の初期化と `main` の呼び出し |

| OCaml | |
|---|---|
| `bin/main.ml` 19–29行 | 同じ3つ |
| `src/program.ml` 158行 | `load_entry` |
| `src/check.ml` 1112行 | `check_program` |
| `src/interp.ml` 504行 | `run_program` |

---

[← 目次](index.md) ／ [1. 構文 →](01-syntax.md)
