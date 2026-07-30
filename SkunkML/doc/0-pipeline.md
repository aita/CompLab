# 0. プログラムが通る道

`skunk examples/tour.sk` を打ったときに何が起きるかを、1パス1段落で追います。以降の章は
すべて、この道のどこか1箇所の話です。

```
   .sk ソース
     │  lexer.mll        字句解析（(* *) は入れ子、List.map は1トークン）
     ▼
   トークン列
     │  parser.mly       構文解析（LR(1)、衝突ゼロ）
     ▼
   Ast.program           表層構文木。型の文法は項とは別に持つ
     │  elab.ml          型推論と正規化を同時に。types.ml が単一化、sem.ml がシグネチャ
     ▼
   Core.item list        型付き A正規形。パターンとラムダはまだ入っている
     │  patmat.ml        パターン → 決定木。ここで join point が現れる
     ▼
   Core.item list        switch と join だけになった
     │  closure.ml       クロージャ変換。join point は変換しない
     ▼
   Flat.program          コードブロック＋捕獲＋join point。型はもうない
     ├──▶ machine.ml     CESK マシン                     → 値
     └──▶ build.ml       値 SSA（[10章](10-ssa.md)）      → amd64 へ向かう途中
```

## 1. 字句解析

`lexer.mll` は ocamllex です。SML に合わせてコメントは `(* *)` で入れ子にでき、`'a` は
型変数として1トークンになり、`x'` は識別子のままです。

ひとつだけ普通でないことをしています。**`List.map` を1トークンとして読みます。** ドットが
文法に一切現れないので、「パス」と「レコードの射影」を見分ける仕事が消えます。SML では
レコードの射影は `#x r` と書くので、そもそも `r.x` という構文がなく、この判断で失うものが
ありません。`#x` も同じ理由で1トークンです。

## 2. 構文解析

`parser.mly` は menhir で、**衝突は0**です。`--explain` を付けて生成しても
`parser.conflicts` は空になります。

SML の文法で難しいのは `|` です。`case` の腕も `fun` の節も `datatype` の構成子も
同じ記号で区切られるので、`fun f x = case y of A => 1 | B => 2` の `|` がどちらのものか
決まりません。SML の答は「内側の `case` のもの」で、この処理系も同じです。実現の仕方は
[1章](1-syntax.md)にあります。

型は**項とは別の文法**を持ちます。理由はモジュールです。シグネチャの `type t` は項が
どこにもない宣言で、しかも構造より先に読まれます。型と項を1本の木にする書き方もあり、
文法は小さくなりますが、ここではその得がありません。

## 3. 型推論と正規化

`elab.ml` が Hindley–Milner 推論と A正規形への変換を**同時に**やります。同じ木を2回
歩く理由がないからです。項は *destination*（「あなたは末尾位置にいる」か「値をこう使え」）に
対して変換され、型はその変換から返ってきます。

単一化は `types.ml` にあります。単一化変数は可変セルで、単一化はセルを破壊的につなぎ、
一般化は環境を走査するかわりに**レベル**を比べます（[2章](2-hm.md)）。

モジュールは `sem.ml` です。シグネチャは意味対象で、そこに書かれた `type t` は
**hole**、構造をシグネチャに照合すると hole が埋まって **realisation** ができます。
`:` はそれを残し、`:>` は捨てる。それが2つの型付けの唯一の違いです（[3章](3-modules.md)）。

このパスを抜けた時点で**モジュールは存在しません**。構造はレコード、ファンクタは関数に
なっていて、以降のパスはモジュールという言葉を知りません。

## 4. 型付き Core

出てくるのは A正規形です。すべてのオペランドはアトム（変数かリテラル）で、ブロックは
`let` の直線＋末尾形、関数は1引数です。

```sml
fun sum (n, acc) = if n = 0 then acc else sum (n - 1, acc + n)
```

```
$ skunk --dump-core sum.sk
-- val sum : int * int -> int
fix sum : int * int -> int = fn a1.19 : int * int =>
  let p.57 : int = #1 a1.19
  let p.58 : int = #2 a1.19
  let n.2 : int = p.57
  let acc.3 : int = p.58
  let t.60 : bool = =(n.2, 0)
  switch t.60 of
  | true =>
      ret acc.3
  | false =>
      let t.61 : int = -(n.2, 1)
      let t.62 : int = +(acc.3, n.2)
      let t.63 : int * int = (t.61, t.62)
      tailcall sum t.63
```

**型が残っているのが要点です。** ふつう正規化のあとに型は消しますが、次のパスが型を
必要とします（[4章](4-core.md)）。ちなみに `if` はここには存在しません。`bool` は
構成子が2つの直和型で、`if` は `case` の書き方のひとつです。

## 5. パターンマッチのコンパイル

`patmat.ml` がパターンを**決定木**に落とします。Maranget の行列アルゴリズムで、
値の各部分を高々1回だけ検査する順序を選びます。

```sml
fun pick (true, 1) = "both"
  | pick (_, 2)    = "two"
  | pick _         = "no"
```

```
  join arm () =
    ret "two"
  join arm.2 () =
    ret "no"
  let p.59 : bool = #1 a1.20
  let p.60 : int = #2 a1.20
  switch p.59 of
  | true =>
      switch p.60 of
      | 1 => ret "both"
      | 2 => jump arm ()
      | _ => jump arm.2 ()
  | _ =>
      switch p.60 of
      | 2 => jump arm ()
      | _ => jump arm.2 ()
```

最初の2つの腕が違う列を検査しているので、どちらを先に見ても最後の腕には**4箇所から**
たどり着きます。本体を4つ複製するかわりにラベルにしたのが `join arm.2` です。1回しか
たどり着かない腕（`"both"`）はその場に書かれます。だからダンプに `join` が出ているところが、
そのまま「共有が起きたところ」です（[5章](5-matching.md)・[6章](6-join.md)）。

網羅性と冗長性は、この木から読めます。到達できる失敗があれば網羅していないし、葉がひとつも
ない腕は誰も到達できない腕です。別の解析は要りません。

```
$ skunk tests/warn.sk
warn.sk:5:5: warning: this match does not cover every case
warn.sk:8:5: warning: this pattern can never match: 0
```

## 6. クロージャ変換

`closure.ml` がラムダを「コード」と「捕獲した値」に分けます。コードはプログラムの先頭へ
出て行き、値は捕獲のリストになります。

```sml
fun adder n = fn m => n + m
```

```
$ skunk --dump-flat adder.sk
code t.61$2 (x.12) =
  let n.2 = capture 0
  let m = x.12
  let t.60 = +(n.2, m)
  ret t.60

code adder$1 (a1.19) =
  let n.2 = a1.19
  let t.61 = closure t.61$2 [n.2]
  ret t.61
```

**join point は変換されません。** 自由変数はそのままです。jump はそれを定義した
ブロックの内側からしか来ないので、値はまだそこにあるからです。ラベルとクロージャを
区別する理由がこれです（[7章](7-closure.md)）。

## 7. 実行

`machine.ml` は CESK マシンです。制御・環境・**ストア**・継続。環境は名前を番地へ、
ストアは番地を値へ写します。CEK なら環境が名前を値へ直接写せば済むところを2段にして
いるのは、この言語に配列があるからです。配列は番地の連なりで、`Array.update` はストアを
1箇所書き換える。それ以外は何も変わりません（[8章](8-cesk.md)）。

継続フレームは1種類しかありません。A正規形では「値を待っているもの」は `let` だけです。
末尾呼び出しはフレームをそのまま渡し、join point への jump はフレームに触りません。

```
$ skunk --trace sum.sk
  fix sum
  ret sum
  let t.64 = (2, 0)
  let t.65 = sum t.64
  let p.57 = #1 a1.19
  ...
  tailcall sum t.63
```

## 8. 報告

各束縛について `val 名前 : 型 = 値` を1行出します。型検査を通らなかったときは
**何も実行しません** — 半分だけ動いた出力を見せないためです。

```
$ skunk examples/tour.sk
val greeting : string = "hello"
val answer : int = 42
...
datatype 'a tree = Leaf | Node of 'a tree * 'a * 'a tree
val sorted : int list = [1, 3, 5, 8]
structure IntSort
val ordered : int list = [1, 2, 4, 9]
the answer is 42
```

エラーはすべて `Loc.Error` 一種類で、`ファイル:行:桁: 種別: 本文` の形に揃えてあります。
警告はエラーではなく、プログラムは走ります。

## この本で使う言葉

どの章でも出てくる語です。章ごとの用語は、それぞれの章の冒頭にあります。

| | |
|---|---|
| パス (pass) | ソースから値までの道を1区間ずつ受け持つ処理。上の図の矢印1本 |
| 中間表現 (IR) | パスの間で受け渡される形。ここでは `Ast`・`Core`・`Flat` の3つ |
| 正規形 (normal form) | 書き方の自由度を削った IR。何を削るかが名前になる |
| A正規形 (ANF) | 「すべてのオペランドはアトム」を削り方に選んだ正規形（[4章](4-core.md)） |
| アトム (atom) | 変数かリテラル。評価しなくても値が分かるもの |
| 末尾位置 (tail position) | その値がそのまま呼び出し元へ返る位置。ANF では構文で決まる |
| エラボレーション (elaboration) | 書かれた構文を、検査済みの内部表現へ翻訳すること |
| 単一化 (unification) | 2つの型が等しくなるように変数を決めること（[2章](2-hm.md)） |
| 一般化 (generalisation) | 単型を型スキームにすること。どの変数を量化してよいかが問題（[2章](2-hm.md)） |
| 型スキーム | `forall` を含む型。環境に入るのはこちら |
| 決定木 (decision tree) | パターンマッチを「検査の木」に直したもの（[5章](5-matching.md)） |
| join point | 引数を持つラベル。跳ぶことしかできず、値としては持てない（[6章](6-join.md)） |
| クロージャ変換 | ラムダを「コード」と「捕獲した値」に分けること（[7章](7-closure.md)） |
| 抽象機械 | 評価を状態の書き換え規則として書いたもの。CEK、CESK など（[8章](8-cesk.md)） |
| 生成的 (generative) | 使うたびに新しい型ができること。ファンクタの性質（[3章](3-modules.md)） |

---

[← 目次](index.md) ・ [1. 構文 →](1-syntax.md)
