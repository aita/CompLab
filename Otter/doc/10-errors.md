# 10. 診断とテスト — `diagnostics.cppm` ／ `diagnostics.ml`, `tests/`

診断が2つの実装で桁まで一致する、という主張には裏付けが要ります。この章はその
仕組みと、22本のうち21本まで一致していること、そして一致しなかった1本の話です。

## 1. 誤りは2種類しかない

```cpp
// プログラムの文面についての苦情。構文の誤り、解決できない名前、型の不一致。
// フロントエンドが拒むものはすべてこれとして届く。
class CompileError : public std::runtime_error { ... };

// プログラムが走っている最中の障害。ゼロ除算、範囲外の添字、null の参照外し。
// 言語はこれらを素通しせず検査する。
class RuntimeError : public std::runtime_error { ... };
```

```ocaml
exception Compile_error of span * string
exception Runtime_error of span * string
```

区別は出力に出ます。実行時のものだけが `otter: ` から始まります。

```cpp
} catch (const otter::CompileError& error) {
    std::println(std::cerr, "{}", error.what());
    return 1;
} catch (const otter::RuntimeError& error) {
    std::println(std::cerr, "otter: {}", error.what());
    return 1;
}
```

```
$ ./interpreter/build/otter tests/errors/mismatched_type.otter
mismatched_type.otter:4:22: this initial value is string, but int was expected
$ ./interpreter/build/otter tests/errors/divide_by_zero.otter
otter: divide_by_zero.otter:5:12: division by zero
```

**接頭辞があるものは「プログラムは正しかったが、この入力で壊れた」を意味します。**

終了状態は3つです。0 が成功（または `main` の返り値）、1 が診断、2 が使い方の誤り
（引数の数、ファイルがない）。

## 2. 位置は1つの点

```cpp
// ソースファイルの中の位置。桁はバイトで数える。解析器が渡してくるのがそれで、
// 位置へ飛ぶエディタが欲しがるのもそれ。
struct Position { int line = 0; int column = 0; };
struct Span { std::string file; Position start; };
```

**範囲ではなく点です。** 名前が `Span` なのに始点しかないのは、下ろす側が
`context->getStart()` しか使っていないからです。範囲を持たせれば波線が引けますが、
その利用者がいません。

`describe` が3通りに分かれます。

```cpp
std::string describe(const Span& span) {
    if (span.file.empty()) { return "<unknown>"; }
    if (span.start.line == 0) { return span.file; }
    return std::format("{}:{}:{}", span.file, span.start.line, span.start.column);
}
```

行が0のときファイル名だけになるのは、**組み込みモジュール**のためです
（[2章](02-modules.md)）。`<io>` には行がありません。

## 3. 集めるものと、投げるもの

型の誤りは集められます。

```cpp
// 1回の実行がファイルの中の型エラーを全部報告できるように、苦情をためる。
class ErrorLog { ... };
```

`ErrorLog` は API として用意されていますが、実際に使われているのは `Checker` が
持っている `std::vector<CompileError> errors_` のほうです。集める境目は
[4章](04-check.md)の `guard` で、**宣言1つにつき1件**まで。

```
$ ./interpreter/build/otter many.otter
many.otter:4:18: this initial value is string, but int was expected
many.otter:9:19: this initial value is int, but bool was expected
many.otter:14:12: there is nothing named `missing` here
```

構文の誤りと、プログラムの形の誤り（相1〜3）は最初の1件で止まります。

## 4. 診断の文面が一致する仕組み

一致は自動では起きません。両方の実装が同じ文字列を書いています。

```cpp
throw CompileError(node.span,
    std::format("this function returns {}, so `return` needs a value", describe(wanted)));
```

```ocaml
compile_error node.s_span "this function returns %s, so `return` needs a value"
  (Types.describe wanted)
```

`std::format` と `Printf.ksprintf` の違いを除けば同じです。**揃える対象は3つ**で、
文面、[3章](03-types.md)の `describe`（型の綴り）、[1章](01-syntax.md)の桁の数え方です。

守っているのはテストです。

## 5. テストは「書いたものと、言うべきこと」

```cmake
# テストは1つのプログラムと、それを走らせたときに書くべき記録。
#
# `cases/` は最後まで走るプログラムで、標準出力で比べる。`errors/` は拒まれるか
# 障害を起こすべきプログラムで、診断で比べる。
```

C++ 側は CMake の関数1つです。

```cmake
function(otter_tests directory prefix stream status)
    file(GLOB transcripts RELATIVE ${directory} ${directory}/*.expected)
    foreach(entry IN LISTS transcripts)
        ...
    endforeach()
endfunction()

otter_tests(${CMAKE_CURRENT_SOURCE_DIR}/cases "" stdout 0)
otter_tests(${CMAKE_CURRENT_SOURCE_DIR}/errors "" stderr 1)

# 例はドキュメントなので、走ることも保証する。
otter_tests(${CMAKE_CURRENT_SOURCE_DIR}/../examples "example-" stdout 0)
```

`.expected` が1つあればテストが1つできます。**テスト一覧という名簿がありません。**
プログラムと記録を置けばテストになります。

比べるものは3つ。指定した側のストリーム、その内容、そして終了状態。

```cmake
if(NOT actual STREQUAL expected)
    message(FATAL_ERROR "${NAME} wrote something else.\n" ...)
endif()
if(DEFINED STATUS AND NOT actualStatus STREQUAL STATUS)
    message(FATAL_ERROR "${NAME} exited with ${actualStatus}, not ${STATUS}")
endif()
```

**作業ディレクトリを対象のディレクトリに移してから走らせます。**

```cmake
# プログラムは自分のディレクトリからの相対で名指す。診断に出るファイル名がビルド木の
# 置き場所に依らないように。
execute_process(COMMAND ${OTTER} ${NAME} WORKING_DIRECTORY ${DIRECTORY} ...)
```

これがないと `.expected` にビルドディレクトリの絶対パスが入り、記録が持ち運べません。
OCaml 側の `run_tests.ml` も同じ理由で `Sys.chdir` します。

```
$ ctest --test-dir build | tail -3
100% tests passed, 0 tests failed out of 40
```

内訳は `cases` が14、`errors` が22、`examples` が4です。OCaml 側は `cases` に
`value_blocks` が1つ多く、41本になります。

## 6. 22本中21本

同じ入力を両方に渡して、診断を比べます。

```sh
for f in interpreter/tests/errors/*.expected; do
  n=$(basename $f .expected)
  a=$(cd interpreter/tests/errors && otter        $n.otter 2>&1 >/dev/null)
  b=$(cd ocaml/tests/errors       && otter.exe    $n.otter 2>&1 >/dev/null)
  [ "$a" = "$b" ] || echo "DIFF $n"
done
```

```
DIFF syntax_error
same=21 diff=1
```

一致しない1本は[1章](01-syntax.md)の構文エラーで、行と桁は一致し、文面が生成器の
ものです。

```
$ diff interpreter/tests/errors/syntax_error.expected ocaml/tests/errors/syntax_error.expected
< syntax_error.otter:4:22: mismatched input ';' expecting {'(', '*', '[', ... }
> syntax_error.otter:4:22: `;` is not what was expected here
```

**`.expected` が実装ごとに分かれているのはこの1本だけです。** ほかの21本と、
`cases` の14本と、`examples` の4本は、2つのディレクトリで同じ内容です。

テストが押さえていない食い違いも1つ見つかります。整数リテラルが 2^64 を超えたとき、
C++ 側は `from_chars` の失敗として、OCaml 側は範囲の誤りとして報告します
（[1章](01-syntax.md)7節）。

## 7. 誤りのテストが押さえているもの

22本の内訳です。

| 相 | テスト |
|---|---|
| 構文 | `syntax_error` |
| モジュール（[2章](02-modules.md)） | `import_cycle`、`not_exported` |
| 型（[3章](03-types.md)） | `alias_cycle`、`type_name_taken`、`struct_holds_itself` |
| 検査・相3〜4（[4章](04-check.md)） | `missing_return`、`no_main`、`duplicate_nested_function`、`unknown_host_function`、`break_outside_loop`、`jump_out_of_value_block` |
| 型付け（[5章](05-expected.md)） | `mismatched_type`、`mismatched_arms`、`no_implicit_conversion`、`literal_out_of_range`、`unknown_name`、`wrong_argument_count`、`string_is_immutable` |
| 実行時（[7章](07-interp.md)） | `divide_by_zero`、`index_out_of_range`、`null_pointer` |

実行時の3本は、言語仕様が挙げる5つの障害のうち3つです。残る2つ（負の長さの配列、
2000段の呼び出し）は記録がありません。

`hidden.otter`・`ping.otter`・`pong.otter` は `.expected` を持たないので、テストに
なりません。**ほかのテストが import する相手**として置かれています。

## 8. 例もテスト

```cmake
# 例はドキュメントなので、走ることも保証する。
otter_tests(${CMAKE_CURRENT_SOURCE_DIR}/../examples "example-" stdout 0)
```

`hello`・`queens`・`sort`・`tour` の4つが、`.expected` を持っています。

```
$ ./interpreter/build/otter examples/tour.otter | head -8
the tour

== numbers
int     42
byte    255
char    o
float64 0.3333333333333333
float32 0.3333333432674408
```

**言語仕様に書いてあることが動くかどうかは、`tour.otter` が答えます。** この本が
引用している出力の多くもそこから来ています。

## していないこと

**単体テストがありません。** テストは全部プログラムを走らせるものです。`TypeArena` や
`Marker` を直接叩くテストはありません。

**性能の回帰を測っていません。** 時間を記録するテストがないので、遅くなったことは
分かりません。

**2つの実装を突き合わせるテストがありません。** 6節の比較は手で走らせるもので、
`ctest` にも `dune test` にも入っていません。入れるには、両方の実行ファイルが揃って
いることを前提にするビルドが要ります。

**診断の文面を1箇所で管理していません。** 同じ文字列が2つのファイルに書かれています。
共有すれば必ず一致しますが、そうすると「共有コードなしで二度書く」という
[11章](11-twice.md)の前提が崩れます。

**波線を引きません。** 2節のとおり位置は点なので、`^^^^` のような下線は出せません。

**警告がありません。** 通るか通らないかだけです。

## 参考文献

- Rust の診断の設計（[*rustc dev guide*, Errors and lints][rustcerr]）。範囲を持ち、
  下線を引き、直し方を示す形。この処理系は3つ目だけを採っていて
  （[5章](05-expected.md)の空の配列など）、最初の2つは採っていません。
- K. Beck, *Test-Driven Development: By Example*, Addison-Wesley, 2002 の
  ゴールデンテスト（transcript testing）の扱い。`.expected` を置けばテストになる
  形はここに近いものです。

[rustcerr]: https://rustc-dev-guide.rust-lang.org/diagnostics.html

## 実装の地図

| C++ | |
|---|---|
| `diagnostics.cppm` 9行 | `Position` — 桁はバイト |
| `diagnostics.cppm` 19行 | `describe` — 3通り |
| `diagnostics.cppm` 31行 | `CompileError` |
| `diagnostics.cppm` 48行 | `RuntimeError` |
| `diagnostics.cppm` 65行 | `ErrorLog` |
| `main.cpp` 43–49行 | 2つの catch と、`otter: ` の接頭辞 |
| `tests/CMakeLists.txt` 10行 | `otter_tests` |
| `tests/run-case.cmake` 6行 | 対象のディレクトリで走らせる |

| OCaml | |
|---|---|
| `diagnostics.ml` 5–6行 | `position`・`span` |
| `diagnostics.ml` 18行 | `describe` |
| `diagnostics.ml` 25・30行 | 2つの例外 |
| `diagnostics.ml` 34・37行 | `compile_error`・`runtime_error` |
| `bin/main.ml` 30–36行 | 2つのハンドラ |
| `tests/run_tests.ml` 20行 | `run` — `Sys.chdir` して走らせる |
| `tests/run_tests.ml` 55行 | `transcripts` — `.expected` を数える |

---

[← 9. ホスト関数](09-host.md) ／ [目次](index.md) ／ [11. 同じ言語を二度書く →](11-twice.md)
