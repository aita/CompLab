# 2. モジュールを集める — `program.cppm` ／ `program.ml`

この段の仕事は3つです。**入口から届くモジュールを全部読む。依存が先に来る並びを作る。
環を拒む。** 177行と170行で、二度ともほぼ同じ形になりました。

## 1. 並びが1つあれば足りる

`Program` が持っているものは4つです。

```cpp
std::filesystem::path directory_;                        // 探す場所
TypeArena types_;                                        // 3章
std::map<std::string, std::unique_ptr<ModuleAst>> modules_;
std::vector<ModuleAst*> order_;                          // 依存が先
std::set<std::string> loading_;                          // 環の検出
ModuleAst* entry_ = nullptr;
```

`order_` は深さ優先の帰りがけに積まれます。

```cpp
void resolveImports(ModuleAst* module) {
    loading_.insert(module->name);
    for (Import& entry : module->imports) {
        ...
        entry.target = require(entry.name, entry.span);
    }
    loading_.erase(module->name);
    order_.push_back(module);          // ← import をすべて解決したあと
}
```

**帰りがけに積むので、あるモジュールが並ぶのは、それが import するものすべてが
並んだあとです。** 検査器も評価器もこの並びをそのまま使います。トポロジカルソートを
別に書く必要はありません。

OCaml 側は先頭に積んで最後に反転します。

```ocaml
program.loaded <- module_ast :: program.loaded
...
let order program = List.rev program.loaded
```

## 2. 大域変数の初期化順が、その並びそのもの

並びが正しいことは、大域変数の初期化を見れば分かります。

```
$ cat deep_a.otter
module deep_a;

import deep_b;
import deep_c;

var mark: int = deep_c.note("deep_a");

fun main() -> int {
    return deep_c.note("main") + mark + deep_b.mark;
}
```

`deep_b` は `deep_c` を import し、`deep_c` は `io` だけを import します。

```
$ ./interpreter/build/otter deep_a.otter
deep_c
deep_b
deep_a
main
$ ./ocaml/_build/default/bin/otter.exe deep_a.otter
deep_c
deep_b
deep_a
main
```

`deep_a` は `deep_b` より先に `deep_c` を書いていますが、並びは import の**書かれた
順ではなく到達順**で決まります。評価器はこれをそのまま回すだけです。

```cpp
for (ModuleAst* module : program_.order()) {
    for (const auto& declaration : module->globals) {
        Root value(heap_, evaluate(*declaration->initializer, *heldScope.get()));
        *value = copyOf(heap_, value.get());
        globals_[declaration.get()] = makeCell(value.get());
    }
}
```

**1つのモジュールの中では書かれた順です。** だから後ろの大域変数は前のものを使えます。

## 3. 環は3つとも拒む

`loading_` は「いま読んでいる途中のモジュール」の集合です。深さ優先の経路そのもの
なので、そこに戻ってきたら環です。

```cpp
if (entry.name == module->name) {
    throw CompileError(entry.span, std::format("module `{}` imports itself", entry.name));
}
if (loading_.contains(entry.name)) {
    throw CompileError(entry.span,
        std::format("modules `{}` and `{}` import one another, and a module has to "
                    "be complete before another can use it", module->name, entry.name));
}
```

```
$ ./interpreter/build/otter self.otter
self.otter:3:1: module `self` imports itself

$ ./interpreter/build/otter import_cycle.otter          import_cycle → ping → pong → ping
pong.otter:3:1: modules `pong` and `ping` import one another, and a module has to be
complete before another can use it
```

位置は**環を閉じた側の import 文**です。`pong.otter` の3行目が `import ping;` で、
そこが環に気づいた場所だからです。

環を禁じるのは実装の都合ではなく言語の判断です。禁じてあるので、
[4章](04-check.md)の相1〜3を `order()` の順に1回ずつ回すだけで済みます。相の中で
「まだ検査していないモジュールに降りる」ことがありません。

## 4. モジュール名はファイル名

```cpp
std::string stem = path.stem().string();
if (module->name != stem) {
    throw CompileError(module->span,
        std::format("this file declares module `{}`, but a module lives "
                    "in a file named after it, so `{}{}` was expected",
                    module->name, module->name, sourceExtension));
}
```

```
$ ./interpreter/build/otter named.otter          中身は module wrong;
named.otter:1:1: this file declares module `wrong`, but a module lives in a file
named after it, so `wrong.otter` was expected
```

import 側にも同じ確認があり、そちらは「`geometry.otter` が `module shapes;` と
書いている」場合を捕まえます。

探す場所は**入口ファイルの隣**だけです。探索パスも、パッケージも、バージョンも
ありません。

```
$ ./interpreter/build/otter nofile.otter
nofile.otter:3:1: no module `nowhere`: there is no file `nowhere.otter`
```

## 5. 組み込みモジュールは、ここで普通のモジュールになる

`io`・`str`・`math`・`gc` はファイルを持ちません。`require` はファイルを探す前に
表を引きます。

```cpp
std::unique_ptr<ModuleAst> parsed;
if (const BuiltinModule* builtin = findBuiltinModule(name)) {
    parsed = buildBuiltinModule(*builtin);
} else {
    std::filesystem::path path = directory_ / (name + std::string(sourceExtension));
    ...
}
```

`buildBuiltinModule` が作るのは**普通の `ModuleAst`** です。特別な印はありません。

```cpp
for (const BuiltinFunction& entry : description.functions) {
    auto definition = std::make_unique<FunctionDefinition>();
    definition->name = entry.name;
    definition->hostName = entry.hostName;      // ← 本体はない
    definition->span = span;
    definition->declaredResult = writtenType(types_.primitiveType(entry.result), span);
    ...
    declaration->exported = true;
}
```

本体がないので、これは**プログラムが `fun otter_io_println(text: string) -> void;` と
書いたのと同じもの**です（[9章](09-host.md)）。だから `io.println` は、検査器から見ても
評価器から見ても、export された普通の関数への普通の参照です。

面白いのは型の作り方です。組み込みの引数と結果の型は既に `Type*` として分かって
いるのに、**わざわざ「ソースがそう書いたことにした型式」に包み直しています**。

```cpp
// 既に分かっている型を、ソースが書けたはずの形に着せ替えて、検査器がほかと
// 同じやり方で解決できるようにする。
static TypeExprPtr writtenType(const Type* type, const Span& span) {
    auto node = std::make_unique<TypeExpr>();
    node->kind = TypeExprKind::Named;
    node->span = span;
    node->path.push_back(describe(type));
    node->resolved = type;                     // ← 解決済みとして渡す
    return node;
}
```

`resolved` が埋まっているので `resolveType` はそこで返り、`path` は診断のためだけに
あります。**検査器に「組み込みかどうか」の分岐を1つも足さないための着せ替え**です。

位置は `<io>` のような擬似ファイル名になります。

```cpp
Span span{std::format("<{}>", description.name), Position{}};
```

行が0なので `describe` は `<io>` とだけ出します。組み込みモジュールの関数について
診断が出たときに、存在しないファイルの行番号を指さないためです。

## 6. 同じモジュールは1つだけ

```cpp
ModuleAst* adopt(std::unique_ptr<ModuleAst> module) {
    const std::string& name = module->name;
    auto [entry, inserted] = modules_.try_emplace(name, std::move(module));
    if (!inserted) {
        throw CompileError(entry->second->span,
                           std::format("module `{}` is already loaded", name));
    }
    return entry->second.get();
}
```

`require` は先に `find` するので、菱形の依存（A が B と C を、B と C が D を）でも
D は1回しか読まれません。`adopt` が投げるのは、入口ファイルと同名のモジュールが
import 経由でも来た場合です。

## していないこと

**部分的な読み込みがありません。** import されたモジュールは全体が読まれ、全体が
検査されます。使われている関数だけを読む仕組みはありません。

**キャッシュがありません。** `Program` は1回の実行のあいだしか生きないので、同じ
モジュールを使う2つのプログラムを続けて走らせれば、2回読まれます。

**探索パスがありません。** モジュールは入口ファイルの隣にしかありません。ディレクトリを
分けたければ、入口ファイルもそこに置くことになります。

**環を許す設計を採っていません。** 相互再帰するモジュールを許すなら、相1〜3を
モジュール横断で回す（すべてのモジュールの struct を宣言してから、すべてのフィールドを
解決する）ように書き換えることになります。相の構造はそのために既にできていますが、
`order()` を前提にしている場所が検査器と評価器の両方にあります。

## 参考文献

- R. Griesemer et al., [*The Go Programming Language Specification*][gospec] の
  "Package initialization"。パッケージが import 順ではなく依存順に初期化されること、
  および import の環を禁じる判断。この章の `order()` はその形です。
- N. Wirth, *Programming in Modula-2*, Springer, 1982。モジュールを別々に読み、
  export したものだけが見える、という区切り方の出どころ。

[gospec]: https://go.dev/ref/spec#Package_initialization

## 実装の地図

| C++ | |
|---|---|
| `program.cppm` 20行 | `Program` |
| `program.cppm` 37行 | `loadEntry` — ファイル名とモジュール名の一致 |
| `program.cppm` 54行 | `adopt` — 同名を拒む |
| `program.cppm` 64行 | `resolveImports` — 環の検出と、帰りがけの `order_` |
| `program.cppm` 84行 | `require` — 組み込みが先、ファイルが後 |
| `program.cppm` 114行 | `writtenType` — 既知の型を型式に着せ替える |
| `program.cppm` 126行 | `buildBuiltinModule` |
| `interp.cppm` 48–54行 | 大域変数を `order()` の順に初期化 |

| OCaml | |
|---|---|
| `program.ml` 12行 | `t` |
| `program.ml` 45行 | `order` — 先頭に積んで反転 |
| `program.ml` 63行 | `build_builtin_module` |
| `program.ml` 115行 | `resolve_imports` |
| `program.ml` 132行 | `require` |
| `program.ml` 158行 | `load_entry` |
| `ast.ml` 261行 | `written_type` |
| `interp.ml` 514–523行 | 大域変数の初期化 |

---

[← 1. 構文](01-syntax.md) ／ [目次](index.md) ／ [3. 型 →](03-types.md)
