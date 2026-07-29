# 2. 数に型をつける — 整数を i64 に落とす

最初は数がすべて f64 でした。この章は、そのうち整数で済むものを i64 に落とす推論の
話です。目的は速度というより**サイズと精度**で、後者は少し意外な結果になります。

## 規則

整数のリテラルは i64 になり、それだけで組み立てられたものも i64 になります。値は
f64 と出会うところで広がり、狭まることはありません。

広がるのは4箇所です。

- `Time` と `Random` と `Input`。ホストから来るので f64 です
- 除算。両端が整数でも商は整数とは限りません
- `Log`・`Out`・ブレークポイント。ホストが受け取るのは f64 です
- `Feedback` の開始値が整数でなかったとき

`min` / `max` も f64 に倒します。wasm に i64 の最小・最大命令がないためです。

```
$ ferretc --emit ir compiler/test/typing.json
(global i int)
(func main (result f64)
  (local result float)
  (local i_next int)
  (log (float (% i 3)))
  (set result (/ (float i) 2))
  (set i_next (+ i 1))
  (set i i_next)
  (return result))
```

対応する命令列:

```wat
(global $i (export "state_i") (mut i64) (i64.const 0))
(func $main (export "main") (result f64)
  (local $result f64)
  (local $i_next i64)
  global.get $i
  i64.const 3
  i64.rem_s             ← 1命令
  f64.convert_i64_s     ← ホストに渡すためにここで1回だけ広げる
  call $log
  global.get $i
  f64.convert_i64_s     ← 商は整数とは限らないのでここでも広げる
  f64.const 2.0
  f64.div
  local.set $result
  …
```

`i64.rem_s` に注目してください。f64 には剰余命令がないので、浮動小数点の `%` は
`x - trunc(x / y) * y` に展開され、**8命令とスクラッチローカル2本**を使います。整数
なら1命令です。

## Feedback は1回見ても型が決まらない

`i` が整数かどうかは、`i` に与えられる式を見れば分かります。ところがその式は `i` を
読みます。鶏と卵です。

そこで **lowering 全体を不動点にしました。** 最初は全 Feedback を整数と仮定して
走り、狭すぎたと分かったらもう一度走ります。仮定は緩む方向にしか動かないので、
Feedback の数ぶんの回数で必ず収束します。

```ocaml
(* Narrowing never happens in a settled pass: reaching it means a feedback
   slot was assumed to be whole and is not, so this pass is about to be
   thrown away and what it emits does not matter. *)
let coerce ctx (e, ty) want =
  if ty = want then e
  else if ty = VInt && want = VFloat then as_float (e, ty)
  else if is_num ty && is_num want then (
    ctx.too_narrow <- true;
    Int 0)
  else …
```

捨てられるパスが何を吐こうと関係ないので、狭める必要が出た地点では適当な値を置いて
先へ進みます。

`examples/count.json` がこの仕組みの見本です。

```
(global step float 1)      ← Input はホストが書くので f64
(global count float)       ← その step を足されるので、整数のつもりでも f64
```

`count` は最初のパスで整数と仮定されます。`count + step` の `step` が f64 だと
分かった時点で緩められ、2回目のパスで float として lowering されます。同じグラフの
`step` を Input ではなく Constant にすると、両方とも int になります。

## 効果

数のリテラルを全部 f64 にしたコンパイラを1本組んで、同じグラフを通しました。

| | すべて f64 | 整数を i64 |
|---|---|---|
| 上の検証用グラフ | 212 | **180** バイト |
| Bounce | 252 | **223** |
| Monte Carlo | 360 | **328** |
| Blink | 217 | **204** |
| Counting | 199 | 199 |
| Wave | 228 | 228 |

最後の2つが動かないのは、Input と 0.25 が f64 なので**元から整数が1つも無い**から
です。推論が効いていないのではなく、効く余地がありません。

差の大半は定数です。`f64.const` は**オペコード1 + 8バイト**の9バイト、`i64.const` は
LEB128 なので小さい値なら**2バイト**です。

この規模のモジュールでは、中身よりそれを説明するセクションのほうが大きいことにも
注意してください。180 バイトのうち命令はごく一部です。

## なぜ i32 ではないのか

Feedback は cook をまたいで足し込み続けます。i32 は 2³¹ ≈ 21億までなので、1 cook で
100 万足すグラフなら 2000 cook ちょっとで静かに溢れます。走らせっぱなしにできるのが
このモデルの売りなのに、走らせっぱなしにすると壊れるのでは話になりません。

そして重要なのは、**整数プログラムに関しては i64 のほうが f64 より正確だ**という
ことです。f64 が整数を正確に表せるのは 2⁵³ までで、それを超えると丸めが始まります。
i64 は 2⁶³ まで正確です。最適化のつもりで入れたものが、精度も上げています。

悪くなる点は1つだけあります。`i64.rem_s` は 0 で割るとトラップします。f64 の `%` は
NaN を返していました。README に明記しています。

## 型は木から読める

lowering が終わった時点で、演算子の両辺は必ず同じ型になっています。だから型は木から
読み戻せます。emit は型注釈を持ち回る必要がありません。

```ocaml
let type_of ~locals ~globals =
  let rec go = function
    | Int _ -> VInt
    | Num _ | Widen _ | Rand _ | Now -> VFloat
    | Local i -> locals i
    | Global i -> globals i
    | Bin ((Div | Min | Max), _, _) -> VFloat
    | Bin (_, a, _) -> go a
    …
```

## 混ぜても壊れないことの確認

型が混ざったモジュールは、wasm の検証で弾かれます。逆に言えば、**instantiate が
通ることが命令選択の正しさの検査**になります。ランダムなグラフを600個生成して、
コンパイルできたものを全部 instantiate しました。

```
{ rounds: 600, compiled: 86, cooked: 86, invalid: 0, hangs: 0 }
```

生成には breakpoint・random・埋め込み定数・小数リテラル・真偽を持つ Feedback も
混ぜています。instantiate したあと `main` を**2回**呼んでいるのは、1回目が Feedback
に置いていったものを2回目が読むからです — 型が合っていなければそこで落ちます。

残り 514 個はコンパイルを断られたものです。無作為に線を張ると、繋ぎ忘れた入力か、
Feedback を通らない閉路のどちらかにたいてい引っかかります。

次は[3章 バイト列を手で書く](emit.md)。
