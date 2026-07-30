# 3. モジュール — シグネチャは意味対象である

`sem.ml` の話です。ソースに書かれた `signature` は構文ですが、ここで扱うシグネチャは
**意味対象**（semantic object）— 型成分・値の型スキーム・部分構造のリストです。この2つの
距離がモジュール機構のすべてで、突き詰めると質問はひとつです。

> シグネチャが `type t` と言ったとき、`t` とは何か。

答は「識別子だけを持つ新しい型構成子」、つまり **hole** です。

## 用語

| | |
|---|---|
| 意味対象 (semantic object) | 構文ではなく、検査器が持つシグネチャの表現。SML Definition の用語 |
| hole | シグネチャが宣言した型成分。構造が埋める空欄 |
| realisation | hole の識別子から型への写像。照合の結果として得られる |
| 透明 / 不透明な型付け | `str : S` と `str :> S`。realisation を残すか捨てるか |
| 生成的 (generative) | ファンクタを適用するたびに新しい型ができること |
| skolem 化 | 「どんな型でも」を「勝手な定数」に置き換えて検査すること |

## 1. シグネチャは hole の集まり

```sml
signature ORD = sig
  type t
  val compare : t * t -> int
end
```

エラボレートすると、こうなります。

```ocaml
sg_tys  = [ ("t", TyName tc₁₇) ]      (* tc₁₇ は新しい識別子を持つ *)
sg_vals = [ ("compare", tc₁₇ * tc₁₇ -> int) ]
holes   = [ tc₁₇ ]
```

`tc₁₇` は名前が `t` で、構成子を持たない型構成子です。`compare` の型はその識別子を
指しています。これで「シグネチャの中では `t` と `t` は同じ型で、他の何とも違う型」が
表現できました。

**名前付きシグネチャは構文のまま覚えておいて、使うたびにエラボレートし直します。**

```ocaml
sigs : (string * (Ast.sigexp * env)) list;
```

`ORD` を2回使えば hole は2組できます。これは手抜きに見えますが、「使うたびに新しい
hole」が要件そのものなので、覚えたシグネチャを毎回作り直す機構（refresh）を書かずに
済ませる方法として素直です。refresh がどうしても要るのはファンクタ適用の1箇所だけで、
それは5節です。

## 2. 照合と realisation

構造をシグネチャに照合するとは、hole を埋めることです。

```ocaml
let rec match_sig loc ~what (actual : sg) (target : sg) (holes : tycon list) =
```

順序があります。**型成分が先、値があと。** 値の型を比べる前に、その型が言及している
型が何なのか決まっていなければならないからです。

型成分ごとに:

- target 側が hole なら、actual 側の型を realisation に記録する。
- target 側が定義付き（`type t = int`）なら、これまでの realisation を適用してから
  actual 側と単一化して、一致を確かめる。
- target 側が `datatype` の指定なら、構成子の名前が**同じ順で同じ**であることも
  確かめる。順が同じでなければならないのは、実行時のタグが順序で決まるからです。

値ごとに:

```ocaml
and more_general (have : scheme) (want : scheme) =
  let skolems = List.map (fun _ -> Tcon (newtycon "?rigid", [])) want.qvars in
  let target = copy { rvars = combine want.qvars skolems } want.sbody in
  let source = instantiate have in
  try unify Loc.unknown source target; true with Loc.Error _ -> false
```

シグネチャが `val f : 'a -> 'a` と言っているなら、それは**どんな型についても**という
主張です。だから `'a` を勝手な定数（skolem）に置き換えて、構造が持っている型がそれに
合わせられるかを見ます。合わせられなければ、構造のほうが特殊すぎる。

```
$ skunk tests/errors/toospecific.sk
errors/toospecific.sk:1:42: signature error: f is int -> int here,
  but the signature asks for 'a -> 'a
```

これは[2章](02-hm.md)の5節で注釈の型変数に対してやっていることと同じ手です。違いは
rigid のままにしておく期間で、注釈のほうは宣言が終わるまで持って最後に変数へ戻し、
照合のほうは照合が終わったら捨てます。

## 3. `:` と `:>` の唯一の違い

照合が終わると realisation が手に入ります。**それをどうするかが2つの型付けの違いの
全部です。**

```ocaml
| Ast.StrAsc (inner, se, opaque) ->
    elab_str env inner (fun asg aa ->
        let target, holes = S.elab_sig env se in
        let rw = S.match_sig loc ~what:"this structure" asg target holes in
        let sg = if opaque then target else S.map_sg (realise rw) target in
        k sg aa)
```

`realise rw target` を通せば `t` は `int` になり、外から `IntOrd.t` は `int` と同じ型に
見えます。通さなければ `t` は hole のままで、外からは何も見えません。

```sml
structure IntOrd : ORD = struct type t = int val compare = Int.compare end
val stillInt = IntOrd.compare (1, 2)     (* 通る: IntOrd.t は int *)
```

**実行時には何も起きません。** `aa` — 構造の値 — はそのまま渡されます。封印は静的な
話しかしていない。

## 4. ファンクタ — 1段上の同じ話

```sml
functor MakeSet (O : ORD) :> SET where type elem = O.t = struct ... end
```

- 引数のシグネチャをエラボレートして hole を得る。それが**ファンクタの型パラメータ**。
- 本体を、その hole を持つ環境で**1回だけ**エラボレートする。
- 結果は `f_param`（引数のシグネチャ）と `f_body`（本体のシグネチャ）。

適用は照合と代入です。

```ocaml
let instantiate_functor loc (f : fct) (arg : sg) =
  let rw = match_sig loc ~what:"the argument" arg f.f_param f.f_holes in
  ...
  let body = map_sg (realise all) f.f_body in
```

`where type` はここに要ります。`SET` は名前付きシグネチャなので `O` を知りません。
`SET where type elem = O.t` は「このシグネチャの抽象型 `elem` に定義を与える」という
操作で、実装はまさに realisation を1つ適用することです。

```ocaml
| Ast.SigWhere (inner, b) ->
    let sg, holes = elab_sig env inner in
    let tc = (* holes の中から名前で探す *) in
    let rw = [ (tc.tid, (tc.tparams, body)) ] in
    (map_sg (realise rw) { sg with ... }, List.filter (...) holes)
```

これがないと、封印したファンクタの結果に値を渡せません。`elem` が完全に抽象だと
`IntSet.add (3, s)` の `3` を受け取る型がないからです。

## 5. 生成性 — 本体が作った型は適用ごとに別物

```sml
functor Wrap (X : sig type t end) = struct datatype box = Box of X.t end
structure A = Wrap (struct type t = int end)
structure B = Wrap (struct type t = int end)
```

`A.box` と `B.box` は**別の型**でなければなりません。同じにすると、引数が違うときに
`int` と `bool` が混ざります。

本体を1回しか検査しないと決めた以上、本体が作った型構成子を適用ごとに作り直す必要が
あります。`sem.ml` で refresh が要るのはここだけです。

どれが「本体が作った型」かは、型構成子を作った順に記録しておいて区切ります。

```ocaml
let before = mark () in
... 本体をエラボレート ...
let generated =
  List.filter (fun tc -> not (List.exists (fun h -> h.tid = tc.tid) holes)) (since before)
```

適用ごとに `generated` に新しい識別子を与え、その置換を realisation と合わせて本体の
シグネチャに通します。直和型については構成子も作り直します — 構成子は自分の属する型を
指しているからです。

```
$ skunk tests/errors/generative.sk
errors/generative.sk:5:12: type error: cannot unify A.box with B.box
```

引数が両方 `int` でもこうなります。SML の生成的ファンクタはそういう規則です
（OCaml の適用的 (applicative) ファンクタは同じにします。どちらが良いかは
depends on what you want、というのが Leroy 1995 以来の話題です）。

## 6. 型に構造の名前を付ける

`A.box` と印字されているのは、構造を束縛したときに改名しているからです。

```ocaml
let rec qualify prefix fresh (sg : S.sg) =
  List.iter
    (fun (n, tf) ->
      match tf with
      | S.TyName tc when List.memq tc fresh && tc.tname = n ->
          tc.tname <- prefix ^ "." ^ n
      | _ -> ())
    sg.S.sg_tys;
  ...
```

「この構造がエラボレートされているあいだに作られた型構成子」だけを改名します
（5節と同じ `mark`/`since`）。そうしないと、透明な型付けで `t` が `int` に解決された
構造が `int` を `IntOrd.t` に改名してしまいます。

効果はこれです。

```
$ skunk examples/modules.sk
val ints : IntSet.set = [1, 2, 3, 4, 5, 6, 9]
val words : StringSet.set = ["apple", "pear"]
```

同じファンクタの2つの適用が、報告の時点で別物だと分かります。

## 7. そして全部消える

エラボレーションを抜けると、モジュールはもうありません。

- **構造はレコードです。** `struct ... end` は宣言を順に走らせて、最後に公開する
  名前のレコードを作るブロックになります。
- **ファンクタは関数です。** レコードを受け取ってレコードを返す。
- **パスは射影です。** `IntSet.add` は変数 `IntSet` の `add` フィールド。
- **型と構成子は実行時に何も残しません。** 静的な話だったので。

```
$ skunk --trace examples/modules.sk
  ...
  let struct.5 = { add = add, empty = empty, member = member, size = size, toList = toList }
  ret struct.5
  let IntSet = app.2
```

`patmat.ml` も `closure.ml` も `machine.ml` も、モジュールという語を一度も使いません。

同じ結論に別の道で着く方法もあります。**defunctorization** — ファンクタを適用ごとに
本体ごと複製して、名前解決だけで済ませてしまうやり方で、MLton がそれをやっています。
複製する側はモジュールが実行時表現を一切持たず、ここでやっている側は本体が1回しか
検査されません。どちらを取るかは、だいたい「分割コンパイルがあるか」で決まります。

## していないこと

- **ファンクタは構造の中に入れられません。** 構文としては書けますが、シグネチャに
  ファンクタ成分がないので外から見えません。SML も高階ファンクタを標準では持ちません。
- **`sharing` がありません。** `where type` で書ける範囲だけです。
- **`where type` はパスを取れません。** `S where type t = ...` は書けますが
  `S where type M.t = ...` は書けません。
- **`datatype` の指定は構成子の順まで一致を要求します。** SML は順を問いませんが、
  ここでは実行時のタグが順序で決まっているので、揃えてもらっています。
- **`open` は再輸出しません。** 構造の中で `open X` しても、その構造は `X` の名前を
  公開しません。
- **分割コンパイルがありません。** 全プログラムが一度に見えている前提です。

## 参考文献

- Milner, Tofte, Harper, MacQueen, *The Definition of Standard ML (Revised)*, 1997.
  4章の semantic objects がこの章の骨格です。hole は Definition の「flexible な
  type name」に当たります。
- Mads Tofte, "Principal Signatures for Higher-Order Program Modules", *POPL* 1992.
- Xavier Leroy, "Applicative Functors and Fully Transparent Higher-order Modules",
  *POPL* 1995. 生成的 vs 適用的。
- Andreas Rossberg, Claudio Russo, Derek Dreyer, "F-ing Modules", *JFP* 24(5), 2014.
  「構造はレコード、ファンクタは関数、封印は存在型の pack」を型理論として最後まで
  やったもの。7節がやっていることの、型の付いた版です。
- Martin Elsman, "Static Interpretation of Modules", *ICFP* 1999. MLton の
  defunctorization の正しさ。7節のもう一方の道。

## 実装の地図

| ファイル | 何が |
|---|---|
| `src/interpreter/sem.ml` | `sg`/`tyfun`/`fct`/`env` の定義（1節）、`elab_sig`・`elab_spec`（1・4節）、`match_sig`・`more_general`・`match_datatype`（2節）、`refresh`・`instantiate_functor`（5節）、`open_sg`・`map_sg` |
| `src/interpreter/elab.ml` | `elab_str`（3・7節）、`elab_topdec` の `TStr`/`TFun`（4・5・6節）、`qualify`（6節）、`struct_ty`（レコードとしての構造の型） |
| `src/interpreter/types.ml` | `tycon.tid`（1節）、`copy`/`realise`（2・5節）、`mark`/`since`（5節） |

---

[← 2. Hindley–Milner](02-hm.md) ・ [4. 型付き Core と A正規形 →](04-core.md)
