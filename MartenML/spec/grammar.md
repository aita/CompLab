# MartenML 文法仕様

この言語には書き方が**2つ**あります。`.mml` の ML 形式と、`.mmb` の brace 形式です。
2つは別の字句解析器と別の文法を持ち、**同じ抽象構文**（`syntax.ml`）を組み立てます。
以降のパスは自分がどちらから来たかを知りません。

この文書はその2つの文法を、パーサーを書くのに必要なだけ述べたものです。言語の意味と
使い方は[付録A 言語リファレンス](../doc/A-language.md)、この文法をこう決めた理由は
[1章 構文解析](../doc/01-syntax.md)にあります。ここには規則しかありません。

参照実装は `compiler/src/` の `lexer.mll`・`parser.mly`（ML 形式）と
`brace_lexer.mll`・`brace_parser.mly`（brace 形式）で、食い違ったときはそちらが正です。

**この2つの文法には衝突があります。** ML 形式に36個、brace 形式に3個で、どれも
shift/reduce、どれも menhir の既定（shift）で解決されています。どこにあり、なぜ shift が
正しい読み方なのかを[4章](#4-ml-形式の衝突)と[6.4](#64-brace-形式の衝突)に書きました。
仕様として意味があるのはそこなので、先に読んでもかまいません。

| | |
|---|---|
| [1. 記法](#1-記法) | EBNF の読み方 |
| [2. ML 形式 — 字句](#2-ml-形式--字句) | |
| [3. ML 形式 — 構文](#3-ml-形式--構文) | プログラム・型・式・パターン |
| [4. ML 形式の衝突](#4-ml-形式の衝突) | 36個が3族に分かれる |
| [5. ML 形式 — LALR 生成規則](#5-ml-形式--lalr-生成規則) | |
| [6. brace 形式](#6-brace-形式) | 字句・構文・衝突3個 |
| [7. 文法の外の規則](#7-文法の外の規則) | 構文解析器を通ったあとに決まるもの |
| [8. 検証](#8-検証) | |

---

## 1. 記法

| | |
|---|---|
| `"..."` | そのままの字面（終端記号） |
| `A \| B` | 選択 |
| `{ A }` | 0回以上の繰り返し |
| `{ A }+` | 1回以上の繰り返し |
| `[ A ]` | 省略可 |
| `<...>` | 地の文による説明 |
| `--` から行末 | 註釈 |

---

## 2. ML 形式 — 字句

### 2.1 予約語

25語です。`true` と `false` も予約語で、`bool` のリテラルになります。

```
and  array  begin  else  end  false  fun  if  in  let  list  match  mod
module  not  of  open  rec  sig  struct  then  true  type  val  with
```

`list` と `array` が予約語なので、`type list = ...` とは書けません。型の後置構成子
専用の語です。`mod` も予約語で、剰余の綴りはこれだけです（`%` は記号として存在
しません）。

### 2.2 記号と、1トークンになる綴り

```
::  ->  <-  <>  <=  >=  &&  ||
+  -  *  /  ^  =  <  >  (  )  [  ]  ,  :  ;  .  |  _
```

さらに、**綴りがそのまま1トークンになるもの**が4つあります。字句解析器がここで
モジュールの見た目を持つ名前を横取りします。

| 綴り | トークン |
|---|---|
| `Array.make`、`Array.create` | `ARRAY_MAKE` |
| `String.length` | `STRING_LENGTH` |
| `String.concat` | 識別子 `string_concat` |
| `String.equal` | 識別子 `string_equal` |

だから `Array` や `String` というモジュールを自分で定義しても、この4つの綴りは
そちらには届きません。

### 2.3 綴り

```
lower     ::= "a"…"z" | "_"
upper     ::= "A"…"Z"
alnum     ::= "a"…"z" | "A"…"Z" | "0"…"9" | "_" | "'"

ident     ::= lower { alnum }                     -- 変数・関数・型
uident    ::= upper { alnum }                     -- コンストラクタ・モジュール
typevar   ::= "'" lower { alnum }                 -- シグネチャの中だけで意味を持つ
int       ::= { digit }+                          -- 64ビット。範囲外はエラー
string    ::= '"' { schar } '"'
schar     ::= <'"'、"\"、改行 以外の1文字>
            | "\n" | "\t" | "\r" | "\\" | '\"'    -- エスケープはこの5つだけ
comment   ::= "(*" { comment | <1文字> } "*)"     -- 入れ子になる
```

`_` ひとつはワイルドカードで、識別子ではありません。負の整数リテラルはなく、`-1` は
単項マイナスの適用です（パターンの `-1` だけは文法に入っています）。

---

## 3. ML 形式 — 構文

### 3.1 プログラム

```
program   ::= { type_decl } exp

type_decl ::= "type" ident "=" [ "|" ] constr_decl { "|" constr_decl }
constr_decl ::= uident [ "of" type_args ]
type_args ::= simple_type { "*" simple_type }
```

**型宣言はすべて本体より前**にまとめて置き、本体は**式1つ**です。順に実行したいものは
`;` で並べます。`main` はありません。

### 3.2 型

型が書けるのはシグネチャの中だけです。

```
type_expr ::= type_args [ "->" type_expr ]
simple_type ::= typevar
            | ident                               -- int, bool, unit, string, 宣言した名前
            | long_name "." ident
            | simple_type "array"
            | simple_type "list"
            | "(" type_expr ")"
```

`*` は引数の区切りでもタプルの区切りでもあり、`->` があるかどうかで決まります。
`int * int -> bool` は**引数2つ**の関数で、タプル1つを取る関数ではありません
（後者は `(int * int) -> bool`）。関数は最初から n 引数で、部分適用はできません。

### 3.3 式

```
simple_exp ::= "(" exp ")" | "begin" exp "end"
            | "(" ")" | int | bool | string | ident
            | long_name                           -- 引数のないコンストラクタ、または module path
            | long_name "." ident                 -- 修飾された名前
            | "[" "]" | "[" list_body "]"
            | simple_exp "." "(" exp ")"          -- 配列の読み
            | simple_exp "." "[" exp "]"          -- 文字列のバイト

exp       ::= simple_exp
            | exp actual_args                     -- 適用。actual_args は simple_exp の並び
            | "not" exp | "-" exp
            | exp binop exp
            | "if" exp "then" exp [ "else" exp ]
            | "match" exp "with" match_cases
            | "fun" { formal_arg }+ "->" exp
            | "let" ident "=" exp "in" exp
            | "let" "rec" fundefs "in" exp
            | "let" "(" tuple_pat ")" "=" exp "in" exp
            | "module" uident [ ":" signature ] "=" module_exp "in" exp
            | "module" uident "(" uident ":" signature ")" "="
              "struct" { item } "end" "in" exp
            | "module" "type" uident "=" signature "in" exp
            | "open" long_name "in" exp
            | elems                               -- タプル。exp "," exp { "," exp }
            | "Array.make" simple_exp simple_exp
            | "String.length" simple_exp
            | simple_exp "." "(" exp ")" "<-" exp -- 配列の書き
            | exp ";" exp

list_body ::= exp { ";" exp }
long_name ::= uident { "." uident }
```

`else` のない `if` は `else ()` です。`[a; b]` は2要素のリストで、1要素の列では
ありません。

演算子は強い順に次のとおりです。適用はどの演算子よりも強く結合します。

| | 演算子 | 結合 |
|---|---|---|
| 1（最強） | 適用、`.` | 左 |
| 2 | `-`（単項）、`not` | — |
| 3 | `*` `/` `mod` | 左 |
| 4 | `+` `-` | 左 |
| 5 | `::` | **右** |
| 6 | `^` | **右** |
| 7 | `=` `<>` `<` `>` `<=` `>=` | 左 |
| 8 | `&&` | **右** |
| 9 | `\|\|` | **右** |
| 10 | `,`（タプル） | 左 |
| 11 | `<-` | **右** |
| 12 | `if`（`else` なし） | — |
| 13 | `;` | **右** |
| 14（最弱） | `let` `fun` `match` `module` `open` | **右** |

`&&` と `||` は文法上の演算子ですが、木では `if` になります。`a && b` は
`if a then b else false` です。

### 3.4 パターン

```
match_cases ::= [ "|" ] case { "|" case }
case      ::= pattern "->" exp

pattern   ::= constr_pattern { "," constr_pattern }        -- タプル
constr_pattern ::= applied_pattern [ "::" constr_pattern ] -- 右結合
applied_pattern ::= simple_pattern | long_name simple_pattern

simple_pattern ::= "_" | ident | int | "-" int | bool
            | "(" ")" | long_name
            | "[" "]" | "[" pattern_list "]"
            | "(" pattern ")"
pattern_list ::= constr_pattern { ";" constr_pattern }
```

コンストラクタのパターンは引数を**1つ**取ります。`Cons (x, rest)` の引数は括弧付きの
タプル1つで、それを引数2つに開くのは後の段です（[7.1](#71-コンストラクタの引数はあとで開かれる)）。

### 3.5 モジュール

```
module_exp ::= "struct" { item } "end"
            | long_name
            | long_name "(" module_exp ")"
            | "(" module_exp ":" signature ")"

signature ::= uident | "sig" { sig_item } "end"
sig_item  ::= "type" ident | "val" ident ":" type_expr

item      ::= "let" ident "=" exp
            | "let" "(" tuple_pat ")" "=" exp
            | "let" "rec" fundefs
            | type_decl
            | "module" uident [ ":" signature ] "=" module_exp
            | "module" uident "(" uident ":" signature ")" "=" "struct" { item } "end"
            | "module" "type" uident "=" signature
            | "open" long_name

fundefs   ::= fundef { "and" fundef }
fundef    ::= ident { formal_arg }+ "=" exp
formal_arg ::= ident | "(" ")"
tuple_pat ::= tuple_pat_name "," tuple_pat_name { "," tuple_pat_name }
tuple_pat_name ::= ident | "_"
```

シグネチャの `'a` は**その `val` 宣言ひとつのもの**です。同じ綴りが2つの `val` に
現れれば別の変数で、これは文法ではなく、宣言の頭で表を空にするアクションが決めています。

---

## 4. ML 形式の衝突

`menhir --explain` は36個の shift/reduce 衝突を報告します。reduce/reduce はありません。
どれも**優先順位では解決されておらず**、menhir の既定（shift）で解決されています。
36個は3族に分かれ、3族とも shift が意図した読み方です。

### 4.1 適用 — 34個

先読みが `begin` `bool` `ident` `int` `[` `(` `string` `uident` のとき、つまり
`simple_exp` が始まりうるすべての形で起きます。

> いま読んでいる `exp` を還元して演算子の項にするか、次のアトムをこの適用の引数として
> shift するか。

shift を採ると**適用は貪欲で、どの演算子よりも強く、左結合**になります。

```
f x + 1     →  (f x) + 1
1 + f x     →  1 + (f x)
f x y       →  f に引数2つ。(f x) y ではなく1回の適用
- f x       →  - (f x)
not f x     →  not (f x)
```

`exp actual_args` と `actual_args: actual_args simple_exp` という書き方をしている以上
この34個は避けられず、優先順位宣言の `prec_app` も潰しません。潰したければ
brace 形式のように式を段に分けることになります（[6.3](#63-brace-形式--構文)）。

### 4.2 ドット — 1個

先読みが `.` のとき。

> `long_name` をここで `simple_exp` に還元するか、`.` を shift して
> `long_name "." uident` としてパスを伸ばすか。

shift を採ると**大文字の名前の並びは伸ばせるだけ伸びます**。

```
M.N.x   →  パス M.N の中の x
M.N     →  パス M.N そのもの（コンストラクタか module path か）
M.x     →  パス M の中の x
```

大文字が続くかぎりパスで、小文字が来たところで終わりです。`long_name` を
コンストラクタと module path の両方に使い回しているので、どちらなのかを `.` の時点で
決めなくて済みます。決めるのは名前解決です。

### 4.3 `match` の `|` — 1個

先読みが `|` のとき。

> `case_list: case` を還元して外側の `match` に戻るか、`|` を shift して内側の
> `match` の腕を続けるか。

shift を採ると `|` は**最も内側の `match`** に付きます。

```
match a with A -> match b with C -> 1 | D -> 2
                                     ^ 内側の match のもの
```

だから `match` を `match` の腕に書いて、そのあと外側の腕を続けたければ、内側を
括弧か `begin ... end` で囲みます。OCaml と同じ規則です。

---

## 5. ML 形式 — LALR 生成規則

`parser.mly` の生成規則から意味動作を外したものです。

### 5.1 終端記号と優先順位

```
%token <int> INT
%token <bool> BOOL
%token <string> IDENT STRING UIDENT TYPEVAR
%token LET IN REC AND IF THEN ELSE FUN NOT ARRAY_MAKE
%token TYPE OF MATCH WITH BAR UNDERSCORE ARRAY_KW LIST_KW
%token PLUS MINUS AST SLASH PERCENT
%token EQUAL LESS_GREATER LESS GREATER LESS_EQUAL GREATER_EQUAL
%token AMPAMP BARBAR
%token LPAREN RPAREN COMMA SEMICOLON DOT LESS_MINUS ARROW
%token LBRACKET RBRACKET COLONCOLON CARET STRING_LENGTH
%token BEGIN END MODULE STRUCT OPEN SIG VAL COLON
%token EOF

%right prec_let prec_match
%right SEMICOLON
%nonassoc prec_list
%right prec_if
%nonassoc ELSE
%right LESS_MINUS
%nonassoc prec_tuple
%left COMMA
%right BARBAR
%right AMPAMP
%left EQUAL LESS_GREATER LESS GREATER LESS_EQUAL GREATER_EQUAL
%right CARET
%right COLONCOLON
%left PLUS MINUS
%left AST SLASH PERCENT
%right prec_unary_minus
%left prec_app
%left DOT
```

`prec_let` `prec_match` `prec_list` `prec_if` `prec_tuple` `prec_unary_minus`
`prec_app` は擬似トークンで、字句解析器は出しません。`prec_app` と `DOT` は
いちばん上にありますが、[4.1](#41-適用--34個)の34個は潰しません。潰しているのは
`%prec prec_list`（`[a; b]` を列ではなく2要素のリストにする）と `%nonassoc ELSE`
と算術の段です。

### 5.2 生成規則

```
program:      type_decls exp EOF
type_decls:   /* empty */ | type_decl type_decls
type_decl:    TYPE IDENT EQUAL opt_bar constr_decls
opt_bar:      /* empty */ | BAR
constr_decls: constr_decl | constr_decl BAR constr_decls
constr_decl:  UIDENT | UIDENT OF type_args
type_args:    simple_type | simple_type AST type_args
signature_type: type_expr

simple_type:  TYPEVAR | IDENT | long_name DOT IDENT
            | simple_type ARRAY_KW | simple_type LIST_KW
            | LPAREN type_expr RPAREN
type_expr:    type_args ARROW type_expr | type_args

simple_exp:   LPAREN exp RPAREN | BEGIN exp END
            | long_name DOT IDENT | LPAREN RPAREN
            | BOOL | INT | STRING | IDENT | long_name
            | LBRACKET RBRACKET | LBRACKET list_body RBRACKET
            | simple_exp DOT LPAREN exp RPAREN
            | simple_exp DOT LBRACKET exp RBRACKET

exp:          simple_exp
            | NOT exp %prec prec_app
            | MINUS exp %prec prec_unary_minus
            | exp PLUS exp | exp MINUS exp | exp AST exp
            | exp SLASH exp | exp PERCENT exp
            | exp EQUAL exp | exp LESS_GREATER exp | exp LESS exp
            | exp GREATER exp | exp LESS_EQUAL exp | exp GREATER_EQUAL exp
            | exp AMPAMP exp | exp BARBAR exp
            | IF exp THEN exp ELSE exp %prec prec_if
            | IF exp THEN exp %prec prec_if
            | MATCH exp WITH match_cases %prec prec_match
            | FUN formal_args ARROW exp %prec prec_let
            | LET IDENT EQUAL exp IN exp %prec prec_let
            | LET REC fundefs IN exp %prec prec_let
            | MODULE UIDENT EQUAL module_exp IN exp %prec prec_let
            | MODULE UIDENT COLON signature EQUAL module_exp IN exp %prec prec_let
            | MODULE UIDENT LPAREN UIDENT COLON signature RPAREN EQUAL
              STRUCT items END IN exp %prec prec_let
            | MODULE TYPE UIDENT EQUAL signature IN exp %prec prec_let
            | OPEN long_name IN exp %prec prec_let
            | LET LPAREN tuple_pat RPAREN EQUAL exp IN exp %prec prec_let
            | exp actual_args %prec prec_app
            | elems %prec prec_tuple
            | ARRAY_MAKE simple_exp simple_exp %prec prec_app
            | STRING_LENGTH simple_exp %prec prec_app
            | exp CARET exp
            | simple_exp DOT LPAREN exp RPAREN LESS_MINUS exp
            | exp COLONCOLON exp
            | exp SEMICOLON exp

list_body:    exp %prec prec_list | list_body SEMICOLON exp %prec prec_list
long_name:    UIDENT | long_name DOT UIDENT

module_exp:   STRUCT items END | long_name
            | long_name LPAREN module_exp RPAREN
            | LPAREN module_exp COLON signature RPAREN
signature:    UIDENT | SIG sig_items END
sig_items:    /* empty */ | TYPE IDENT sig_items
            | VAL IDENT COLON start_declaration signature_type sig_items
start_declaration: /* empty */

items:        /* empty */ | item items
item:         LET IDENT EQUAL exp
            | LET LPAREN tuple_pat RPAREN EQUAL exp
            | LET REC fundefs
            | type_decl
            | MODULE UIDENT EQUAL module_exp
            | MODULE UIDENT COLON signature EQUAL module_exp
            | MODULE UIDENT LPAREN UIDENT COLON signature RPAREN EQUAL
              STRUCT items END
            | MODULE TYPE UIDENT EQUAL signature
            | OPEN long_name

fundefs:      fundef | fundef AND fundefs
fundef:       IDENT formal_args EQUAL exp
formal_args:  formal_arg formal_args | formal_arg
formal_arg:   IDENT | LPAREN RPAREN
actual_args:  actual_args simple_exp %prec prec_app | simple_exp %prec prec_app
elems:        elems COMMA exp | exp COMMA exp
tuple_pat:    tuple_pat COMMA tuple_pat_name | tuple_pat_name COMMA tuple_pat_name
tuple_pat_name: IDENT | UNDERSCORE

match_cases:  opt_bar case_list
case_list:    case | case BAR case_list
case:         pattern ARROW exp %prec prec_match
pattern:      pattern_comma_list
pattern_comma_list: constr_pattern | constr_pattern COMMA pattern_comma_list
constr_pattern: applied_pattern | applied_pattern COLONCOLON constr_pattern
applied_pattern: simple_pattern | long_name simple_pattern
simple_pattern: UNDERSCORE | IDENT | INT | MINUS INT | BOOL
            | LPAREN RPAREN | long_name
            | LBRACKET RBRACKET | LBRACKET pattern_list RBRACKET
            | LPAREN pattern RPAREN
pattern_list: constr_pattern | constr_pattern SEMICOLON pattern_list
```

`start_declaration` は空の規則です。シグネチャの型変数表を、その宣言の型を読む**前**に
空にするためにあります。空でない規則の末尾でやると、シグネチャの残り全部を読んだあとに
なってしまいます。

---

## 6. brace 形式

同じ言語を波括弧で書く形です。改行に意味はなく、ブロックは `{ }`、文は `;` で
区切ります。

### 6.1 字句

予約語は12語です。

```
array  else  fun  if  match  module  open  signature  true  false  type  val
```

ML 形式とは記号がかなり違います。

| | ML 形式 | brace 形式 |
|---|---|---|
| 等値 | `=` `<>` | `==` `!=` |
| 否定 | `not e` | `!e` |
| 剰余 | `mod` | `%` |
| 文字列連結 | `^` | `++` |
| 行コメント | なし | `//` |
| ブロックコメント | `(* *)` 入れ子 | `/* */` 入れ子 |
| 型引数・ファンクタ引数 | `int list`、`F (A)` | `list<int>`、`F<A>` |

識別子に `'` は使えません（`alnum` に入っていません）。文字列のエスケープは
ML 形式と同じ5つです。

### 6.2 プログラム

```
program   ::= { declaration }
```

宣言の並びだけで、末尾に**暗黙の `main()` 呼び出し**が付きます。ML 形式の
「本体は式1つ」と違い、brace 形式のプログラムは `main` を必要とします。

```
declaration ::= "val" ident [ ":" type ] "=" expr
            | "val" "(" names ")" "=" expr
            | "fun" ident "(" parameters ")" [ ":" type ] function_body
            | "type" uident "{" constructors "}"
            | "module" uident "{" declarations "}"
            | "module" uident ":" uident "{" declarations "}"
            | "module" uident "=" module_exp
            | "module" uident "<" uident ":" uident ">" "{" declarations "}"
            | "signature" uident "{" signature_items "}"
            | "open" path

function_body ::= "=" expr | block
block     ::= "{" block_items "}"
block_items ::= <なし> | expr | statement ";" block_items
statement ::= declaration | expr
```

`and` にあたる語がありません。隣り合う `fun` は互いに見え、再帰の群は
**呼び出しグラフの強連結成分**で切られます（`brace_build.ml`）。ML 形式では同じ判断を
書き手が `and` で行います。

### 6.3 brace 形式 — 構文

式は段に分けてあります。だから ML 形式の34個の衝突がここにはありません。

```
expr      ::= "if" "(" expr ")" expr [ "else" expr ]
            | "match" "(" expr ")" "{" cases "}"
            | "fun" "(" parameters ")" [ ":" type ] function_body
            | postfix "[" expr "]" "=" expr             -- 配列の書き
            | disjunction
disjunction ::= disjunction "||" conjunction | conjunction
conjunction ::= conjunction "&&" comparison | comparison
comparison ::= cons ( "==" | "!=" | "<" | "<=" | ">" | ">=" ) cons | cons
cons      ::= sum "::" cons | sum "++" cons | sum        -- 右結合
sum       ::= sum ( "+" | "-" ) product | product
product   ::= product ( "*" | "/" | "%" ) unary | unary
unary     ::= "-" unary | "!" unary | postfix
postfix   ::= postfix "(" arguments ")"                  -- 呼び出し
            | postfix "[" expr "]"                       -- 配列の読み
            | postfix "." uident                         -- パスを伸ばす
            | postfix "." ident                          -- 選択
            | postfix "." ident "(" arguments ")"        -- メソッド呼び
            | primary
primary   ::= int | string | bool | ident | uident
            | "array" "(" expr "," expr ")"
            | "[" "]" | "[" arguments "]"
            | "(" ")" | "(" arguments ")"
            | block
arguments ::= <なし> | expr { "," expr }
```

比較は `%nonassoc` ではなく `cons ( … ) cons` と書いてあるので、`a == b == c` は
そもそも文法に載りません。

`.` の後ろが大文字ならパスを伸ばし、小文字なら選択です。値に対する選択は
`s.length` だけ、メソッド呼びは `s.at(i)` と `s.equals(t)` だけで、それ以外は
アクションが断ります。

### 6.4 brace 形式の衝突

3個、すべて shift/reduce です。3個とも「空の並びに還元するか、閉じ記号を shift するか」
という同じ形をしています。

| 先読み | 競っているもの | shift が選ぶ読み |
|---|---|---|
| `)` | `arguments: <なし>` の還元 対 `"(" ")"` の `)` | `()` は unit |
| `]` | `arguments: <なし>` の還元 対 `"[" "]"` の `]` | `[]` は空リスト |
| `(` | `postfix "." ident` の還元 対 `postfix "." ident "(" …` | `s.at(0)` はメソッド呼び |

3つ目を reduce にすると `s.at(0)` が `(s.at)(0)` になり、`at` という選択が存在しない
のでアクションが断ります。shift が唯一動く読み方です。

---

## 7. 文法の外の規則

### 7.1 コンストラクタの引数はあとで開かれる

コンストラクタ適用と関数適用を文法で分けると LR の衝突になるので、分けていません。
`exp actual_args` を還元するときに頭が引数のないコンストラクタなら
`Constr (c, args)`、そうでなければ `App (f, args)` にします。

**このとき引数はまだ開かれていません。**

```
type t = C of int * int
C (1, 2)        →  構文解析の直後は  Constr ("C", [Tuple [1; 2]])
                →  名前解決のあと    Constr ("C", [1; 2])
```

宣言された引数個数と照合して括弧付きタプル1つを n 個に開くのは
`Modules.flatten_constructor_args` で、名前解決の段です。構文解析はコンストラクタの
引数個数を知りません。開くのは「個数が一致し、かつ1ではない」ときだけなので、
1引数のコンストラクタにタプルを渡す `C (1, 2)`（`C of int * int` でない場合）は
タプルのまま残ります。

brace 形式は引数を最初から並びとして読むので、この段は要りません
（`Rect(1, 2)` は構文解析の直後から `Constr ("Rect", [1; 2])`）。

### 7.2 その他

| | |
|---|---|
| 名前がコンストラクタかモジュールか | `long_name` はどちらにもなる。決めるのは名前解決 |
| 型宣言の名前が実在するか | 宣言は互いを（自分自身も）参照してよいので、全宣言を読み終えてから `Datatype.check_wellformed` |
| brace 形式の再帰群の切り方 | 隣り合う `fun` を呼び出しグラフの強連結成分に分ける。群の中は単相になるので、切らないと `length` を2つの要素型で使えない |
| シグネチャの `'a` の有効範囲 | `val` 宣言ひとつ。表を空にする空規則が決める |
| 網羅していないマッチ | 型検査以降 |

---

## 8. 検証

衝突の数と中身は、生成器に通すだけで確かめられます。

```sh
menhir --explain compiler/src/parser.mly        # parser.conflicts に36個
menhir --explain compiler/src/brace_parser.mly  # brace_parser.conflicts に3個
```

36個の内訳（先読みトークンで分けたもの）と、shift がどう読むかは、実際に組まれる木と
突き合わせてあります。[3.3](#33-式)と[6.3](#63-brace-形式--構文)の結合の向き、
[4章](#4-ml-形式の衝突)の3族、[7.1](#71-コンストラクタの引数はあとで開かれる)の
2段階も同じです。

[5章](#5-ml-形式--lalr-生成規則)が `parser.mly` と同じ文法であることは、この文書から
機械的に抜き出して確かめられます。133個の生成規則、優先順位宣言18行、終端記号58個が
どれも一致します。
