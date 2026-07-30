# 8. 依存型と NbE

`dep` システムには**型と項の区別がありません**。`(n : nat) -> vec a n` は他の項と同じ項で、
`Type` はその型です。だから型検査は「型を比べる」ために**項を走らせる**必要があります。
実装は [`lab/src/dep.ml`](../lab/src/dep.ml) です。

このシステムだけ、検査のあとに実行しません。正規化することが実行することなので、出力の
右辺は値ではなく**正規形**です。

```
$ mink examples/dep.mnk
plus : nat -> nat -> nat = fn n => fn m => natrec (fn _ => nat) m (fn _ => fn r => suc r) n
seven : nat = 7
leftUnit : (n : nat) -> Eq nat (plus 0 n) n = fn n => refl nat n
```

## 用語

### Curry–Howard 対応

この章で「型」と「命題」、「項」と「証明」が同じ言葉で語られるのは、それが同じものだからです。

| 論理 | 型 |
|---|---|
| 命題 | 型 |
| 証明 | その型を持つ項 |
| `A ⟹ B` | `A -> B` |
| `A ∧ B` | `A * B` |
| `∀x:A. P(x)` | 依存関数型 `(x : A) -> P x` |
| `∃x:A. P(x)` | 依存直積 `(x : A) * P x` |

だから `rightUnit : (n : nat) -> Eq nat (plus n 0) n` は「すべての `n` について `plus n 0 = n`」
という**命題**で、その型を持つ項が**証明**です。そして「停止しない定義を許すと何でも証明できて
しまう」という下の注意が意味を持ちます——嘘の証明が作れる、ということです。

依存型の2つの型を、論理の言葉と対応させて呼びます。

| | 名前 | 読み |
|---|---|---|
| `(x : A) -> B` | **Π型**（依存関数型） | 結果の型が引数の値に依存できる関数 |
| `(x : A) * B` | **Σ型**（依存直積） | 第2成分の型が第1成分の値に依存できる対 |

`B` が `x` を使わなければ、Π型は `A -> B`、Σ型は `A * B` に戻ります。**ふつうの矢印と対は、
依存版の特別な場合**です。

### 定義的等値と命題的等値

この章の中心にある区別です。

| | 何か | 誰が決めるか |
|---|---|---|
| **定義的等値** (definitional / judgmental equality) | 計算して同じ形になる | **型検査器**が自動で判定する（`conv`） |
| **命題的等値** (propositional equality) | 等式を主張する**型** `Eq A a b` | **人**が証明項を書く。使うのは除去子 `J` |

`plus 0 n` と `n` は定義的に等しいので `refl` だけで済みます。`plus n 0` と `n` は定義的には
等しくない（`n` が変数だと計算が詰まる）ので、命題的等値を帰納法で証明することになります。
「`plus 0 n` と `plus n 0` — 証明の非対称」の節が全部この差の話です。

定義的等値を判定する手続きを **変換検査 (conversion checking)** と呼び、この処理系ではそれを
NbE でやります。含めているのは β（適用の計算）、除去子の計算、そして **η**（`fn x => f x` と
`f` を同じとみなす）です。

### そのほか

| | |
|---|---|
| **宇宙 (universe)** | 型の型。`Type : Type 1 : Type 2 : ...` |
| **Girard のパラドックス** | `Type : Type` にすると矛盾が導けるという結果。だから階層が要る |
| **除去子 (eliminator)** | その型の値を「使う」唯一の方法。`nat` には `natrec`、`Eq` には `J`。パターンマッチのかわり |
| **動機 (motive)** | 除去子に渡す「結果の型が引数によってどう変わるか」を言う関数 |
| **中性値 (neutral)** | 自由変数に当たって計算が止まった値。`x`、`f x`、`natrec ... x` |
| **α 変換** | 束縛変数の名前替え。de Bruijn レベルで名前を使わないので問題にならない |
| **de Bruijn レベル** | 変数を「外側から数えた深さ」で表す方式。`conv` の `lvl` がこれ |
| **エラボレーション** | 書かれた構文を、検査済みの核言語の項に翻訳すること |

**NbE (normalization by evaluation)** の名前は手順そのものです——正規化 (normalization) を、
構文の書き換えではなく**評価 (evaluation) して読み戻す**ことで行う。`eval` で意味的な値にし、
`quote` で構文に戻します。代入が現れないのが利点です。

## 何が入っているか

- **宇宙（universe）の階層** `Type`、`Type 1`、… — 「型の型」です。`Type : Type 1` で、
  `Type : Type` にはしていません（それは矛盾するので）。
- **依存関数型** `(x : A) -> B`（Π型）と**依存直積** `(x : A) * B`（Σ型）。
- **自然数** `nat` と、その除去子 `natrec`。
- **単位型** `unit` とその値 `tt`。
- **命題的等式** `Eq A a b` と `refl`、そして除去子 `J`。

これだけで、プログラムについて主張を述べて証明することができ、添字付きの族も作れます。

## 変換検査を NbE でやる

`(x : A) -> B` と `(x : A') -> B'` が同じ型かを判定するには、`A` と `A'` を同じかどうか
比べる必要があります。依存型では `A` が計算を含むので、単なる構文の一致では足りません。

素朴には「構文に代入して正規化する」ことになりますが、代入は捕獲の回避が面倒で、繰り返すと
遅いです。**NbE（normalization by evaluation）**はそれを避けます。

1. 項を**意味的な値**へ評価する。関数は OCaml のクロージャになる。
2. 値の上で比較する（`conv`）。
3. 表示や型注釈のために、値を構文へ**読み戻す**（`quote`）。

```ocaml
type value =
  | VUniv of int
  | VPi of string * value * closure     (* 引数の型と、結果を計算するクロージャ *)
  | VLam of string * closure
  | VSigma of string * value * closure
  | VPair of value * value
  | VNat | VZero | VSuc of value
  | VUnit | VTT
  | VEq of value * value * value
  | VRefl of value * value
  | VNeutral of neutral                 (* 変数で詰まったもの *)
```

`closure` は「環境＋本体の構文」です。適用は環境を伸ばして本体を評価するだけで、代入は
どこにも現れません。

```ocaml
and inst (c : closure) (v : value) = eval ((c.cvar, v) :: c.cenv) c.cbody
```

### 中性値 — 詰まった計算

自由変数に当たって計算が進まなくなったものが**中性値（neutral）**です。

```ocaml
and neutral =
  | NVar of int * string    (* 剛性変数。int はレベル *)
  | NApp of neutral * value
  | NFst of neutral | NSnd of neutral
  | NNatRec of value * value * value * neutral
  | NJ of value * value * value * value * value * neutral
```

除去子はそれぞれ「計算できるなら計算し、できないなら中性値を作る」関数を持ちます。これが
この体系の動的意味論の全部です。

```ocaml
and do_natrec m z s n =
  match n with
  | VZero -> z
  | VSuc k -> apply (apply s k) (do_natrec m z s k)
  | VNeutral nu -> VNeutral (NNatRec (m, z, s, nu))
```

`J` が計算するのは証明が `refl` のときだけです。**この1行が、等式の証明を「型が付くだけの
もの」から「使えるもの」に変えています**。

```ocaml
and do_j a x m base y p =
  match p with
  | VRefl _ -> base
  | VNeutral n -> VNeutral (NJ (a, x, m, base, y, n))
```

### 変換検査とレベル

`conv` は2つの値を比べます。関数どうしは**新しい剛性変数を適用して**比べます。これで
η 同値が自動的に入ります。

```ocaml
| VLam (x, c1), VLam (_, c2) ->
    let v = VNeutral (NVar (lvl, x)) in
    conv (lvl + 1) (inst c1 v) (inst c2 v)
| VLam (x, c), other | other, VLam (x, c) ->
    (* η: fn x => f x と f を同じとみなす *)
    let v = VNeutral (NVar (lvl, x)) in
    conv (lvl + 1) (inst c v) (apply other v)
```

`lvl` は「いま何個の剛性変数があるか」で、新しい変数の名前の代わりです（de Bruijn
レベル）。名前ではなくレベルで比べるので、α 変換は問題になりません。対にも η を入れて
あります。

## `plus 0 n` と `plus n 0` — 証明の非対称

```sml
val plus : nat -> nat -> nat =
  fn n => fn m => natrec (fn _ => nat) m (fn _ => fn r => suc r) n
```

`plus` は第1引数について再帰します。だから

```sml
val leftUnit : (n : nat) -> Eq nat (plus 0 n) n = fn n => refl nat n
```

は `refl` だけで通ります。`plus 0 n` を評価すると `natrec` の `VZero` の枝に入り、`n` そのもの
になるからです。**定義的に等しい**ので、証明は要りません。

逆側はそうなりません。`plus n 0` は `n` が変数なので `natrec` が中性値のまま詰まります。
だから帰納法が必要です。

```sml
val rightUnit : (n : nat) -> Eq nat (plus n 0) n =
  fn n =>
    natrec
      (fn k => Eq nat (plus k 0) k)          (* 動機（motive）が等式そのもの *)
      (refl nat 0)                            (* 0 の場合 *)
      (fn k => fn ih =>                       (* k の証明から suc k の証明へ *)
        J nat (plus k 0)
          (fn y => fn _ => Eq nat (suc (plus k 0)) (suc y))
          (refl nat (suc (plus k 0)))
          k ih)
      n
```

`natrec` の動機が命題になっている——これが**依存型で帰納法が特別な機構でない**理由です。
再帰と帰納法が同じ除去子です。

## 動機の宇宙は決め打ちにできない

`natrec` の動機は `nat -> Type i` の形をしていますが、`i` は場合によります。値を作る
`plus` では `nat -> Type 0`、型を作る `vec` では `nat -> Type 1` です。

```sml
val vec : Type -> nat -> Type =
  fn a => fn n => natrec (fn _ => Type) unit (fn _ => fn rest => a * rest) n
```

だから実装では動機を**検査せずに合成し**、形だけ確かめています。

```ocaml
let m', mty = infer_family ctx m [ VNat ] in
(match mty with
| VPi (_, VNat, cod) -> (
    match inst cod (VNeutral (NVar (ctx.lvl, "n"))) with
    | VUniv _ -> ()      (* どの宇宙でもよい *)
    | other -> (* エラー *))
```

`infer_family` は「動機の引数の型は除去子が知っているのだから、注釈がなくても埋めてよい」
という小さな仕掛けです。これがないと `natrec (fn (_ : nat) => nat) ...` と書かねばならず、
例が読みにくくなります。

## 添字付きの族を、添字付きデータなしで

`vec a n` は `natrec` で `Type` へ再帰して作った型です。長さ 0 なら `unit`、長さ n+1 なら
`a * (残り)`。つまり**入れ子の対**です。

```
empty : vec nat 0 = tt
digits : vec nat 3 = (1, (2, (3, tt)))
```

そして `head` の型が、全域的な `head` に必要なものを言います。

```sml
val head : (a : Type) -> (n : nat) -> vec a (suc n) -> a =
  fn a => fn n => fn v => fst v
```

`vec a 0` は `unit` なので、空ベクトルは渡せません。

```
$ mink tests/errors/headOfEmpty.mnk
tests/errors/headOfEmpty.mnk:6:22: type error: this has type unit, but nat * unit was expected
```

`vec nat (suc 0)` を正規化すると `nat * unit` になり、`tt : unit` が合わない——という
説明がそのままエラーになっています。**添字付きデータ型（inductive family）を実装せずに、
長さつきベクタが得られている**のがこの章の見どころです。

## 型の表示について

正規形はすべての定義を展開します。値としてはそれが正しいのですが、型としては読めません
（`plus` についての主張が `natrec` の塊になる）。そこで**注釈のある宣言は、注釈を
エラボレートしたものを型として表示します**——正規化はしません。

```
rightUnit : (n : nat) -> Eq nat (plus n 0) n = fn n => natrec (fn k => Eq nat (natrec ...
```

左が読める形、右が本物の証明項です。

## 意図的に入れていないもの

- **再帰。** `fun` は自分の名前を束縛しません。停止しない定義を許すと、何でも「証明」
  できてしまいます。構造的再帰は `natrec` を通します。

  ```
  $ mink tests/errors/recursion.mnk
  tests/errors/recursion.mnk:4:28: type error: loop cannot call itself: the `dep` system
  has no recursion, because a definition that never finishes would prove anything.
  Recur with natrec instead
  ```

- **宇宙の累積性（cumulativity）と宇宙多相。** `Type 0` の型は `Type 1` の型として通り
  ません。宇宙のレベルは書かれたものだけで、単一化しません。
- **暗黙引数とメタ変数。** `id nat 3` の `nat` は書く必要があります。メタ変数がないので、
  穴（hole）を置いて推論させることもできません。
- **添字付き帰納型。** `nat` と `Eq` だけが組み込みで、`data` 宣言はありません。上のように
  `natrec` で族を作るのが代わりです。
- **停止性検査。** 再帰がないので要りません。

## 発展 — 依存型と NbE の系譜

依存型の理論と、その型検査を実際に動かす技術は、別々に育って NbE で出会いました。

### 理論の側

```
1967  de Bruijn (AUTOMATH)       依存型を持つ最初の証明チェッカ
1972  Martin-Löf                 直観主義型理論。Π・Σ・等式
1984  Martin-Löf (Bibliopolis)   この章が写した体系の標準的な提示
1988  Coquand–Huet               Calculus of Constructions。Coq の土台
1994  Dybjer                     帰納族（inductive families）。Vec を直接書く道
2013  Univalent Foundations      等式を空間として見る（HoTT）
2018  Cohen ら                   Cubical 型理論。等式の計算的な扱い
```

MinkML の `dep` は **1984年の体系の小さな部分**です。Π・Σ・`nat`・`Eq`・宇宙だけで、
帰納族はありません。だから `vec` を大きな除去（large elimination）で作っています
——**1994 の Dybjer 以降の言語（Agda、Coq、Idris、Lean）なら `data Vec` と書けます**。

`Eq` と `J` については、この章の選択が古い方だと知っておく価値があります。`refl` と `J` は
Martin-Löf の等式で、「等しさの証明は1つしかない」（UIP）を仮定するかどうかで分かれます。
**2013 以降の HoTT / Cubical** は仮定しない方向へ行き、等式を空間として扱います。関数の外延性
（`f = g` を各点の等式から導く）が MinkML で証明できないのは、この選択の帰結です。

### 実装の側

```
1991  Berger–Schwichtenberg      NbE。評価してから読み戻す
1996  Coquand                    依存型の型検査アルゴリズム（意味論的な変換検査）
2005+ Abel ら                    NbE で依存型・宇宙・非述語性を扱う
2010s Agda / Idris / Lean        メタ変数・暗黙引数・単一化を備えた実装
2019+ Kovács (elaboration zoo)   その実装を段階ごとに読める形にしたもの
```

**代入の代わりに評価する**という発想が NbE で、この章の `eval`/`quote`/`conv` はその最小形です。
素朴な実装は型を比べるたびに構文へ代入して正規化しますが、それは遅く、捕獲の回避が面倒です。
NbE はクロージャを使うことで両方を避けます。

`dep` に足りていないものは、そのまま **elaboration zoo が段ごとに足していくもの**です:
メタ変数（穴 `_` を置いて推論させる）、暗黙引数（`id 3` と書ける）、パターン単一化、
宇宙多相、そして停止性検査。**MinkML の `dep` はその第0段で、依存型の骨格だけを見るための
大きさに留めてあります。**

## 参考文献

- P. Martin-Löf, *Intuitionistic type theory*, Bibliopolis 1984。Π・Σ・`nat`・`Eq` と、
  それぞれの除去子。この章が実装している体系の出どころ。
- J.-Y. Girard, *Interprétation fonctionnelle et élimination des coupures*, 1972。
  `Type : Type` から矛盾が出ること（Girard のパラドックス）。宇宙に階層がある理由。
- U. Berger, H. Schwichtenberg, [*An inverse of the evaluation functional for typed
  λ-calculus*][nbe], LICS 1991。NbE。`eval` と `quote` の対。
- A. Abel, [*Normalization by evaluation: dependent types and impredicativity*][abel13],
  Habilitationsschrift 2013。依存型に対する NbE と変換検査の、いま使われている形。
- A. Kovács, [*Elaboration zoo*][zoo]。メタ変数・暗黙引数・単一化まで含めた実装の見本。
  この章が「入れていない」ものが、そこにあります。

- N. G. de Bruijn, *AUTOMATH, a language for mathematics*, 1968。
  依存型を持つ最初の実装。
- T. Coquand, G. Huet, *The calculus of constructions*, Information and Computation 76(2-3), 1988。
- P. Dybjer, *Inductive families*, Formal Aspects of Computing 6(4), 1994。
  `vec` を大きな除去で作らずに済ませる道。
- T. Coquand, *An algorithm for type-checking dependent types*,
  Science of Computer Programming 26(1-3), 1996。意味論的な変換検査。
- C. Cohen, T. Coquand, S. Huber, A. Mörtberg, *Cubical type theory: a constructive
  interpretation of the univalence axiom*, TYPES 2015 / 2018。等式のもう一つの道。

[nbe]: https://doi.org/10.1109/LICS.1991.151645
[abel13]: https://www.cse.chalmers.se/~abela/habil.pdf
[zoo]: https://github.com/AndrasKovacs/elaboration-zoo
