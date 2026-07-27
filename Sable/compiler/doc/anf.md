# A正規化とその後 — `anf.ml`, `alpha.ml`, `optim.ml`

構文木を、バックエンドが読める形に均す3つのパスです。順に、**中間結果すべてに名前を付け**、
**その名前を一意にし**、**付けすぎた名前を畳みます**。

## 1. A正規化 — `anf.ml`

**中間結果すべてに `let` で名前を付ける**変換です（[A-normal form][anf]。MinCaml が
K正規形と呼ぶものと同じです）。

```
$ sablec --dump-anf -o /dev/null a.sbl        let rec f a b c = (a + b) * (c - 1)
let rec f.10 a.11 b.12 c.13 =
  let t.2.14 : int =
    a.11 + b.12                              ← 部分式に名前
  in
  let t.3.16 : int =
    1                                        ← 定数にも名前
  in
  let t.4.15 : int =
    c.13 - t.3.16
  in
  t.2.14 * t.4.15
in
```

名前を付けるのは `insert_let` の1関数で、**すでに変数ならそのまま**、そうでなければ新しい
`t` を作って `let` で包みます。定数にまで名前が付くのはこの規則の素直な帰結です。無駄に
見えますが、§3 の伝播と除去がまとめて片づけます（`li` に読み手がいなくなれば
[生存解析](selection.md#3-生存解析--livenessml)のデッドコード除去が命令ごと持って
いきます）。

### なぜバックエンドがこの形を欲しがるか

2つあります。

**評価順を発明しなくてよくなります。** 機械語命令が食う部分式はすでに変数なので、命令選択は
「どちらを先に計算するか」を考えません。順番は `let` の並びとして既に決まっています。

**変数の生存区間が、そのまま「レジスタに置いておかねばならない区間」になります。** `let` で
束縛された地点から最後の使用までがその区間です。生存解析が数えるのはこれで、干渉グラフの
辺はここから出ます（[レジスタ割り付け](regalloc.md#2-干渉グラフを作る)）。

### 比較は分岐に融合される

A正規形の `t` には比較演算がありません。**`if` の条件に現れた比較は、そのまま分岐命令に
なります**（`If_eq` と `If_le`）。しかも到達するのはこの2つだけで、残る4つは腕か被演算子を
入れ替えて表します。

```
$ sablec --dump-anf -o /dev/null a.sbl
let rec g.10 x.11 y.12 =                      let rec g x y = if x < y then 1 else 2
  if y.12 <= x.11 then                        ← 被演算子も腕も入れ替わって `<=` に
    2
  else
    1
in
let rec h.13 x.14 y.15 =                      let rec h x y = if x <> y then 1 else 2
  if x.14 = y.15 then                         ← 腕を入れ替えて `=` に
    2
  else
    1
in
```

| 書いたもの | 出るもの |
|---|---|
| `x = y` | `If_eq (x, y, then, else)` |
| `x <> y` | `If_eq (x, y, else, then)` |
| `x <= y` | `If_le (x, y, then, else)` |
| `x > y` | `If_le (x, y, else, then)` |
| `x >= y` | `If_le (y, x, then, else)` |
| `x < y` | `If_le (y, x, else, then)` |

RISC-V の分岐命令に合わせた形です。バックエンドが知る比較が2種類で済みます。

値として使われた比較は行き場がないので、**1 か 0 を返す `if` に展開します**。

```
let rec cmp.8 x.9 y.10 =                      let rec cmp x y = x <= y
  if x.9 <= y.10 then
    1
  else
    0
in
```

これは分岐2つとジャンプに落ちて損なので、[命令選択](selection.md)が `slt` の並びに
組み直します。
条件が比較でないただの真偽値なら、`false` と比べる `If_eq` にして同じ形に揃えます。

### 表現についての決めごと

`unit`・`bool`・`int` はどれも1ワードです（`unit` は 0、`true` は 1）。だから A正規形に
真偽値専用の節点がありません。`Int 0` と `Int 1` で足ります。

`sum` のダンプでは、これらが組み合わさった形が見えます。

```
$ sablec --dump-anf -o /dev/null doc/sum.sbl
let rec sum.18 l.19 =
  let t.8.21 : int =
    l.19[0]                    ← タグの読み出し。match が決定木になっている
  in
  let t.9.22 : int =
    0
  in
  if t.8.21 = t.9.22 then      ← タグ 0 なら Nil
    0
  else
    let fld.6.23 : int =
      l.19[1]                  ← x
    in
    let fld.7.24 : chain =
      l.19[2]                  ← rest
    in
    let t.10.27 : int =
      sum.18 fld.7.24
    in
    fld.6.23 + t.10.27
in
...
let t.13.35 : chain =
  &sable_const_Nil_3           ← 定数コンストラクタはアドレス。確保しない
in
let t.14.33 : chain =
  block 1 (t.12.34 t.13.35)    ← Cons (2, Nil)
in
```

`match` はもう存在せず、タグの読み出しと比較と分岐になっています。`Nil` は
`sable_const_Nil_3` のアドレスで、確保は起きません。

## 2. α変換 — `alpha.ml`

すべての束縛子に別々の名前を与えます（上のダンプの `.15`、`.16` という接尾辞）。

これ以降、**名前がそのまま束縛の同一性**になります。だから後続パスは名前をキーにした
ただの `Set`／`Map` で仕事ができます。最適化は捕獲を心配せずに `let` を動かせるし、
クロージャ変換はシャドーイングを気にせず自由変数を計算できます。

## 3. 最適化 — `optim.ml`

3つのパスを数回まわします。

| | |
|---|---|
| `flatten_lets` | `let x = (let y = e1 in e2) in e3` を `let y = e1 in let x = e2 in e3` に。A正規化が作る入れ子をほどき、残り2つが効く形にする |
| `propagate` | コピー伝播、定数畳み込み、両辺が既知の分岐の畳み込み |
| `eliminate` | 使われていない、かつ副作用のない `let` を落とす |

見た目より効きます。A正規化は**定数にもフィールド読み出しにも名前を付ける**ので、伝播と
除去を通すとそれらの名前が消え、レジスタを奪い合わなくなります。決定木が出すフィールド
読み出しのうち、その分岐が読まないものもここで落ちます。

不動点ではなく回数固定（既定3回）です。項が可変な型変数を抱えているので構造的等価に
頼りたくないのと、実際2〜3回で収束するからです。

## 実装の地図

| | |
|---|---|
| `anf.ml` 15–39行 | `t` — A正規形。部分式の位置に来るのは `Ident.t` だけです |
| `anf.ml` 58–84行 | `free_vars`。クロージャ変換が使うのと同じ定義 |
| `anf.ml` 86–95行 | `insert_let` — すでに変数ならそのまま、でなければ名前を付ける |
| `anf.ml` 101–238行 | `normalize_exp`。比較の融合は118–137行 |
| `alpha.ml` | 束縛子を一意な名前に |
| `optim.ml` | `flatten_lets`・`propagate`・`eliminate` を規定回数まわす |

## 参考文献

- C. Flanagan, A. Sabry, B. F. Duba, M. Felleisen,
  [*The essence of compiling with continuations*][anf], PLDI 1993. A正規形。
- E. Sumii, [*MinCaml: a simple and efficient compiler for a minimal functional
  language*][mincaml], FDPE 2005（[PDF][mincaml-pdf]）。この並び — A正規化・α変換・
  最適化・クロージャ変換 — はこれに倣っています。

[anf]: https://doi.org/10.1145/155090.155113
[mincaml]: https://doi.org/10.1145/1085114.1085122
[mincaml-pdf]: https://esumii.github.io/min-caml/paper.pdf

---

隣の文書：[パイプライン全体](pipeline.md)、[クロージャ変換](closure.md)。
