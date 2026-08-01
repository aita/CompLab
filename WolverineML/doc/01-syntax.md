# 1. 字句と構文解析

`lexer.py` と `parser.py`。

主張は1行で言えます。**式の形は前置か中置のどちらかしかなく、優先順位は表1つに収まる。**
それが Pratt 構文解析（演算子順位法）で、この言語の文法にはそれ以上のものが要りません。

---

## 用語

| | |
|---|---|
| 束縛力 (binding power) | 演算子が左右をどれだけ強く引き寄せるか。数が大きいほど強い |
| nud | 前置位置での意味（*null denotation*）。`~x`、`if`、`(`、リテラル |
| led | 中置位置での意味（*left denotation*）。`+`、`:=`、`andalso` |
| 最長一致 | 記号は長いものから試す。`:=` は `:` と `=` ではない |

---

## 1.1 字句

正規表現は使いません。1文字見て分岐し、そのまま進みます。位置は1から数え、
どのトークンも自分がどこで始まったかを持ちます。

```
$ uv run python -m wolv emit -s tokens tiny.wol
1:1	VAL	val
1:5	IDENT	x
1:7	EQ	=
1:9	INT	1
1:11	PLUS	+
1:13	INT	2
2:1	EOF
```

記号は**長いものから**試します。表を長さで降順に並べておくだけです。

```python
PUNCTUATION: Final[tuple[tuple[str, Tok], ...]] = tuple(
    sorted(
        ((tok.value, tok) for tok in Tok if not tok.value[0].isalpha()),
        key=lambda pair: -len(pair[0]),
    )
)
```

これを忘れると `:=` が `:` と `=` に割れ、`<=` が `<` と `=` に割れます。表を作るときに
一度だけ考えれば済むようにしてあります。

コメント `(* ... *)` は**入れ子になります**。深さを数えるだけですが、数えていないと
`(* (* *) *)` の閉じ位置を間違えます。

### 文字列はバイト列である

`size` も `substring` も実行時にはバイトを数えます。だから字句の段でも、文字では
なくバイトとして読みます —— ソースの文字はその UTF-8 のバイト列になり、`\ddd` は
そのうちの1バイトを名指しします。

```
"日"        →  3バイト（E6 97 A5）
"\230\151\165"  →  同じ3バイト
size ("日本語")  →  9
```

ここは一度間違えています。`\ddd` を Unicode のコードポイントとして読んでいたので、
`\230` が2バイト（U+00E6 の UTF-8）になっていました。テストにすると1行です。

```python
assert lex(r'"\230\151\165"')[0].text == lex('"日"')[0].text
```

---

## 1.2 Pratt 構文解析

表はこれで全部です。

```python
BP: Final[dict[Tok, tuple[int, int]]] = {
    Tok.ASSIGN: (2, 1),      # 右結合
    Tok.ORELSE: (4, 5),
    Tok.ANDALSO: (6, 7),
    Tok.EQ: (8, 9), Tok.NE: (8, 9), Tok.LT: (8, 9), ...
    Tok.CARET: (10, 11),
    Tok.PLUS: (12, 13), Tok.MINUS: (12, 13),
    Tok.STAR: (14, 15), Tok.SLASH: (14, 15), Tok.MOD: (14, 15),
}
```

対の左が**左束縛力**、右が「右側をどの強さで読むか」です。左 < 右なら左結合、
左 > 右なら右結合。`:=` だけが `(2, 1)` で右結合になっているのが表から読めます。

読む側は本当にこれだけです。

```python
def exp(self, min_bp: int) -> ast.Exp:
    left = self.atom()
    while True:
        bp = BP.get(self.cur.kind)
        if bp is None or bp[0] < min_bp:
            return left
        tok = self.cur
        self.pos += 1
        left = ...(tok, left, self.exp(bp[1]))
```

`1 + 2 * 3` が `(+ 1 (* 2 3))` になるのは、`*` の左束縛力 14 が `+` の右 13 より
大きいからです。表を変えれば構文が変わります。

---

## 1.3 末尾に式を取る前置形

`if`・`while`・`for`・`let` は前置形（nud）で、末尾に式を1つ取ります。その式を
**束縛力 0** で読む —— この構文解析で判断が要るのは、そこだけです。

```sml
if c then x := 1 else x := 2
```

`then` の後を束縛力 0 で読むので `x := 1` が丸ごと入ります。0 でなければ `x` だけを
読んで `:= 1` の行き場がなくなります。同じ理由で

```sml
if c then a else b + 1
```

の `else` 側は `b + 1` です。SML と同じ読み方になります。

`;` は中置演算子ではありません。括弧の中と `let ... in ... end` の中だけで、列を
読む専用の関数が処理します。だから `if c then a else b ; d` は「`if` 式」と `d` の
2つに割れます。

---

## 1.4 呼び出しとレコードの見分け

関数は値ではないので、呼び出しは必ず `名前 (…)` の形です。だから識別子の直後を1つ
覗くだけで決まります。

| 直後 | 何になるか |
|---|---|
| `(` | 呼び出し |
| `{` | レコードの生成（型名が要る） |
| その他 | 変数 |

レコードが型名を要求するのは、レコード型が**公称的**（名前で決まる）だからです
（[2章](02-types.md)）。`point { x = 1, y = 2 }` の `point` は飾りではなく、どの型の
値を作るのかを決めている部分です。

後置は `[…]`（添字）と `.名前`（フィールド）で、どちらも最も強く結合します。
`a[i].f[j]` は左から順に積み上がります。

---

## 1.5 代入できるものは構文で決める

`:=` の左に置けるのは変数・添字・フィールドの3つだけです。これは構文解析の時点で
弾きます。

```python
def check_lvalue(self, e: ast.Exp) -> None:
    match e:
        case ast.Var() | ast.Index() | ast.Field():
            return
        case _:
            raise ParseError(e.span, "the left of `:=` is not assignable")
```

型検査まで待つ理由がありません。`1 + 2 := 3` は型の問題ではなく形の問題です。

一方「その変数が `val` だから代入できない」は型検査の仕事です（[2章](02-types.md)）。
形は正しく、**束縛の性質**が許さないからです。

---

## 1.6 文法の全体

以上をまとめると次のようになります。`{ }` は0回以上の繰り返し、`[ ]` は省略可、
`|` は選択で、引用符の中がそのままの字面です。

### 宣言

```
program   ::= { decl }

decl      ::= "type" typebind { "and" typebind }
            | ( "val" | "var" ) ( ident | "(" ")" ) [ ":" ty ] "=" exp
            | "fun" funbind { "and" funbind }

typebind  ::= ident "=" ty
funbind   ::= ident "(" [ param { "," param } ] ")" [ ":" ty ] "=" exp
param     ::= ident ":" ty
```

`and` で繋いだ組は互いに再帰してよく、そこが1つの宣言の単位です。`val () = e` は
名前を付けない束縛で、`e` は `unit` でなければなりません。

### 型

```
ty        ::= tyatom { "array" }
tyatom    ::= ident
            | "{" [ tyfield { "," tyfield } ] "}"
            | "(" ty ")"
tyfield   ::= ident ":" ty
```

`array` は予約語ではありません。型の位置に現れた識別子 `array` だけが後置の
構成子として読まれ、式の位置では組み込み関数の名前です。レコード型 `{ … }` は
ここでは読めますが、`type` で名前を与えていない限り型検査が拒みます —— レコード型が
公称的だからです（[2章](02-types.md)）。

### 式

構文解析は優先順位表1つの Pratt 法で、階層を持ちません（[1.2](#12-pratt-構文解析)）。
以下は**その表と同じものを階層で書き直したもの**で、読み方の定義としては等価です。
上ほど弱く結合します。

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
```

`:=` だけが右結合で、残りは全て左結合です。`~` は `*` より強く結合するので
`~x * y` は `(~x) * y` になります。

```
primary   ::= atom { postfix }
            | "true" | "false" | "nil" | "break"
            | "if" exp "then" exp [ "else" exp ]
            | "while" exp "do" exp
            | "for" ident "=" exp "to" exp "do" exp
            | "let" { decl } "in" [ seq ] "end"

atom      ::= int | string
            | ident "(" [ exp { "," exp } ] ")"               -- 呼び出し
            | ident "{" [ field { "," field } ] "}"           -- レコード生成
            | ident                                           -- 変数
            | "(" ")"                                         -- unit
            | "(" seq ")"

field     ::= ident "=" exp
postfix   ::= "[" exp "]" | "." ident
seq       ::= exp { ";" exp } [ ";" ]
```

3つ、この形からしか読めないことがあります。

- **後置が付くのは `atom` だけ**です。`if` 式やリテラルの `nil` に `.f` を続けることは
  できず、`(if c then a else b).f` と書きます。
- **`;` は演算子ではありません**。`( … )` の中と `let … in … end` の中だけに現れます。
  だから `if c then a else b ; d` は `if` 式と `d` の2つに割れます。閉じ括弧の直前の
  `;` は許されます。
- **`let … in end` は合法**で、値は `unit` です。

`:=` の左に置ける `orelse` は構文上は何でも書けますが、変数・添字・フィールドの
いずれかでなければその場で弾かれます（[1.5](#15-代入できるものは構文で決める)）。

### 字句

```
ident     ::= ( letter | "_" ) { letter | digit | "_" | "'" }
int       ::= digit { digit }
string    ::= '"' { schar } '"'
schar     ::= <"、\、改行 以外の1文字> | escape
escape    ::= "\" ( "n" | "t" | "r" | '"' | "\" )
            | "\" digit digit digit                           -- 1バイトを名指す
comment   ::= "(*" { comment | <任意の1文字> } "*)"            -- 入れ子になる
```

`letter` と `digit` は Unicode の分類で、名前は ASCII に限りません。文字列リテラルは
バイト列で、ソースの1文字はその UTF-8 のバイト列になります（[1.1](#11-字句)）。

予約語は次の22個です。これ以外の識別子は変数か関数か型の名前になります。

```
and  andalso  break  do  else  end  false  for  fun  if  in  let  mod
nil  orelse  then  to  true  type  val  var  while
```

---

## していないこと

- 演算子の定義（`infix` 宣言）はありません。表は固定です。
- 中置の関数適用（`x + y` 以外の中置）はありません。
- 誤り回復をしません。最初の構文エラーで止まります。`1:13: expected ')', found ...`
  のように位置を言うところまでです。

---

## 参考文献

- Vaughan Pratt, *Top Down Operator Precedence*, POPL 1973.
- Andrew Appel, *Modern Compiler Implementation in ML*, 3章（Tiger の文法）.

---

## 実装の地図

| | |
|---|---|
| `lexer.py` | `Tok`（トークンの種類）、`Lexer`、`lex` |
| `parser.py` | `BP`（優先順位表）、`Parser.exp`（led）、`Parser.atom`（nud） |
| `ast.py` | 構文木。`ty` と `sym` は型検査が後から埋める |
| `astshow.py` | `emit -s ast` の表示 |
