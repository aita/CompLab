# WolverineML 文法仕様

この文書は WolverineML の字句と構文を、**パーサーを1つ書くのに必要なだけ**述べたものです。
解説は [`doc/`](../doc/index.md) の本にあり、ここには規則しかありません。

参照実装 `python/wolv/lexer.py`・`python/wolv/parser.py` は Pratt 構文解析（演算子順位法）
ですが、この文書は yacc・bison・menhir・ocamlyacc に渡せる形、すなわち **LALR(1) の
生成規則と優先順位宣言**で書いてあります。2つは同じ言語を同じ木に読みます。

| | |
|---|---|
| [1. 記法](#1-記法) | EBNF の読み方 |
| [2. 字句](#2-字句) | トークン、予約語、走査の規則 |
| [3. 構文](#3-構文) | 宣言・型・式の EBNF |
| [4. 曖昧さの解消](#4-曖昧さの解消) | 3つの規則と、その優先順位への翻訳 |
| [5. LALR(1) 文法](#5-lalr1-文法) | そのまま yacc/menhir に渡せる形 |
| [6. 文法の外の規則](#6-文法の外の規則) | 構文解析器が断るもの、型検査に回るもの |

---

## 1. 記法

| | |
|---|---|
| `"..."` | そのままの字面（終端記号） |
| `A \| B` | 選択 |
| `{ A }` | 0回以上の繰り返し |
| `[ A ]` | 省略可 |
| `( A )` | まとまり |
| `<...>` | 地の文による説明 |
| `--` から行末 | 註釈 |

---

## 2. 字句

### 2.1 トークン

```
token     ::= keyword | ident | int | string | punct
```

**予約語**は次の22語です。これ以外の語はすべて `ident` になります。

```
and  andalso  break  do  else  end  false  for  fun  if  in  let  mod
nil  orelse  then  to  true  type  val  var  while
```

**記号**は次の23個です。

```
:=  <>  <=  >=
(  )  [  ]  {  }  ,  :  ;  .  =  <  >  +  -  *  /  ^  ~
```

`-` は二項の減算だけです。負号は `~` で、`-x` は構文解析器が名指しで断ります
（[6.1](#61-構文解析器が断るもの)）。

### 2.2 綴り

```
ident     ::= ( letter | "_" ) { letter | digit | "_" | "'" }
int       ::= digit { digit }
string    ::= '"' { schar } '"'
schar     ::= <'"'、'\'、改行 以外の1文字>
            | escape
escape    ::= "\" ( "n" | "t" | "r" | '"' | "\" )
            | "\" digit digit digit                -- 1バイトを名指す。値は 255 以下

trivia    ::= <空白 | タブ | 復帰 | 改行>
            | comment
comment   ::= "(*" { comment | <"(*" でも "*)" でもない位置の1文字> } "*)"
```

`letter` は Unicode の**文字カテゴリ**（`L*`）、`digit` は**十進数字カテゴリ**（`Nd`）です。
名前は ASCII に限りません。数字を ASCII の `0`–`9` に限る字句解析器との差は、名前や
数値に非 ASCII の数字を書いたときにしか出ません。

### 2.3 走査の規則

1. **記号は最長一致**です。`:=` は `:` と `=` ではなく、`<=` は `<` と `=` ではありません。
   表を長さの降順に並べて先頭から試すだけで足ります。
2. **語は先に読み切ってから引きます**。`ident` の綴りで読み切った語が22語のどれかに
   一致すればその予約語、しなければ `ident` です。`iffy` は `if` と `fy` ではありません。
3. **コメントは入れ子**です。深さを数えます。`(* (* *) *)` は1つのコメントで、
   閉じないまま入力が尽きればエラーです。
4. **数字列の直後に文字か `_` が来たらエラー**です。`123abc` は `123` と `abc` の2つでは
   ありません。
5. **文字列はバイト列**です。ソースの文字はその UTF-8 のバイト列になり、`\ddd` は
   そのうちの1バイトを名指します（`ddd` はちょうど3桁、値は255以下）。改行をまたぐ
   文字列と、閉じない文字列はエラーです。`size` も `substring` も実行時にバイトを
   数えるので、字句もそう読みます。

```
"日"             →  3バイト（E6 97 A5）
"\230\151\165"   →  同じ3バイト
```

6. `trivia` はトークンの区切りにしかならず、どこにでも置けます。

### 2.4 `array` は予約語ではない

`array` は**型の位置でだけ**後置の型構成子として働き、それ以外の位置では普通の名前です。
組み込み関数 `array (n, init)` の名前でもあり、`val array = 1` と束縛することもできます。

字句解析器で文字列を見る余地のない生成器（menhir、ocamlyacc、yacc）では、**`array` に
専用のトークン `ARRAY` を与え、識別子を要求するすべての位置で `IDENT | ARRAY` を
受ける**のがいちばん短い扱いです。[5章](#5-lalr1-文法)の `name` がそれです。

---

## 3. 構文

### 3.1 プログラムと宣言

```
program   ::= { decl }

decl      ::= "type" typebind { "and" typebind }
            | ( "val" | "var" ) ( ident | "(" ")" ) [ ":" ty ] "=" exp
            | "fun" funbind { "and" funbind }

typebind  ::= ident "=" ty
funbind   ::= ident "(" [ param { "," param } ] ")" [ ":" ty ] "=" exp
param     ::= ident ":" ty
```

プログラムは宣言の並びで、`main` はありません。宣言が0個のプログラムは合法です。

`and` で繋いだ組が1つの宣言の単位で、その中は互いに再帰してよいものです。
`val () = e` は名前を付けない束縛です。仮引数の型注釈は必須で、`fun` に結果型が
なければ `unit` を返す手続きです。

### 3.2 型

```
ty        ::= tyatom { "array" }
tyatom    ::= ident
            | "{" [ tyfield { "," tyfield } ] "}"
            | "(" ty ")"
tyfield   ::= ident ":" ty
```

`array` は後置で、いくつ続けてもかまいません（`int array array`）。空のレコード型
`{}` は書けます。

### 3.3 式

優先順位は次の8段で、上ほど弱く結合します。

| | 演算子 | 結合 |
|---|---|---|
| 1（最弱） | `:=` | **右** |
| 2 | `orelse` | 左 |
| 3 | `andalso` | 左 |
| 4 | `=` `<>` `<` `<=` `>` `>=` | 左 |
| 5 | `^` | 左 |
| 6 | `+` `-` | 左 |
| 7 | `*` `/` `mod` | 左 |
| 8（最強） | `~`（前置） | — |

右結合は `:=` だけです。`~` は `*` より強いので `~x * y` は `(~x) * y`、
`a ^ b ^ c` は `(a ^ b) ^ c`、`a = b = c` は `(a = b) = c` です。

この表を階層で書き直すと次のようになります。参照実装は優先順位表1つの Pratt 法で
階層を持ちませんが、読み方の定義としては等価です。

```
exp       ::= assign
assign    ::= orelse [ ":=" assign ]                          -- 右結合
orelse    ::= andalso { "orelse" andalso }
andalso   ::= compare { "andalso" compare }
compare   ::= concat { ( "=" | "<>" | "<" | "<=" | ">" | ">=" ) concat }
concat    ::= additive { "^" additive }
additive  ::= product { ( "+" | "-" ) product }
product   ::= unary { ( "*" | "/" | "mod" ) unary }
unary     ::= "~" unary | primary

primary   ::= atom { postfix }
            | "true" | "false" | "nil" | "break"
            | "if" exp "then" exp [ "else" exp ]
            | "while" exp "do" exp
            | "for" ident "=" exp "to" exp "do" exp
            | "let" { decl } "in" [ seq ] "end"

atom      ::= int | string
            | ident "(" [ exp { "," exp } ] ")"               -- 呼び出し
            | ident "{" [ field { "," field } ] "}"           -- レコードの生成
            | ident                                           -- 変数
            | "(" ")"                                         -- unit
            | "(" seq ")"

field     ::= ident "=" exp
postfix   ::= "[" exp "]" | "." ident
seq       ::= exp { ";" exp } [ ";" ]
```

この階層は曖昧です。`if`・`while`・`for` の末尾の式が `primary` の位置にありながら
`exp` を丸ごと取るからで、その読み方を決めるのが次の章です。

---

## 4. 曖昧さの解消

規則は4つです。

### 4.1 末尾の枝は右へ伸びる

`if`・`while`・`for` の末尾の式は、**そこから右をできるだけ長く**読みます。

```sml
if c then x := 1 else x := 2      →  (if c (:= x 1) (:= x 2))
if c then a else b + 1            →  (if c a (+ b 1))
while c do x := 1                 →  (while c (:= x 1))
1 + if c then a else b * 2        →  (+ 1 (if c a (* b 2)))
```

つまり `then`・`else`・`do` の後は**どの二項演算子よりも弱い**位置です。

### 4.2 `else` は最も内側の `if` に付く

```sml
if a then if b then c else d      →  (if a (if b c d))
```

`else` のない `if` は `then` の枝が `unit` になるので、この規則は意味も変えます。

### 4.3 後置が付くのは `atom` だけ

`[…]` と `.名前` が続けられるのは `atom`、すなわち `int`・`string`・`( … )` と、
`ident` で始まる3つの形（変数・呼び出し・レコードの生成）だけです。
`nil`・`true`・`false`・`break`、および `if`・`while`・`for`・`let` の式には直接続かず、
括弧が要ります。

```sml
(if c then a else b).f            -- よい
if c then a else b.f              -- `b.f` が else の枝になる
nil.f                             -- 構文エラー
```

呼び出しは `名前 ( … )` の形しかありません（関数は値ではないので）。`f(1)(2)` は
構文エラーです。

### 4.4 `;` は演算子ではない

`;` は `( … )` の中と `let … in … end` の中にしか現れず、閉じる直前の1つは余分に
書けます。だから

```sml
if c then a else b ; d
```

は「`if` 式」と `d` の2つに割れ、括弧の外では構文エラーになります。
`let … in end` は合法で、値は `unit` です。

### 4.5 優先順位への翻訳

4.1 と 4.2 は yacc/menhir の優先順位宣言で表せます。弱いほうから並べます。

```
%nonassoc THEN            /* 4.2: else は shift される */
%nonassoc DO ELSE         /* 4.1: 末尾の枝はどの演算子よりも弱い */
%right    ASSIGN
%left     ORELSE
%left     ANDALSO
%left     EQ NE LT LE GT GE
%left     CARET
%left     PLUS MINUS
%left     STAR SLASH MOD
%right    UNARY
```

理屈はこうです。yacc は規則の優先順位を**その規則の最後の終端記号**から取るので、
`IF exp THEN exp` は `THEN` の、`IF exp THEN exp ELSE exp` と `WHILE exp DO exp` と
`FOR … DO exp` は `ELSE`/`DO` の優先順位を持ちます。

- `IF exp THEN exp` を読み終えて `ELSE` を見たとき、還元（規則＝`THEN`）と
  shift（`ELSE`）が競う。`ELSE` が上なので shift、すなわち内側の `if` に付く（4.2）。
- 同じ状態で `+` を見たときも、`+` が `THEN`/`ELSE`/`DO` より上なので shift、
  すなわち枝が右へ伸びる（4.1）。

`%prec` が要るのは `TILDE exp %prec UNARY` の1本だけで、残りは既定の規則優先順位が
そのまま正しく働きます。4.3 は優先順位ではなく**非終端記号の分け方**で表します
（`atom` / `primary` / `exp`）。

bison 3 以降は結合性を持たない段に `%precedence` を使えます（`THEN`・`DO ELSE`・
`UNARY`）。menhir にその綴りはないので `%nonassoc` のままにします。

---

## 5. LALR(1) 文法

以下は上の規則をそのまま生成規則にしたものです。bison でも menhir でも
**衝突は0**で、意味動作を除けば両者で同じ本文が使えます。

### 5.1 終端記号

```
%token <string> INT STRING IDENT
%token ARRAY                                    /* 綴りが array の識別子 */
%token AND ANDALSO BREAK DO ELSE END FALSE FOR FUN IF IN LET MOD NIL ORELSE
%token THEN TO TRUE TYPE VAL VAR WHILE
%token LPAREN RPAREN LBRACK RBRACK LBRACE RBRACE COMMA COLON SEMI DOT
%token ASSIGN EQ NE LE LT GE GT PLUS MINUS STAR SLASH CARET TILDE
%token EOF                                      /* menhir だけが要る */
```

### 5.2 優先順位

[4.5](#45-優先順位への翻訳) の10行をそのまま置きます。

### 5.3 生成規則

```
program : decls
        ;

decls   : /* empty */
        | decls decl
        ;

decl    : TYPE typebinds
        | VAL name  COLON ty EQ exp
        | VAL name            EQ exp
        | VAL LPAREN RPAREN COLON ty EQ exp
        | VAL LPAREN RPAREN           EQ exp
        | VAR name  COLON ty EQ exp
        | VAR name            EQ exp
        | VAR LPAREN RPAREN COLON ty EQ exp
        | VAR LPAREN RPAREN           EQ exp
        | FUN funbinds
        ;

typebinds : typebind | typebinds AND typebind ;
typebind  : name EQ ty ;

funbinds  : funbind | funbinds AND funbind ;
funbind   : name LPAREN params RPAREN COLON ty EQ exp
          | name LPAREN params RPAREN          EQ exp
          ;

params    : /* empty */ | paramlist ;
paramlist : param | paramlist COMMA param ;
param     : name COLON ty ;

/* `array` は型を作る位置でだけ構成子で、ほかでは普通の名前 */
name      : IDENT | ARRAY ;

ty        : tyatom
          | ty ARRAY
          ;
tyatom    : name
          | LBRACE tyfields RBRACE
          | LPAREN ty RPAREN
          ;
tyfields    : /* empty */ | tyfieldlist ;
tyfieldlist : tyfield | tyfieldlist COMMA tyfield ;
tyfield     : name COLON ty ;

exp : exp ASSIGN exp
    | exp ORELSE exp
    | exp ANDALSO exp
    | exp EQ exp   | exp NE exp | exp LT exp
    | exp LE exp   | exp GT exp | exp GE exp
    | exp CARET exp
    | exp PLUS exp | exp MINUS exp
    | exp STAR exp | exp SLASH exp | exp MOD exp
    | TILDE exp %prec UNARY
    | TRUE | FALSE | NIL | BREAK
    | IF exp THEN exp
    | IF exp THEN exp ELSE exp
    | WHILE exp DO exp
    | FOR name EQ exp TO exp DO exp
    | LET decls IN letbody END
    | primary
    ;

letbody : /* empty */ | seq ;

/* `;` は演算子ではない。括弧と let の中にだけ現れ、1つ余分に書ける */
seq : exp
    | seq SEMI exp
    | seq SEMI
    ;

/* 後置が付くのは atom だけ（4.3） */
primary : atom
        | primary LBRACK exp RBRACK
        | primary DOT name
        ;

atom : INT
     | STRING
     | name
     | name LPAREN args RPAREN
     | name LBRACE fields RBRACE
     | LPAREN RPAREN
     | LPAREN seq RPAREN
     ;

args      : /* empty */ | arglist ;
arglist   : exp | arglist COMMA exp ;
fields    : /* empty */ | fieldlist ;
fieldlist : field | fieldlist COMMA field ;
field     : name EQ exp ;
```

### 5.4 生成器ごとの差

| | |
|---|---|
| bison | `program` に終端記号は要らない。`%token <string>` の綴りは `%union` の要素名（`%union { char *s; }` なら `%token <s>`）。`%nonassoc THEN` などは `%precedence` にすると警告が消える |
| menhir | 開始記号は `program : decls EOF` と書く。`list(decl)`・`separated_list(COMMA, param)` などの標準の部品に置き換えても衝突は増えない |
| ocamlyacc | `%precedence` はないので `%nonassoc` のまま |

### 5.5 木の形

生成規則から作る木は、`emit -s ast` が表示するものと同じにします。要点だけ。

- `LPAREN seq RPAREN` は要素が1つならその式そのもの、2つ以上なら列。
  `LPAREN RPAREN` は `unit` のリテラル。
- `LET decls IN letbody END` の `letbody` が空なら本体は `unit` のリテラル。
- `name LBRACE fields RBRACE` のフィールドは書かれた順に持つ。型検査が宣言順に
  並べ替えます。
- `ty ARRAY` は左から積み上がるので `int array array` は「`int array` の配列」。

---

## 6. 文法の外の規則

### 6.1 字句と構文の段で断るもの

生成規則には書けないが、木を組み立てるまでに断るものが4つあります。参照実装は最初の
エラーで止まり、誤り回復をしません。

| | どこで | |
|---|---|---|
| `:=` の左が場所でない | 構文 | 変数・`a[i]`・`r.f` の3つだけが書ける。`1 + 2 := 3` は形の問題 |
| `-x` | 構文 | 「負号は `~` で書く」と名指しで言う |
| 数字列の直後の文字 | 字句 | `123abc` |
| `\ddd` が3桁でない、または255を超える | 字句 | `"\65"`、`"\300"` |

`:=` の左の検査は、生成規則を分けるのではなく**還元のときに木を見て**行います。
そのほうが「代入できない」というエラーを、`orelse` 以下のどの形からも同じ言葉で
出せるからです。Pratt 実装は `:=` を見た時点で、LALR 実装は規則を還元する時点で
断るので、報告の順序は違いますが、受理する言語は同じです。

### 6.2 型検査に回るもの

構文としては正しく、意味の段で断るものです。

| | |
|---|---|
| `val` で束縛した変数への代入 | 形は正しく、束縛の性質が許さない |
| 名前のないレコード型 | `val x : {a:int} = …` は書けるが、レコード型は公称的なので拒む |
| `break` がループの外 | |
| 型の付かない `nil` | `val a = nil` は文脈がない |
| 未宣言の名前、引数の数、フィールド名 | |

詳しくは[2章 型検査とエスケープ解析](../doc/02-types.md)。

---

## 7. この文法の検証

`bison -Wall` と `menhir --explain --strict` のどちらでも衝突は0です。生成器に
かけるだけで確かめられます。

参照実装との一致は、同じトークン列を両方に渡して木を比べることで確かめてあります
——リポジトリの `.wol` 150本、優先順位と結合を1つずつ突く式・宣言 105本、および
実在のソースをトークン単位で 1〜3 箇所壊した 3000 本について、受理・不受理と木の
形がすべて一致します。
