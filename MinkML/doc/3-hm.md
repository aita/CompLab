# 3. Hindley–Milner と Algorithm W

`hm` システムは、他の4つが変奏している主題そのものです。**注釈をひとつも書かずに、書ける
プログラムすべてに主要型（principal type）を付ける**——その範囲を確認するための基準線です。

実装は [`lab/src/hm.ml`](../lab/src/hm.ml) で、**紙の上の Algorithm W をそのまま**書いてあります。
効率的な書き方（[5章](5-rows.md)の `row`）とは意図的に別物です。

```
$ mink examples/hm.mnk
id : forall 'a. 'a -> 'a = <fun>
twice : forall 'a. ('a -> 'a) -> 'a -> 'a = <fun>
compose : forall 'a 'b 'c. ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b = <fun>
usedTwice : int * bool = (1, true)
```

## 用語 — 置換・単一化・主要型

**置換 (substitution)** は型変数から型への有限写像です。`[?1 := int, ?2 := bool -> ?3]` のように
書き、型に**適用 (apply)** すると変数がその像に置き換わります。2つの置換 `s1`・`s2` の
**合成 (composition)** `s2 ∘ s1` は「`s1` を適用してから `s2` を適用する」のと同じ1つの置換です。
Algorithm W が持ち回るのはこれで、破壊的な代入は使いません。

**単一化 (unification)** は2つの型を等しくする置換を求めることです。求まる置換のうち
「余計な決定をしていない」もの——**最汎単一化子 (most general unifier, mgu)**——が一意に存在
することが Robinson の結果で、そのおかげで HM は**主要型 (principal type)** を出せます:
推論した型は、その項が持ちうる型のうち最も一般的なものです。

**出現検査 (occurs check)** は `?1` と `?1 -> int` の単一化を止めます。これを省くと無限の型が
できます。

**単型 (monotype)** は `forall` を含まない型、**型スキーム (type scheme)** は
`forall 'a … . τ` です。環境に入るのはスキームで、**一般化 (generalization)** が単型を
スキームにし（`let` の境目）、**具体化 (instantiation)** がスキームを単型に開きます（変数を
使うたび）。同じ束縛を2つの型で使えるのはこれのおかげで、**let 多相**と呼びます。

| | |
|---|---|
| 置換 | 型変数 → 型の有限写像。`apply` で効かせ、`compose` で繋ぐ |
| mgu | 余計な決定をしない単一化子。一意に存在する |
| 主要型 | その項が持ちうる型のうち最も一般的なもの |
| 一般化 | 単型 → スキーム。ここでは `ftv(型) \ ftv(環境)` で判定する |
| 具体化 | スキーム → 単型。量化変数を新しい単一化変数に開く |

**rank-1** は「`forall` が型の先頭にしかない」ことです。HM の型スキームはこれだけで、
`(forall 'a. 'a -> 'a) -> …` のような rank-2 は型の文法に入りません（[4章](4-poly.md)）。

## 型・スキーム・置換

型に量化子はありません。量化するのは**スキーム**で、それは `let` と（トップレベルの）束縛
だけが作ります。これが「let 多相」の意味です。

```ocaml
type ty =
  | TCon of string          (* int, bool, unit と注釈由来の剛性名 *)
  | TVar of string          (* 単一化変数 *)
  | TArrow of ty * ty
  | TPair of ty * ty

type scheme = Forall of string list * ty
```

そして Algorithm W の性格を決めているのが**置換（substitution）**です。型変数から型への
有限写像で、単一化はそれを**返します**。破壊的な代入はどこにもありません。

```ocaml
type subst = ty Map.t

let rec apply (s : subst) t = ...          (* 置換を型に適用する *)
let compose (s2 : subst) (s1 : subst) = ...  (* s1 のあとに s2 *)
```

`compose s2 s1` は「s1 を適用してから s2 を適用する」のと同じ置換です。**この合成を正しい
順序で、正しい場所に挟むことがコードのほとんど**で、忘れるのが古典的な間違いです。

## 単一化

2つの型を等しくする置換を返します。返す、というのがここでの要点です。

```ocaml
let rec unify loc t1 t2 : subst =
  match (t1, t2) with
  | TCon a, TCon b when a = b -> empty_subst
  | TVar a, TVar b when a = b -> empty_subst
  | TVar a, t | t, TVar a ->
      if Vars.mem a (ftv t) then (* 出現検査 *) ...;
      Map.singleton a t
  | TArrow (a1, b1), TArrow (a2, b2) ->
      let s1 = unify loc a1 a2 in
      let s2 = unify loc (apply s1 b1) (apply s1 b2) in   (* s1 を挟む *)
      compose s2 s1
  | _ -> (* 失敗 *)
```

矢印の場合で、右の成分を単一化する前に **`s1` を適用している**のが本質です。左の成分から
得た情報を右に持ち込まないと、`?1 -> ?1` と `int -> bool` が通ってしまいます。

出現検査（occurs check）は `?1 = ?1 -> ?1` のような無限の型を止めます。

## 一般化 — 環境を走査する

型変数を量化してよいのは、それが**環境に現れていない**ときです。環境に現れているなら、外側の
誰かがまだその変数を決められる立場にあるので、勝手に量化してはいけません。

```ocaml
let generalize (env : env) t =
  Forall (Vars.elements (Vars.diff (ftv t) (ftv_env env)), t)
```

`ftv_env` が環境全体を走ります。**`let` ごとに環境を全部見る**のがこの方式の代償で、これを
避けるために発明されたのがレベルです（[5章](5-rows.md)）。

具体化（instantiate）は逆向きで、スキームの量化変数を新しい単一化変数に置き換えます。だから
同じスキームを2回使えば別の型として使えます。

## Algorithm W を読む

```ocaml
let rec infer st env e : subst * ty =
  match e.it with
  | Ast.Var x -> (empty_subst, instantiate (lookup x env))
  | Ast.App (f, a) ->
      let s1, tf = infer st env f in
      let s2, ta = infer st (apply_env s1 env) a in     (* s1 を環境に効かせる *)
      let res = fresh () in
      let s3 = unify e.loc (apply s2 tf) (TArrow (ta, res)) in
      (compose s3 (compose s2 s1), apply s3 res)
  | Ast.LetIn (d, body) ->
      let s1, env' = bind_decl st env d in              (* 右辺を推論して一般化 *)
      let s2, t = infer st env' body in
      (compose s2 s1, t)
```

`App` の3行が Algorithm W の教科書的な姿です。関数を推論し、**その結果を環境に適用してから**
引数を推論し、新しい変数 `res` を立てて「関数型であること」を単一化で要求する。

## 動くところを見る

`--dump-infer` を付けると、単一化・解決・具体化・一般化がすべて出ます。`fun twice f x = f (f x)`
の場合はこうです。

```
$ mink --dump-infer tests/infer.mnk
-- infer twice
  unify  ?2  ~  ?3 -> ?4
  solve  ?2 := ?3 -> ?4
  unify  ?3 -> ?4  ~  ?4 -> ?5
  unify  ?3  ~  ?4
  solve  ?3 := ?4
  unify  ?4  ~  ?5
  solve  ?4 := ?5
  unify  ?1  ~  (?5 -> ?5) -> ?5 -> ?5
  solve  ?1 := (?5 -> ?5) -> ?5 -> ?5
  generalise (?5 -> ?5) -> ?5 -> ?5  over env {}  =>  forall 'a. ('a -> 'a) -> 'a -> 'a
```

読み方はこうです。`f : ?2`、`x : ?3` として本体に入り、

1. 内側の `f x` が「`?2` は `?3` から何かへの関数」を要求して `?2 := ?3 -> ?4`。
2. 外側の `f (...)` が同じ `f` を使うので、`?3 -> ?4` と `?4 -> ?5` を単一化する。ここで
   `?3 := ?4`、`?4 := ?5` と繋がり、**引数と結果が同じ型に潰れる**。
3. `fun` は再帰的なので、最初に立てた自分の型 `?1` を得られた型と単一化する。
4. 環境に自由変数がないので `?5` が量化され、`forall 'a. ('a -> 'a) -> 'a -> 'a`。

let 多相も見えます。

```
-- infer usedTwice
-- infer same
  generalise ?6 -> ?6  over env {}  =>  forall 'a. 'a -> 'a
  instantiate forall 'a. 'a -> 'a  as  ?7 -> ?7
  unify  ?7 -> ?7  ~  int -> ?8
  ...
  instantiate forall 'a. 'a -> 'a  as  ?9 -> ?9
  unify  ?9 -> ?9  ~  bool -> ?10
```

`same` が一般化され、2つの使用でそれぞれ別の変数に具体化されています。これが

```sml
val usedTwice = let val same = fn x => x in (same 1, same true) end
```

を通す仕組みで、**`let` でなければ通りません**。

## 限界 — ラムダ束縛は一般化されない

同じ本体を、引数として受け取った関数で書くと落ちます。

```
$ mink tests/errors/monomorphic.mnk
errors/monomorphic.mnk:6:25: type error: cannot unify int with bool
```

`fn f => (f 1, f true)` の `f` は単一化変数1つなので、`f 1` が `int -> ?` に決め、`f true` が
矛盾します。**HM にはこれを書く型が存在しません**——`f` に与えたい型 `forall 'a. 'a -> 'a` は
矢印の左に量化子を持つ rank-2 で、HM の型の文法に入らないからです。

`poly` システムはそこを注釈で埋めます（[4章](4-poly.md)）。同じプログラムに対する2つの
システムの反応を並べると、境界がはっきりします。

| | `hm` | `poly` |
|---|---|---|
| `fn g => (g 1, g true)` | 落ちる（型が存在しない） | 落ちる（推論しない） |
| `val f : (forall 'a. 'a -> 'a) -> int * bool = fn g => (g 1, g true)` | 落ちる（注釈が効かない） | 通る |

2行目の `hm` の挙動には理由があります。`read_ty` は `forall` を**読み飛ばし**、残った `'a` を
剛性の定数として読みます。だから注釈は「`('a -> 'a) -> int * bool`（`'a` は何か1つの型）」に
なり、`g 1` が `'a` を `int` に合わせようとした時点で失敗します。

```
$ mink /tmp/hm2.mnk
/tmp/hm2.mnk:2:61: type error: cannot unify int with bool
```

**HM では、この型を書く場所がないのではなく、書いても意味が変わってしまう**——これが
rank-2 を「注釈で受け取る」ために双方向型検査が必要になる理由です。

## 意図的に入れていないもの

- **値制限（value restriction）。** 参照も可変性もないので要りません。副作用のある言語で
  `let` 多相を安全に保つための制限で、ここには危険がありません。
- **多相再帰。** `fun` は自分の名前を単型として持ちます。注釈があっても通しません。
- **レコード・ヴァリアント。** `row` の担当です。`hm` は関数・対・基底型だけの、いちばん
  素の HM です。
- **効率。** 置換の合成と環境走査を素直にやるので、深い `let` の入れ子では `row` より遅く
  なります。それが次章の主題です。

## 参考文献

- R. Milner, [*A theory of type polymorphism in programming*][milner78], JCSS 17(3), 1978。
  Algorithm W の原型と、let 多相。
- L. Damas, R. Milner, [*Principal type-schemes for functional programs*][dm82], POPL 1982。
  この章が写した提示。W の健全性と完全性、主要型の存在。
- J. A. Robinson, [*A machine-oriented logic based on the resolution principle*][robinson],
  JACM 12(1), 1965。単一化と最汎単一化子。
- D. Rémy, [*Extension of ML type system with a sorted equational theory on types*][remy],
  INRIA RR-1766, 1992。環境走査をレベルに置き換える方。実装は[5章](5-rows.md)にあります。
- O. Kiselyov, [*Efficient and Insightful Generalization*][oleg]、2013。レベル方式の解説として
  読みやすく、この章との対応が付けやすい。

[milner78]: https://doi.org/10.1016/0022-0000(78)90014-4
[dm82]: https://doi.org/10.1145/582153.582176
[robinson]: https://doi.org/10.1145/321250.321253
[remy]: https://hal.inria.fr/inria-00077006
[oleg]: https://okmij.org/ftp/ML/generalization.html
