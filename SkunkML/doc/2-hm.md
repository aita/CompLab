# 2. Hindley–Milner — レベルと破壊的単一化

`types.ml` の話です。教科書の Algorithm W ではなく、**実装が実際に書く形**で書いてあります。
置換は返しません。単一化変数は可変セルで、単一化はセルを破壊的につなぎ、一般化は環境を
走査するかわりに整数をひとつ比べます。

隣の [MinkML](../../MinkML) の `hm.ml` が「紙のとおりの Algorithm W」なので、同じ推論の2通りの書き方を
並べて読むことができます。あちらは置換を合成して回し、こちらは何も返しません。

## 用語

| | |
|---|---|
| 単一化変数 | まだ決まっていない型。`Tvar of tv ref` で、`Unbound` か `Link` が入る |
| 破壊的単一化 | 変数を決めるとは、そのセルに `Link` を書き込むこと。置換は作らない |
| レベル (level) | 変数が作られたときの `let` の深さ。一般化してよいかの判定に使う |
| 出現検査 (occurs check) | `'a = 'a -> 'a` を止める検査。ここではレベルの引き下げも同時にやる |
| 一般化 / 具体化 | 単型を型スキームにする / 型スキームから単型を作る |
| 値制限 (value restriction) | 右辺が値でなければ一般化しない、という規則 |
| rigid な型変数 | 書かれた `'a`。何とも単一化しない定数として扱う |

## 1. 型の表現

```ocaml
type ty =
  | Tvar of tv ref
  | Tcon of tycon * ty list
  | Tarrow of ty * ty
  | Ttuple of ty list          (* 空タプルが unit *)
  | Trecord of (string * ty) list   (* ラベル順にソート *)

and tv = Link of ty | Unbound of { id : int; level : int; must : (string * ty) list }
```

`unit` を独立した型構成子にせず `Ttuple []` にしてあるのは SML に合わせたものです
（SML の `unit` は空レコード）。おかげでパターン `()` も値 `()` も特別扱いが要りません。

レコードは**ラベル順にソート**して持ちます。`{ y = 1, x = 2 }` と `{ x = 2, y = 1 }` が
同じ型で同じ値になるのはこのためで、単一化はラベル列を比べるだけで済みます。

型構成子には**名前とは別に識別子**があります。

```ocaml
and tycon = { tid : int; mutable tname : string; ... }
```

これが3章の全部です。2つのシグネチャの `type t` はどちらも `t` と印字されますが別の型で、
ファンクタ適用は「この識別子をこの型に置き換える」ことをします。名前ではそれができません。
`tname` が可変なのは印字のためだけで、構造が束縛されたときに `IntSet.set` へ改名します。

## 2. レベル — 一般化を整数の比較にする

一般化は「型に自由で環境に自由でない変数を量化する」ことです。素直に書くと `let` ごとに
環境を全部走査することになり、Algorithm W が二乗になる原因になります。

Rémy のレベル法はこうです。`let` に入るたびにレベルを1つ上げ、変数はそのときのレベルを
覚えます。

```ocaml
let newvar_with must =
  incr var_counter;
  Tvar (ref (Unbound { id = !var_counter; level = !current_level; must }))
```

`let` の右辺を推論し終えてレベルを下げたあと、**レベルが今より深い変数が量化してよい
変数**です。環境から見えているなら、その変数はどこかで外側のレベルの型に埋め込まれている
はずで、そのとき出現検査がレベルを引き下げてくれています。

```ocaml
| Unbound u ->
    List.iter (fun (_, t) -> occurs loc r level t) u.must;
    if u.level > level then r' := Unbound { u with level }
```

出現検査がレベルの引き下げも兼ねているのがこの方式の要点で、`occurs` が単なる安全検査
ではなく**一般化の準備**になっています。

型スキームは「量化した変数をそのまま持つ」形です。

```ocaml
type scheme = { qvars : tv ref list; sbody : ty }
```

具体化は本体をコピーして、`qvars` にあるセルだけ新しいセルに写します。それ以外のセルは
**共有します** — 自由変数を持つスキームが正しく意味を持つのはそのためです。コピーの
関数はひとつしかなく、具体化にも、構成子の引数型を求めるのにも、ファンクタ適用の
realisation にも同じ `copy` を使います。

## 3. 値制限 — 配列があるから要る

```sml
val cell = Array.array (1, [])
```

これを一般化すると `'a list array` になり、`int list` を書き込んでから `bool list` として
読み出せます。だから**右辺が「値」でなければ一般化しない**。

```ocaml
let rec non_expansive (e : Ast.exp) =
  match e.Ast.e with
  | Ast.EVar _ | Ast.EInt _ | Ast.EStr _ | Ast.ESelect _ | Ast.EFn _ -> true
  | Ast.ETuple es | Ast.EList es -> List.for_all non_expansive es
  ...
  | _ -> false
```

関数適用は expansive です。割り切った規則で、`val id2 = List.map` のような無害なものも
一般化されなくなりますが、健全側に倒す取引としては SML と同じところに立っています。

効いているところ:

```
$ skunk tests/errors/valrestriction.sk
errors/valrestriction.sk:3:10: type error: cannot unify int with bool
```

```sml
val cell = Array.array (1, [])
val () = Array.update (cell, 0, [1])      (* ここで int list に決まる *)
val () = Array.update (cell, 0, [true])   (* もう遅い *)
```

配列がなければこの規則は要りません。**この処理系に値制限があるのは、ストアがあるのと
同じ理由です**（[8章](8-cesk.md)）。

## 4. 書かれた `'a` は約束である

```sml
val id : 'a -> 'a = fn x => x + 1
```

これは通ってはいけません。`'a` をただの単一化変数として読むと `int` と単一化できて
しまい、`val id : int -> int` として受理されます。書いた側の宣言が黙って弱められる、
という気持ちの悪い挙動です。

そこで**書かれた型変数は rigid な型構成子として読みます**。

```ocaml
let read_ann env t =
  let mk name =
    let tc = newtycon name in
    ann_rigids := (name, tc) :: !ann_rigids;
    Tcon (tc, [])
  in
  S.read_ty ~mk env ann_table t
```

`newtycon name` の `name` は `'a` のままなので、エラーメッセージが自分の正体を言えます。

```
$ skunk tests/errors/rigid.sk
errors/rigid.sk:2:5: type error: 'a was written in an annotation,
  so it has to work for every type, and this needs it to be int
```

宣言が終わったら rigid な定数を新しい単一化変数に戻し、それから一般化します。戻すのは
**レベルを下げる前**でなければなりません。下げたあとに作った変数は「今のレベル」なので
量化されないからです。

```ocaml
let rw = close_ann ann in   (* 新しい変数はここで作る *)
leave_level ();
let sch = generalise loc (realise rw ty) in
```

有効範囲は1つの宣言です。同じ `'a` は宣言のあいだ同じものを指し、宣言をまたぐと別に
なります。SML の暗黙のスコープ規則の近似で、そのとおりではありません。

## 5. `#lab` — 決めなければならない柔軟レコード

SML には行多相がありません。それでも `#x r` は書けます。`r` の型が**その場ですでに
決まっていれば**。

やり方は、単一化変数に「持っていなければならないフィールド」を持たせることです。

```ocaml
| Unbound of { id : int; level : int; must : (string * ty) list }
```

`#x r` は `r` の型を `must = [("x", 'b)]` の変数と単一化します。あとでその変数が
レコードと単一化されたら、フィールドがあるかを確かめる。別の変数と単一化されたら要求が
合流する。

行変数と違うのは**一般化の前に決まっていなければならない**ことです。

```ocaml
if u.must <> [] then
  Loc.type_error loc
    "this record's type is not determined here: %s. Write the type out, as SML makes you"
```

```
$ skunk tests/errors/flexrecord.sk
errors/flexrecord.sk:2:5: type error: this record's type is not determined here:
  { x : '_3, ... }. Write the type out, as SML makes you
```

これは SML そのままの挙動です。`fun getX r = #x r` は SML でも通りません。行多相を
入れればこの制限は消えますが、それは別の型システムであって、MinkML の `row` が
そちらを扱っています。

閉じたレコードパターンには制限がありません。`{ x, y }` は「フィールドはこの2つで全部」と
言っているので、型がその場で決まります。`...` を付けたときだけ決めてもらう必要があります。

## 6. 何が単一化しないかを言う

型が違うと言うだけのエラーは、モジュールがあるとほとんど役に立ちません。

```
cannot unify box with box
```

名前が同じで識別子が違うときは、そう言います。

```ocaml
| Tcon (c1, _), Tcon (c2, _) when c1.tname = c2.tname && c1.tid <> c2.tid ->
    Loc.type_error loc
      "these are two different types both called %s: one abstract type is not another"
```

さらに、構造が束縛されるときに型構成子を `IntSet.set` へ改名しているので（[3章](3-modules.md)の6節）、
実際に出るのはたいていこちらです。

```
$ skunk tests/errors/generative.sk
errors/generative.sk:5:12: type error: cannot unify A.box with B.box
```

## していないこと

- **多相再帰がありません。** `fun` は自分の名前を単型として見ながら本体を検査します。
  注釈を付けても変わりません（注釈は rigid になりますが、再帰呼び出しの型は環境の
  単型から取ります）。
- **オーバーロードがありません。** `<` は `int` のみです。SML は `int`/`string`/`char`/`real`
  にオーバーロードして既定型を持ちますが、それは HM の外側にもう1つ機構が要ります。
- **等値型 (eqtype) がありません。** `=` はどんな型にも付き、関数を比べようとしたときだけ
  実行時に落ちます。健全ではありますが、静的に止めるのが SML です。
- **弱い型変数を印字で区別していません。** 値制限で一般化されなかった変数は `'_31` と
  出ます。SML の `'_a` と同じ意味です。

## 参考文献

- Robin Milner, "A Theory of Type Polymorphism in Programming",
  *JCSS* 17(3), 1978. Algorithm W。
- Didier Rémy, "Extension of ML Type System with a Sorted Equational Theory on
  Types", INRIA RR-1766, 1992. レベルによる一般化。実装はここから。
- Andrew Wright, "Simple Imperative Polymorphism", *LISP and Symbolic
  Computation* 8(4), 1995. 値制限が今の形になった論文。
- Oleg Kiselyov, "Efficient and Insightful Generalization". レベル法の解説として
  いちばん短い。
- 隣の [MinkML](../../MinkML) の `lab/src/hm.ml` が、同じ推論を置換で書いたものです。
  置換を手で合成する版とレベル版を並べて読めます。

## 実装の地図

| ファイル | 何が |
|---|---|
| `src/types.ml` | `newvar`/`enter_level`/`leave_level`（2節）、`copy`（2節）、`unify`/`occurs`（1・2節）、`require_fields`（5節）、`generalise`（2・5節）、`show_scheme`（印字） |
| `src/elab.ml` | `non_expansive`（3節）、`read_ann`/`open_ann`/`close_ann`（4節） |
| `src/sem.ml` | `read_ty` の `?mk`（4節）、`read_scheme`（シグネチャの `val`） |

---

[← 1. 構文](1-syntax.md) ・ [3. モジュール →](3-modules.md)
