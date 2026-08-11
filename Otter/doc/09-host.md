# 9. ホスト関数と組み込みモジュール — `builtins.cppm` ／ `builtins.ml`

`io.println` を書けるようにするために、この処理系が言語に足した機能は**1つ**です。

> 本体のない関数は、ホストが提供するものである。

それ以外は全部これで済んでいます。組み込みモジュールも、その帰結です。

## 1. 本体がないという1つの機能

文法では `functionBody` が2択になっているだけです。

```antlr
// 本体のない関数は、ホストが提供するものへの束縛。
functionBody
    : block
    | ';'
    ;
```

下ろす側は、本体がなければ**自分の名前をホスト関数の名前にします**。

```cpp
if (auto* body = context->functionBody()->block()) {
    definition->body = block(body);
} else {
    // 本体なしで書かれたので、ホストが提供する。名前が探し当てるものになる。
    definition->hostName = definition->name;
}
```

検査器が名前の存在を確かめ（[4章](04-check.md)相3）、評価器が本体の有無で分岐する
（[7章](07-interp.md)）。これで終わりです。

```
$ cat host.otter
// 本体のない関数は、ホストが提供するものへの束縛
fun otter_io_println(text: string) -> void;
fun otter_math_sqrt(value: float64) -> float64;
...
$ ./interpreter/build/otter host.otter
direct
wrapped!
3
a
b
c
d
e!
$ ./ocaml/_build/default/bin/otter.exe host.otter
（同じ）
```

**プログラムがホスト関数に直接束縛できます。** 名前が引き当てるものなので、別の名前を
付けたければ包むことになります。

## 2. 名前に接頭辞がある理由

```cpp
// 名前に接頭辞が付いているのは、プログラムが本体のない関数を書いてこれらの1つに
// 束縛できる以上、プログラムが自分で宣言する名前と衝突しえないようにするため。
// 組み込みモジュールは短い名前でこれらを指す。
const std::vector<NativeEntry>& nativeTable() {
```

`otter_io_println` という綴りは、`println` という名前の普通の関数を書いたときに
うっかりホスト関数に束縛されないためにあります。**束縛が名前で起きるので、名前空間を
分けるには綴りを分けるしかありません。**

表は20個あり、[言語仕様](language.md#host-functions)に並んでいるものと同じです。

## 3. 型は `NativeEntry` の外にある

```cpp
// ホストが提供する関数。本体のない宣言の裏にいる。これらは収集されない。表は
// どのプログラムより長生きする。
struct NativeEntry {
    std::string name;
    std::function<Value(Heap&, std::span<Value>, const Span&)> call;
};
```

**シグネチャがありません。** 引数の数も型も、宣言のほうが決めます。

```cpp
entries.push_back({"otter_str_substring",
                   [](Heap& heap, std::span<Value> arguments, const Span& span) {
                       const std::string& text = textOf(arguments[0]);
                       auto start = arguments[1].as<std::int64_t>();
                       auto length = arguments[2].as<std::int64_t>();
```

`arguments[2]` を読めるのは、検査器が「3引数で呼ばれている」ことを確かめたからです。
`as<std::int64_t>()` が例外を投げないのは、検査器が「2番目は int」を確かめたからです。
**ホスト関数は型検査の結果に全面的に寄りかかっています。**

代償として、宣言とホスト関数がずれていても検査で捕まりません。

```
fun otter_math_sqrt(value: string) -> string;      // 誤った宣言
```

これは検査を通り、呼ばれたときに `std::get` が投げます。表が持つのは名前だけなので、
確かめようがありません。

## 4. 組み込みモジュールは記述から作られる

```cpp
// 組み込みモジュールの関数1つ。そこでの名前、それが指すホスト関数、そして
// シグネチャ。ここに出てくる型はすべて引数を取らないので、種類を言えば足りる。
struct BuiltinFunction {
    std::string name;
    std::string hostName;
    TypeKind result;
    std::vector<TypeKind> parameters;
};
```

```cpp
{"str",
 {
     {"from_int", "otter_str_from_int", String, {Int}},
     {"from_float", "otter_str_from_float", String, {Float64}},
     ...
     {"substring", "otter_str_substring", String, {String, Int, Int}},
     {"index_of", "otter_str_index_of", Int, {String, String}},
 }},
```

**`TypeKind` で足りるのは、組み込みの関数が配列も構造体もポインタも使わないからです。**
`array<int>` を取る組み込み関数を足したくなったら、この表の型の欄は `TypeKind` では
なくなります。

記述から普通のモジュールを組み立てるのは[2章](02-modules.md)の
`buildBuiltinModule` で、そこで作られる関数は**本体がなく、`hostName` を持つ**もの、
つまり1節でプログラムが書けるものと同じです。

引数の名前は使われないので、番号が振られます。

```cpp
parameter.name = std::format("argument{}", index + 1);
```

## 5. だから `io.println` は普通の値

```
fun apply(each: fun(string) -> void, values: array<string>) -> void {
    for (var i: int = 0; i < values.length; i = i + 1) { each(values[i]); }
    return;
}
...
    apply(otter_io_println, ["a", "b"]);
    apply(io.println, ["c", "d"]);
    apply(shout, ["e"]);
```

3つとも `fun(string) -> void` として通ります。ホスト関数は捕捉できませんが、
**もともと本体がないので捕捉するものがありません**。

評価器の側では、ホスト関数の閉包も普通の閉包です。

```cpp
Value callNative(const FunctionDefinition& definition, std::vector<Value>& arguments,
                 const Span& span) {
    auto entry = natives_.find(&definition);
    if (entry == natives_.end()) {
        const NativeEntry* native = findNative(definition.hostName);
        ...
        entry = natives_.emplace(&definition, native).first;
    }
    return entry->second->call(heap_, arguments, span);
}
```

`natives_` は表引きの記憶です。**線形探索する表なので、1回引いたら覚えます。**

## 6. ホスト関数もヒープを触る

引数の `Heap&` は、文字列を作るためにあります。

```cpp
entries.push_back({"otter_str_from_int",
                   [](Heap& heap, std::span<Value> arguments, const Span&) {
                       return Value(heap.makeString(
                           std::format("{}", arguments[0].as<std::int64_t>())));
                   }});
```

呼ぶ側は引数を `RootVector` に入れているので（[8章](08-gc.md)）、`makeString` の中で
収集が起きても引数は生きています。**ホスト関数の中で根を積む必要はありません。**
引数を保持したまま2回割り付ける関数を書けば必要になりますが、表にそういうものは
ありません。

`Span&` は、失敗するホスト関数が位置を報告するためです。

```cpp
if (error != std::errc{} || stop != text.data() + text.size()) {
    throw RuntimeError(span, std::format("`{}` is not a whole number", text));
}
```

```
$ echo 'x' | ./interpreter/build/otter -   # str.to_int("x") を呼ぶプログラムなら
otter: <file>:<line>:<col>: `x` is not a whole number
```

## 7. 二度書いて、いちばん長くなった差

`str.from_float` は C++ 側では1行です。

```cpp
return Value(heap.makeString(std::format("{}", arguments[0].as<double>())));
```

OCaml 側では60行あります。

```ocaml
(* 数は、同じものとして読み戻せる最少の桁数で、2つの記法のうち短いほうで書く。 *)

(* 往復する最短形の桁と指数。値は 0.d1d2... を桁送りしたもの、というより
   d1.d2d3... の10の指数乗である。 *)
let significant value =
  let rec search digits =
    let text = Printf.sprintf "%.*e" digits value in
    if digits >= 16 || float_of_string text = value then text else search (digits + 1)
  in
  ...
```

`%.0e` から始めて、**読み戻して同じ値になるまで桁を増やします**。そのあと位取り記法と
指数記法を両方作り、短いほうを採ります。

これは C++ の `std::format` が `to_chars` の shortest round-trip 表現を使うことに
合わせるためで、OCaml の `Printf` にはそれがありません。合わせた結果は一致します。

```
$ ./interpreter/build/otter floats.otter > c.txt
$ ./ocaml/_build/default/bin/otter.exe floats.otter > o.txt
$ cat c.txt
1
0.1
0.3333333333333333
0.001
1e+21
1e-07
123456789
1.4142135623730951
0
inf
$ diff c.txt o.txt && echo IDENTICAL
IDENTICAL
```

**言語仕様が「数を文字列にする」としか言っていないところで、60行が必要になりました。**
仕様に綴りが書いていないものを二度実装すると、こうなります。ここは
[11章](11-twice.md)の主題です。

## していないこと

**ホスト関数のシグネチャを確かめていません。** 3節のとおり、宣言とホスト関数の食い違いは
実行時まで分かりません。表に型を持たせれば検査時に確かめられますが、そうすると
`NativeEntry` が `BuiltinFunction` と同じものを2箇所に持つことになります。

**動的に読み込めません。** 表はコンパイル時に決まっています。共有ライブラリから
足す仕組みはありません。

**ホスト関数から Otter の関数を呼べません。** `call` は評価器のメンバなので、
`NativeEntry` からは届きません。「配列の各要素に関数を適用する」ようなホスト関数は
書けず、Otter で書くことになります（`sort.otter` がそうしています）。

**引数の数を可変にできません。** 言語に可変長引数がないので、`printf` のようなものは
ありません。

**標準入出力以外がありません。** ファイルもネットワークも時計も乱数もありません。
`io` は3つだけです。

## 参考文献

- U. Steinmann らの慣行というより、この形の直接の親は Lua の C API と、
  R. Ierusalimschy, *Programming in Lua* の "Extending your application"。
  ただしこちらは関数を「本体のない宣言」として言語側に見せる点が違います。
- U. Adams, [*Ryū: fast float-to-string conversion*][ryu], PLDI 2018 と、
  G. Steele, J. White, [*How to print floating-point numbers accurately*][dragon],
  PLDI 1990。7節の「読み戻して同じになる最少の桁」がこの2本の主題です。
  OCaml 側の実装は素朴な探索で、速さは追っていません。
- ISO/IEC 14882 の `std::to_chars`（P0067）。`std::format("{}", double)` が
  shortest round-trip を出すのはこれによります。

[ryu]: https://doi.org/10.1145/3192366.3192369
[dragon]: https://doi.org/10.1145/93542.93559

## 実装の地図

| C++ | |
|---|---|
| `Otter.g4` 42–46行 | `functionBody` — 本体か `;` か |
| `parse.cppm` 258–264行 | 本体がなければ名前が `hostName` になる |
| `value.cppm` 153行 | `NativeEntry` — 名前と関数だけ |
| `builtins.cppm` 36行 | `nativeTable` — 20個 |
| `builtins.cppm` 176行 | `findNative` |
| `builtins.cppm` 188行 | `BuiltinFunction` |
| `builtins.cppm` 203行 | `builtinModules` — 4つ |
| `check.cppm` 287行 | 検査時のホスト関数の存在確認 |
| `interp.cppm` 121行 | `callNative` — 引きを覚える |
| `program.cppm` 126行 | `buildBuiltinModule` |

| OCaml | |
|---|---|
| `builtins.ml` 41行 | `significant` — 往復する最短形 |
| `builtins.ml` 68・79行 | `positional`・`scientific` |
| `builtins.ml` 90行 | `float_text` — 短いほうを採る |
| `builtins.ml` 110行 | `natives` |
| `builtins.ml` 198行 | `find_native` |
| `builtins.ml` 226行 | `builtin_modules` |
| `interp.ml` 100行 | `call_native` |

---

[← 8. 収集器と根](08-gc.md) ／ [目次](index.md) ／ [10. 診断とテスト →](10-errors.md)
