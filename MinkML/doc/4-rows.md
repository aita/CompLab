# 4. 行多相

`row` システムは Hindley–Milner の完全推論に**行（row）**を足したものです。レコードと
ヴァリアントが構造的になり、「`x` を持つ何か」という型が書けるようになります。実装は
[`lab/src/row.ml`](../lab/src/row.ml) です。

```
$ mink examples/rows.mnk
getX : { x : 'a, ..'b } -> 'a = <fun>
shiftX : { x : int, ..'a } -> int -> { x : int, ..'a } = <fun>
describe : [ `Int : int, `Bool : bool, `Pair : { x : int, ..'a } ] -> int = <fun>
count : [ `Some : int, ..'a ] -> int = <fun>
```

`..'b` が行変数です。「他に何のフィールドがあってもよい」を型が言っている状態で、これが
注釈なしに推論されます。

## 用語 — Hindley–Milner とは何か

このシステムの土台は Hindley–Milner（HM）で、行はその上の追加です。HM の道具は3つです。

**単一化 (unification)。** 2つの型を「等しくなるように変数を決める」操作です。`'a -> int` と
`bool -> 'b` を単一化すると `'a = bool`、`'b = int`。結果は**最汎単一化子 (most general
unifier)** ——余計な決定をしない、一番緩い解——であることが保証されます。だから HM は
**主要型 (principal type)** を出せます: 推論した型は、その項が持ちうる型のうち最も一般的なもの
です。

実装は変数を可変参照にして、解けたら相手を指す（**破壊的リンク**）方式です。`force`（別名
`find`）がリンクを辿る union-find の `find` に当たります。

**出現検査 (occurs check)。** `'a` と `'a -> int` を単一化しようとすると無限型ができるので、
「左辺の変数が右辺に現れないか」を先に見ます。行にも必要で、`occurs_rvar` がそれです。

**一般化 (generalization) と具体化 (instantiation)。** `let` の右辺を推論し終えたら、残った
変数を `forall` で束縛して**型スキーム**にします（一般化）。その名前を使うたびに `forall` を
新しい変数に開き直します（具体化）。**同じ `let` 束縛を別の型で2回使えるのはこれのおかげ**で、
これを **let 多相**と呼びます。

古典的な提示は **Algorithm W**（Damas–Milner 1982）で、代入を明示的に持ち回ります。ここでは
代入のかわりに可変参照、レベル判定のかわりに… は下の「レベルによる一般化」の節です。

| | |
|---|---|
| 単型 (monotype) | `forall` を含まない型。単一化変数を含んでよい |
| 型スキーム (type scheme) | `forall 'a ... . τ`。環境に入るのはこちら |
| 一般化 | 単型 → 型スキーム。`let` の境目で起きる |
| 具体化 | 型スキーム → 単型。変数を使うたびに起きる |
| 剛性変数 (rigid) | 注釈由来。何とも単一化しない（「注釈は約束として扱う」の節） |

**なぜ rank-1 に限ると完全推論になるのか。** 一般化と具体化がこの形で成立するのは、`forall` が
型の先頭にしか来ないからです。矢印の左に `forall` が入ると「引数として多相な関数を要求する」に
なり、単一化変数では表せません。そこが[3章](3-poly.md)の話で、この2章は**同じ問題の両側**です。

行が足すのは型の種類（`TRecord` / `TVariant`）と、単一化の相手として**行**を増やすことだけ
です。HM の3つの道具はそのまま使えます。

## 型と行

型と行は別の OCaml 型にしてあります。こうすると「行を型の位置に書く」ような間違いが構文的に
起こらず、カインド（kind）の検査が要りません。

```ocaml
type ty =
  | TCon of string           (* int, bool, unit と注釈由来の剛性変数 *)
  | TArrow of ty * ty
  | TPair of ty * ty
  | TRecord of row
  | TVariant of row
  | TVar of tvar ref

and row =
  | REmpty                        (* 閉じた行 *)
  | RExtend of string * ty * row  (* l : t を持ち、残りは row *)
  | RCon of string                (* 注釈由来の剛性な行変数 *)
  | RVar of rvar ref              (* 未確定の行 *)
```

レコードもヴァリアントも同じ `row` を使い、向きだけが違います。**レコードは行が言う
フィールドを全部持ち、ヴァリアントは行が言うタグのどれか1つである**。だから

```
{ x : int, y : bool }     x と y を両方持つ
[ `A : int, `B : bool ]   `A か `B のどちらか
```

となり、片方に情報を足すこと（フィールドを増やす／タグを増やす）が、部分型の向きとしては
逆になります。これが「双対」と言われる関係で、`row.ml` では同じ `unify_row` が両方を扱います。

## scoped labels — 重複を許す

行の設計には2つの流派があります。

| 方式 | 重複ラベル | 必要な仕掛け |
|---|---|---|
| Rémy 流 | 禁止 | 行変数ごとに「このラベルを持たない」制約（absence/lacks constraint） |
| Leijen の scoped labels | **許す** | 制約なし。操作は「行を書き換えて l を先頭に出す」だけ |

MinkML は後者（Daan Leijen, "Extensible Records with Scoped Labels", 2005）です。制約を
持ち回らなくてよいので、単一化がふつうの単一化のままになります。

代償は、同じラベルが2回現れる型が存在することです。しかしこれは代償というより**観察できる
挙動**です。

```sml
val shadowed = { x = true, ..origin }   (* origin は { x : int, y : int } *)
val outerX = shadowed.x
val innerX = (shadowed \ x).x
```

```
shadowed : { x : bool, x : int, y : int } = { x = true, x = 0, y = 0 }
outerX : bool = true
innerX : int = 0
```

拡張は**上に載せる**、射影は**一番外側を取る**、制限（`\`）は一番外側を**剥がして下を出す**。
ラベルにスコープがある、というのはこの意味です。実行時の表現もそのまま重複を許す連想リスト
なので、型と値が同じ構造をしています。

## 行の単一化

型の単一化はふつうです。面白いのは行の方で、規則は実質2つです。

```ocaml
and unify_row loc r1 r2 =
  match (r1, r2) with
  | RVar r, other | other, RVar r -> (* 出現検査してリンク *)
  | RExtend (l, t, rest), other ->
      let t', rest' = rewrite loc other l in   (* ここが本体 *)
      unify loc t t';
      unify_row loc rest rest'
  ...
```

`rewrite row l` が「その行を、ラベル `l` が先頭に来る形に書き換える」関数です。

```ocaml
and rewrite loc row l =
  match force_row row with
  | RExtend (l', t, rest) when l' = l -> (t, rest)      (* 先頭にあった *)
  | RExtend (l', t, rest) ->                            (* 奥を探して、通り道を戻す *)
      let t', rest' = rewrite loc rest l in
      (t', RExtend (l', t, rest'))
  | RVar r ->                                           (* まだ何も分かっていない *)
      let t = fresh_var () and rest = fresh_row () in
      r := RLink (RExtend (l, t, rest));                (* l を持つことに決める *)
      (t, rest)
  | REmpty -> Loc.type_error loc "there is no field %s here" l
```

3番目の場合が行多相そのものです。`fun getX r = r.x` を推論するとき、`r` の型は未確定の行を
持つレコードで、`r.x` が `rewrite` を呼び、行変数が「`x` を持ち、残りは新しい行変数」に
分裂します。残った行変数が一般化されて `..'b` になります。

`REmpty` の場合がエラーです。

```
$ mink tests/errors/field.mnk
tests/errors/field.mnk:3:11: type error: there is no field x here
```

出現検査は行にも必要です。`{ l : t | 'r }` と `'r` を単一化しようとすると無限の行ができるので、
`occurs_rvar` が止めます。

## レベルによる一般化

一般化の判定は Rémy 由来のレベル方式です。単一化変数は作られた `let` の深さを覚えていて、

- `let` の右辺を推論するときにレベルを1つ上げる、
- 推論が終わったら下げて、**現在のレベルより深いレベルを持つ変数だけ**を一般化する。

```ocaml
and bind_decl st env (d : Ast.decl) : env =
  incr level;
  let t = (* 右辺を推論 *) in
  decr level;
  generalize t;   (* level より深い変数を generic 印にする *)
```

深いレベルの変数は「この `let` の中で生まれ、外からは参照されていない」ことを意味します。
リンクするときに `update_level` で相手側のレベルを引き上げるのが、この不変条件を保つ仕掛け
です。これを忘れると、外から参照されている変数を一般化してしまい、型システムが壊れます。

[3章](3-poly.md)の `poly` は同じ判定を目印 ▶ の位置でやっています。**レベル（整数）と
文脈の位置（順序）は、同じ「外から見えるか」を別の方法で測っている**わけです。

## 注釈は約束として扱う

`row` は完全推論なので注釈は要りませんが、書けます。書いた場合、それは**約束**として検査
されます。仕掛けは2段です。

1. 注釈に現れる名前（`'a` や行の `..'r`）を**剛性**な定数（`TCon` / `RCon`）として読む。
   剛性な定数は何とも単一化しないので、本体が勝手に具体化することができません。
2. 本体の検査が終わったら、その剛性な名前を新しい一般化済み変数に置き換えて、束縛の
   スキームにする。

```
$ mink tests/errors/rigid.mnk
tests/errors/rigid.mnk:3:22: type error: cannot unify int with 'a
```

`val bad : 'a -> 'a = fn x => x + 1` の失敗です。剛性でなければ `'a` が `int` に解けて
黙って通ってしまい、注釈が意味を失います。逆に、剛性のままスキームにしてしまうと呼び出し側で
使えません。だから「検査中は剛性、束縛時に量化」の2段になっています。

`examples/rows.mnk` の

```sml
fun getY r = r.y                       (* 推論に任せる *)
val getY2 : { y : 'a, ..'r } -> 'a = fn r => r.y   (* 同じ型を書いてもよい *)
```

はどちらも同じスキームになります。

## ヴァリアントと `case`

`case` の腕が行を組み立てます。

- 腕がラベル付き（`` `Int n => ... ``）なら、そのラベルを行に足す。
- **すべての腕がラベル付きなら行は閉じる**（`REmpty` で終わる）。
- 落穂拾いの腕（`other => ...`）があるなら、行の末尾は行変数のままにし、その腕の中で
  `other` は「残りのヴァリアント」の型を持つ。

```
describe : [ `Int : int, `Bool : bool, `Pair : { x : int, ..'a } ] -> int
count : [ `Some : int, ..'a ] -> int
```

`describe` は3つのタグしか受け取りません。`count` は `` `Some `` を持ちうる任意の
ヴァリアントを受け取ります——`` `Nothing () `` でも `` `Anything { x = 1 } `` でも通ります。
**閉じているか開いているかが型に出ている**のがこのシステムの見どころです。

## 意図的に入れていないもの

- **絶対制約（lacks constraints）。** 重複を禁じる代わりに制約を持ち回る Rémy 方式は採って
  いません。重複が見えることは、上に書いたとおり機能として扱っています。
- **レコードの部分型付け。** 幅も深さもありません。`{ x : int, y : int }` は
  `{ x : int }` として渡せません（行多相の関数に渡すのが正解です）。
- **第一級ラベル。** ラベルを値として取り回すことはできません。
- **多相な `case` の網羅性検査。** 開いた行に対する網羅性は落穂拾いの腕の有無だけで決まり、
  決定木も生成しません（それは MartenML の主題です）。

## 参考文献

- L. Damas, R. Milner, [*Principal type-schemes for functional programs*][dm82], POPL 1982。
  Algorithm W と主要型。上の「単一化・一般化・具体化」の出どころ。
- J. A. Robinson, [*A machine-oriented logic based on the resolution principle*][robinson],
  JACM 12(1), 1965。単一化アルゴリズムそのもの。最汎単一化子の存在はここです。
- D. Rémy, [*Extension of ML type system with a sorted equational theory on
  types*][remy-rows], INRIA RR-1766, 1992。行多相と、絶対制約（lacks constraints）を持つ流派。
  レベルによる一般化もこの系譜です。
- D. Leijen, [*Extensible records with scoped labels*][leijen], TFP 2005。この章が採った方、
  重複ラベルを許す `rewrite` 1つで済ませる流派。
- O. Kiselyov, R. Lämmel, K. Schupke, [*Strongly typed heterogeneous
  collections*][hlist], Haskell Workshop 2004。行を型クラスで再現する側の代表。比較用。

[dm82]: https://doi.org/10.1145/582153.582176
[robinson]: https://doi.org/10.1145/321250.321253
[remy-rows]: https://hal.inria.fr/inria-00077006
[leijen]: https://doi.org/10.1007/11964681_11
[hlist]: https://doi.org/10.1145/1017472.1017488
