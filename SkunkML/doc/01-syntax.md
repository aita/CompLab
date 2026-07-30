# 1. 構文 — SML をどう読むか

`lexer.mll` と `parser.mly` の話です。文法そのものは SML の部分集合なので、面白いのは
**LR(1) で衝突ゼロにするために構文へ入れた3つの制約**と、その代償です。

## 用語

| | |
|---|---|
| LR(1) | 1トークン先読みで還元と shift を決められる文法のクラス。menhir が作るのはこれ |
| 衝突 (conflict) | 同じ状態で「還元してよい」と「shift してよい」が両立してしまうこと |
| 優先順位宣言 | `%left` `%right` `%nonassoc`。衝突を「どちらを選ぶか」で潰す仕組み |
| `%prec` | 生成規則の優先順位を、最後の終端記号でなく明示で決める |
| 表層構文 (surface syntax) | 書かれた文字列の文法。抽象構文木になる前 |

## 1. 字句 — ドットを文法から追い出す

`List.map` は3トークン（`List` `.` `map`）ではなく**1トークン**です。

```ocaml
| qual (lid | uid) as s { let q, b = split_path s in QID (q, b) }
```

こうすると `.` が文法に一度も現れません。パスとレコード射影を見分ける仕事も、
`A . B` と `A.B` の空白の扱いも、まとめて消えます。SML はレコードの射影を `#x r` と
書くので、`r.x` という構文が最初から存在せず、この判断で失うものがありません。`#x` も
同じ理由で1トークン (`SELECT "x"`) です。

残りは普通です。コメント `(* *)` は入れ子にでき、`'a` は型変数、`x'` は識別子、
文字列のエスケープは4つだけで改行をまたげません。

**大文字と小文字を区別するのは修飾子だけです。** パスの前半（`List` の部分）は大文字で
始まらなければなりませんが、構成子は大文字でも小文字でもかまいません。SML の `nil` と
`true` が小文字だからです。「その名前は構成子か変数か」は文法ではなく環境が決めます
（[5章](05-matching.md)の1節）。

## 2. `|` は誰のものか

SML でいちばん厄介なのはこれです。

```sml
fun f x = case x of A => 1 | B => 2
```

この `|` は `case` の腕の区切りにも、`fun` の次の節の始まりにも読めます。SML の規則は
「内側の `case` のもの」で、だから `fun` の節を2つ書きたければ `case` を括弧で囲め、
ということになります。

LR で「内側」を選ぶのは shift することです。衝突を優先順位で潰します。

```
%nonassoc LOWEST
%nonassoc BAR DARROW
%right SEMI
...
%left STAR DIV MOD
%nonassoc TILDE
```

効いているのは下2つの並びではなく、**上2行**です。

- `rule: pat DARROW term` の優先順位は最後の終端記号 `DARROW` のもので、`DARROW` は
  一番下に置いてあります。つまり腕の本体は**右のものを何でも飲み込みます**。
  `A => 1 + 2` の `+` は腕のもの。
- `match_rules: rule %prec LOWEST` は `BAR` より下です。つまり腕がひとつだけの
  `match_rules` を還元するか `|` を shift するかで迷ったら、**shift**。だから `|` は
  いつでも最も内側の match に付きます。

この2つを入れると、残りの衝突はゼロになります。`FN`/`CASE` の生成規則に `%prec` を
付ける必要すらありません（menhir が「その `%prec` は無駄だ」と言ってくるので、
言われたとおり外してあります）。

## 3. 式の型注釈は括弧の中だけ

`e : t` を式の構文として許すと、ここで詰みます。

```sml
val x = e : int * int
```

`int * int` まで読んだところで、`*` が掛け算なのか直積型なのか決まりません。
`(e : int) * int` とも `e : (int * int)` とも読めて、SML の答は後者（型を最長に取る）
ですが、それを LR(1) で表現しようとすると型の文法と項の文法が `*` を取り合います。

この処理系は**式の型注釈を括弧の中に限りました**。

```sml
val m = (someExpression : int)      (* 括弧が要る *)
val n : int = 41 + 1                (* 宣言の注釈は括弧なし *)
fun size (xs : int list) : int = List.length xs
```

失うものはほとんどありません。よく書くのは宣言の注釈と引数の注釈で、そちらは
**パターンの**注釈です。パターンには `*` を使う構文がないので `pat : ty` を制限なしに
許すことができ、`val n : int = 41 + 1` も `fun f (a : string, b) = ...` もそちらで
通ります。詰まるのは項の側だけです。

## 4. 型は項とは別の文法を持つ

型と項を**1本の木**にする書き方もあります。`x * y` を掛け算とも直積型とも読める同じ
節点にしてしまえば、文法は小さくなり、型の構文を項の構文がただで手に入れます。

ここでは分けました。理由はモジュールです。

```sml
signature ORD = sig
  type t                      (* 項がどこにもない *)
  val compare : t * t -> int
end
```

シグネチャの `type t` は型成分の宣言で、対応する項が存在しません。しかもシグネチャは
構造より**先に**エラボレートされます（先に hole を作らないと照合できない、
[3章](03-modules.md)）。型と項を同じ木にしても得るものがないので、分けました。

型の文法は後置適用で左結合です。

```
ty       ::= ty_tuple | ty_tuple ARROW ty
ty_tuple ::= ty_app | ty_app (STAR ty_app)+
ty_app   ::= ty_atom | ty_app path | LPAREN ty (COMMA ty)+ RPAREN path
ty_atom  ::= TYVAR | path | ( ty ) | { l : ty, ... }
```

`int list list` はリストのリスト、`(int, string) either` は2引数の適用です。
`ty_app path` と `ty_atom` がどちらも `path` から始まりますが、`ty_app` の続きに
`ty_atom` は来ないので、LR(1) は迷いません。

## 5. `fun` の節は構文解析の時点で揃える

```sml
fun merge ([], ys) = ys
  | merge (xs, []) = xs
  | merge (x :: xs, y :: ys) = ...
```

「全部の節が同じ名前を定義しているか」「引数の数は揃っているか」は、構文解析の
アクションで確かめます。悪い節がまだ手元にあるうちに言えるからです。

```
this clause defines g, but the ones before it define f
this clause of f takes 2 arguments, the first takes 1
```

節の引数は `pat_atom`（アトミックなパターン）に限ります。`fun f x :: xs = ...` は
`(f x) :: xs` と読めてしまうので、SML と同じく `fun f (x :: xs)` と書きます。

## 6. 名前は構文解析では決まらない

パターンの中の裸の名前は、いつも `PVar` として作られます。

```ocaml
| x = LID  { mkp $startpos (PVar x) }
| c = UID  { mkp $startpos (PVar c) }
```

`nil` も `true` も `NONE` も、ここでは変数です。構成子かどうかを決めるのは環境で、
それはエラボレーションの仕事です（`elab.ml` の `check_pat`）。SML がそうなっているのは、
構成子の綴りに規則がないからです — `nil` は小文字で、`Leaf` は大文字。

修飾された名前（`A.Box`）だけは例外で、構文の時点で構成子だと決めます。構造の中の値を
パターンに書くことはできないので、迷う余地がありません。

## していないこと

- **ユーザ定義の中置演算子がありません。** `infix` 宣言は演算子表を実行時に書き換える
  ということで、LR の表を固定にしておくならパーサの外に演算子優先順位法をもう1段
  積む必要があります（Badger の Prolog リーダはそれをやっています）。ここでは
  SML の演算子表を固定で持っています。
- **`op` がありません。** `foldl op + 0 xs` は書けません。`fn (a, b) => a + b` と
  書きます。
- **文字と実数がありません。** 文字がないので `String.sub` もありません。
- **`local`・`abstype`・`withtype`・`sharing` がありません。** どれも構文の仕事が
  増えるだけで、この本の主題に何も足しません。
- **`e : t` を括弧なしで書けません。** 3節のとおりです。

## 参考文献

- Milner, Tofte, Harper, MacQueen, *The Definition of Standard ML (Revised)*,
  MIT Press, 1997. 文法は付録 B。この章の制約はすべて「Definition のどれを落としたか」
  として読めます。
- François Pottier, *Menhir Reference Manual*. `%prec` と優先順位の効き方、
  `--explain` の読み方。
- Andrew Appel, *Compiling with Continuations*, 1992, §1。SML の構文が実装から見て
  どこが厄介かの古典的な整理。

## 実装の地図

| ファイル | 何が |
|---|---|
| `src/lexer.mll` | `split_path` が `List.map` を1トークンにする。`comment` が入れ子、`string` がエスケープ |
| `src/parser.mly` | 冒頭の優先順位宣言（2節）、`fun_bind` が節を揃える（5節）、`ty`/`ty_tuple`/`ty_app`/`ty_atom` が型の文法（4節） |
| `src/ast.ml` | 表層構文木。型を知らず、名前が構成子かどうかも知らない |

---

[← 0. プログラムが通る道](00-pipeline.md) ・ [2. Hindley–Milner →](02-hm.md)
