# 付録. 文法（EBNF）

MinkML の構文の全体です。最終的な決定権を持つのは
[`lab/src/lexer.mll`](../lab/src/lexer.mll) と
[`lab/src/parser.mly`](../lab/src/parser.mly)（menhir、**衝突0**）ですが、この付録はそれと
同じ言語を EBNF で書いたものです。

読み方の設計については[1章](1-syntax.md)を、なぜ型と項が同じ文法なのかもそちらを見てください。

## 記法

| 書き方 | 意味 |
|---|---|
| `"..."` | 終端記号（トークンそのもの） |
| `A B` | 連接 |
| <code>A &#124; B</code> | 選択 |
| `{ A }` | 0回以上の繰り返し |
| `[ A ]` | 省略可能 |
| `( A )` | まとめ |

EBNF は結合の強さと結合方向を表せないので、**演算子の優先順位は別表**にしてあります。
`term binop term` の1行だけでは曖昧なので、そこは優先順位表で読んでください。

## 字句

```ebnf
letter      = "a" … "z" | "A" … "Z" | "_" ;
digit       = "0" … "9" ;
ident       = letter { letter | digit | "'" } ;
tyvar       = "'" ident ;                    (* 'a — 型変数。ident として字句解析される *)
label       = "`" ident ;                    (* `Some — 構成子とセッションの枝 *)
int         = digit { digit } ;
```

- **コメント**は `(* … *)` で、入れ子にできます。行コメントはありません。
- **`_`** は `ident` の一種です（パターンの位置でだけワイルドカードとして読まれます）。
- **`x'`** は識別子、**`'a`** は型変数。区別するのは引用符の位置だけです。字句解析器は
  引用符を名前の一部として `ident` トークンに含めるので、**以下の生成規則で `ident` と書いて
  ある場所には `'a` も書けます**（型変数を書いても意味があるのは型の位置だけです）。
- **負の数のリテラルはありません。** `-3` は単項マイナスの適用です。
- **`#system` 指令**は字句解析器が1トークンとして読みます: `"#system" ident`。宣言より前、
  つまりプログラム最初のトークンとしてだけ置けます（前に空行やコメントがあってもよい）。
- 予約語は次の21語です。
  `val` `fun` `fn` `let` `in` `end` `if` `then` `else` `case` `of` `type`
  `andalso` `orelse` `div` `mod` `forall` `select` `branch` `true` `false`
- 記号トークン:
  `=>` `->` `-o` `==>` `==` `<>` `<=` `>=` `+{` `&{` `..`
  `=` `<` `>` `+` `-` `*` `!` `?` `.` `,` `:` `;` `|` `\` `(` `)` `{` `}` `[` `]`

`-o`（線形矢印）は1トークンなので、`x-o` と書くと `x` に続く線形矢印として読まれます。
`x - o` と書いてください。

## 宣言

```ebnf
program     = [ system ] { toplevel } ;
system      = "#system" ident ;

toplevel    = decl
            | "type" ident { ident } "=" term ;

decl        = "val" dpat [ ":" term ] "=" term
            | "fun" ident binder { binder } [ ":" term ] "=" term ;

dpat        = ident
            | "(" ")"
            | "(" ident "," ident ")" ;

binder      = ident
            | "(" ident ":" term ")" ;
```

`val` は再帰せず、`fun` は自分の名前を束縛します（SML の規則）。`fun` は引数を1つ以上
取ります——引数のない `fun` は `val` です。

## 項

型も項です。この1つの `term` に、`int -> bool` も `{ v : int | v > 0 }` も
`!int ; ?bool ; stop` も入ります。

```ebnf
term        = "fn" binder { binder } "=>" term
            | "let" decl { decl } "in" term "end"
            | "case" term "of" cases
            | "branch" term "of" bcases
            | "forall" ident { ident } "." term
            | "if" term "then" term "else" term
            | "select" label app
            | term binop term
            | unop term
            | app ;

unop        = "-" | "!" | "?" ;

binop       = ";"
            | "->" | "-o"
            | "==>"
            | "orelse" | "andalso"
            | "==" | "<>" | "<" | "<=" | ">" | ">="
            | "+" | "-"
            | "*" | "div" | "mod" ;

app         = atom
            | app atom
            | label atom ;                   (* `Some 3 — 構成子への適用 *)

atom        = ident
            | int
            | "true" | "false"
            | "(" ")"
            | "(" term ")"
            | "(" term ":" term ")"          (* 型指定、または束縛子 *)
            | "(" term "," term ")"
            | atom "." ident                 (* レコードの射影 *)
            | atom "\" ident                 (* レコードの制限 *)
            | "{" "}"
            | "{" eqrow "}"                  (* レコードの値 *)
            | "{" colonrow "}"               (* レコードの型 *)
            | "{" ident ":" term "|" term "}"  (* 篩型 *)
            | "[" "]"
            | "[" tickrow "]"                (* ヴァリアントの型 *)
            | "+{" tickrow "}"               (* 内部選択 *)
            | "&{" tickrow "}" ;             (* 外部選択 *)
```

`label atom` に注意してください。項の位置では**構成子は引数を必ず取ります**。値を持たない
ヴァリアントは `` `None () `` と書きます（パターンの位置では省略できます）。

## 行

```ebnf
eqrow       = ident "=" term { "," ident "=" term } [ "," ".." term ] ;
colonrow    = ident ":" term { "," ident ":" term } [ "," ".." term ] ;
tickrow     = label ":" term { "," label ":" term } [ "," ".." term ] ;
```

レコードのフィールドは素の名前、ヴァリアントの枝とセッションの選択肢は `` ` `` 付きです。
`, ..r` が行の尾です。

実装（`parser.mly`）では、この3つを「`, ..r` と `, l = e` が読点を共有する」形に左因子化して
あります。それは LR(1) の先読み1つで済ませるための書き方で、受理する言語は上と同じです。

## 場合分けとパターン

```ebnf
cases       = [ "|" ] case { "|" case } ;
case        = pat "=>" term ;

bcases      = [ "|" ] bcase { "|" bcase } ;
bcase       = label ident "=>" term ;        (* `add c => … *)

pat         = patatom
            | label
            | label patatom ;

patatom     = ident                          (* "_" はワイルドカード *)
            | "(" ")"
            | "(" pat ")"
            | "(" pat "," pat ")" ;
```

パターンは変数・ワイルドカード・`()`・対・構成子だけです。数値や真偽値のパターンはありません
（`if` を使ってください）。構成子のパターンは腕の先頭にしか置けません（[2章](2-anf.md)）。

## 優先順位と結合

弱い順です。同じ行のものは同じ強さです。

| | 演算子・形 | 結合 |
|---|---|---|
| 1（最弱） | `fn` `let` `case` `branch` `forall` の本体 | 右へ最大限伸びる |
| 2 | `\|`（場合分けの区切り） | — |
| 3 | `;` | 右 |
| 4 | `if … then … else …` | — |
| 5 | `->` `-o` | 右 |
| 6 | `==>` | 右 |
| 7 | `orelse` | 右 |
| 8 | `andalso` | 右 |
| 9 | `==` `<>` `<` `<=` `>` `>=` | 非結合 |
| 10 | `+` `-` | 左 |
| 11 | `*` `div` `mod` | 左 |
| 12 | 単項 `-` `!` `?` | 前置 |
| 13（最強） | 適用、`.`、`\` | 左 |

この表から出てくる読み方で、覚えておく価値があるものは3つです。

```sml
if p then a else b; c        (* (if p then a else b); c  — ML と同じ *)
fn x => e; f                 (* fn x => (e; f)  — 本体は最大限伸びる *)
case x of a => e | b => e2   (* 内側の case が `|` を取る *)
```

3つめは、`case` の腕の中に `case` を書いたときに効きます。内側が `|` を吸うので、外側の腕を
続けたいときは括弧が必要です。

## 曖昧なところ、そうでないところ

`( term : term )` は**型指定にも束縛子にもなります**。決まるのは次のトークンです。

```ebnf
(* 同じ構文が3通りに読まれる *)
"(" ident ":" term ")" "->" term    (* 依存関数型 — 引数に名前が付く *)
"(" ident ":" term ")" "*" term     (* Σ型 *)
"(" term  ":" term ")"              (* ただの型指定 *)
```

パーサは先に注釈の節点を作り、`->` か `*` を見た規則の側で束縛子として読み直します。
LR(1) の先読み1つで足りるので、これは曖昧さではありません。

一方で、この文法は**意味のない型も受理します**。`3 -> 4` は構文を通り、各システムの
`read_ty` で落ちます。型の文法を分けない設計の代償で、その代わりに同じファイルを別の
システムへ渡せます（[1章](1-syntax.md)）。

## どの構文がどのシステムのものか

`term` の選択肢の多くは、1つのシステムしか使いません。文法は全部を受け付け、拒否は
システムの側が担当します。

| 構文 | 使うシステム |
|---|---|
| `{ ident : term \| term }` | `refine` |
| `{ … }` `[ … ]` `.` `\` `..` | `row` |
| `-o` `+{ … }` `&{ … }` `!` `?` `select` `branch` | `linear` |
| `( ident : term ) ->` `( ident : term ) *` | `refine`（前者のみ）・`dep` |
| `forall` | `hm`（読み飛ばす）・`poly`・`row` |
