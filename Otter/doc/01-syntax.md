# 1. 構文 — 生成器に任せた2つの解析器 — `Otter.g4`, `parse.cppm` ／ `lexer.mll`, `parser.mly`

構文はどちらの実装でも生成器の仕事です。手書きの解析器はありません。それでいて、
**曖昧性の始末だけは二度とも違うものになりました。** この章はその話です。

## 1. 予約語に型名がない

どちらの実装でも、`int` や `string` はキーワードではありません。

```antlr
// Otter.g4
Module      : 'module';
Import      : 'import';
...
Null        : 'null';

Identifier
    : [a-zA-Z_] [a-zA-Z_0-9]*
    ;
```

```ocaml
(* lexer.mll *)
let keywords = [ ("module", MODULE); ("import", IMPORT); ... ("null", NULL) ]
let identifier text =
  match List.assoc_opt text keywords with Some token -> token | None -> IDENT text
```

`int` はどちらでも `Identifier` / `IDENT` です。型名であることは、**検査器が
`builtinType` の表を引いたときに初めて決まります**（[3章](03-types.md)）。だから
モジュールが `struct int { ... }` と書けば、そのモジュールの中では `int` はその構造体に
なります。予約語を19個に抑えることが目的で、19個は言語仕様の
[Reserved words](language.md#reserved-words) に並んでいるものと同じです。

## 2. ANTLR — 並べる順序が優先順位

C++ 側の文法は字句と構文が1つのファイルにあり、式の優先順位は**選択肢の並び順**です。

```antlr
expression
    : expression '(' (expression (',' expression)*)? ')'    # callExpression
    | expression '[' expression ']'                         # indexExpression
    | expression '.' Identifier                             # fieldExpression
    | op=('+' | '-' | '!' | '~' | '*' | '&') expression     # unaryExpression
    | expression 'as' type                                  # castExpression
    | expression op=('*' | '/' | '%') expression            # multiplicativeExpression
    ...
    | <assoc=right> expression '=' expression               # assignmentExpression
```

左再帰は ANTLR が自分で取り除き、上にあるものほど強く結びます。優先順位表を別に書く
必要はなく、**表そのものが文法です**。[言語仕様の優先順位表](language.md#expressions)は
この並びを読んだものです。

各選択肢の `# 名前` はラベルで、生成器はラベルごとに別のクラスを作ります。下ろす側は
その型で分岐します。

```cpp
if (auto* node = dynamic_cast<Parser::MultiplicativeExpressionContext*>(context)) {
    return binary(span, binaryOp(node->op->getText()), node->expression(0),
                  node->expression(1));
}
```

`dynamic_cast` の連なりは 436行から 536行まで続きます。**ラベルの数だけ分岐がある**の
であって、それ以上のことはしていません。

## 3. 木を2つ持つ理由

ANTLR が作るのは文法の形をした解析木で、括弧も区切り記号もノードとして残っています。
検査器が注釈を書き込みたいのは別の形の木なので、`Lowering` が下ろします。

```cpp
if (auto* node = dynamic_cast<Parser::GroupExpressionContext*>(context)) {
    return expression(node->expression());
}
```

`(x)` は下ろした木に残りません。`x` そのものになります。

**この段には型の判断が1つもありません。** 名前は書かれたまま文字列として運ばれ、
`a.b.c` は `path = ["a", "b", "c"]` という並びのまま検査器に渡されます。それが
モジュール名なのか構造体名なのかを決めるのは検査器です（[4章](04-check.md)）。

下ろす途中で1箇所だけ、文法が名前を付けてくれなかったものを子から探しています。

```cpp
// `[value; count]` と `[a, b, c]` は区切り記号だけが違い、文法はそれに名前を
// 付けていないので、子の中から探す。
bool repeated = false;
for (auto* child : context->children) {
    if (auto* terminal = dynamic_cast<antlr4::tree::TerminalNode*>(child)) {
        if (terminal->getText() == ";") { repeated = true; }
    }
}
```

関数型も似た形で、文法が引数と結果を1つのリストに並べるので、**最後の1つが結果**という
規約で分けます。

```cpp
std::vector<grammar::OtterParser::TypeContext*> parts = function->type();
for (std::size_t index = 0; index + 1 < parts.size(); ++index) {
    node->parameters.push_back(typeExpression(parts[index]));
}
node->target = typeExpression(parts.back());
```

## 4. menhir — 優先順位は宣言、木は動作の中

OCaml 側は字句と構文が別のファイルで、優先順位は宣言です。

```
%right ASSIGN
%left OR
%left AND
%left EQUAL NOT_EQUAL
%left LESS LESS_EQUAL GREATER GREATER_EQUAL
%left PLUS MINUS
%left STAR SLASH PERCENT
%left AS
%nonassoc UNARY
%left DOT LPAREN LBRACKET
```

**ANTLR とは向きが逆で、下にあるものほど強く結びます。** 同じ表を二度、別の記法で
書いていることになります。

木は動作の中で直接組まれるので、下ろす段がありません。

```
| left = expr op = binary_operator right = expr
    { Ast.expr (at $symbolstartpos) (E_binary (Ast.binary op left right)) }
```

`(x)` を消すのも動作の中です。

```
| LPAREN inner = expr RPAREN { inner }
```

## 5. 残した衝突は3つ

`parser.mly` は `--explain` 付きで生成されるので、衝突の一覧が出ます。

```
$ menhir --explain parser.mly
Warning: 2 states have shift/reduce conflicts.
Warning: one state has reduce/reduce conflicts.
Warning: 2 shift/reduce conflicts were arbitrarily resolved.
Warning: 6 reduce/reduce conflicts were arbitrarily resolved.
```

3つとも意図して残してあり、生成器はすべて**長いほうを選ぶ**ことで解決します。

**衝突1・2（シフト/還元）** は `as` の右です。

```
** Conflict (shift/reduce) in state 16.
** Token involved: DOT
...
expr AS type_expr
        qualified_name loption(type_arguments)
        separated_nonempty_list(DOT,IDENT)
        IDENT . DOT separated_nonempty_list(DOT,IDENT)
```

`x as name.other` を「`x as name` のあとに `.other`」と読むこともできますが、シフト
すれば `name.other` が1つの型名になります。`x as name<other>` も同じ形です。
`as` の右は型なので、長いほうが欲しいものです。

**衝突3（還元/還元）** は値ブロックの終わりです。

```
** Conflict (reduce/reduce) in state 171.
** Tokens involved: STAR RBRACE PLUS MINUS LPAREN LBRACKET
...
** In state 171, looking ahead at STAR, reducing production
** expr -> conditional
...
** In state 171, looking ahead at STAR, reducing production
** statement -> conditional
```

`{ ... if (c) { 1 } else { 2 } * 3 }` を見たとき、`if` を**式**として還元して
`* 3` を続けることも、**文**として還元して `* 3` を次の文の頭とみなすこともできます。
menhir は文法に先に現れたほう、つまり `statement` を選びます。

## 6. その選択の帰結

ここが、二度書いて揃わなかった箇所です。

```
$ cat vb2.otter
module vb2;

import io;
import str;

fun main() -> int {
    var c: bool = true;
    var n: int = if (true) {
        if (c) { 1 } else { 2 } * 3
    } else {
        0
    };
    io.println(str.from_int(n));
    return 0;
}

$ ./interpreter/build/otter vb2.otter
3
$ ./ocaml/_build/default/bin/otter.exe vb2.otter
vb2.otter:9:18: this block runs statements, so what it ends with needs a `;`
```

ANTLR 側の文法には値ブロックという別の規則があるので、この曖昧性が起きません。

```antlr
valueBlock
    : '{' statement* expression '}'
    ;
```

menhir 側にはブロックが1種類しかなく、値を持つかどうかは後から決まります。

```
block_contents:
  | { ([], None) }
  | first = statement rest = block_contents
      { let statements, value = rest in (first :: statements, value) }
  | value = expr { ([], Some value) }
```

そのため、**最後が `if` だったブロックを値として使いたくなったとき**、検査器が木を
書き換えて埋め合わせます。

```ocaml
(* check.ml *)
let value_of_block block =
  match block.blk_value with
  | Some value -> value
  | None -> (
      match List.rev block.blk_statements with
      | ({ s_kind = S_if branch; _ } as last) :: earlier when branch.if_else <> None ->
          let value = Ast.expr last.s_span (E_if branch) in
          block.blk_statements <- List.rev earlier;
          block.blk_value <- Some value;
          value
      | _ -> compile_error block.blk_span
               "this block stands for a value, so it has to end in the expression it gives")
```

**最後の文が `else` 付きの `if` なら、文から式へ移し替える。** これで実際の
プログラムが書く形（`tests/cases/value_blocks.otter`）はすべて通り、通らないのは
その `if` に演算子を続けた形だけになります。そのテストは OCaml 側にしかありませんが、
C++ 側に渡しても同じ出力になります。

```
$ ./interpreter/build/otter ocaml/tests/cases/value_blocks.otter
grade invalid low high
scaled 42
picked 21
counted 3
inline 11
```

## 7. リテラル — 桁と escape を作るのは誰か

数値リテラルの値を作る場所も二度とも違います。OCaml 側は**字句解析の時点**で
64ビットに収まるかを見ます。

```ocaml
(* lexer.mll — 下線は区切りで、int に収まらない literal はここで拒む *)
let whole_number position base digits =
  let base64 = Int64.of_int base in
  let limit = Int64.div Int64.max_int base64 in
  ...
        if Int64.compare !value limit > 0 then
          fail position "`%s` does not fit in an int" digits;
```

C++ 側は ANTLR がトークンの文字列を渡してくるだけなので、下ろす段で `from_chars`
します。

```cpp
std::uint64_t value = 0;
auto [stop, error] = std::from_chars(body.data(), body.data() + body.size(), value, base);
if (error != std::errc{} || stop != body.data() + body.size()) {
    throw CompileError(span, std::format("`{}` is not a whole number", text));
}
if (value > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
    throw CompileError(span, std::format("`{}` does not fit in an int", text));
}
```

`int64` の上限と `uint64` の上限のあいだは同じ文面になり、`uint64` の上限を超えると
`from_chars` 自身が失敗するので文面が変わります。

```
$ ./interpreter/build/otter big2.otter          10000000000000000000
big2.otter:4:18: `10000000000000000000` does not fit in an int
$ ./ocaml/_build/default/bin/otter.exe big2.otter
big2.otter:4:18: `10000000000000000000` does not fit in an int

$ ./interpreter/build/otter big.otter            99999999999999999999
big.otter:4:18: `99999999999999999999` is not a whole number
$ ./ocaml/_build/default/bin/otter.exe big.otter
big.otter:4:18: `99999999999999999999` does not fit in an int
```

**2^64 を超えたところで文面が分かれます。** テストが押さえているのは範囲の話
（`literal_out_of_range`、`256 does not fit in byte`）で、こちらは押さえていません。

escape も置き場所が違います。OCaml 側は字句解析器の中に `escape` という規則があり、
C++ 側は ANTLR がトークンとして受け取った文字列を `unescape` が後から解きます。
どちらも同じ12個の escape と `\xHH`・`\u{...}` を扱い、`\u{...}` は UTF-8 に
展開されます。

```
$ ./interpreter/build/otter lit.otter
1000265
🦦
$ ./ocaml/_build/default/bin/otter.exe lit.otter
1000265
🦦
```

## 8. 位置は1始まりの桁で揃える

診断の桁が一致するのは、両方が同じ規約に直しているからです。ANTLR の
`getCharPositionInLine()` は0始まりなので +1 し、

```cpp
return Span{file_, Position{static_cast<int>(token->getLine()),
                            static_cast<int>(token->getCharPositionInLine()) + 1}};
```

OCaml の `Lexing.position` は行頭からのバイト数なので引いて +1 します。

```ocaml
let of_position (position : Lexing.position) =
  { file = position.pos_fname;
    start = { line = position.pos_lnum;
              column = position.pos_cnum - position.pos_bol + 1 } }
```

どちらも**バイトで数えます**。UTF-8 の文字数ではありません。エディタが飛ぶのに
使う位置がバイトだからです。

## していないこと

**誤り回復がありません。** どちらも最初の1件で例外を投げます。継ぎ接ぎされた木からは、
実在しない型エラーがいくらでも出てくるからです。型エラーのほうは複数まとめて出ます
（[10章](10-errors.md)）。

**構文エラーの文面を揃えていません。** ANTLR の "mismatched input" と menhir 経由の
「`;` is not what was expected here」は別物です。揃えるには ANTLR 側の
`ThrowingErrorListener` でメッセージを組み直す必要があり、そうすると今度は ANTLR が
持っている「何が来られたか」の一覧を捨てることになります。

**インクリメンタル構文解析がありません。** ファイルは毎回まるごと読まれます。

## 参考文献

- T. Parr, *The Definitive ANTLR 4 Reference*, 2nd ed., Pragmatic Bookshelf, 2013。
  左再帰の除去と、選択肢の順序を優先順位として読む規則。3章と5章がこの文法の書き方です。
- F. Pottier, Y. Régis-Gianas, [*Menhir Reference Manual*][menhir]。`--explain` が
  出す衝突の説明の読み方と、還元/還元衝突が「文法に先に現れたほう」で解決されること。
- ISO/IEC 14882 の `std::from_chars`（`<charconv>`）。桁あふれを例外ではなく
  `errc` で返すので、6節の分岐がそのまま診断の分岐になります。

[menhir]: https://cambium.inria.fr/~fpottier/menhir/manual.pdf

## 実装の地図

| C++ | |
|---|---|
| `Otter.g4` 152–178行 | 式。並び順が優先順位表 |
| `Otter.g4` 182–188行 | `ifExpression` と `valueBlock` — 値ブロックが独立した規則 |
| `Otter.g4` 215–233行 | 予約語19個。型名は入っていない |
| `parse.cppm` 21行 | `ThrowingErrorListener` — 1件目で投げる |
| `parse.cppm` 71行 | `unescape` |
| `parse.cppm` 128行 | `parseInteger` |
| `parse.cppm` 174行 | `Lowering` — 解析木を AST へ |
| `parse.cppm` 210行 | `spanOf` — 桁を1始まりに直す |
| `parse.cppm` 432行 | `expression` — ラベルごとの `dynamic_cast` |
| `parse.cppm` 610行 | `arrayLiteral` — `;` を子から探す |
| `parse.cppm` 672行 | `parseModule` |

| OCaml | |
|---|---|
| `lexer.mll` 19行 | キーワード表 |
| `lexer.mll` 53行 | `whole_number` — 字句の時点で範囲を見る |
| `lexer.mll` 204行 | `escape` |
| `parser.mly` 45–54行 | 優先順位宣言。ANTLR とは向きが逆 |
| `parser.mly` 197–206行 | `block` と `block_contents` — 値を持つかは後決め |
| `parser.mly` 282–313行 | `expr` |
| `parse.ml` 14行 | `parse_module` — 苦情を翻訳する |
| `check.ml` 183行 | `value_of_block` — 最後の `if` を文から式へ移す |
| `diagnostics.ml` 8行 | `of_position` |

---

[← 0. プログラムが走るまで](00-run.md) ／ [目次](index.md) ／ [2. モジュールを集める →](02-modules.md)
