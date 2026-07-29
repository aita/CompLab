# 2. ANF と CEK マシン

型検査を通ったプログラムは A正規形（ANF）に落ち、CEK 風の機械で走ります。5つの型システムは
「どのプログラムが正しいか」で意見が分かれますが、「正しいプログラムがどう走るか」では完全に
一致するので、この2つは共有されます。

## 用語 — 正規形と抽象機械

**正規形 (normal form)** とは、書き方の自由度を削って「同じことを言う書き方が1通りしかない」
形にした中間表現のことです。削るのは後段が読みやすくなる自由度で、どの自由度を削るかが
正規形の名前になります。

**A正規形 (ANF, administrative normal form / A-normal form)** が削るのは
**部分式の入れ子**です。演算や呼び出しの被演算子は**原子 (atom)** ——変数かリテラル——でなければ
ならず、それ以外は `let` で名前を付けます。だから `f (g x)` は書けず、
`let t = g x in f t` になります。

**CPS (continuation-passing style)** はもっと強く、「次に何をするか」を関数（継続）として
明示的に渡す形にします。表現力は上ですが、変換の副産物として意味のない β 冗長
（**administrative redex**）が大量に出るので、ダンプが読みにくくなります。ANF は
「CPS のうち継続が呼び出しスタックで足りる部分」に相当します。

**抽象機械 (abstract machine)** は、評価を「状態の書き換え規則」として書いたものです。名前は
状態の構成要素の頭文字です。

| | 状態 | |
|---|---|---|
| **CEK** | **C**ontrol（実行中の項）・**E**nvironment（環境）・**K**ontinuation（継続フレーム列） | この処理系の基本形 |
| **CESK** | CEK ＋ **S**tore（可変な記憶） | チャネルの端点を置くので、`linear` があるとこちら |
| **SECD** | **S**tack・**E**nvironment・**C**ontrol・**D**ump | Landin の古典。ANF では S が要らず、D は K の劣った版になる |

継続を「フレームの列」として持つことが要点です。**フレームが1種類しかない**（`KLet`）のは、
A正規形では「値を待っているもの」が `let` だけだからです。

そのほか、この章で出てくる語:

| | |
|---|---|
| 末尾位置 (tail position) | その式の値がそのまま関数の返り値になる位置。ここでの呼び出しはフレームを積まなくてよい |
| 末尾呼び出し (tail call) | 末尾位置にある呼び出し。ANF では `tailcall` という別の節点 |
| join point | 分岐が合流する点。ここでは局所関数として具体化する |
| カリー化 (currying) | 2引数関数を「1引数関数を返す1引数関数」にすること |
| PAP (partial application) | 引数が足りない呼び出しを表す実行時の表現。カリー化を正規化でやると要らない |
| CBPV (call-by-push-value) | 値と計算を型で分ける体系。構文カテゴリが2つ増える |

## なぜ木を直接歩かないのか

構文木をそのまま再帰で評価する方式（tree-walking）は短く書けますが、ラボとしては情報が
足りません。ANF に落とすと3つのことが**構文から見える**ようになります。

1. **オペランドが原子である。** 呼び出しの引数は変数かリテラルだけなので、1ステップの評価が
   部分項に再帰しません。機械の1ステップが本当に1ステップです。
2. **末尾位置が構文である。** `tailcall` と `let x = f a` が別の節点なので、末尾呼び出しが
   フレームを積まないことが「規約」ではなく「型」になります。末尾再帰が定数スタックで走ることが
   実装の性質ではなく IR の性質になります。
3. **中間結果に名前がある。** これは篩型システムが独立に必要としたものでもあります。
   `refine.ml` の `value_of` は、述語に現れる式を変数に束縛し直します——ANF がやることを、
   型検査の側で必要に応じてやっている（[5章](5-refine.md)）。

## 何を採らなかったか

| 候補 | 採らなかった理由 |
|---|---|
| KNF（MinCaml の K正規形、= monadic normal form） | 末尾位置が構文から見えない。MartenML が採っているので、リポジトリに2つの正規形が並ぶ方が読み比べられる |
| join point 付き ANF（GHC Core） | 合流点をラベルとして残せるが、スコープ規則を自前で守る必要がある。下記のクロージャ化で足りる |
| 本物の CPS | 継続が第一級になるが administrative redex が増え、ダンプが読みにくくなる |
| CBPV | 値と計算を型で分けられて線形型と噛み合うが、構文カテゴリが2つになる |
| SECD | ANF ではオペランドスタック（S）が要らず、ダンプ（D）は継続フレーム列の劣った版になる |

教科書どおりの ANF＋CEK が、この処理系の目的に対しては一番情報量が多くて短い、という判断です。

## 正規化

`anf.ml` の変換は教科書どおりで、**行き先（destination）**に対して項を変換します。行き先は
「末尾位置にいる」か「値をこう使え」のどちらかです。

```ocaml
type dest =
  | Tail
  | Cont of (C.atom -> C.block)
```

`fun add x y = x + y` はこうなります。関数は1引数なので、カリー化は正規化の側の仕事です。

```
-- add in A-normal form
let t.3 = fun x ->
  let f.1 = fun y ->
    let t.2 = +(x, y)
    ret t.2

  ret f.1

ret t.3
-- five in A-normal form
let t.4 = add 2
tailcall t.4 3
```

`add 2 3` が「`add 2` を呼んでフレームを積み、返ってきたクロージャに末尾呼び出しする」2段に
なっています。部分適用が機械に存在しないので、アリティ検査も PAP も要りません。

### 非末尾位置の条件分岐

ANF が素朴に書けない唯一の場所がここです。`let x = if c then a else b in rest` は ANF の
形をしていません。ブロックは「`let` の直線＋末尾形」でなければならないからです。

やり方は2つあります。`rest` を両方の腕にコピーする（入れ子ごとにプログラムが倍になる）か、
**継続を局所関数として具体化して両方の腕から末尾呼び出しする**か。後者を採っています。

```sml
fun f n = (if n > 0 then n else 0) + 1
```

```
-- f in A-normal form
let t.5 = fun n ->
  let t.1 = >(n, 0)
  let j.2 = fun v.3 ->
    let t.4 = +(v.3, 1)
    ret t.4

  if t.1 then
    tailcall j.2 n
  else
    tailcall j.2 0

ret t.5
```

`j.2` が具体化された継続です。**これは join point をクロージャで表現したもの**で、GHC の
Core が `join j v = ...` としてラベルに保つのと同じものです。ラベルなら割り当てが要らず、
クロージャなら IR に新しい概念が要らない。ここでは後者を採り、代わりに「割り当てが1つ増える」
ことを引き受けています。

`anf.ml` の該当箇所はこれだけです。

```ocaml
and with_join d f =
  match d with
  | Tail -> f Tail
  | Cont k ->
      let j = C.fresh "j" and v = C.fresh "v" in
      C.Let (j, C.Lam (v, k (C.AVar v)),
             f (Cont (fun a -> C.Tail (C.TCall (C.AVar j, a)))))
```

`if`、`case`、`branch` はすべてこれを通ります。

### パターン

パターンは専用パスを持たず、ここで潰します。ヴァリアントは `case` 節点になり、それ以外
（対・変数・`()`）は射影の連続になります。ヴァリアントのパターンは腕の先頭にしか書けない、という
制限つきです——決定木のコンパイラは MartenML にあり、MinkML の主題ではありません。

## 機械

`machine.ml` は制御（実行中のブロック）・環境・継続フレーム列の3つ組です。**フレームは
1種類しかありません。**

```ocaml
type frame = KLet of string * Core.block * env
```

A正規形では「値を待っているもの」は `let` だけなので、これで全部です。末尾呼び出しは
フレーム列をそのまま渡すので、末尾再帰は定数スタックになります。`sumTo` の内側の `go` が
その例です（`tests/anf.expected` に全体があります）。

`let rec` は環境に可変セルを置いてからクロージャを詰める、という結び目1つで済みます。

```ocaml
let cell = ref VUnit in
let env = Env.add f cell p.renv in
cell := VClos (param, body, env);
```

### ストア — セッションのために

`linear` システムのセッション型があるので、機械には第4の要素、ストアがあります。ストアには
チャネルの端点が入り、状態は CEK ではなく CESK になります。

- 端点は対で割り当てられ、双対は1ビット違い（`dual n = n lxor 1`）。
- 通信は**1メッセージ分のバッファ**です。送信は相手が追いついていないときだけブロックします。
- ブロックしたステップは**何も消費しません**。あとで同じ命令をやり直すだけなので、中断した
  プロセスの状態を別に持つ必要がありません。
- スケジューラはラウンドロビンで、各プロセスをブロックか終了まで走らせて次へ移ります。
  全プロセスがブロックしたら、デッドロックとして報告します。

バッファを1つにしたのは、セッション型が緩衝の有無に依存しないからです。ただし1つあれば
「プロセスがプロトコルの途中で中断する」ことは起き、それが観察したい部分です。
`examples/session.mnk` の `ponger` の出力に交代が見えます。

```
1
10
2
20
```

`--trace` を付けると、各プロセスがどの命令にいるかが逐一出ます。

## この2つを共有したことの帰結

型システムを1つ足すときに書くのは検査器だけで、実行系には触りません。注釈だけで書いた
プログラムは、4つのシステムのどれに渡しても同じ ANF になり同じ値を出します。

```sml
fun inc (n : int) : int = n + 1
val four = inc 3
```

```
$ for s in poly row refine linear; do mink -s $s both.mnk; done
inc : int -> int = <fun>
four : int = 4
inc : int -> int = <fun>
four : int = 4
inc : int -> int = <fun>
four : int = 4
inc : int -> int = <fun>
four : int = 4
```

型システムが変えているのは、プログラムが走る前に何を証明させられるかだけです。`inc` の
引数を `{ v : int | v > 0 }` に変えれば `refine` だけが呼び出し側に証明を要求し、他の3つは
その型を読むことすらできません。

## 参考文献

- C. Flanagan, A. Sabry, B. F. Duba, M. Felleisen, [*The essence of compiling with
  continuations*][anf], PLDI 1993。A正規形。CPS 変換の後に administrative redex を消すと
  ANF になる、という関係がここに書かれています。
- P. J. Landin, [*The mechanical evaluation of expressions*][landin], Computer Journal 6(4),
  1964。SECD 機械。
- M. Felleisen, D. P. Friedman, [*Control operators, the SECD machine, and the
  λ-calculus*][cek], 1986。CEK 機械。
- L. Maurer, P. Downen, S. Peyton Jones, [*Compiling without continuations*][joinpoints],
  PLDI 2017。join point を IR の一級市民にする側。ここではクロージャで代用しています。
- P. B. Levy, [*Call-by-push-value: a subsuming paradigm*][cbpv], TLCA 1999。上の表の CBPV。

[anf]: https://doi.org/10.1145/155090.155113
[landin]: https://doi.org/10.1093/comjnl/6.4.308
[cek]: https://legacy.cs.indiana.edu/ftp/techreports/TR197.pdf
[joinpoints]: https://doi.org/10.1145/3062341.3062380
[cbpv]: https://doi.org/10.1007/3-540-48959-2_17
