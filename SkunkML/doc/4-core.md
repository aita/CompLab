# 4. 型付き Core と A正規形

`core.ml` と `elab.ml` の話です。ここで**書かれたプログラムと走るプログラムが別物に
なります**。この本の前半と後半の境目です。

## 用語

| | |
|---|---|
| A正規形 (ANF) | 「すべてのオペランドはアトム」を規則に選んだ正規形 |
| アトム | 変数かリテラル。評価しなくても値が分かるもの |
| ブロック | `let` の直線が末尾形で終わったもの。`let` は別のブロックを束縛しない |
| 末尾位置 | その値がそのまま呼び出し元へ返る位置。ANF では構文で決まる |
| destination | 変換のときに項へ渡すもの。「末尾にいる」か「値をこう使え」 |
| カリー化 | 多引数関数を1引数関数の連なりにすること。ここでは正規化がやる |

## 1. 3つの不変条件

```ocaml
type atom = AVar of string | AInt of int | AStr of string | AUnit

type rhs = Atom of atom | Lam of ... | Call of atom * atom | Prim of string * atom list
         | Tuple of atom list | Record of ... | Con of ... | Proj of ... | Field of ... | Payload of ...

and block = Let of string * Types.ty * rhs * block
          | LetRec of fn list * block
          | Join of label * (string * Types.ty) list * block * block
          | Tail of tail

and tail = Ret of atom | TCall of atom * atom
         | Case of ... | Switch of ... | Jump of ... | Fail of ...
```

1. **すべてのオペランドはアトム**です。呼び出しの引数を求めるために何かを評価する必要が
   ないので、機械の1ステップが部分項へ再帰しません。
2. **ブロックは `let` の直線＋末尾形**です。`let` が別のブロックを束縛することはないので、
   末尾位置が構文の性質になります。`TCall` は末尾呼び出しでフレームを積まず、`Call` は
   積む。判断は機械ではなく変換の側で終わっています。
3. **適用は1引数**です。カリー化は正規化がやるので、機械に部分適用もアリティ検査も
   要りません。

`if` はありません。`bool` は構成子が2つの直和型で、`if` は `case` の書き方のひとつです。

## 2. destination 渡しで、推論と正規化を同時にやる

`elab.ml` は型推論と ANF 変換を1回の走査でやります。同じ木を2回歩く理由がないからです。

```ocaml
type dest = Tail | Cont of (C.atom -> ty -> C.block)

let ret d a t = match d with Tail -> C.Tail (C.Ret a) | Cont k -> k a t

let emit ?(base = "t") ty rhs d =
  let x = C.fresh_name base in
  C.Let (x, ty, rhs, ret d (C.AVar x) ty)
```

項は destination に対して変換されます。`Tail` なら「この値がそのまま返る」、
`Cont k` なら「この値をこう使う」。中間結果に名前を付けるのが destination の仕事です。

型はどこから来るか。**複合形は結果の型変数を先に作り、継続の中で単一化します。**

```ocaml
| Ast.EApp (f, a) ->
    let res = newvar () in
    let _, blk =
      infer env f (Cont (fun fa ft ->
        let _, blk = infer env a (Cont (fun aa at ->
            unify loc ft (Tarrow (at, res));
            match d with
            | Tail -> C.Tail (C.TCall (fa, aa))
            | Cont _ -> emit res (C.Call (fa, aa)) d))
        in blk))
    in (res, blk)
```

`res` は関数の型が分かる前に作られ、単一化は一番内側で起きます。これが「1つの関数に
見えて、推論のパスと正規化のパスの合成ではない」理由です。

継続がいつ呼ばれるかも決まっています。**`e` の推論が完全に終わったところ**です。
`emit` が `ret d` を呼ぶのは `unify` のあとだからで、だから `val` の宣言で
「右辺を推論し終えてから一般化する」を継続の中に書けます。

```ocaml
| Ast.DVal (p, e) ->
    enter_level ();
    infer env e (Cont (fun a te ->
      ...
      leave_level ();
      let sch = if non_expansive e then generalise loc te else mono te in
      ...))
```

## 3. カリー化と多節の `fun`

```sml
fun merge ([], ys) = ys
  | merge (xs, []) = xs
  | merge (x :: xs, y :: ys) = ...
```

は

```
fn a1 => case a1 of ([], ys) => ys | (xs, []) => xs | ...
```

になり、引数が2つ以上あれば

```
fn a1 => fn a2 => case (a1, a2) of ...
```

になります。節をタプルの `case` にまとめるので、多節の `fun` と `case` は Core から見て
同じものです。パターンマッチのコンパイラも1種類で済みます。

## 4. なぜ型を捨てないのか

正規化のあと型を消すのが普通です。隣の [MinkML](../../MinkML) の `lab/src/core.ml` は
消していて、その理由を
「5つの型システムは正しいプログラムがどう走るかでは完全に一致するから」と書いています。
ここでは消しません。**次のパスが型を必要とします。**

```
switch p.59 of
| true => ...
| _ => ...
```

この `switch` に default がいるかどうかは、「`bool` に構成子はいくつあるか」で決まります。
2つとも枝があるなら default は要らないし、`int` のように構成子が無限にあるなら必ず要る。
これは型への質問で、推論が終わったあとに聞くしかありません（[5章](5-matching.md)）。

型が残っていることの副産物として、ダンプが読めます。

```
$ skunk --dump-core tests/core.sk
-- val swap : 'a * 'b -> 'b * 'a
let rec swap : '_7 * '_6 -> '_6 * '_7 = fn a1.19 =>
  let p.57 : '_7 = #1 a1.19
  let p.58 : '_6 = #2 a1.19
  let a : '_7 = p.57
  let b : '_6 = p.58
  let t.60 : '_6 * '_7 = (b, a)
  ret t.60
ret swap
```

タプルパターンが `#1`・`#2` の射影になっていて、検査は1つも出ていません。タプルは形が
1つしかないからです（[5章](5-matching.md)の3節）。

型が消えるのはクロージャ変換のときです（[7章](7-closure.md)）。そこまで来ると、型に
決めさせることが何も残っていません。

## 5. 名前 — 書かれた名前を残しつつ一意にする

ダンプがソースの横に置いて読めるように、束縛は書かれた名前を保ちます。同じ名前が
2回目に出てきたら番号が付きます。

```ocaml
let fresh_name base =
  match Hashtbl.find_opt used base with
  | None -> Hashtbl.replace used base 1; base
  | Some n -> Hashtbl.replace used base (n + 1); Printf.sprintf "%s.%d" base (n + 1)
```

上のダンプの `a` と `b` は書かれたとおり、`p.57` は正規化が作ったものです。

**プログラム中のすべての束縛が一意になる**のは飾りではありません。join point が
「定義された場所の環境」ではなく「跳んだ先で見えている環境」を読んでよくなるのは
この性質のおかげで、それが join point がクロージャでない理由の実装側の言い分です
（[6章](6-join.md)・[7章](7-closure.md)）。

## 6. トップレベルは1宣言1ブロック

トップレベルの宣言はそれぞれ独立したブロックになります。走らせて、束縛されたものを
報告して、次へ行けるようにするためです。

複数の名前を束縛する宣言（`fun ... and ...` や `val (x, y) = ...`）は、タプルを返す
1つのブロックになり、そのあと射影で取り出します。相互再帰の閉包は**1つのブロックの
中で一緒に作られ**、結果だけが配られます。

```
-- (報告しない)
let rec even = ...
and odd = ...
let group = (even, odd)
ret group
-- val even : int -> bool
let t = #1 group
ret t
```

`val () = print "hi"` のように何も束縛しない宣言も、ブロックは走ります。宣言は
束縛のためだけでなく効果のためにも書かれるからです。

## していないこと

- **最適化がありません。** インライン展開も、共通部分式除去も、`Proj (Tuple ...)` の
  簡約もしません。ダンプに `let p.57 = #1 a1.19` と `let a = p.57` が並んで出るのは
  そのためで、消せますが消すと「パターン変数がどこから来たか」が読めなくなります。
- **既知関数の直接呼び出しがありません。** `letrec` で束縛した関数を飽和して呼んでも、
  クロージャを経由します（[7章](7-closure.md)）。
- **`Case` の腕の型は揃っているだけで、結果の型は Core に書かれていません。**
  必要になるのは join point の引数型だけで、それは `with_join` が持っています。

## 参考文献

- Cormac Flanagan, Amr Sabry, Bruce Duba, Matthias Felleisen, "The Essence of
  Compiling with Continuations", *PLDI* 1993. A正規形の出典。
- Andrew Appel, *Compiling with Continuations*, 1992. CPS 側の古典。ANF は
  「CPS を書かずに CPS の利益を得る」提案として読むのが分かりやすい。
- Simon Peyton Jones, "Implementing Lazy Functional Languages on Stock Hardware:
  the Spineless Tagless G-machine", *JFP* 2(2), 1992. 型付き中間言語を最後まで
  持つ路線。
- 同じ repo の MartenML は K正規形（KNF）を使っています。ANF との違いは実質
  「どこまでを1つの束縛にするか」で、`doc/knormal.md` にあります。

## 実装の地図

| ファイル | 何が |
|---|---|
| `src/core.ml` | IR の定義（1節）、`fresh_name`（5節）、`item`（6節）、`print_block` 系（ダンプ） |
| `src/elab.ml` | `dest`/`ret`/`emit`（2節）、`infer`（2節）、`elab_fun`（3節）、`elab_dec`（2・6節）、`program`（6節） |

---

[← 3. モジュール](3-modules.md) ・ [5. パターンマッチを決定木にする →](5-matching.md)
