# 2. 数に型をつける — 整数を i64 に落とす

最初は数がすべて f64 でした。この章は、そのうち整数で済むものを i64 に落とす推論の
話です。目的は速度というより**サイズと精度**で、後者は少し意外な結果になります。

## 規則

整数のリテラルは i64 になり、それだけで組み立てられたものも i64 になります。値は
f64 と出会うところで広がり、狭まることはありません。

広がるのは3箇所です。

- `Start` の時刻。ホストから来るので f64 です
- 除算。両端が整数でも商は整数とは限りません
- `Log`・`End`・ブレークポイント。ホストが受け取るのは f64 です

`min` / `max` も f64 に倒します。wasm に i64 の最小・最大命令がないためです。

```
$ ferretc --emit ir compiler/test/typing.json
(func main (result f64)
  (local i int)
  (set i 0)
  (loop $1
    (if (< i 10)
      (then
        (log (float (% i 3)))
        (set i (+ i 1))
        (br $1))
      (else
        (return (/ (float i) 2))))))
```

対応する命令列:

```wat
(local $i i64)
i64.const 0
local.set $i
loop  ;; $1
  local.get $i
  i64.const 10
  i64.lt_s              ← 両辺が整数なので i64 の比較
  if
    local.get $i
    i64.const 3
    i64.rem_s           ← 1命令
    f64.convert_i64_s   ← ホストに渡すためにここで1回だけ広げる
    call $log
    …
```

`i64.rem_s` に注目してください。f64 には剰余命令がないので、浮動小数点の `%` は
`x - trunc(x / y) * y` に展開され、**8命令とスクラッチローカル2本**を使います。整数
なら1命令です。

## Counter は1回見ても型が決まらない

`i` が整数かどうかは、`i` の step を見れば分かります。ところがその式は `i` を
読みます。鶏と卵です。

そこで **lowering 全体を不動点にしました。** 最初は全 Counter を整数と仮定して
走り、狭すぎたと分かったらもう一度走ります。仮定は緩む方向にしか動かないので、
Counter の数ぶんの回数で必ず収束します。

```ocaml
(* Narrowing never happens in a settled pass: reaching it means a loop slot
   was assumed to be whole and is not, so this pass is about to be thrown
   away and what it emits does not matter. *)
let coerce ctx (e, ty) want =
  if ty = want then e
  else if ty = VInt then as_float (e, ty)
  else (
    ctx.too_narrow <- true;
    Int 0)
```

捨てられるパスが何を吐こうと関係ないので、狭める必要が出た地点では適当な値を置いて
先へ進みます。

collatz の例がこの仕組みの見本です。

```
(func main (result f64)
  (local cur float)          ← 27 から始まるが、2で割るので float
  (local steps int)          ← 0 から始まり 1 ずつ増えるので int
  …
```

`cur` は最初のパスで整数と仮定され、`cur / 2` が整数とは限らないと分かった時点で
緩められ、2回目のパスで float として lowering されます。

## 効果

| | すべて f64 | 整数を i64 |
|---|---|---|
| Sum of 1 to n | 169 | **160** バイト |
| Collatz steps | 242 | **250** |
| π by throwing darts | 290 | **276** |
| 上の検証用グラフ | 188 | **166** |

（f64 側の数は Loop / Count ノードだった頃のもので、いまの節点集合で測り直しては
いません。i64 側は現在の値で、f64 側には無かったインポート2本を含んでいます。小さな
モジュールでは、いまや import セクションがいちばん大きい部分です。）

差の大半は定数です。`f64.const` は**オペコード1 + 8バイト**の9バイト、`i64.const` は
LEB128 なので小さい値なら**2バイト**です。

## なぜ i32 ではないのか

`sum(1..100000)` は 5,000,050,000 です。i32 は 2³¹ ≈ 21億までなので、静かに溢れて
壊れます。それが flagship の例で起きるのは論外でした。

そして重要なのは、**整数プログラムに関しては i64 のほうが f64 より正確だ**という
ことです。f64 が整数を正確に表せるのは 2⁵³ までで、それを超えると丸めが始まります。
i64 は 2⁶³ まで正確です。最適化のつもりで入れたものが、精度も上げています。

悪くなる点は1つだけあります。`i64.rem_s` は 0 で割るとトラップします。f64 の `%` は
NaN を返していました。README に明記しています。

## 型は木から読める

lowering が終わった時点で、演算子の両辺は必ず同じ型になっています。だから型は木から
読み戻せます。emit は型注釈を持ち回る必要がありません。

```ocaml
let rec type_of locals = function
  | Int _ -> VInt
  | Num _ | Widen _ | Rand _ -> VFloat
  | Local i -> locals i
  | Bin ((Div | Min | Max), _, _) -> VFloat
  | Bin (_, a, _) -> type_of locals a
  …
```

## 混ぜても壊れないことの確認

型が混ざったモジュールは、wasm の検証で弾かれます。逆に言えば、**instantiate が
通ることが命令選択の正しさの検査**になります。ランダムなグラフを600個生成して、
コンパイルできたものを全部 instantiate しました。

```
600 graphs, 299 compiled, 0 hangs, 0 invalid
```

生成には breakpoint・random・埋め込み定数・小数リテラル・実行エッジの循環も
混ぜています。

次は[3章 バイト列を手で書く](emit.md)。
