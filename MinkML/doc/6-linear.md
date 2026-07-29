# 6. 線形型とセッション型

`linear` システムでは、すべての型が**修飾子**を持ちます。`un`（unrestricted）は何回使っても
よく、0回でもよい。`lin`（linear）は**ちょうど1回**使わなければなりません。

これは Walker による Advanced Topics in Types and Programming Languages 第1章の体系です。
そこから出てくる規則は2つだけで、実装
（[`lab/src/linear.ml`](../lab/src/linear.ml)）はほとんどその2つでできています。

## 用語 — 部分構造型システム

ふつうの型システムの文脈（`x : A, y : B, ...`）には、暗黙に2つの構造規則が入っています。

| | 意味 | 使われ方 |
|---|---|---|
| **弱化 (weakening)** | 仮定を使わなくてよい | 束縛した変数を1度も使わないことが許される |
| **縮約 (contraction)** | 仮定を何度でも使ってよい | 同じ変数を2回書くことが許される |

**部分構造型システム (substructural type system)** とは、このどちらかを**落とした**体系の
ことです。落とし方で名前が変わります。

| 体系 | 弱化 | 縮約 | 使用回数 |
|---|---|---|---|
| ふつう（un） | ある | ある | 0回以上 |
| **アフィン (affine)** | ある | ない | 0回か1回 |
| 関連 (relevant) | ない | ある | 1回以上 |
| **線形 (linear)** | ない | ない | **ちょうど1回** |
| 順序 (ordered) | ない | ない | ちょうど1回、しかも**順番どおり** |

このシステムが持つのは `un` と `lin` の2つだけです。そして実装の2つの規則は、落とした構造規則
そのものです——「文脈を分割する」が**縮約の否定**、「残ってはいけない」が**弱化の否定**。

出どころは Girard の**線形論理 (linear logic)** です。記法もそこから来ています。

| 記法 | 読み | この処理系では |
|---|---|---|
| `A -o B` | 線形含意 (lollipop) | 1回だけ適用できる関数。`lin` なクロージャの型 |
| `!A` | of course / 指数 | 「何回でも使える A」。ここでは修飾子 `un` がその役 |
| `A (x) B` | テンソル積 | `lin (A * B)`。両方を消費する対 |

**なぜ線形性が要るのか。** 型が「残っているプロトコル」を表すなら、端点を2つに複製できたら
2人が別々にプロトコルを進めてしまいます。捨てられたら相手が永遠に待ちます。**ちょうど1回**が、
プロトコルの状態と実際の通信を一致させる条件です。だから「セッション型固有の考えは双対性だけで、
健全性を支えているのは線形性」になります。

セッション型のまわりの語:

| | |
|---|---|
| セッション型 (session type) | チャネルの端点の型。残りのプロトコルを表す |
| 内部選択 (internal choice) `+{...}` | **こちら**が選ぶ。`select` する側 |
| 外部選択 (external choice) `&{...}` | **相手**が選ぶ。`branch` で全部答える側 |
| 双対 (dual) | 送受信と選択の向きを入れ替えたプロトコル。ピアが持つ型 |
| 委譲 (delegation) | チャネルの端点をチャネルで送ること |

## 規則1 — 文脈を共有せず分割する

部分項を検査すると、**使い残しの文脈**が返ります。次の部分項はその残りから始めます。

```ocaml
let use loc ctx x =
  let t = lookup loc ctx x in
  if is_lin t then (t, List.remove_assoc x ctx)   (* 線形なら取り去る *)
  else (t, ctx)                                    (* un ならそのまま *)
```

2回使えないのは、2回目が見つけられないからです。エラーは「使用済み」として報告されます。

```
$ mink tests/errors/twice.mnk
tests/errors/twice.mnk:7:23: type error: c has linear type chan (!int ; !int ; stop)
and has already been used: a linear value is used exactly once
```

逆に「残ってしまった」ことも検出されます。関数の本体を抜けるとき、`let` を抜けるとき、
そしてプログラムの最後で、線形な束縛が残っていればエラーです。

```
$ mink tests/errors/dropped.mnk
tests/errors/dropped.mnk:4:15: type error: c has linear type chan (!int ; stop) and is never used
```

分岐は特別です。**どの腕も同じものを使わなければなりません**。片方だけで使うと、
プログラムの振る舞いが「どちらを通ったか」に依存してしまいます。

```ocaml
let same_leftovers loc a b = (* 残った線形名の集合が一致するか *)
```

## 規則2 — `un` は `lin` を含めない

`un` な値の中に `lin` な値が入っていると、外側をコピーすることで中身もコピーできてしまいます。
だから `un (int * chan S)` のような型は存在しません。

```
$ mink -s linear /dev/stdin <<< 'val x : un (lin int * int) = (1, 2)'
type error: `un (lin int * int)` would let a linear value be copied with the pair that holds it
```

同じ理由が**クロージャ**にも効きます。線形な変数を捕獲したクロージャは線形です。ここが
このシステムで唯一「修飾子が推論される」場所で、書く必要がありません。**検査の前後で外側の
文脈を比べ、線形なものが消えていたら捕獲したと分かる**という仕掛けです。

```ocaml
let before = linear_names ctx in
...
let captured = List.exists (fun x -> not (List.mem_assoc x out)) before in
(TFun ((if captured then Lin else Un), dom, cod), out)
```

```sml
val addedOnce =
  let val p : lin (int * int) = (10, 20)
      val adder = fn (n : int) => let val (x, y) = p in x + y + n end
  in adder 12 end
```

`adder` の型は `int -o int` になり、それ自身も1回しか適用できません。

なお、逆向きの緩和は許しています。**`un` な値は `lin` が要求される場所に渡せます**——
1回だけ使うという約束は、誰でも守れる約束です。型の一番外側でだけ許し、内側では許しません
（内側で許すと反変の位置で壊れます）。

```ocaml
let compatible got want =
  equal got want || (qual_of got = Un && equal (set_qual Lin got) want)
```

## セッション型

ここまでが線形型で、セッション型はその上にほとんど無料で乗ります。

チャネルの端点は線形です——2つのピアの歩調を合わせる方法が他にないので。そして端点の型は
**残っているプロトコル**です。

```
chan (!int ; ?bool ; stop)     int を送り、bool を受け取り、終わる
+{ `add : S1, `quit : S2 }     こちらが選ぶ（内部選択）
&{ `add : S1, `quit : S2 }     相手が選ぶ（外部選択）
```

操作は5つで、どれも「端点を消費して、残りのプロトコルを型に持つ端点を返す」形です。

| 式 | 型 |
|---|---|
| `send v c` | `c : chan (!A ; S)`、`v : A` ならば `chan S` |
| `recv c` | `c : chan (?A ; S)` ならば `lin (A * chan S)` |
| `close c` | `c : chan stop` ならば `unit` |
| `select `l c` | `c : chan (+{ ..., `l : S, ... })` ならば `chan S` |
| `branch c of `l c' => e \| ...` | `c : chan (&{ ... })`。腕ごとに `c'` が続きの端点 |
| `fork f` | `f : chan S -o unit` ならば `chan (dual S)` |

だから、プロトコルを進める記述はこうなります。同じ名前を再束縛していくのが定型です。

```sml
fun classify (c : chan (?int ; !bool ; stop)) : unit =
  let val (n, c) = recv c
      val c = send (n > 10) c
  in close c end
```

`val c = send ... c` の右の `c` と左の `c` は別の型です。線形性があるので、古い `c` が
残って誤用される心配はありません。

### 双対性

`fork` が2つの端点を作り、片方を子プロセスに渡します。渡すのは**双対**のプロトコルです。

```ocaml
let rec dual = function
  | SSend (t, s) -> SRecv (t, dual s)
  | SRecv (t, s) -> SSend (t, dual s)
  | SSelect ls -> SBranch (List.map (fun (l, s) -> (l, dual s)) ls)
  | SBranch ls -> SSelect (List.map (fun (l, s) -> (l, dual s)) ls)
  | SStop -> SStop
```

送信は受信に、こちらの選択は相手の選択に入れ替わります。**セッション型のうち、セッション
固有の考えはこれだけ**です。健全性を支えているのは前半の線形性です。

`branch` は選択肢を**すべて**答えなければなりません。相手はどれを選ぶか分からないからです。

```
$ mink tests/errors/branches.mnk
tests/errors/branches.mnk:3:3: type error: the protocol offers `yes : stop, `no : stop;
every branch must be answered
```

### 委譲

チャネルもただの値なので、チャネルの上で送れます。プロトコルが値と一緒に移動します。

```sml
fun broker (c : chan (?chan (!int ; ?int ; stop) ; stop)) : unit =
  let val (w, c) = recv c
      val () = close c
      val w = send 41 w
      val (answer, w) = recv w
      val () = print answer
  in close w end
```

`examples/session.mnk` の最後がこれで、broker は worker と直接話さずに端点を受け取って
使います。

## 実行時に見えるもの

セッション型は「プロトコルの順序が守られる」ことを静的に保証しますが、**守られている様子**は
実行しないと見えません。機械はプロセスとストアを持っているので、それが観察できます
（[2章](2-anf.md)）。

```
$ mink examples/session.mnk
...
1
10
2
20
pinged : unit = ()
```

通信は1メッセージ分のバッファなので、送信側は相手が取るまで先に進めません。だから2つの
プロセスが交代します。全プロセスがブロックしたら、機械はデッドロックとして報告します
——ただし1本のチャネルだけを使う限り、型が付いたプログラムでそれは起きません。

## どこまで推論するか

| 書くもの | 推論されるもの |
|---|---|
| 引数の型（`fn (x : int) => ...`） | クロージャの修飾子（捕獲から決まる） |
| `lin` / `un`（基底型・対に付けるとき） | 対の修飾子（成分が `lin` なら `lin`） |
| セッション型（チャネルの引数） | `send`/`recv` 後の残りプロトコル |
| `fun` の引数と結果の型（再帰するので必要） | — |

## 意図的に入れていないもの

- **再帰的セッション型。** `rec X. !int ; X` のような無限に続くプロトコルは書けません。
  1回のやり取りで終わる有限のプロトコルだけです。
- **多相。** 単型です。`send` などが多相に見えるのは、それらが環境の項ではなく検査器の
  特別扱いだからです。
- **マルチパーティ・セッション型。** 2者間だけです。
- **アフィン型・順序型。** 修飾子は `lin` と `un` の2つだけで、「0回か1回」（affine）や
  順序に関する制限はありません。
- **`fst`/`snd`。** 対は `let val (x, y) = p` で分解します。射影は線形な対を壊すので、
  この体系には置けません。

## 参考文献

- J.-Y. Girard, [*Linear logic*][ll], Theoretical Computer Science 50(1), 1987。
  弱化と縮約を落とすという発想、`-o` と `!` の記法。
- D. Walker, *Substructural type systems*, in *Advanced Topics in Types and Programming
  Languages*（B. C. Pierce 編）, MIT Press 2005, 第1章。この章が実装した体系。修飾子
  `lin`/`un` を型に付けて、文脈を分割する形はここです。
- K. Honda, [*Types for dyadic interaction*][honda], CONCUR 1993。セッション型の最初の形。
- K. Honda, V. T. Vasconcelos, M. Kubo, [*Language primitives and type discipline for
  structured communication-based programming*][honda98], ESOP 1998。`select`/`branch` と
  双対性を含む、いま使われている形。
- P. Wadler, [*Propositions as sessions*][wadler12], ICFP 2012。セッション型と線形論理が
  同じものだという読み。上の「健全性を支えているのは線形性」を正面から述べたものです。

[ll]: https://doi.org/10.1016/0304-3975(87)90045-4
[honda]: https://doi.org/10.1007/3-540-57208-2_35
[honda98]: https://doi.org/10.1007/BFb0053567
[wadler12]: https://doi.org/10.1145/2364527.2364568
