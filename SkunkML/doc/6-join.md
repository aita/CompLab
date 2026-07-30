# 6. join point — ラベルはクロージャではない

この章だけは1つのファイルの話ではありません。**別々の理由で必要になった2つのものが、
同じ形をしていた**という話です。片方は[4章](4-core.md)の正規化から、もう片方は
[5章](5-matching.md)の決定木から出てきます。

## 用語

| | |
|---|---|
| join point | 引数を持つラベル。跳ぶことしかできず、値として持ち回せない |
| jump | join point への制御移動。フレームも環境も作らない |
| 継続の具体化 | 「このあと何をするか」を関数として作ってしまうこと |
| 合流 (join) | 分岐した制御が1点に戻ること。名前の由来 |

## 1. 出どころ その1 — 値を求められている `case`

A正規形は「`let` は別のブロックを束縛しない」を規則にしています。だからこれは書けません。

```
let x = (switch xs of nil => ... | :: => ...) in rest
```

素直な逃げ道は2つあり、どちらも高くつきます。

- **`rest` を両方の枝に複製する。** `case` が入れ子になるたびにプログラムが倍になります。
- **`rest` を関数にして、両方の枝から呼ぶ。** 呼び出しなのでクロージャを作り、フレームを
  積みます。

隣の [MinkML](../../MinkML) の `lab/src/anf.ml` は2番目をやっていて、コメントにこう
書いてあります。

> that function is what a compiler with join points would keep as a label
> instead of a closure

ここではその「ラベル」を持ちます。

```ocaml
let with_join ty d f =
  match d with
  | Tail -> f Tail
  | Cont k ->
      let j = C.fresh_name "k" and v = C.fresh_name "v" in
      C.Join (j, [ (v, ty) ], k (C.AVar v) ty,
              f (Cont (fun a _ -> C.Tail (C.Jump (j, [ a ])))))
```

末尾位置なら何もしません。そうでなければ継続を1度だけ名前に付けて、枝はそこへ跳びます。

```sml
fun depth xs = 1 + (case xs of [] => 0 | _ :: rest => depth rest)
```

```
$ skunk --dump-core tests/core.sk
-- val depth : 'a list -> int
let rec depth : '_31 list -> int = fn a1.22 =>
  let xs.13 : '_31 list = a1.22
  join k (v : int) =
    let t.66 : int = +(1, v)
    ret t.66
  switch xs.13 of
  | nil =>
      jump k (0)
  | :: =>
      let arg.15 : '_31 * '_31 list = payload xs.13
      let p.63 : '_31 = #1 arg.15
      let p.64 : '_31 list = #2 arg.15
      let rest.2 : '_31 list = p.64
      let t.65 : int = depth rest.2
      jump k (t.65)
ret depth
```

`+1` が1回だけ書かれていて、両方の枝がそこへ跳びます。**共有されているのは継続**です。

## 2. 出どころ その2 — 決定木が同じ腕に何度もたどり着く

こちらは[5章](5-matching.md)から来ます。

```sml
fun overlap (true, _, 1) = "first"
  | overlap (_, true, 2) = "second"
  | overlap _            = "neither"
```

最初の2つの腕が別の列を検査しています。1列目を先に見ても3列目を先に見ても、
最後の腕には複数の道からたどり着きます。

```
let rec overlap : bool * bool * int -> string = fn a1.20 =>
  join arm () =
    ret "second"
  join arm.2 () =
    ret "neither"
  let p.63 : bool = #1 a1.20
  let p.64 : bool = #2 a1.20
  let p.65 : int = #3 a1.20
  switch p.63 of
  | true =>
      switch p.65 of
      | 1 => ret "first"
      | 2 => switch p.64 of
             | true => jump arm ()
             | _    => jump arm.2 ()
      | _ => jump arm.2 ()
  | _ =>
      switch p.64 of
      | true => switch p.65 of
                | 2 => jump arm ()
                | _ => jump arm.2 ()
      | _ => jump arm.2 ()
```

`arm.2` へは4箇所から跳んでいます。**共有されているのは腕の本体**です。

これは決定木の代償です。バックトラック法（Wadler 1987）なら本体は1回しか現れませんが、
そのかわり同じ値を何度も検査します。決定木は検査の重複をなくすかわりに**道が増える**。
join point はその増えた道が同じところへ着くことを、複製せずに書く方法です。

## 3. 1つの構文、2つの理由

`Core.block` に入っているのは1つの節点です。

```ocaml
| Join of label * (string * Types.ty) list * block * block
```

`Join (j, params, body, rest)` は「`rest` の中で `j` に跳べる」と読みます。跳ぶ側は
末尾形です。

```ocaml
| Jump of label * atom list
```

1節と2節は**同じものを違う理由で必要としました**。1節は「継続を複製したくない」で、
2節は「腕を複製したくない」。どちらも「合流点に名前を付けたい」に落ちるので、
節点は1つで足ります。

## 4. なぜ関数ではないのか

join point を単なる局所関数にしても、意味は同じです。違うのは費用です。

| | 局所関数 | join point |
|---|---|---|
| 自由変数 | 捕獲する（ヒープに確保） | そのまま。何も確保しない |
| 呼ぶ | フレームを積む（末尾なら積まない） | 制御が移るだけ |
| 値として | 持ち回せる。返せる。データ構造に入れられる | できない |
| クロージャ変換 | 変換する | 触らない |

一番下の行が本質です。join point が自由変数を捕獲しなくてよいのは、**跳ぶ側が必ず
それを定義したブロックの内側にいる**からです。値が消えていることがありえない。

これが成り立つのは、この処理系が join point を上の2箇所でしか作らず、どちらも
「`case` を包んで、その腕から跳ぶ」形だからです。ラムダの境界をまたぐ join point は
生まれません。[7章](7-closure.md)はその前提の上に立っています。

## 5. ラベルにするかどうかの判断

腕を全部ラベルにするのが素直ですが、`case x of 1 => a | _ => b` が引数ゼロのラベル2つに
なってダンプが読めなくなります。そこで**2回以上たどり着く腕だけ**ラベルにして、
1回のものはその場に書き出します（[5章](5-matching.md)の7節）。

副作用が本題より嬉しい: **ダンプの `join` は、そのまま「そこで共有が起きた」の印**です。
上の `overlap` で `"first"` が `ret "first"` と直に書かれているのは、そこへの道が
1本しかないからです。

1節の `with_join` には同じ判断がありません。継続は必ず「枝の数だけ」跳ばれるので、
分岐がある以上たいてい2回以上です。ただし末尾位置なら join point 自体を作りません。

## 6. 機械での姿

`machine.ml` では join point は環境に入ります。

```ocaml
| F.Join (j, ps, body, rest) ->
    st.env <- { st.env with joins = Map.add j { jparams = ps; jbody = body; jenv = st.env } st.env.joins };
    st.ctrl <- rest;
    run w st
```

```ocaml
| F.Jump (j, args) ->
    let vs = List.map (atom w st.env) args in
    let env = List.fold_left2 (bind w) jp.jenv jp.jparams vs in
    st.env <- env; st.ctrl <- jp.jbody; run w st
```

**フレームには触りません。** `st.ks` は読まれも書かれもしない。跳ぶのは goto であって
呼び出しではない、が実装に見えているのはここです。

インタプリタなので定義時の環境を覚えていますが、それは同じ環境の共有であって複製では
ありません。コンパイラなら「同じスタックフレームの中のラベル」になります。Core の
束縛名が全部一意なので（[4章](4-core.md)の5節）、跳んだ先で見えている環境を使っても
同じことになります。

## していないこと

- **join point の引数を減らしません。** 全ての枝で同じ値を渡している引数は落とせますが、
  やっていません。
- **join point を join point へインライン展開しません。** 1回しか跳ばれない join point は
  展開できます（腕については5節でやっていますが、`with_join` のほうはしていません）。
- **ラムダをまたぐ join point を作りません。** 作らないので、そういうものが来たときの
  対処もありません（7章の前提）。
- **末尾呼び出しの join point 化をしません。** 相互再帰の末尾呼び出しはラベルに
  できますが、それは別の最適化です。

## 参考文献

- Luke Maurer, Paul Downen, Zena Ariola, Simon Peyton Jones, "Compiling without
  Continuations", *PLDI* 2017. GHC の join point。「join point とは、ラムダのうち
  末尾からしか呼ばれないと分かっているもの」という定式化がこの章の背景です。
- Andrew Kennedy, "Compiling with Continuations, Continued", *ICFP* 2007.
  CPS を持たずに CPS の利益を得る話。join point はその中心。
- Cliff Click, Michael Paleczny, "A Simple Graph-Based Intermediate
  Representation", 1995. SSA の φ 節点。合流点に名前を付けるという同じ問題の、
  命令型側の答。join point の引数は φ です。
- Luc Maranget, "Compiling Pattern Matching to Good Decision Trees", 2008, §4。
  決定木が本体を共有する話。

## 実装の地図

| ファイル | 何が |
|---|---|
| `src/elab.ml` | `with_join`（1節）。`EIf`・`ECase` が呼ぶ |
| `src/patmat.ml` | `compile_case` の `joins`（2・5節）、`emit` の `TLeaf`（跳ぶか書き出すか） |
| `src/core.ml` / `src/flat.ml` | `Join`/`Jump`（3節）。Flat 側では型が落ちるだけで形は同じ |
| `src/closure.ml` | `conv` の `C.Join`。触らないことがコードに見える（[7章](7-closure.md)） |
| `src/machine.ml` | `env.joins`、`F.Join`、`F.Jump`（6節） |

---

[← 5. パターンマッチを決定木にする](5-matching.md) ・ [7. クロージャ変換 →](7-closure.md)
