# 4. 双方向型検査と高階多相

`poly` システムは Dunfield と Krishnaswami の
"Complete and Easy Bidirectional Typechecking for Higher-Rank Polymorphism"
(ICFP 2013、以下 DK'13) の実装に、整数・真偽値・対・`let` の一般化を足したものです。
実装は [`lab/src/poly.ml`](../lab/src/poly.ml) の1ファイルです。

## 用語 — rank とは何か

**単型 (monotype)** は `forall` を含まない型です。`int`、`int -> bool`、`'a -> 'a`（`'a` が
束縛されていないなら単型の一部）。**多相型 (polytype / type scheme)** は `forall` を持つ型です。

**rank** は「`forall` が矢印の**左側**に何段入れ子になっているか」です。右側に何個あっても
rank は上がりません。

| rank | 型の例 | |
|---|---|---|
| 0 | `int -> bool` | 単型。`forall` なし |
| 1 | `forall 'a. 'a -> 'a` | `forall` が先頭だけ。**Hindley–Milner が推論できる範囲** |
| 1 | `forall 'a. 'a -> (forall 'b. 'b -> 'b)` | 右にいくつあっても rank 1（前に出せる） |
| 2 | `(forall 'a. 'a -> 'a) -> int * bool` | `forall` が矢印の**左**に1段 |
| 3 | `((forall 'a. 'a -> 'a) -> int) -> int` | 左に2段 |

rank-1 が特別なのは、**`forall` を全部型の先頭に集められる**ことです。だから「型スキームを
具体化して単型で扱い、最後に一般化する」という Hindley–Milner の手順が成立します。矢印の左に
`forall` があると、それを前に出すことができません——引数の位置に「どんな型でも受け取れる関数」
という要求が立ってしまい、単型では表せない。

そして **rank-2 以上の推論は決定不能**です（Wells 1999）。だから rank-N を扱う体系はどれも
「どこを書いてもらうか」を決めます。DK'13 の答えは**多相な引数の型は書いてもらう**、です。

この章で出てくる、rank に付随する語:

| | |
|---|---|
| 述語的 (predicative) | `â`（未確定変数）に代入できるのは**単型だけ**。多相型は入らない |
| 非述語的 (impredicative) | `â` に多相型も代入できる。表現力は上がるが推論はさらに難しくなる |
| 剛性変数 (rigid variable) | `forall` で束縛された変数。**何とも単一化しない**。「任意の型で成り立つ」を強制する側 |
| 未確定変数 (existential variable) | まだ決まっていない単型を表す穴。解かれる側。`â`、表示は `?n` |
| 反変 (contravariant) | 矢印の引数の位置。部分型の向きが逆になる |
| 共変 (covariant) | 矢印の結果の位置。部分型の向きがそのまま |

`â` を "existential variable" と呼ぶのは DK'13 の用語で、**存在型 (existential type) とは
無関係**です。意味は「未確定」だけです。

## 解きたい問題

Hindley–Milner（[3章](3-hm.md)の `hm`、[5章](5-rows.md)の `row`）が推論できるのは rank-1 の
多相、つまり `forall` が型の**先頭にしかない**型までです。これは推論できません。

```sml
val useTwice = fn f => (f 1, f true)
```

`f` を2つの型で使っているので、`f : forall 'a. 'a -> 'a` でなければなりません。すると
`useTwice` の型は `(forall 'a. 'a -> 'a) -> int * bool` で、`forall` が矢印の左に入ります
（rank-2）。この型を本体から推論する問題は決定不能です。

DK'13 の答えは「**推論をあきらめる場所を決める**」ことです。多相な引数の型は書いてもらう。
その代わり、書いてもらった型を**使う**ための機構を、単型の推論と同じ枠組みで与える。

```sml
val useTwice : (forall 'a. 'a -> 'a) -> int * bool = fn f => (f 1, f true)
```

## 2つのモード

双方向型検査には判断が2つあります。

| 判断 | 読み方 | 使うとき |
|---|---|---|
| `Γ ⊢ e ⇒ A ⊣ Δ` | e から型 A を**合成**する | 型が分かっていない式 |
| `Γ ⊢ e ⇐ A ⊣ Δ` | e を型 A に対して**検査**する | 期待される型が分かっている式 |

実装では `synth` と `check` です。注釈は「合成しかできない場所」を「検査できる場所」に変える
ものだと考えると、注釈の役割がはっきりします。

- `(e : A)` と `val x : A = e` は、`A` を持って `check` に入る。
- `fn x => e` を `A -> B` に対して検査するときは、`x : A` を仮定して本体を `B` に対して
  検査する。**このとき A が `forall` でも困りません**。これが rank-2 が通る理由です。
- 逆に `fn x => e` を注釈なしで合成するときは、引数の型を「まだ分からない単型」として立てる
  しかない。だから rank-2 は推論できない。

`check` の最後の規則が2つのモードをつなぎます。「検査せよと言われたが規則がない」なら、合成
してから部分型関係を確かめる。

```ocaml
| _ ->
    let ctx, s = synth ctx e in
    subtype e.loc ctx (apply ctx s) (apply ctx t)
```

## 順序付き文脈

DK'13 の鍵は文脈の作り方です。ふつうの型推論のように「変数から型への写像」ではなく、
**入った順に並んだ列**です。

```ocaml
type entry =
  | EVar of string          (* 型変数 α *)
  | ETerm of string * ty    (* x : A *)
  | EEx of int              (* â — 未確定変数（existential variable） *)
  | ESolved of int * ty     (* â = τ *)
  | EMark of int            (* ▶ — ここまで戻る、という目印 *)
```

`â`（実装では `TEx n`、表示は `?n`）は「まだ分かっていない単型」です。`forall` で束縛された
`α` とは別物で、また**存在型（existential type）とも無関係**です。DK'13 の呼び方が
"existential variable" なのでそう呼びますが、意味は「未確定」です。

順序が要る理由は**スコープ**です。`â` を型 τ で解くとき、τ が言及していい変数は
「â より前に導入されたもの」だけです。これが述語性（predicativity）を保ちます。

```ocaml
(* â を解くときの健全性検査：â より古い部分でだけ τ が組み立てられているか *)
let split_ex loc ctx n = ...   (* â の前と後ろに切る *)
```

もう1つ、判断がすべて文脈を**返す**ことも本質的です。`â` が解けたという情報は、返り値の
文脈に載って伝わります。可変参照も別の代入表もありません。答えを読むのは `apply` です。

```ocaml
let rec apply ctx t = ...   (* 文脈から解を読んで型に反映する *)
```

## 3つの判断

### 部分型付け `Γ ⊢ A <: B ⊣ Δ`

「A は B より多相である」。矢印は引数について反変、結果について共変です。

```ocaml
| TArrow (a1, a2), TArrow (b1, b2) ->
    let ctx = subtype loc ctx b1 a1 in
    subtype loc ctx (apply ctx a2) (apply ctx b2)
```

`forall` は左右で扱いが違い、ここが「多相の順序」の定義になります。

- 左が `forall α. A`：α を新しい `â` に置き換えて続ける。目印 ▶ を置いて、終わったらそこまで
  文脈を切り戻す。**より多相な型は、具体化して比べれば通る**。
- 右が `forall α. B`：新しい**剛性変数**（rigid variable、`EVar`）を導入して比べる。左側は
  それについて何も仮定できないので、「任意の型で成り立つ」ことが強制されます。

### 具体化 `Γ ⊢ â :=< A ⊣ Δ` と `Γ ⊢ A =<: â ⊣ Δ`

`â` を A の下（上）になるように解きます。実装では `instantiate_l` と `instantiate_r` で、
互いに鏡像です。中身は3種類しかありません。

1. **A が単型で â より前だけで書けている** → `â = A` として解く。
2. **A が別の未確定変数 β̂** → 古い方を残して新しい方を解く（`older_than` が決める）。
3. **A が矢印や対** → `â` を `â₁ -> â₂` の形に分解してから、成分ごとに続ける。矢印の
   引数側では左右が入れ替わります（反変だから）。

### 型付け

`synth`／`check` に加えて、DK'13 には**適用の判断** `Γ ⊢ A • e ⇒⇒ C ⊣ Δ` があります。
「型 A のものに e を適用したら何になるか」で、実装は `app_synth` です。

```ocaml
and app_synth loc ctx t arg =
  match t with
  | TForall (x, body) -> (* 先頭の forall を â で具体化してから続ける *)
  | TArrow (dom, cod) -> (* 引数を dom に対して検査し、cod を返す *)
  | TEx n -> (* â を â₁ -> â₂ に分解してから同じことをする *)
```

`forall` の行がいわゆる暗黙の具体化です。`id 3` と書けるのは、`id : forall 'a. 'a -> 'a` の
先頭の量化子がここで `â` に置き換わり、`â = int` と解かれるからです。

## 一般化 — 目印を使う

`let`（`val`）と、注釈のないラムダの合成では、最後に一般化します。方法は「目印 ▶ を置き、
検査が終わったら**目印より後ろに残った未解決の `â`**を `forall` に変える」です。

```ocaml
and generalize loc ctx mark t =
  let newer, older = split_mark ctx mark in
  let t = apply newer (apply older t) in
  let unsolved = (* newer の中で解かれなかった â *) in
  (* â を新しい型変数に置き換えて forall で包む *)
```

「目印より後ろ」が「この束縛の中で作られた」の意味になります。`hm` が環境の走査で、`row` が
レベル（整数）で同じことをするのに対し、こちらは文脈の位置でやります。**同じ判定を3つの
道具でしている**ので、並べて読むと一般化の本質（外から参照され得るか）が見えます——
その対応表は[9章](9-inference.md)にあります。

## `fun twice f x = f (f x)` を追う

`fun` なので再帰的です。手順はこうなります。

1. 目印 ▶ と `â_t` を置き、`twice : â_t` を仮定して本体を `â_t` に対して検査する（単型再帰）。
2. 本体は注釈のないラムダなので、`check` の規則に合わず合成に落ちる。合成は引数ごとに
   `â_f`、`â_x` を、結果に `â_r` を立て、`f (f x)` を `â_r` に対して検査する。
3. `f (f x)` の合成で `f : â_f` に適用が来るので、`app_synth` が `â_f = â₁ -> â₂` と分解する。
   内側の `f x` も同じ `â_f` を使うので、`â_x` が `â₁` に、`â₂` が `â₁` に順に解かれ、結局
   `â_f = â₁ -> â₁`、`â_r = â₁` になる。
4. ラムダの合成が終わり、目印より後ろに残った未解決は `â₁` だけ。これが `'a` になる。
5. `â_t` を得られた型に解いて、外側の一般化が `forall 'a.` を付ける。

```
$ mink examples/poly.mnk
twice : forall 'a. ('a -> 'a) -> 'a -> 'a = <fun>
```

`?n` が残った型が表示されたら、それは「検査器が最後まで決められなかった」という意味です。
通常は起きません（一般化で消えるか、エラーになる）。

## どこまで推論するか

| 書き方 | 結果 |
|---|---|
| `val id = fn x => x` | `forall 'a. 'a -> 'a` — 注釈不要 |
| `fun compose f g x = f (g x)` | `forall 'a 'b 'c. ('a -> 'c) -> ('b -> 'a) -> 'b -> 'c` |
| `val useTwice = fn f => (f 1, f true)` | 落ちる（rank-2 は推論しない） |
| `val useTwice : (forall 'a. 'a -> 'a) -> int * bool = ...` | 通る |
| `fun fact n = if n == 0 then 1 else n * fact (n - 1)` | `int -> int` — 単型再帰 |

失敗の様子も見ておきます。

```
$ mink tests/errors/rank2.mnk
tests/errors/rank2.mnk:4:32: type error: cannot make bool a subtype of int
```

桁 32 は `f true` の `true` です。`f 1` が `â_f` を `int -> ?` に解いてしまったので、次の
`true` が `int` に対して検査され、`bool <: int` を要求して落ちます。**注釈がないと最初の使用が
型を決めてしまう**、という失敗が位置つきで出ます。

## 意図的に入れていないもの

- **多相再帰。** `fun` は自分の型を単型の `â` として立てて検査します。注釈があっても
  多相再帰は通しません（DK'13 の範囲外）。
- **非述語的（impredicative）具体化。** `â` は単型しか受け取りません。`id id` は通りますが、
  それは `id` の型を具体化した結果が単型だからです。
- **型別名（`type`）。** `poly` では拒否します。行や篩と違い、多相の話に別名は要らないからです。
- **レコード・ヴァリアント・チャネル・依存型。** それぞれ担当システムのエラーになります。

## 発展 — 高階多相と双方向型検査の系譜

「注釈をどこまで減らせるか」の歴史です。

```
1972  System F (Girard)               多相λ計算。型の言語に forall が入る
1974  Reynolds                        独立に同じ体系。パラメトリシティ
1994  Kfoury–Wells                    rank-2 の推論は決定可能
1994  Wells                           System F の型推論は決定不能（rank-3 以上）
1996  Odersky–Läufer                  注釈を置く場所を決めて rank-N を通す
2003  MLF (Le Botlan–Rémy)            主要型を保つ多相の順序を設計する
2007  Peyton Jones ら                 実用的な arbitrary-rank 推論（GHC の基礎）
2013  Dunfield–Krishnaswami           順序付き文脈による完全で簡単な定式化 ← この章
2020  Quick Look (Serrano ら)         非述語的な具体化を実用的な範囲で
2021  Dunfield–Krishnaswami (survey)  双方向型検査の総説
```

**1994 の2つ**が分岐点です。System F 全体の推論は決定不能、しかし rank-2 なら決定可能——
つまり「どこまでを推論に任せ、どこから注釈を要求するか」は設計の問題になりました。

**1996 と 2007** は「注釈のある場所では注釈を使う」路線を実用に持っていった仕事で、GHC の
`RankNTypes` はこの系譜です。**2013 の DK'13**（この章）はそれを最小の道具立てで書き直したもので、
順序付き文脈と3つの判断（部分型・具体化・型付け）しか使いません。**健全かつ完全**であることが
証明されていて、しかも実装が数百行で済む——教材としてこれが選ばれる理由です。

**2003 の MLF** は別の答えです。注釈を要求する代わりに型の言語を拡張し（束縛付き量化）、
多相の順序そのものを設計して主要型を保ちます。強力ですが型が読みにくくなり、主流には
なりませんでした。

**2020 の Quick Look** は、述語性の制限（`â` が単型しか受け取らない、この章の
`instantiate_l` の制限）を実用的な範囲で外す提案です。GHC 9 系に入っています。MinkML の
`poly` は述語的なままなので、`id id` が通るのは「具体化の結果が単型だから」であって、
非述語的な具体化をしているのではありません。

双方向型検査そのものは、この章より広い道具です。2021 年の総説は、依存型（[8章](8-dep.md)）・
篩型（[6章](6-refine.md)）・部分型付けまで含めて「合成と検査の2モード」がどこで使われているかを
まとめています。**MinkML で `poly`・`refine`・`dep` の3つが双方向なのは偶然ではありません。**

## 参考文献

- J. Dunfield, N. R. Krishnaswami, [*Complete and Easy Bidirectional Typechecking for
  Higher-Rank Polymorphism*][dk13], ICFP 2013。この章の実装元。順序付き文脈、`â`、目印、
  そして4つの判断（`⇐` `⇒` `<:` `•`）はこの論文の図そのままです。
- J. B. Wells, [*Typability and type checking in System F are equivalent and
  undecidable*][wells], Annals of Pure and Applied Logic 98, 1999。rank-2 以上の推論が
  決定不能であること。「推論をあきらめる場所を決める」の根拠です。
- D. Le Botlan, D. Rémy, [*MLF: raising ML to the power of System F*][mlf], ICFP 2003。
  別の答え——注釈を型の中に持ち込んで、非述語的な多相まで推論する道。こちらは採っていません。

- J. C. Reynolds, *Towards a theory of type structure*, Programming Symposium 1974。
  System F の独立な発見。
- A. J. Kfoury, J. B. Wells, *A direct algorithm for type inference in the rank-2 fragment of
  the second-order λ-calculus*, LFP 1994。rank-2 は決定可能という側。
- M. Odersky, K. Läufer, *Putting type annotations to work*, POPL 1996。
  注釈の置き場所を決める路線の起点。
- S. Peyton Jones, D. Vytiniotis, S. Weirich, M. Shields,
  *Practical type inference for arbitrary-rank types*, JFP 17(1), 2007。GHC の基礎。
- A. Serrano, J. Hage, S. Peyton Jones, D. Vytiniotis, *A quick look at impredicativity*,
  ICFP 2020。非述語性を実用的な範囲で入れる。
- J. Dunfield, N. R. Krishnaswami, *Bidirectional typing*, ACM Computing Surveys 54(5), 2021。
  双方向型検査の総説。どの型システムでどう使われているかの地図。

[dk13]: https://doi.org/10.1145/2500365.2500582
[wells]: https://doi.org/10.1016/S0168-0072(98)00047-5
[mlf]: https://doi.org/10.1145/944705.944709
