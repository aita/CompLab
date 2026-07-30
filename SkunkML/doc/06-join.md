# 6. join point — 分かれた道が同じところへ戻るとき

`if` や `case` は道を分けます。分かれた道は、たいていまた合流します。**その合流点に
名前を付けたもの**が join point です。

この章は定義から始めません。同じ `if` が、置かれた場所によって別のコードになるところを
見て、なぜそうなるのかを追い、最後に「これは何なのか」に戻ります。

## 用語

いまは目を通すだけで結構です。中身は1節から3節で作ります。

| | |
|---|---|
| 末尾位置 | その値がそのまま呼び出し元へ返る位置。`fun f x = ここ` |
| 継続 | 「この値が求まったあとにすること」 |
| join point | 引数を持つラベル。跳んで入り、値としては持ち回せない |
| jump | join point へ跳ぶこと。関数呼び出しではなく goto |
| 合流 (join) | 分かれた制御が1点に戻ること。名前の由来 |

## 1. 同じ `if` が、置かれた場所で別のコードになる

3つ書きます。どれも同じことをしています。

```sml
fun answer b = if b then "yes" else "no"
fun describe b = "it is " ^ answer b
fun inline b = "it is " ^ (if b then "yes" else "no")
```

`answer` の `if` は**末尾位置**にあります。`if` が返した値が、そのまま `answer` の
返り値です。

```
$ skunk --dump-core tests/join.sk
-- val answer : bool -> string
let answer : bool -> string = fn a1.19 : bool =>
  let b : bool = a1.19
  switch b of
  | true =>
      ret "yes"
  | false =>
      ret "no"
```

分岐が `switch` になって、枝がそれぞれ `ret` する。合流していません — **分かれたまま
関数から出ていきます**。

`describe` には分岐がありません。まっすぐです。

```
-- val describe : bool -> string
let describe : bool -> string = fn a1.20 : bool =>
  let b.2 : bool = a1.20
  let t.60 : string = answer b.2
  let t.61 : string = ^("it is ", t.60)
  ret t.61
```

`inline` は2つを合わせただけですが、出てくるものが違います。

```
-- val inline : bool -> string
let inline : bool -> string = fn a1.21 : bool =>
  let b.3 : bool = a1.21
  join k (v : string) =
    let t.62 : string = ^("it is ", v)
    ret t.62
  switch b.3 of
  | true =>
      jump k ("yes")
  | false =>
      jump k ("no")
```

`join` と `jump` が出ました。何が起きたのかを2節で見ます。

## 2. なぜ `inline` だけ困るのか

`inline` の `if` は**末尾位置にありません**。`if` が返した値のあとに、まだ
やることが残っています — `"it is " ^ …` です。これが**継続**です。

そして枝は2本あるので、**継続に入る道が2本**あります。ここが合流点です。

書きたいのはこういうものですが、書けません。

```
let t = (switch b of true => "yes" | false => "no")     ← 書けない
let t.62 = ^("it is ", t)
ret t.62
```

[4章](04-core.md)の1節の規則です。**ブロックは `let` の直線が末尾形で終わったもの**で、
`let` が束縛できるのは「1手ぶんの仕事」だけ。`switch` は末尾形であってブロックではなく、
`let` の右辺に置けません。

これは意地悪な規則ではなく、[8章](08-cesk.md)の3節を成り立たせるためのものです。
「値を待っているもの」が `let` しかないから、機械の継続フレームは1種類で済んでいます。
`let` が分岐を待てるようにした瞬間、それが崩れます。

では、どうするか。素直な手が2つあります。

### 手その1 — 継続を両方の枝に複製する

```
switch b.3 of
| true =>
    let t.62 : string = ^("it is ", "yes")     ← 複製
    ret t.62
| false =>
    let t.63 : string = ^("it is ", "no")      ← 複製
    ret t.63
```

これは書けますし、走ります。問題は大きさです。枝が2本なら2倍、`if` が入れ子になれば
4倍、8倍。継続が1行だからここでは安く見えますが、継続は**そのあとの残り全部**なので、
たいてい1行ではありません。

### 手その2 — 継続を関数にして、両方の枝から呼ぶ

```
let k = fn v => (let t = ^("it is ", v) in ret t)
switch b.3 of
| true  => tailcall k "yes"
| false => tailcall k "no"
```

複製は消えました。かわりに**関数が1つ増えました**。関数はクロージャです。ヒープに
確保され、自由変数を捕獲します（[7章](07-closure.md)）。`if` を1つ書くたびに
1つ確保するのは、分岐の値段としては高い。

## 3. 3つ目の道 — 「呼ばない」と約束した関数

手その2の `k` をよく見ると、ふつうの関数がしてよいことを何もしていません。

- **値として持ち回されていません。** 返しもしないし、データ構造にも入らない。
  名前が出てくるのは `tailcall k …` の2箇所だけです。
- **必ず末尾で呼ばれています。** `k` から戻ってきてやることは、誰にもありません。
- **定義したブロックの内側からしか呼ばれていません。**

この3つが分かっているなら、クロージャにする必要はありません。

- 持ち回されない → **ヒープに置かなくてよい**
- 末尾でしか呼ばれない → 戻り先を覚えなくてよい → **フレームを積まなくてよい**
- 内側からしか呼ばれない → 呼ばれた時点で外側の変数はまだ生きている →
  **捕獲しなくてよい**

残るのは「引数を持つラベル」と「そこへの goto」です。それが join point と jump で、
**join point とは、末尾からしか呼ばれないと分かっている局所関数**のことです。

もう一度さっきの出力を、今度は1行ずつ。

```
join k (v : string) =          k は「答えが出たあとにすること」。
  let t.62 : string =          v はその答えが入る穴。
    ^("it is ", v)             継続は 1回だけ 書かれている。
  ret t.62
switch b.3 of
| true =>
    jump k ("yes")             枝は答えを渡して跳ぶ。呼ぶのではない。
| false =>
    jump k ("no")
```

`answer` に `join` が出なかったのは、そちらの `if` が末尾位置にあって、
**継続が空だった**からです。合流するものが何もないので、合流点も要りません。

## 4. 出どころ その1 — 値を求められている分岐

1節から3節の話が、コードでは9行です。

```ocaml
let with_join ty d f =
  match d with
  | Tail -> f Tail
  | Cont k ->
      let j = C.fresh_name "k" and v = C.fresh_name "v" in
      C.Join (j, [ (v, ty) ], k (C.AVar v) ty,
              f (Cont (fun a _ -> C.Tail (C.Jump (j, [ a ])))))
```

`d` は destination（[4章](04-core.md)の2節）で、`Tail` なら末尾位置、`Cont k` なら
「値をこう使え」。**末尾位置なら何もしません** — `answer` の場合です。そうでなければ
継続 `k` を1度だけ名前に付け、枝には「そこへ跳べ」という destination を渡します。

`if` と `case` の両方がこれを呼びます。`if` が `case` の書き方のひとつだからです
（[4章](04-core.md)の1節）。

## 5. 出どころ その2 — 決定木が同じ腕に何度も着く

こちらは[5章](05-matching.md)から来ます。腕が2つしかない例で足ります。

```sml
fun both (true, 1) = "yes"
  | both _         = "no"
```

```
let both : bool * int -> string = fn a1.22 : bool * int =>
  join arm () =
    ret "no"
  let p.57 : bool = #1 a1.22
  let p.58 : int = #2 a1.22
  switch p.57 of
  | true =>
      switch p.58 of
      | 1 =>
          ret "yes"
      | _ =>
          jump arm ()      ← 1列目は true、2列目が 1 でなかった
  | _ =>
      jump arm ()          ← 1列目が true でなかった
```

`"no"` にたどり着く道が**2本**あります。1列目で外れた道と、1列目は通ったが2列目で
外れた道です。腕は1つなのに、そこへ来る道が2本。これも合流点です。

3節の3条件は、ここでもそのまま成り立っています。腕の本体は値として持ち回されないし、
末尾からしか跳ばれないし、跳ぶ側は必ず内側にいます。だから同じものが使えます。

これは決定木の代償です。バックトラック法（Wadler 1987）なら本体は1回しか現れませんが、
そのかわり同じ値を何度も検査します。決定木は**検査の重複をなくすかわりに道が増える**。
join point は、増えた道が同じところへ着くことを複製せずに書く方法です。

腕を全部ラベルにするのが素直ですが、そうすると `case x of 1 => a | _ => b` が
引数ゼロのラベル2つになって読めなくなります。そこで**2回以上たどり着く腕だけ**を
ラベルにしました（[5章](05-matching.md)の7節）。上の出力で `"yes"` が `ret "yes"` と
直に書かれているのは、そこへの道が1本しかないからです。

つまり **ダンプに `join` が出ているところが、そのまま「共有が起きたところ」** です。

## 6. 1つの節点、2つの理由

4節と5節は違う理由で同じものを必要としました。片方は「継続を複製したくない」、
もう片方は「腕を複製したくない」。どちらも「合流点に名前を付けたい」なので、IR の
節点は1つです。

```ocaml
| Join of label * (string * Types.ty) list * block * block
| Jump of label * atom list
```

`Join (j, params, body, rest)` は「`rest` の中で `j` に跳べる」と読みます。`Jump` は
末尾形です — 跳んだら戻ってこないので、跳ぶのは末尾でしかありえません。

## 7. まとめ — 関数との違い

意味は局所関数と同じです。違うのは費用と、できないことです。

| | 局所関数 | join point |
|---|---|---|
| 自由変数 | 捕獲する（ヒープに確保） | そのまま。何も確保しない |
| 呼ぶ | フレームを積む（末尾なら積まない） | 制御が移るだけ |
| 値として | 持ち回せる。返せる。データ構造に入れられる | できない |
| クロージャ変換 | 変換する | 触らない |

一番下の行が、この区別が実装に現れるところです（[7章](07-closure.md)の2節）。

CPS ならこの区別は要りません。継続がふつうの関数で、そもそも末尾でない位置という
ものが存在しないからです。区別が要るのは ANF を選んだからで、その選択の理由は
[4章](04-core.md)の7節にあります。

そして3つ目の条件 —「定義したブロックの内側からしか跳ばれない」— は、この処理系が
join point を4節と5節の2箇所でしか作らないから成り立っています。どちらも
「分岐を包んで、その枝から跳ぶ」形なので、ラムダの境界をまたぐ join point は生まれ
ません。7章はその前提の上に立っています。

## 8. 機械での姿

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

**フレームには触りません。** `st.ks` は読まれも書かれもしていません。跳ぶのは goto で
あって呼び出しではない、が実装に見えているのはここです。

クロージャ変換を抜けたあとも、join point はコードブロックの外に出ていません。

```
$ skunk --dump-flat tests/join.sk
code inline$3 (a1.21) =
  let b.3 = a1.21
  join k (v) =
    let t.62 = ^("it is ", v)
    ret t.62
  switch b.3 of
  | true =>
      jump k ("yes")
  | false =>
      jump k ("no")
```

インタプリタなので定義時の環境を覚えていますが、それは同じ環境の共有であって複製では
ありません。コンパイラなら「同じスタックフレームの中のラベル」になります。Core の
束縛名が全部一意なので（[4章](04-core.md)の5節）、跳んだ先で見えている環境を使っても
同じことになります。

## していないこと

- **join point の引数を減らしません。** 全ての枝で同じ値を渡している引数は落とせますが、
  やっていません。
- **1回しか跳ばれない `with_join` の join point を展開しません。** 腕については
  5節でやっていますが、継続のほうはしていません。
- **ラムダをまたぐ join point を作りません。** 作らないので、そういうものが来たときの
  対処もありません（7節の最後）。
- **末尾呼び出しの join point 化をしません。** 相互再帰の末尾呼び出しはラベルに
  できますが、それは別の最適化です。

## 参考文献

- Luke Maurer, Paul Downen, Zena Ariola, Simon Peyton Jones, "Compiling without
  Continuations", *PLDI* 2017. GHC の join point。「join point とは、ラムダのうち
  末尾からしか呼ばれないと分かっているもの」— 3節はこの定式化です。
- Andrew Kennedy, "Compiling with Continuations, Continued", *ICFP* 2007.
  CPS を持たずに CPS の利益を得る話。join point はその中心。
- Cliff Click, Michael Paleczny, "A Simple Graph-Based Intermediate
  Representation", 1995. SSA の φ 節点。合流点に名前を付けるという同じ問題の、
  命令型側の答。join point の引数は φ です。
- Luc Maranget, "Compiling Pattern Matching to Good Decision Trees", 2008, §4。
  決定木が本体を共有する話（5節）。

## 実装の地図

| ファイル | 何が |
|---|---|
| `src/front/elab.ml` | `with_join`（4節）。`EIf`・`ECase` が呼ぶ |
| `src/front/patmat.ml` | `compile_case` の `joins`（5節）、`emit` の `TLeaf`（跳ぶか書き出すか） |
| `src/front/core.ml` / `src/front/flat.ml` | `Join`/`Jump`（6節）。Flat 側では型が落ちるだけで形は同じ |
| `src/front/closure.ml` | `conv` の `C.Join`。触らないことがコードに見える（[7章](07-closure.md)） |
| `src/interpreter/machine.ml` | `env.joins`、`F.Join`、`F.Jump`（8節） |

---

[← 5. パターンマッチを決定木にする](05-matching.md) ・ [7. クロージャ変換 →](07-closure.md)
