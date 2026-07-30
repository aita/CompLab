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

## 用語

篩型は **基底型＋述語**です。集合として読むと、基底型の**部分集合**を書いていることになります
——述語が篩（ふるい）で、通らない値を落とします。

| | | |
|---|---|---|
| 基底型 (base type) | 篩をかける前の型 | `int`・`bool`・`unit` |
| 篩述語 (refinement predicate) | 住人を絞る論理式 | `v >= 0` |
| 値変数 (value variable) | 「その値自身」を指す名前 | `v`。篩の中でだけ束縛される |
| 依存関数型 (dependent function type) | 引数に名前が付き、結果の型がそれを参照できる型 | `(a : int) -> { v : int | v >= a }` |
| 検証条件 (VC) | 型検査が生んだ、1つの含意 | `n >= 0 ⟹ n + 1 > 0` |

値変数は篩の中でだけ生きているので、名前は何でもよく、`{ v : int | v >= 0 }` と
`{ x : int | x >= 0 }` は同じ型です。部分型判定が最初にすることは、両辺の値変数を1つの新しい
名前に揃えることです。

依存関数型が効くのは `max` のような場合です。引数に `a` という名前があるからこそ、結果の述語が
`v >= a` と書けます。**結果が引数について語れること**が、篩型を単なる assert 以上のものにして
います。

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

## valid と satisfiable — なぜ目標を否定するのか

示したいのは「この含意が **valid**（妥当）である」——どんな値の割り当てでも真である——ことです。
ところがソルバが判定するのは **satisfiability**（充足可能性）で、validity は直接聞けません。

| | |
|---|---|
| valid | どんな割り当てでも真 |
| satisfiable | 真になる割り当てが1つ以上ある |
| unsatisfiable | どう割り当てても偽 |

使うのはこの同値です。

```
F が valid   ⟺   ¬F が unsatisfiable
```

だから VC は「仮定を assert し、**目標を否定して** assert し、充足可能かを問う」形に組み替えられ
ます。答えの読み方は3通りです。

| ソルバの答え | 意味 |
|---|---|
| `unsat` | 反例が存在しない = **証明できた** |
| `sat` | 反例がある = プログラムが間違っている |
| `unknown` | 決められなかった。**「偽」ではない** |

3つめが独立した答えであることが、あとで出てくる健全性と完全性の取引の全部です。

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

## SMT とは何か

**SMT = Satisfiability Modulo Theories**（理論を法とする充足可能性）。

出発点は **SAT** ——命題論理の充足可能性です。`(p ∨ ¬q) ∧ (q ∨ r)` のように、原子が単なる真偽値の
式。NP完全ですが、現代の SAT ソルバ（**CDCL**: conflict-driven clause learning、DPLL の子孫）は
数百万変数を実用的に解きます。

SMT はそこで、**原子を「理論の言明」に取り替えます**。`p` のかわりに `v1 = n + 1` が入る。

### 理論と、量化子のない断片

理論 (theory) とは、記号の意味を公理で固定したものです。VC の1行目
`(set-logic QF_LIA)` が「どの理論で聞くか」の宣言です。

| 略号 | 理論 | |
|---|---|---|
| `QF_LIA` | 線形整数算術 | この章が使うもの |
| `QF_LRA` | 線形実数（有理数）算術 | 下の Fourier–Motzkin が実際に決めるのはこちら |
| `QF_UF` | 等号付き未解釈関数 | 「同じ項に同じ名前」だけを知る理論。非線形項の抽象化の居場所 |
| `QF_NIA` | 非線形整数算術 | **決定不能**（ヒルベルトの第10問題） |
| `QF_BV`・`QF_A` | ビットベクタ・配列 | |

`QF` は **quantifier-free**（量化子なし）です。ここが決定可能性の鍵で、量化子を入れると多くの
理論で決定不能になるか、決定可能でも爆発します（量化子つき整数算術＝**Presburger 算術**は
決定可能ですが二重指数）。**篩型が述語を量化子なしの線形算術に閉じ込めているのは、決定可能な
断片に留まるためです。**「述語に式を入れないための2つの工夫」は、この制限を守るための工夫です。

### DPLL(T)

現代のソルバの標準形はこうです。

1. **SAT 側**が、理論の原子を単なる命題変数と見なして真偽を割り当てる
2. **理論ソルバ (T-solver)** がその割り当ての無矛盾性を判定する。`x > 0` と `x < 0` を両方真に
   していたら矛盾
3. 矛盾なら理論ソルバが**衝突節 (theory lemma)** を返し、SAT 側がそれを学習して探索し直す

複数の理論を混ぜるときは **Nelson–Oppen 法**（各理論ソルバが等式を交換し合う）で組み合わせます。
線形整数算術の理論ソルバは、有理数上の **simplex** ＋ 整数解を探す
**branch-and-bound / cutting planes（Gomory カット）** が主流です。

次の節の組み込み手続きは、この DPLL(T) から学習と含意伝播を落として骨だけ残した形です——
論理層が 1 で、算術層が 2 に当たります。

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

## 液体型 — 述語を推論するということ

この章が実装しているのは**検査**です。関数が自分の約束を書き、検査器がそれを確かめる。
**液体型 (liquid types)** は述語そのものを推論します。アルゴリズムはこうです。

1. **修飾子 (qualifier)** の集合を人が与える。`v >= 0`・`v < ★`・`v == ★` のようなテンプレート
   で、`★` はスコープ内の変数が入る穴
2. 型の述語の位置に**述語変数 κ** を置く。`{ v : int | κ }`
3. 部分型制約を集める。「部分型付けが含意になる」のとおり、それは `κ₁ ∧ p ⟹ κ₂` の形
   ——つまり **Horn 制約**
4. 各 κ の候補を「修飾子の連言」に限り、**最小不動点**を反復で求める。制約を破る修飾子を
   落としていくだけなので必ず止まる（**述語抽象, predicate abstraction**）

推論の余地を「与えられた修飾子の連言」に限ることで決定可能にする、という取引です。
LiquidHaskell がこの系譜で、さらに遡ると F*・Dafny・Why3・ESC/Java があります。

## 篩型・依存型・契約

同じ「値についての性質を言う」ことを、3通りのやり方が分担しています。

| | 型が値に依存 | 証明を書くのは | 表現力 |
|---|---|---|---|
| 実行時契約 (contract) | しない | 誰も。実行時に落ちる | — |
| **篩型** | 述語で | ソルバ | 決定可能な断片の範囲 |
| **依存型**（[8章](8-dep.md)） | 型式が値を含む | 人（証明項を書く） | 制限なし |

**篩型の設計思想は、表現力を決定可能な断片に切り落とすかわりに、証明を全部機械にやらせること
です。** `refine` と `dep` が同じ言語の上に並んでいるのは、この取引を突き合わせるためです。

## 意図的に入れていないもの

- **述語の推論。** 上の液体型がしていることです。MinkML は検査だけで、関数は自分の約束を
  書きます。
- **多相。** `refine` は単型です。`forall` を書くと `poly` に案内されます。
- **測度（measure）とデータ型。** リストの長さのような測度はありません。基底型は
  `int`・`bool`・`unit` だけです。
- **完全な整数算術。** 上に書いたとおり、組み込み手続きは整数について不完全です。
  `--smt` がその答えです。

## 参考文献

- P. M. Rondon, M. Kawaguchi, R. Jhala, [*Liquid types*][liquid], PLDI 2008。修飾子・κ・
  Horn 制約・述語抽象。「液体型」の節がこれです。
- R. Jhala, N. Vazou, [*Refinement types: a tutorial*][rt-tutorial], 2020。篩型の入門として
  一番読みやすいもの。測度とデータ型まで含みます。
- R. Nieuwenhuis, A. Oliveras, C. Tinelli, [*Solving SAT and SAT modulo theories*][dpllt],
  JACM 53(6), 2006。「SMT とは何か」の DPLL(T) の節。
- G. Nelson, D. C. Oppen, [*Simplification by cooperating decision procedures*][no79],
  TOPLAS 1(2), 1979。理論を組み合わせる方法。
- L. de Moura, N. Bjørner, [*Z3: an efficient SMT solver*][z3], TACAS 2008。
  `--smt "z3 -in"` の相手。
- A. Schrijver, *Theory of Linear and Integer Programming*, Wiley 1986, §12。
  Fourier–Motzkin 消去と、有理数緩和が整数解について何を言えるか。
- C. Barrett, A. Stump, C. Tinelli, [*The SMT-LIB standard*][smtlib], version 2.0, 2010。
  `--dump-vc` が出す言語。

[liquid]: https://doi.org/10.1145/1375581.1375602
[rt-tutorial]: https://arxiv.org/abs/2010.07763
[dpllt]: https://doi.org/10.1145/1217856.1217859
[no79]: https://doi.org/10.1145/357073.357079
[z3]: https://doi.org/10.1007/978-3-540-78800-3_24
[smtlib]: https://smtlib.cs.uiowa.edu/papers/smt-lib-reference-v2.0-r10.12.21.pdf
