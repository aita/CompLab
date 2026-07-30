# 6. 篩型と SMT

`refine` システムでは基底型が**述語**を持てます。

```sml
fun inc (n : { v : int | v >= 0 }) : { v : int | v > 0 } = n + 1
```

`{ v : int | v >= 0 }` は「0 以上の整数」です。`v` は「その値」を指す名前で、篩型
（refinement type）の中でだけ意味を持ちます。関数型は引数に名前を付けられるので、結果が
引数について語れます。

```sml
fun max (a : int) (b : int) : { v : int | v >= a andalso v >= b } =
  if a >= b then a else b
```

この章に登場するのは4ファイルです。[`refine.ml`](../lab/src/refine.ml) が型検査、
[`logic.ml`](../lab/src/logic.ml) が論理式と検証条件（verification condition, VC）の形、
[`solver.ml`](../lab/src/solver.ml) が組み込みの決定手続き、
[`smt.ml`](../lab/src/smt.ml) が外部ソルバとの接続です。

## 部分型付けが含意になる

型検査の骨格は[4章](4-poly.md)と同じ双方向です。違うのは、部分型関係が**論理式**を生む
ところです。

```
Γ ⊢ { v : int | p } <: { v : int | q }
```

これが成り立つのは、`Γ` が知っていることと `p` を仮定して `q` が導けるときです。つまり

```
（環境の仮定たち） ∧ p[v := x]  ⟹  q[v := x]
```

という含意が valid であること。この含意が VC で、`Smt.discharge` に渡されます。

```ocaml
| Base (b1, v1, p1), Base (b2, v2, p2) ->
    (* 新しい名前 x を立てて、左の述語を仮定に、右の述語を目標にする *)
    vc env loc note (Logic.subst v2 (Logic.Var x) p2)
```

関数型は反変・共変で、引数を環境に入れてから結果を比べます。ここで引数が環境に入るからこそ、
`max` の結果の述語に出てくる `a` と `b` が意味を持ちます。

環境に情報が入る唯一の経路は**束縛**です。

```ocaml
let bind env x t =
  match t with
  | Base (b, v, p) ->
      (* x をソルバに宣言し、p[v := x] を仮定に加える *)
```

## 述語に式を入れないための2つの工夫

VC は決定可能な断片に収まっていなければなりません。そのために2つのことをしています。

### 1. 変数は単集合型を持つ

変数を合成すると、その変数と等しいという型が返ります（selfification）。

```ocaml
| Ast.Var x -> (
    match List.assoc_opt x env.binds with
    | Some (Base (b, _, _)) -> (singleton b (Logic.Var x), env)
```

`x : int` を合成すると `{ v : int | v == x }` です。これで等式が自然に流れ、環境を後から
掘り返す必要がなくなります。

### 2. 式は先に名前を付ける

述語に現れてよいのは変数・リテラル・それらの算術だけです。それ以外（関数呼び出しなど）が
論理の中に必要になったら、**新しい名前に束縛してから**使います。

```ocaml
and value_of env (e : Ast.t) (t : ty) : Logic.expr * env =
  match e.it with
  | Ast.Var x -> (Logic.Var x, env)
  | Ast.Int n -> (Logic.Lit n, env)
  ...
  | _ ->
      (* 名前を付けて、その型が言うことを仮定に加える *)
      let t', _ = synth env e in
      let x = fresh "t" in
      let env = bind env x t' in
      (Logic.Var x, env)
```

これは **ANF がやることを、型検査の側で必要な分だけやっている**のと同じです
（[2章](2-anf.md)）。液体型（liquid types）の実装が最初にプログラムを ANF に落とすのは、
まさにこの理由です。

## 分岐は仮定になる

`if` の各腕は、**その腕に入る条件を仮定して**検査されます。

```ocaml
| Ast.If (c, thn, els), _ ->
    let v, env = value_of env c bool_ in
    let _ = check (assume env v) thn t in
    let _ = check (assume env (Logic.Not v)) els t in
```

`abs` が結果型を満たすのはこれのおかげです。

```sml
fun abs (n : int) : { v : int | v >= 0 } = if n < 0 then -n else n
```

`then` 側では `n < 0` を仮定して `-n >= 0` を示し、`else` 側では `not (n < 0)` を仮定して
`n >= 0` を示す。どちらも組み込みソルバで足ります。

## 要求する側の VC — 除算

述語は「約束」だけでなく「要求」も書けます。除算の右辺は 0 でないことを要求します。

```ocaml
if op = "/" || op = "%" then
  vc env b.Ast.loc "the right operand of `div` must not be zero"
    (Logic.Cmp ("!=", vb, Logic.Lit 0));
```

これは型に書かれた要求ではなく、演算子そのものが持つ要求です。失敗するとこうなります。

```
$ mink tests/errors/divisor.mnk
tests/errors/divisor.mnk:2:43: cannot verify: b <> 0
    the right operand of `div` must not be zero
    it can fail when not (b <> 0)
```

`safeDiv` のように型で要求すれば、義務は呼び出し側に移ります。

```sml
fun safeDiv (a : int) (b : { v : int | v <> 0 }) : int = a div b
```

## VC を見る

`--dump-vc` で、生成された含意が SMT-LIB 2 で出ます。**目標を否定して充足不能性を問う**形に
なっているのは、それが SMT ソルバに聞ける形だからです。

```
$ mink --dump-vc tests/vc.mnk
-- vc.mnk:5:60: checking that this has type { v : int | v > 0 }
(set-logic QF_LIA)
(declare-const n Int)
(declare-const v1 Int)
(assert (>= n 0))
(assert (= v1 (+ n 1)))
(assert (not (> v1 0)))
(check-sat)
```

`n >= 0` が環境（引数の型）から、`v1 == n + 1` が本体から、最後の1行が目標の否定です。
`unsat` なら証明できたことになります。

同じ型を同じ型に照合するだけの自明な VC は生成しません。`--dump-vc` の出力が
「プログラムが実際に背負っている義務」の一覧になるようにしてあります。

## 組み込みの決定手続き

外部ソルバがなくても動くように、`solver.ml` に小さな手続きが入っています。2層です。

### 論理層 — 原子で場合分け

比較式と真偽値変数を**原子**とし、真偽を割り当てながら探索します。部分的な割り当てで式が
すでに偽なら、その枝は捨てます。学習も含意伝播もない DPLL です。原子が十数個までなら十分です。

真偽値どうしの等式（`v == true` など）は算術ではないので、探索の前に論理構造へ書き換えます
（`normalise`）。こうしておくと、残った原子はすべて算術になります。

### 算術層 — Fourier–Motzkin

1つの枝で真になった比較式を集め、変数を順に消去します。すべての制約を `Σ c·x + k ≤ 0` の形に
揃えてあるので、消去は「上限と下限を組み合わせて新しい制約を作る」だけです。

```ocaml
let eliminate v cs =
  (* v の係数が正のもの（上限）と負のもの（下限）を総当たりで組み合わせる *)
```

最後に変数のない制約だけが残るので、定数がすべて 0 以下かを見ます。

### ここが健全性と完全性の取引

Fourier–Motzkin が決めるのは**有理数上の**充足可能性です。変数は整数なのに、です。
それでも健全なのは、含意の向きが片方だからです。

- 有理数上で充足不能 ⟹ 整数上でも充足不能 ⟹ **目標は valid**（証明になる）
- 有理数上で充足可能 ⟹ 整数上のことは何も言えない ⟹ **「証明できなかった」と報告する**

だから、この手続きが「証明した」と言ったときは本物の証明です。言えなかったときは
`cannot verify` と出ますが、それは「偽である」ではありません。

有理数への緩和で失われる精度は、**整数版の強化**でかなり戻せます。整数では `e < 0` は
`e + 1 ≤ 0` なので、制約を作る時点でそう書きます。

```ocaml
(* `a < b` over the integers is `a - b + 1 <= 0`. *)
let lt a b = lin_add (lin_sub a b) (lin_const (qi 1))
```

これで、篩型が必要とする程度の算術（`examples/refine.mnk` の全部）は組み込みの手続きだけで
通ります。

非線形な項（変数どうしの積、除算、剰余）は**不透明な値**として抽象化します。同じ項は同じ
名前になるので `x * y == x * y` は証明できますが、それ以上のことは何も言えません。抽象化は
制約を増やさないので、これも健全側に倒れています。

### 外部ソルバに投げる

組み込みが諦めた VC は、同じ問題をそのまま本物のソルバに渡せます。

```
$ mink --smt "z3 -in" examples/refine.mnk
$ mink --smt "cvc5 --lang smt2" examples/refine.mnk
```

`smt.ml` は SMT-LIB 2 をコマンドの標準入力に書き、`unsat` / `sat` を読むだけです。
**2つのバックエンドには同じ質問が行きます**——`--dump-vc` で見えるあの質問です。

## 意図的に入れていないもの

- **述語の推論。** 液体型は、修飾子（qualifier）の集合から Horn 制約を解いて述語を**推測**
  します。MinkML は検査だけです。関数は自分の約束を書き、検査器はそれを確かめます。
- **多相。** `refine` は単型です。`forall` を書くと `poly` に案内されます。
- **測度（measure）とデータ型。** リストの長さのような測度はありません。基底型は
  `int`・`bool`・`unit` だけです。
- **完全な整数算術。** 上に書いたとおり、組み込み手続きは整数について不完全です。
  `--smt` がその答えです。
