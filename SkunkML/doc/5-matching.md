# 5. パターンマッチを決定木にする

`patmat.ml` の話です。入る形は「入れ子で、重なっていて、網羅しているとは限らない」
パターンの列。出る形は、値の各部分を高々1回だけ検査して勝った腕へ跳ぶ木です。

## 用語

| | |
|---|---|
| パターン行列 | 各行が1つの腕、各列が値の1つの部分に対応する表 |
| occurrence | 列が問い合わせている値の部分。ここでは Core のアトム |
| 特殊化 (specialisation) | ある構成子を仮定して行列を狭めること |
| default 行列 | どの構成子でもない場合に残る行列。ワイルドカードの行だけ |
| 決定木 (decision tree) | 「この値を検査して、この枝へ」の木。検査の重複がない |
| 網羅性 / 冗長性 | 全部の場合を覆っているか / 到達できない腕があるか |

## 1. 名前は環境が決める

行列に入る前にひとつ。構文解析はパターンの裸の名前を全部 `PVar` にします
（[1章](1-syntax.md)の6節）。構成子かどうかを決めるのはここです。

```ocaml
| Ast.PVar x -> (
    match S.lookup_con env loc (Ast.ident x) with
    | Some c -> check_con env loc c None ty
    | None -> let v = C.fresh_name x in ([ ... ], C.PAny (Some v)))
```

`nil` も `true` も `NONE` も、環境が構成子だと言うから構成子になります。特別扱いは
1行もありません。

同じところで、レコードパターンは**型の全フィールドに展開されます**。`{ name = n, ... }`
は型が `{ age : int, name : string }` なら `{ age = _, name = n }` になります。おかげで
決定木のほうはレコードをタプルと同じに扱えます。

## 2. 行列

```ocaml
type row = {
  rpats : C.pat list;                        (* 列 *)
  rbind : (string * C.atom * ty) list;       (* ここまでに分かった束縛 *)
  rarm : int;                                (* どの腕か *)
}
```

最初は1列（走査対象そのもの）と、腕の数だけの行です。毎ステップこうします。

- **行がない** → ここで失敗しうる（`TFail`）
- **最初の行が全部 `_`** → その行が勝ち。腕へ跳ぶ（`TLeaf`）
- **それ以外** → 列を1つ選び、そこに現れる構成子ごとに枝を作る

変数パターンと `as` パターンは行列に入る前に落とします。必ず一致するので、
情報としては束縛だけだからです。

```ocaml
let rec strip occ ty p binds =
  match p with
  | C.PAny (Some x) -> (C.PAny None, (x, occ, ty) :: binds)
  | C.PAs (x, q) -> strip occ ty q ((x, occ, ty) :: binds)
  | _ -> (p, binds)
```

## 3. 列の選び方と、検査しない列

選ぶのは**最初の行が実際に検査している一番左の列**です。

```ocaml
let i =
  let rec find j = function
    | [] -> 0
    | p :: rest -> if is_wild p then find (j + 1) rest else j
  in find 0 row0.rpats
```

これで最初の行は毎ステップ勝ちに1歩近づくので、再帰は必ず終わります。Maranget は
もっと賢い選び方（列ごとにスコアを付ける）を並べていますが、この「最初の行の一番左」は
その中の一番素直なもので、これだけでも列の順序をソースの順序から離す効果があります。

選んだ列が**タプルかレコード**なら、検査は出ません。形が1つしかないからです。列を
成分の数だけの列に**展開**して、そのぶん `let` で部分値を束縛します。

```
let p.57 : '_7 = #1 a1.19
let p.58 : '_6 = #2 a1.19
```

構成子・整数・文字列なら `switch` になります。

## 4. 特殊化と default

構成子 `c` の枝では、行はこうなります。

- 先頭が `PCon (c, sub)` → `sub` を先頭の列にして残す
- 先頭が `_` → 先頭の列を `_` にして残す
- それ以外の構成子 → 落とす

構成子が引数を取るなら、その引数を取り出す `let` が枝の先頭に入ります。

```
| :: =>
    let arg.15 : '_31 * '_31 list = payload xs.13
    let p.63 : '_31 = #1 arg.15
    let p.64 : '_31 list = #2 arg.15
```

`payload` が構成子の中身を取り出す操作で、その中身がタプルなら次のステップで
展開されます。だから `x :: xs` の2つの束縛は「1回の payload と2回の射影」になります。

**default が要るかどうかは型が決めます。**

```ocaml
let complete =
  match (head, repr oty) with
  | C.PCon _, Tcon (tc, _) -> tc.tcons <> [] && List.length !keys = List.length tc.tcons
  | _ -> false
```

直和型で、構成子が全部そろっていれば default は要りません。`int` や `string` は
構成子が無限にあるので必ず要ります。**これが[4章](4-core.md)で型を捨てなかった理由の
全部です。**

## 5. 出てくる木

```sml
fun pick (true, 1) = "both"
  | pick (_, 2)    = "two"
  | pick _         = "no"
```

```
$ skunk --dump-core tests/core.sk
-- val pick : bool * int -> string
let pick : bool * int -> string = fn a1.20 : bool * int =>
  join arm () =
    ret "two"
  join arm.2 () =
    ret "no"
  let p.59 : bool = #1 a1.20
  let p.60 : int = #2 a1.20
  switch p.59 of
  | true =>
      switch p.60 of
      | 1 =>
          ret "both"
      | 2 =>
          jump arm ()
      | _ =>
          jump arm.2 ()
  | _ =>
      switch p.60 of
      | 2 =>
          jump arm ()
      | _ =>
          jump arm.2 ()
ret pick
```

読みどころは2つです。

`p.59`（1列目）を先に検査していますが、`true` の枝でも `_` の枝でも次に `p.60` を
検査しています。**同じ値を2回検査してはいません。** 2つの枝は別の道で、それぞれの中で
1回ずつです。

そして `"two"` と `"no"` が `join` になっています。最初の2つの腕が別の列を検査して
いるので、どちらを先に見ても最後の腕には4箇所からたどり着きます。木は本体を複製する
かわりにラベルにしました。これが[6章](6-join.md)です。

もうひとつ、こちらは検査が1回も出ない例。

```sml
fun merge ([], ys) = ys
  | merge (xs, []) = xs
  | merge (x :: xs, y :: ys) = ...
```

```
switch p.57 of
| nil =>
    let ys : int list = p.58
    ret ys
| :: =>
    let arg.15 : int * int list = payload p.57
    switch p.58 of
    | nil =>
        let xs.13 : int list = p.57
        ret xs.13
    | :: => ...
```

2番目の腕 `(xs, [])` は、1列目が `::` だと分かったあとでしか到達しません。だから
`xs` は `p.57` そのものに束縛されます — もう一度検査することはありません。

## 6. 網羅性と冗長性は木から読む

別の解析は要りません。木を作ったあと数えるだけです。

```ocaml
let uses = Array.make n 0 in
count uses tree;
List.iteri (fun k arm -> if uses.(k) = 0 then Loc.warn loc "this pattern can never match: %s" ...) arms;
if reaches_fail tree then Loc.warn loc "this match does not cover every case";
```

- 葉がひとつもない腕 → 誰も到達できない
- 到達できる `TFail` がある → 網羅していない

```
$ skunk tests/warn.sk
warn.sk:5:5: warning: this match does not cover every case
warn.sk:8:5: warning: this pattern can never match: 0
warn.sk:16:5: warning: this match does not cover every case
val partial : 'a option -> 'a = fn
val fine : int = 1
...
```

**警告であって、エラーではありません。** 網羅していないマッチも、その場合が来なければ
正しく走ります。来たらそこで止まります。

```
$ skunk tests/errors/nomatch.sk
errors/nomatch.sk:1:5: warning: this match does not cover every case
val only : int * 'a -> 'a = fn
errors/nomatch.sk:1:5: match failure: no pattern matched
```

行番号が同じなのは偶然ではありません。`Fail` は生成された場所を覚えていて、実行時の
メッセージはそれを言います。

Maranget が示しているとおり、この判定は「決定木を作ったら副産物として出る」ものですが、
**木を作らずに同じことを言うアルゴリズム**（usefulness）もあります。OCaml の
警告はそちらです。木のほうが安いのは、どうせ木を作るからです。

## 7. 1回しか使わない腕はラベルにしない

腕を全部 join point にするのが素直ですが、そうすると `case x of 1 => a | _ => b` が
引数ゼロのラベル2つになって、ダンプが読めなくなります。

そこで**2回以上たどり着く腕だけ**をラベルにします。1回だけの腕は、その場に書き出します。

```ocaml
let joins =
  List.mapi (fun k arm ->
      if uses.(k) > 1 then Some (k, C.fresh_name "arm", binder_types ty arm.C.apat, arm.C.abody)
      else None) arms
  |> List.filter_map Fun.id
```

副作用として、**ダンプに `join` が出ているところが、そのまま「共有が起きたところ」に
なります**。上の `pick` で `"both"` が `ret "both"` と直に書かれているのは、そこへ
たどり着く道が1本しかないからです。

腕の変数はラベルの引数になります。順序はパターンを歩いた順で、`binders` と
`binder_types` が同じ順で返すことに依っています。

## していないこと

- **列の選び方はヒューリスティックを持ちません。** Maranget の論文にある「必要性」の
  スコアリングを実装すれば、もっと小さい木が出ることがあります。
- **or パターンがありません。** `A | B => e` は書けません。あると列の選び方が難しく
  なり、この章の面白さがそちらに寄ります。
- **ガードがありません。** SML にもありません。
- **どの構成子が来なかったかを言いません。** 「網羅していない」とだけ言います。
  反例を作るには usefulness アルゴリズムを別に持つことになります。
- **文字列の switch は線形探索です。** 機械が `List.find_opt` で枝を探します。

## 参考文献

- Luc Maranget, "Compiling Pattern Matching to Good Decision Trees", *ML Workshop*
  2008. この章の実装はこの論文の図をなぞったものです。
- Luc Maranget, "Warnings for Pattern Matching", *JFP* 17(3), 2007. 木を作らずに
  網羅性と冗長性を言う方法。
- Philip Wadler, "Efficient Compilation of Pattern-Matching", in Peyton Jones,
  *The Implementation of Functional Programming Languages*, 1987, 5章。
  バックトラック法。決定木より木は小さく、実行は遅い。
- Fabrice Le Fessant, Luc Maranget, "Optimizing Pattern Matching", *ICFP* 2001.
  OCaml の実装の話。
- 同じ repo の MartenML も決定木を作ります（`compiler/src/match_compile.ml`、
  `doc/matching.md`）。あちらは join point を持たないので、共有する腕を関数にします。

## 実装の地図

| ファイル | 何が |
|---|---|
| `src/patmat.ml` | `row`/`tree`（2節）、`strip`/`simplify`（2節）、`build`（3・4節）、`count`/`reaches_fail`（6節）、`compile_case`（5・6・7節）、`binders`/`binder_types`（7節） |
| `src/elab.ml` | `check_pat`（1節）、`match_arms_d`（`case` を Core の `Case` にする） |
| `src/core.ml` | `pat`/`key`/`Case`/`Switch`（IR の側） |

---

[← 4. 型付き Core と A正規形](4-core.md) ・ [6. join point →](6-join.md)
