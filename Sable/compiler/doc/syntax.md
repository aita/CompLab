# 構文解析 — 1つの言語、2つの書き方

`lexer.mll` と `parser.mly` が ML 形式（`.sbl`）を、`brace_lexer.mll` と
`brace_parser.mly` と `brace_build.ml` が brace 形式（`.sbb`）を読みます。**2つは同じ
抽象構文（`syntax.ml`）を組み立てます** — これ以降のパスは、自分がどちらの形から来たかを
知りません。生成されるコードも同一です。

## 1. 字句解析・構文解析

ocamllex と menhir です。文法上、説明が要るのは2点だけです。

**`type` 宣言はプログラム本体より前**にまとめて書きます。`Datatype.declare` は構文解析の
アクションから呼ばれるので、本体を読む時点ではコンストラクタ表が完成しています。宣言は
互いを（そして自分自身を）参照できるので、名前が実在するかの検査は全宣言を読み終えた
あと `Datatype.check_wellformed` で行います。再帰型 `list` はこれで通ります。

**`Cons (1, rest)` は「`Cons` を1個の括弧付きタプルに適用したもの」として構文解析されます**。
コンストラクタ適用と関数適用を文法レベルで分けようとすると LR の衝突になるため、いったん
`App (Constr ("Cons", []), [Tuple [1; rest]])` に読み、パーサのアクションでコンストラクタの
引数個数と照合して `Constr ("Cons", [1; rest])` に畳み直しています。OCaml と同じ見た目に
なり、文法には衝突が持ち込まれません。

### もう1つの書き方 — brace form

この言語には書き方が2つあります。`.sbl` を **ML form**、`.sbb` を **brace form** と
呼びます。後者は中括弧でブロックを区切り、文を `;` で並べます。`brace_lexer.mll` と
`brace_parser.mly` が **ML form のパーサとまったく同じ抽象構文を組み立てる**ので、これ以降の
パスは自分がどちらの形から来たかを知りません。生成されるコードも同一です。

brace form には `and` にあたる語がないので、隣り合う `fun` は互いに見えます。ただし
全部を1つの再帰群にすると群の中で単相化し、`length` を2つの要素型で使えなくなります。そこで
**呼び出しグラフの強連結成分で群を切って**います（`brace_build.ml`）。相互再帰と多相が
両立するのはこのためです。ML form では同じ判断を書き手が `and` で行います。

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

## 参考文献

- R. Tarjan, [*Depth-first search and linear graph algorithms*][tarjan],
  SIAM J. Comput. 1(2), 1972. brace 形式が隣り合う関数を強連結成分に切るのに使います。

[tarjan]: https://doi.org/10.1137/0201010

---

隣の文書：[パイプライン全体](pipeline.md)、[名前解決](modules.md)。
