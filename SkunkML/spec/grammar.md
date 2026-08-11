# SkunkML 文法仕様

この文書は SkunkML の字句と構文を、**パーサーを1つ書くのに必要なだけ**述べたものです。
言語は Standard ML の部分集合で、その意味と使い方は
[9章 言語リファレンス](../doc/09-language.md)、この文法をこう決めた理由は
[1章 構文](../doc/01-syntax.md)にあります。ここには規則しかありません。

参照実装は `src/front/lexer.mll`（ocamllex）と `src/front/parser.mly`（menhir）で、
食い違ったときはそちらが正です。この文書はその2つから意味動作を外し、生成器に
依らない形に書き直したもので、[5章](#5-lalr1-文法)の生成規則は `parser.mly` と
1つ残らず同じものです。

| | |
|---|---|
| [1. 記法](#1-記法) | EBNF の読み方 |
| [2. 字句](#2-字句) | トークン、予約語、走査の規則 |
| [3. 構文](#3-構文) | モジュール・宣言・型・パターン・項の EBNF |
| [4. 曖昧さの解消](#4-曖昧さの解消) | 優先順位表と、それが決めている5つのこと |
| [5. LALR(1) 文法](#5-lalr1-文法) | 生成規則。衝突は0 |
| [6. 文法の外の規則](#6-文法の外の規則) | 構文解析器が断るもの、後の段に回るもの |

---

## 1. 記法

| | |
|---|---|
| `"..."` | そのままの字面（終端記号） |
| `A \| B` | 選択 |
| `{ A }` | 0回以上の繰り返し |
| `{ A }+` | 1回以上の繰り返し |
| `[ A ]` | 省略可 |
| `( A )` | まとまり |
| `<...>` | 地の文による説明 |
| `--` から行末 | 註釈 |

---

## 2. 字句

### 2.1 予約語

28語です。これ以外の語は識別子になります。

```
and  andalso  as  case  datatype  div  else  end  eqtype  fn  fun  functor
if  in  include  let  mod  of  open  orelse  sig  signature  struct
structure  then  type  val  where
```

ループの構文はありません。`while` も `for` も、再帰と `List` の関数が受け持ちます。

**`true` と `false` は予約語ではありません。** `bool` の構成子で、
`datatype` で自分で書けるものと同じ資格です。`nil` も `NONE` も同じで、
「その名前が構成子か変数か」は文法では決まりません（[6.2](#62-後の段に回るもの)）。

### 2.2 記号

```
=>  ->  ::  :>  <>  <=  >=  ...  :=
:  =  <  >  +  -  *  /  ^  @  ~  |  ,  ;  (  )  [  ]  {  }  _
```

多くの言語にある綴りで、この言語にないものが4つあります。剰余は `%` ではなく `mod`、
不等は `!=` ではなく `<>`、単項マイナスは `-` ではなく `~`、そして `.` は
**文法に一度も現れません**（[2.4](#24-ドットは文法に現れない)）。`!` は記号ではなく
ふつうの識別子なので、`!r` は関数適用です。

### 2.3 綴り

```
letter    ::= "A"…"Z" | "a"…"z"
digit     ::= "0"…"9"
idchar    ::= letter | digit | "_" | "'"

lid       ::= ( "a"…"z" | "_" ) { idchar }        -- 変数・型・ラベル・構成子
uid       ::= "A"…"Z" { idchar }                  -- 構造・シグネチャ・ファンクタ・構成子
qid       ::= { uid "." }+ ( lid | uid )          -- 修飾名。1つのトークン
tyvar     ::= "'" { idchar }+                     -- 'a。''a は等値型変数
select    ::= "#" lid | "#" { digit }+            -- #x、#1。1つのトークン

int       ::= { digit }+
real      ::= { digit }+ "." { digit }+ [ exponent ]
            | { digit }+ exponent
exponent  ::= ( "e" | "E" ) [ "~" ] { digit }+    -- 指数の符号は "~"

string    ::= '"' { schar } '"'
schar     ::= <'"'、"\"、改行 以外の1文字>
            | "\n" | "\t" | "\\" | '\"'           -- エスケープはこの4つだけ

comment   ::= "(*" { comment | <1文字> } "*)"     -- 入れ子になる
```

負のリテラルはありません。`~1` は `~` を `1` に適用した式で、`~1.5` も同じです。
整数パターン `~1` だけは例外で、これは文法に入っています（[3.4](#34-パターン)）。

### 2.4 ドットは文法に現れない

`List.map` は `List` `.` `map` の3トークンではなく、**1トークン**（`qid`）です。
`#x` も1トークンです。この2つで `.` が文法から消え、パスとレコード射影を見分ける
仕事がなくなります。SML はレコードの射影を `r.x` ではなく `#x r` と書くので、
失うものがありません。

修飾名の**前半だけ**が大文字を強制されます。`A.B.c` の `A` と `B` は大文字始まり、
最後の名前はどちらでもかまいません。構成子も同じで、`nil` は小文字、`Leaf` は
大文字です。

### 2.5 走査の規則

1. **最長一致**です。`=>` は `=` と `>` ではなく、`:=` は `:` と `=` ではありません。
2. **実数は整数より先に**試します。`1.5` は1トークンで、`1` と何かではありません。
   点の両側に数字を要求してあるので、危なそうな組み合わせは全部黙って正しくなります
   —— `1.` は整数のあとにエラー、修飾子は大文字始まりなので `1.foo` はパスに
   なりようがなく、`1exp` は指数部に数字がないので `1` と `exp` に戻ります。
3. **引用符の位置がすべて**です。`'a` は型変数、`x'` は識別子。`''a` も型変数で、
   等値型だけを表します。
4. **`_` は単独ならワイルドカード**、`_x` は識別子です。最長一致がそう決めます。
5. **コメントは入れ子**です。閉じないまま入力が尽きればエラーになります。
6. **文字列は改行をまたげません。** エスケープは4つだけで、5つ目を書くとエラーです。

---

## 3. 構文

### 3.1 プログラムとモジュール

```
program   ::= { topdec }

topdec    ::= dec
            | "structure" uid [ ( ":" | ":>" ) sigexp ] "=" strexp
            | "signature" uid "=" sigexp
            | "functor" uid "(" uid ":" sigexp ")" [ ( ":" | ":>" ) sigexp ]
              "=" strexp

strexp    ::= "struct" { topdec } "end"
            | path
            | uid "(" strexp ")"                  -- ファンクタ適用

sigexp    ::= "sig" { spec } "end"
            | uid
            | sigexp "where" "type" tybind        -- 何段でも重ねられる

spec      ::= "val" lid ":" ty
            | "type" tyvars lid
            | "eqtype" tyvars lid
            | "type" tyvars lid "=" ty
            | "datatype" databind { "and" databind }
            | "structure" uid ":" sigexp
            | "include" sigexp
```

式だけのプログラムは書けません。`val () = ...` と書きます。

`:` は透明な、`:>` は不透明な封印です。ファンクタの引数は1つで、
`functor F (X : S) (Y : T) = ...` のようなカリー化はありません。

### 3.2 宣言

```
dec       ::= "val" pat "=" term
            | "fun" funbind { "and" funbind }
            | "type" tybind { "and" tybind }
            | "datatype" databind { "and" databind }
            | "open" { path }+

funbind   ::= clause { "|" clause }
clause    ::= lid { pat_atom }+ [ ":" ty ] "=" term

tybind    ::= tyvars lid "=" ty
databind  ::= tyvars lid "=" conbind { "|" conbind }
conbind   ::= con_name [ "of" ty ]
con_name  ::= uid | lid

tyvars    ::= <なし> | tyvar | "(" tyvar { "," tyvar } ")"
```

`val` は型注釈を持ちません。`val x : int = e` の `: int` は**パターンの**注釈です
（`pat ::= pat ":" ty`）。

節の引数は `pat_atom`、すなわちアトミックなパターンに限ります。`fun f x :: xs = ...`
は `(f x) :: xs` と読めてしまうので構文エラーで、`fun f (x :: xs)` と書きます。

### 3.3 型

型は項とは**別の文法**です。シグネチャの `type t` には対応する項がないので、
1本の木にしても得るものがありません。

```
ty        ::= ty_tuple [ "->" ty ]                -- "->" は右結合
ty_tuple  ::= ty_app { "*" ty_app }
ty_app    ::= ty_atom
            | ty_app path                         -- 後置適用。左結合
            | "(" ty { "," ty }+ ")" path         -- 2引数以上の適用
ty_atom   ::= tyvar
            | path
            | "(" ty ")"
            | "{" [ ty_field { "," ty_field } ] "}"
ty_field  ::= lid ":" ty
```

`int list list` はリストのリスト、`(int, string) either` は2引数の適用です。
`*` は `->` より強く、`->` は右結合なので `int * bool -> unit` は
`(int * bool) -> unit`、`int -> bool -> unit` は `int -> (bool -> unit)` です。

### 3.4 パターン

```
pat       ::= pat_app
            | pat ":" ty                          -- いちばん弱い
            | pat "::" pat                        -- 右結合
            | lid "as" pat

pat_app   ::= pat_atom
            | path pat_atom                       -- 構成子の適用。1段だけ

pat_atom  ::= "_"
            | lid | uid                           -- 変数か構成子かは環境が決める
            | qid                                 -- 修飾名は必ず構成子
            | int | "~" int | string
            | "(" ")"
            | "(" pat ")"
            | "(" pat { "," pat }+ ")"
            | "[" [ pat { "," pat } ] "]"
            | "{" [ pat_row ] "}"

pat_row   ::= "..."                               -- 柔軟。他にフィールドがあってよい
            | pat_field [ "," pat_row ]
pat_field ::= lid "=" pat
            | lid                                 -- { x } は { x = x }
```

強い順に `::`、`as`、`:` です。`x as y :: z` は `x as (y :: z)`、`a :: b : t` は
`(a :: b) : t` になります。構成子の適用は1段だけなので、`C D x` は書けず
`C (D x)` と書きます。

**実数のパターンは書けません。** リテラルのパターンは等値の検査で、`real` は
等値型ではないからです。

### 3.5 項

```
term      ::= app
            | term binop term
            | "~" term
            | "if" term "then" term "else" term
            | term "andalso" term
            | term "orelse" term
            | term ";" term
            | "fn" match
            | "case" term "of" match
            | "let" { dec } "in" term "end"

match     ::= rule { "|" rule }
rule      ::= pat "=>" term

app       ::= atom | app atom                     -- 適用。左結合、いちばん強い

atom      ::= path | int | real | string | select
            | "(" ")"
            | "(" term ")"
            | "(" term ":" ty ")"                 -- 式の型注釈。括弧が要る
            | "(" term { "," term }+ ")"
            | "[" [ term { "," term } ] "]"
            | "{" [ exp_field { "," exp_field } ] "}"
exp_field ::= lid "=" term

path      ::= lid | uid | qid
```

`{ }` と `( )` はどちらも `unit` です。`else` のない `if` はありません。

演算子は強い順に次のとおりです。

| | 演算子 | 結合 |
|---|---|---|
| 1（最強） | `~`（前置） | — |
| 2 | `*` `/` `div` `mod` | 左 |
| 3 | `+` `-` `^` | 左 |
| 4 | `::` `@` | **右** |
| 5 | `=` `<>` `<` `<=` `>` `>=` | 左 |
| 6 | `:=` | **右** |
| 7 | `andalso` | **右** |
| 8 | `orelse` | **右** |
| 9（最弱） | `;` | **右** |

適用はどの演算子よりも強く、`f x + g y` は `(f x) + (g y)` です。`^` が `+` `-` と
同じ段にいるので `2 + 3 * 4 ^ s` は `(2 + (3 * 4)) ^ s` になります。`:=` は
`andalso` より**強い**ので、`r := a andalso b` は `(r := a) andalso b` です。

---

## 4. 曖昧さの解消

この5つが優先順位宣言の仕事です。宣言は弱いほうから並べます。

```
%nonassoc LOWEST
%nonassoc BAR DARROW
%right    SEMI
%nonassoc IF_PREC
%right    ORELSE
%right    ANDALSO
%right    ASSIGN
%left     EQ NE LT LE GT GE
%nonassoc COLON
%nonassoc AS
%right    CONS AT
%left     PLUS MINUS CARET
%left     STAR SLASH DIV MOD
%nonassoc TILDE
```

`COLON` と `AS` はパターンのためだけにここにいます（[3.4](#34-パターン)）。項の側で
`:` が出るのは `( term : ty )` の中だけで、そこでは競う相手がいません。

### 4.1 `|` は最も内側の match に付く

SML でいちばん厄介なところです。

```sml
fun f x = case x of A => 1 | B => 2
```

この `|` は `case` の腕の区切りとも `fun` の次の節の始まりとも読めます。答えは
**`case` のもの**で、つまりこれは1つの節です。

LR で「内側」を選ぶのは shift することです。`match ::= rule` に `%prec LOWEST` を
与え、`LOWEST` を `BAR` より下に置くと、腕がひとつの `match` を還元するか `|` を
shift するかで迷ったとき shift になります。

だから `fun` の節を2つ書きたければ `case` を括弧で囲みます。

```sml
fun f x = (case x of A => 1) | f y = 2
```

### 4.2 腕の本体は右へ伸びる

`rule ::= pat "=>" term` の優先順位は最後の終端記号 `DARROW` のもので、`DARROW` は
`BAR` と並んでいちばん下です。つまり腕の本体は**右にあるものを何でも飲み込みます**。

```sml
case x of A => 1 | B => 2 ; 3     →  2つ目の腕の本体が (2 ; 3)
fn a => 1 andalso b               →  本体が (1 andalso b)
```

### 4.3 `if` の枝は演算子を飲み込み、`;` は飲み込まない

`IF_PREC` が `SEMI` の上、`ORELSE` の下にいるのは、この2つを同時に決めるためです。

```sml
if a then b else c orelse d       →  (if a b (c orelse d))
if a then b else c ; d            →  ((if a b c) ; d)
```

`then` と `else` の間は規則の途中なので、そちらは何でも入ります。

```sml
if a then b ; c else d            →  (if a (b ; c) d)
```

`else` のない `if` がないので、ぶら下がり `else` の問題は起きません。

### 4.4 式の型注釈は括弧の中だけ

`e : t` を項の構文として許すと、ここで詰みます。

```sml
val x = e : int * int
```

`int * int` まで読んだところで `*` が掛け算か直積型か決まらず、型の文法と項の文法が
`*` を取り合います。SML の答え（型を最長に取る）を LR(1) で書くのは割に合わないので、
**項の型注釈は括弧の中に限りました**。

```sml
val m = (someExpression : int)      (* 括弧が要る *)
val n : int = 41 + 1                (* こちらはパターンの注釈 *)
fun size (xs : int list) : int = …  (* 引数はパターン、結果は clause の一部 *)
```

パターンには `*` を使う構文がないので、`pat : ty` は制限なしに許せます。よく書くのは
そちらなので、失うものはほとんどありません。

### 4.5 `%prec` は2箇所だけ

規則の優先順位は既定でその**最後の終端記号**のものです。それで足りないのが2つあります。

| | |
|---|---|
| `match ::= rule` | 終端記号を1つも含まないので、`%prec LOWEST` がないと順位が付かない（4.1） |
| `if … then … else …` | 最後の終端記号は `ELSE` で、`ELSE` には順位を与えていない。`%prec IF_PREC` が要る（4.3） |

`~` の規則にも `%prec TILDE` が書いてありますが、これは最後の終端記号が `TILDE`
なので既定と同じで、外しても何も変わりません。`fn` と `case` の規則は `%prec` を
必要としません。

---

## 5. LALR(1) 文法

`parser.mly` の生成規則から意味動作を外したものです。menhir でも yacc でも
**衝突は0**で、[4章](#4-曖昧さの解消)の宣言と合わせてそのまま渡せます。

### 5.1 終端記号

```
%token <int>                 INT
%token <float>               REAL
%token <string>              STRING LID UID TYVAR SELECT
%token <string list * string> QID
%token VAL FUN FN LET IN END IF THEN ELSE CASE OF AS
%token DATATYPE TYPE AND ANDALSO ORELSE DIV MOD OPEN
%token STRUCTURE SIGNATURE FUNCTOR STRUCT SIG WHERE INCLUDE EQTYPE
%token DARROW ARROW CONS COLONGT COLON ASSIGN EQ NE LE GE LT GT
%token PLUS MINUS STAR SLASH CARET AT TILDE BAR COMMA SEMI DOTS UNDERSCORE
%token LPAREN RPAREN LBRACK RBRACK LBRACE RBRACE EOF
```

`LOWEST` と `IF_PREC` は擬似トークンで、字句解析器は出しません。

### 5.2 生成規則

`list(X)`・`nonempty_list(X)`・`separated_nonempty_list(S, X)` は menhir の標準の
部品です。yacc ならそれぞれ左再帰の補助非終端記号1つに開きます。

```
program: list(topdec) EOF

topdec:
    dec
  | STRUCTURE UID EQ strexp
  | STRUCTURE UID COLON sigexp EQ strexp
  | STRUCTURE UID COLONGT sigexp EQ strexp
  | SIGNATURE UID EQ sigexp
  | FUNCTOR UID LPAREN UID COLON sigexp RPAREN result_sig EQ strexp

result_sig:                          | COLON sigexp | COLONGT sigexp

dec:
    VAL pat EQ term
  | FUN separated_nonempty_list(AND, fun_bind)
  | TYPE separated_nonempty_list(AND, tybind)
  | DATATYPE separated_nonempty_list(AND, databind)
  | OPEN nonempty_list(path)

fun_bind: clauses
clauses:  clause | clause BAR clauses
clause:   LID nonempty_list(pat_atom) ret_opt EQ term
ret_opt:                             | COLON ty

tybind:   tyvars LID EQ ty
databind: tyvars LID EQ separated_nonempty_list(BAR, conbind)
conbind:  con_name | con_name OF ty
con_name: UID | LID
tyvars:                              | TYVAR
        | LPAREN separated_nonempty_list(COMMA, TYVAR) RPAREN

strexp:
    STRUCT list(topdec) END
  | path
  | UID LPAREN strexp RPAREN

sigexp:
    SIG list(spec) END
  | UID
  | sigexp WHERE TYPE tybind

spec:
    VAL LID COLON ty
  | TYPE tyvars LID
  | EQTYPE tyvars LID
  | TYPE tyvars LID EQ ty
  | DATATYPE separated_nonempty_list(AND, databind)
  | STRUCTURE UID COLON sigexp
  | INCLUDE sigexp

ty:       ty_tuple | ty_tuple ARROW ty
ty_tuple: ty_app | ty_app STAR separated_nonempty_list(STAR, ty_app)
ty_app:   ty_atom | ty_app path
        | LPAREN ty COMMA separated_nonempty_list(COMMA, ty) RPAREN path
ty_atom:  TYVAR | path | LPAREN ty RPAREN
        | LBRACE RBRACE
        | LBRACE separated_nonempty_list(COMMA, ty_field) RBRACE
ty_field: LID COLON ty

pat:      pat_app | pat COLON ty | pat CONS pat | LID AS pat
pat_app:  pat_atom | path pat_atom
pat_atom: UNDERSCORE | LID | UID | QID
        | INT | TILDE INT | STRING
        | LPAREN RPAREN | LPAREN pat RPAREN
        | LPAREN pat COMMA separated_nonempty_list(COMMA, pat) RPAREN
        | LBRACK RBRACK
        | LBRACK separated_nonempty_list(COMMA, pat) RBRACK
        | LBRACE RBRACE | LBRACE pat_row RBRACE
pat_row:  DOTS | pat_field | pat_field COMMA pat_row
pat_field: LID EQ pat | LID

term:
    FN match_rules
  | CASE term OF match_rules
  | LET list(dec) IN term END
  | IF term THEN term ELSE term %prec IF_PREC
  | term SEMI term
  | term ORELSE term
  | term ANDALSO term
  | term ASSIGN term
  | term EQ term    | term NE term    | term LT term
  | term LE term    | term GT term    | term GE term
  | term CONS term  | term AT term
  | term PLUS term  | term MINUS term | term CARET term
  | term STAR term  | term SLASH term
  | term DIV term   | term MOD term
  | TILDE term %prec TILDE
  | app

match_rules: rule %prec LOWEST | rule BAR match_rules
rule:        pat DARROW term

app:      atom | app atom
atom:     path | INT | REAL | STRING | SELECT
        | LPAREN RPAREN
        | LPAREN term RPAREN
        | LPAREN term COLON ty RPAREN
        | LPAREN term COMMA separated_nonempty_list(COMMA, term) RPAREN
        | LBRACK RBRACK
        | LBRACK separated_nonempty_list(COMMA, term) RBRACK
        | LBRACE RBRACE
        | LBRACE separated_nonempty_list(COMMA, exp_field) RBRACE
exp_field: LID EQ term

path:     LID | UID | QID
```

### 5.3 木の形

- `pat CONS pat` は構成子 `::` を2要素タプルに適用した形にします。`[a, b]` は
  `PList` で、cons の連鎖には開きません。
- `LBRACE RBRACE` は項では `unit`（空タプル）、パターンでは空の閉じたレコード、
  型では空のレコード型です。
- `TILDE INT` はパターンでは負の整数リテラルそのもの、項では `~` の適用です。
- `structure X : S = e` は封印を構造式のほうに巻きます。`X` の中身が
  `StrAsc (e, S, 不透明か)` になります。

---

## 6. 文法の外の規則

### 6.1 構文解析器が断るもの

生成規則には書けないが、木を組み立てるまでに断るものです。

| | どこで | |
|---|---|---|
| `fun` の節が違う名前を定義している | 構文 | `this clause defines g, but the ones before it define f` |
| `fun` の節で引数の数が違う | 構文 | `this clause of f takes 2 arguments, the first takes 1` |
| 5つ目のエスケープ | 字句 | `\r` はありません |
| 改行をまたぐ文字列 | 字句 | |
| 閉じないコメント・文字列 | 字句 | |

節の検査を構文解析のアクションでするのは、**悪い節がまだ手元にあるうち**に言えるから
です。エラボレーションまで待つと、どの節が悪いのかを言い直す羽目になります。

### 6.2 後の段に回るもの

| | |
|---|---|
| 裸の名前が構成子か変数か | パターンの `lid`・`uid` は必ず `PVar` として作られ、環境が構成子だと言えば構成子になる。SML の構成子には綴りの規則がなく（`nil` は小文字、`Leaf` は大文字）、文法では決められない。修飾名 `A.Box` だけは例外で、構造の中の値をパターンに書けない以上、構文の時点で構成子と決まる |
| 同じ変数を1つのパターンで2回束縛 | エラボレーション |
| 網羅していないマッチ、到達しない腕 | 警告。プログラムは走る |
| 値制限、型変数の約束 | 型検査（[2章](../doc/02-hm.md)） |
| シグネチャと構造の照合 | モジュールのエラボレーション（[3章](../doc/03-modules.md)） |

---

## 7. この文法の検証

`menhir --explain` にかけて衝突が0であることは、生成器に通すだけで確かめられます。
`--explain` は衝突があるときにだけ `parser.conflicts` を書くので、そのファイルが
空であることがそのまま答えです。

[4.5](#45-prec-は2箇所だけ)の「どの宣言が効いているか」は、1つずつ外して数えてあります。

| 外したもの | 衝突 |
|---|---|
| なし（現状） | 0 |
| `%prec LOWEST` | 1 |
| `%prec IF_PREC` | 1 |
| `BAR` の順位 | 1 |
| `DARROW` の順位 | 1 |
| `%prec TILDE` | 0 —— これだけは既定と同じで、書いてあっても何もしていない |

[5章](#5-lalr1-文法)が `parser.mly` と同じ文法であることは、この文書から生成規則を
機械的に抜き出して確かめられます。128個の生成規則、優先順位宣言14行、終端記号の集合が
どれも一致し、抜き出したものだけを単独で menhir にかけても衝突は0です。

[3章](#3-構文)の EBNF と[4章](#4-曖昧さの解消)の結合の向きは、`parser.mly` が実際に
組む木と突き合わせてあります。
