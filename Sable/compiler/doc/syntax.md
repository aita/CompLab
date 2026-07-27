# 構文解析 — 1つの言語、2つの書き方

ML 形式（`.sbl`）を読むのが `lexer.mll` と `parser.mly`、brace 形式（`.sbb`）を読むのが
`brace_lexer.mll`・`brace_parser.mly`・`brace_build.ml` です。**2つは同じ抽象構文
（`syntax.ml`）を組み立てます。** これ以降のパスは、自分がどちらの形から来たかを知りません。
生成されるコードも同一です。

## 1. 文法上の決めごと

ocamllex と menhir です。説明が要るのは2点だけです。

**`type` 宣言はプログラム本体より前**にまとめて書きます。`Datatype.declare` は構文解析の
アクションから呼ばれるので、本体を読む時点ではコンストラクタ表が完成しています。宣言は
互いを（そして自分自身を）参照できるので、名前が実在するかの検査は全宣言を読み終えた
あと `Datatype.check_wellformed` で行います。再帰型 `list` はこれで通ります。

**`Cons (1, rest)` は「`Cons` を1個の括弧付きタプルに適用したもの」として構文解析されます**。
コンストラクタ適用と関数適用を文法レベルで分けようとすると、LR の衝突になります。そこで
いったん `App (Constr ("Cons", []), [Tuple [1; rest]])` として読みます。畳み直すのは
パーサのアクションで、コンストラクタの引数個数と照合して `Constr ("Cons", [1; rest])` に
します。OCaml と同じ見た目になり、文法には衝突が持ち込まれません。

## 2. もう1つの書き方 — brace 形式

この言語には書き方が2つあります。`.sbl` を **ML 形式**、`.sbb` を **brace 形式**と
呼びます。後者は中括弧でブロックを区切り、文を `;` で並べます。`brace_lexer.mll` と `brace_parser.mly` は
**ML 形式のパーサとまったく同じ抽象構文を組み立てます。** だからこれ以降のパスは、自分が
どちらの形から来たかを知りません。

brace 形式には `and` にあたる語がないので、隣り合う `fun` は互いに見えます。ただし
全部を1つの再帰群にすると群の中で単相化し、`length` を2つの要素型で使えなくなります。そこで
**呼び出しグラフの強連結成分で群を切って**います（`brace_build.ml`）。相互再帰と多相が
両立するのはこのためです。ML 形式では同じ判断を書き手が `and` で行います。

## 参考文献

- R. Tarjan, [*Depth-first search and linear graph algorithms*][tarjan],
  SIAM J. Comput. 1(2), 1972. brace 形式が隣り合う関数を強連結成分に切るのに使います。

[tarjan]: https://doi.org/10.1137/0201010

## 実装の地図

| | |
|---|---|
| `lexer.mll` | ML 形式の字句解析 |
| `parser.mly` | ML 形式の文法。`--explain` が `parser.conflicts` を出します |
| `brace_lexer.mll` | brace 形式の字句解析 |
| `brace_parser.mly` | brace 形式の文法 |
| `brace_build.ml` | brace 形式の構文木を `syntax.ml` の形へ。隣り合う `fun` の強連結成分分解もここ |
| `syntax.ml` | 2つの形式が合流する抽象構文 |
| `datatype.ml` | `type` 宣言の表。構文解析のアクションから登録されます |

---

[← プログラムが機械語になるまで](pipeline.md) ／ [目次](index.md) ／ [2. 名前解決 →](modules.md)
