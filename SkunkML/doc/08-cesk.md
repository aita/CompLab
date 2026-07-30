# 8. CESK マシン — ストアがある理由

`machine.ml` の話です。4つ組の状態と、その書き換え規則。

```
C  control        いま走っているブロック
E  environment    名前 → 番地
S  store          番地 → 値
K  kontinuation   フレームのリスト
```

## 用語

| | |
|---|---|
| 抽象機械 | 評価を状態の書き換え規則として書いたもの |
| CEK | 制御・環境・継続の3つ組。環境が名前を値へ直接写す |
| CESK | それにストアを足したもの。環境は名前を番地へ写す |
| フレーム | 「値が来たらこれをする」を1つ覚えたもの |
| 末尾呼び出し | フレームを積まない呼び出し |

## 1. なぜ S があるのか

CEK なら環境が名前を値へ直接写せば済みます。この言語の値は**可変なものを除いて**
一度作ったら変わらないので、それで足ります。

可変なものは2つ、`ref` と `array` です。

```sml
val counter = ref 0
val alias = counter
val () = alias := 100
val throughTheOther = !counter     (* 100 *)
```

`counter` と `alias` は同じ**場所**を指していなければなりません。値のコピーではなく。

そこで変数は場所を指し、ストアが中身を言う、という2段にします。`ref` は1つの番地、
配列は番地の連なりです。

```ocaml
| VRef of int              (* 1つの番地 *)
| VArray of int * int      (* 先頭番地、長さ *)
```

`:=` も `Array.update` もストアを1箇所書き換えるだけで、機械の他の部分は何も
変わりません。**これが4つ目の要素の説明の全部です。**

`ref` が構成子を1つ持つ直和型であること（[9章](09-language.md)の5節）は、機械の側では
数行です。**確保するのはこの構成子だけ**で、`Payload` はセルを読みます。

```ocaml
| F.Con (c, Some a) when c.Types.cres.Types.tid = Types.ref_tc.Types.tid ->
    let cell = alloc w 1 in
    set w cell (atom w env a);
    VRef cell
```

おかげで `ref x` はパターンとしても書けます。決定木は他の構成子と区別しません。

```
$ skunk examples/store.sk
val counter : int ref = ref 0
val now : int = 2
val bump : int ref -> int = fn
val next : int = 3
val alias : int ref = ref 3
val throughTheOther : int = 100
val same : bool = true
val other : bool = false
```

`alias` の行が `ref 3` なのは、その時点でまだ 100 を書いていないからです。報告は
束縛のたびに出ます。最後の2行は**可変なものの等値は同一性である**ことで、
`counter = alias` は真、`counter = ref 100` は偽です。

同じ理由で[2章](02-hm.md)の4節に値制限があります。**ストアがあるから値制限が要る**、
というのは同じ事実の型側の言い方です。

## 2. 束縛はセルを1つ確保する

```ocaml
let bind w env x v =
  let a = alloc w 1 in
  set w a v;
  { env with vars = Map.add x a env.vars }
```

`let` ひとつにつきセルひとつ。ストアを持つ以上これが筋で、配列に何も足さずに済む理由でも
あります。代償は正直に出ます。

```sml
fun count (i, acc) = if i = 0 then acc else count (i - 1, acc + i)
val big = count (100000, 0)
```

```
$ skunk --steps count.sk
1000036 steps, 900047 cells
```

10万回のループで90万セル。**回収しないからです。** GC がないので `w.next` は増える
一方で、`alloc` は倍々で伸ばすだけ。実装として不足なのは確かですが、
「ストアがある」ことを覆い隠さない形ではあります。

## 3. フレームは1種類しかない

```ocaml
type frame = KLet of string * F.block * env
```

A正規形では「値を待っているもの」は `let` しかありません（[4章](04-core.md)の1節）。
だからフレームの種類は1つです。積むのは末尾でない呼び出しのときだけ。

```ocaml
| F.Call (f, a) -> (
    match enter w fv av with
    | Some (body, env) ->
        st.ks <- KLet (x, rest, st.env) :: st.ks;
        st.env <- env; st.ctrl <- body; run w st
    | None -> ...)
```

末尾呼び出しは `st.ks` に触りません。

```ocaml
| F.TCall (f, a) -> (
    match enter w fv av with
    | Some (body, env) -> st.env <- env; st.ctrl <- body; run w st
    | None -> ...)
```

だから末尾再帰で書いたループは定数スタックで走ります。上の10万回は、フレームを
1つも積んでいません。

`jump` も積みません（[6章](06-join.md)の8節）。ラベルへ跳ぶのは呼び出しではない、が
ここでも実装に見えています。

## 4. 関数に入る

クロージャはコードのラベルと、捕獲を置いた番地です。

```ocaml
| VClos of string * int * int      (* ラベル、捕獲の先頭番地、個数 *)
```

入るときに作る環境は、引数だけを持つ新しい環境です。捕獲は `caps` に入れた番地から
`Capture i` で読みます。

```ocaml
let enter w (v : value) (arg : value) =
  match v with
  | VClos (label, base, _) ->
      let c = code w label in
      let env = bind w { vars = Map.empty; joins = Map.empty; caps = base } c.F.c_param arg in
      Some (c.F.c_body, env)
  | VPrim _ -> None
  | _ -> fault "expected a function"
```

**環境が空から始まる**のが、クロージャ変換が終わっていることの証拠です。呼び出し元の
環境は一切引き継がれません。必要なものは全部捕獲に入っています。

`VPrim` は基盤ライブラリの関数で、`None` を返して別の道へ行きます。基盤の関数は
すべて1引数で、複数要るものはタプルを取ります — SML の基盤ライブラリと同じ形です。

## 5. トレース

```
$ skunk --trace sum.sk
  fix sum
  ret sum
  let t.64 = (2, 0)
  let t.65 = sum t.64
  let p.57 = #1 a1.19
  let p.58 = #2 a1.19
  let n.2 = p.57
  let acc.3 = p.58
  let t.60 = =(n.2, 0)
  switch t.60
  let t.61 = -(n.2, 1)
  let t.62 = +(acc.3, n.2)
  let t.63 = (t.61, t.62)
  tailcall sum t.63
  let p.57 = #1 a1.19
  ...
```

1行が1ステップです。`tailcall` のあと `p.57` へ戻っていて、そのあいだに何も積まれて
いません。トレースは標準エラーへ出るので、プログラムの出力とは混ざりません。

プレリュード（`List` などを SkunkML で書いた部分）はトレースに出ません。誰も見たいと
言っていないからです。

## 6. 失敗

実行時の失敗も型エラーと同じ例外です。

```
$ skunk tests/errors/bounds.sk
val a : int array = [|0, 0|]
?: runtime error: Array.sub: index 5 out of 0..1
```

位置が `?` なのは、機械がソース位置を持っていないからです。ひとつだけ例外があって、
パターンマッチの失敗は生成された場所を覚えています。

```
$ skunk tests/errors/nomatch.sk
errors/nomatch.sk:1:5: warning: this match does not cover every case
val only : int * 'a -> 'a = fn
errors/nomatch.sk:1:5: match failure: no pattern matched
```

同じ行を、コンパイル時には警告として、実行時にはエラーとして言っています。

## 7. 値の印字

```ocaml
| VCon (c, _) when c.Types.cres.Types.tid = Types.list_tc.Types.tid -> show_list w v
```

リストだけ特別扱いして `[1, 2, 3]` と出します。それ以外の直和型は
`Node (Leaf, 1, Leaf)` のように構成子のまま。`ref` は `ref 3`、配列は `[|1, 2|]` で、
どちらも中身はストアから読みます。レコードのラベルが 1..n なら `(1, true)`、
そうでなければ `{ x = 1 }`。関数は `fn`。

負の数は `~3` です。SML の綴りに合わせています。

**実数だけは印字が規定です。** `machine.ml` はここで `Types.real_str` を呼ぶだけで、
どう綴るかは `types.ml` に書いてあります。有効数字は12桁まで、点のあとに必ず1桁、
符号は `~`、そして `0.0001` から `10^12` までの外は `1.0E12` や `1.5E~7` のような
指数形です。

```
$ skunk tests/reals.sk
val tenth : real = 0.1
val exponent : real = 15000000000.0
...
val quotient : real = 0.333333333333
...
val fixed : real list = [0.0001, 123456789012.0]
val scientific : real list = [1.0E~5, 1.0E12, 1.0E~300, 1.0E300]
val digits : real list = [0.333333333333, 0.666666666667, 3.14159265359]
val notNumbers : real list = [inf, ~inf, nan]
```

12桁なのは、`1.0 + 0.1` が `1.1` と出てほしいからです。double は10進で15〜17桁を
持っていますが、後ろのほうは10進で書いた数がそこにないという事実の見え方でしかない。
12桁で切ると `1.1000000000000001` は消え、それでいて `1.0 / 3.0` は12桁出ます。

**なぜ規定が要るのか。** コンパイラの実行時ライブラリは libc なしの C で、`printf` が
ありません（[14章](14-elf.md)）。それでも同じ値は同じバイト列で出なければならないので、
「よさそうに丸める」では足りない。だから `real_str` の仕様は**性質ではなく手順**として
書いてあります — 10.0 で割る／掛ける正規化のループ、`1e11` を1回掛けて 12桁の整数に
する、桁を取り出す。全部が IEEE-754 の binary64 演算と整数演算なので、同じ順で C に
書き直せばビットまで一致します。実数はまだコンパイルできないので、その C はまだ
書かれていません。

## 8. オーバーロードされた算術は値が決める

`+` は `int` と `real` の両方で意味を持ちますが（[2章](02-hm.md)の8節）、Core に出るのは
`+(a, b)` という1つのプリミティブです。型はここへは来ません。

```ocaml
let num fi fr a b =
  match (a, b) with
  | VInt a, VInt b -> VInt (fi a b)
  | VReal a, VReal b -> VReal (fr a b)
  | _ -> fault "%s wants two numbers of the same type" name
```

**もっと早く決めることはできません。** エラボレーションが `Prim` を出す時点では、
単一化が `int` か `real` かを決め終わっているとは限らない — `fun double x = x + x` は
呼ばれた場所で決まります。そして機械が走るころには、決めた型はもうどこにもありません。
`order` が `<` で同じことをしているのと同じ取引です（1つの綴り、値による分岐）。

コンパイラは同じ問いに別の答を出すことになります。命令を1つ選ばなければならないので、
どちらの算術かを**静的に**知る必要がある。ところが `Flat` には型がありません
（[7章](07-closure.md)）。だから振り分けは、型が残っている最後のパス —
クロージャ変換 — でやることになります。実数をコンパイルするときの仕事の1つで、
まだやっていません。

## していないこと

- **GC がありません。** 2節のとおり。ストアは増える一方です。コンパイラのほうには
  あります（[15章](15-gc.md)）。同じ言語の2つのバックエンドで、片方だけが回収します。
- **継続をストアに入れていません。** 本来の CESK\* はフレームもストアに置いて、
  すべての状態を有限にします（抽象解釈の下準備）。ここでは K は OCaml のリストです。
- **例外がありません。** 失敗はホストの例外で外まで飛び、プログラムが止まります。
  `handle` を入れるならフレームに2種類目が要ります。
- **`=` の実行時検査が残っています。** 関数と実数は型検査で止まる
  （[2章](02-hm.md)の7節）ので到達しないはずですが、`equal` はまだ落ちるように
  書いてあります。
- **NaN が「順序を持たない」扱いになっていません。** SML の `Real.compare` は
  `Unordered` を上げますが、例外がないので、「どの数より小さい」として全順序に
  してあります。`order` が型ごとに全順序であるほうが、機械としては単純です。
- **文字列の switch は線形探索です。**
- **プリミティブに部分適用がありません。** すべて1引数なので必要ありません。

## 参考文献

- Matthias Felleisen, Daniel Friedman, "Control Operators, the SECD Machine, and
  the λ-calculus", 1986. CESK の出典。
- Matthias Felleisen, Robert Findler, Matthew Flatt, *Semantics Engineering with
  PLT Redex*, MIT Press, 2009. CEK から CESK への道が丁寧。
- David Van Horn, Matthew Might, "Abstracting Abstract Machines", *ICFP* 2010.
  ストアに継続まで入れる（CESK\*）と、機械がそのまま静的解析になる話。
- Peter Landin, "The Mechanical Evaluation of Expressions", *Computer Journal*
  6(4), 1964. SECD。すべての祖先。

## 実装の地図

| ファイル | 何が |
|---|---|
| `src/interpreter/machine.ml` | `value`/`env`/`frame`/`world`（1節）、`alloc`/`get`/`set`/`bind`（1・2節）、`enter`（4節）、`run`（3・5節）、`prim`/`call_prim`（基盤）、`num`/`order`（8節）、`install_basis`（`basis.ml` が宣言した名前を機械の側で束縛する）、`show`（7節） |
| `src/front/types.ml` | `real_str`（7節）。実数の綴りの規定。値の印字なのに前段にあるのは、ダンプも `Real.toString` も同じものを使うから |
| `src/front/basis.ml` | 初期環境に何という名前があり、その型が何かという宣言と、SkunkML で書いたプレリュード。**どちらのバックエンドがどう提供するかは書いていない** — 共通の前段だから |
| `src/interpreter/skunk.ml` | 単位ごとのコンパイルと実行、`--trace`/`--steps` |

---

[← 7. クロージャ変換](07-closure.md) ・ [9. 言語リファレンス →](09-language.md)
