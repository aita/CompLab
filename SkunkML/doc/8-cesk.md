# 8. CESK マシン

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

CEK なら環境が名前を値へ直接写せば済みます。この言語の値は**配列を除いて**一度作ったら
変わらないので、それで足ります。

配列があると足りません。

```sml
val zeroes = Array.array (5, 0)
val alias = zeroes
val () = Array.update (alias, 2, 99)
val throughTheOther = Array.sub (zeroes, 2)   (* 99 *)
```

`zeroes` と `alias` は同じ**場所**を指していなければなりません。値のコピーではなく。

そこで変数は場所を指し、ストアが中身を言う、という2段にします。配列は番地の連なりです。

```ocaml
| VArray of int * int      (* 先頭番地、長さ *)
```

`Array.update` はストアを1箇所書き換えるだけで、機械の他の部分は何も変わりません。
**これが4つ目の要素の説明の全部です。**

```
$ skunk examples/arrays.sk
val zeroes : int array = [|0, 0, 0, 0, 0|]
val contents : int list = [10, 0, 0, 0, 40]
val alias : int array = [|10, 0, 0, 0, 40|]
val throughTheOther : int = 99
```

`zeroes` の行が全部ゼロなのは、その時点でまだ書き換えていないからです。報告は束縛の
たびに出ます。

同じ理由で[2章](2-hm.md)の3節に値制限があります。**ストアがあるから値制限が要る**、
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

A正規形では「値を待っているもの」は `let` しかありません（[4章](4-core.md)の1節）。
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

`jump` も積みません（[6章](6-join.md)の6節）。ラベルへ跳ぶのは呼び出しではない、が
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

前奏（prelude、`List` などを SkunkML で書いた部分）はトレースに出ません。誰も見たいと
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
`Node (Leaf, 1, Leaf)` のように構成子のまま。配列は `[|1, 2|]` で、中身はストアから
読みます。関数は `fn`。

負の数は `~3` です。SML の綴りに合わせています。

## していないこと

- **GC がありません。** 2節のとおり。ストアは増える一方です。
- **継続をストアに入れていません。** 本来の CESK\* はフレームもストアに置いて、
  すべての状態を有限にします（抽象解釈の下準備）。ここでは K は OCaml のリストです。
- **例外がありません。** 失敗はホストの例外で外まで飛び、プログラムが止まります。
  `handle` を入れるならフレームに2種類目が要ります。
- **`=` は eqtype を見ません。** 関数を比べようとしたときに実行時に落ちます。
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
- 隣の [MinkML](../../MinkML) の `lab/src/machine.ml` は CEK です。あちらは可変な値を
  持たないので S が要りません。並べると S が何のためにあるかが分かります。

## 実装の地図

| ファイル | 何が |
|---|---|
| `src/machine.ml` | `value`/`env`/`frame`/`world`（1節）、`alloc`/`get`/`set`/`bind`（1・2節）、`enter`（4節）、`run`（3・5節）、`prim`/`call_prim`（基盤）、`show`（7節） |
| `src/basis.ml` | 初期環境と、SkunkML で書いた前奏 |
| `src/skunk.ml` | 単位ごとのコンパイルと実行、`--trace`/`--steps` |

---

[← 7. クロージャ変換](7-closure.md) ・ [9. 言語リファレンス →](9-language.md)
