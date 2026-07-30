# 10. SSA — join point は φ だった

ここから2つ目のバックエンドです。機械が `Flat` を走らせるのに対して、コンパイラは
同じ `Flat` から**静的単一代入形式**（SSA）を作ります。始点が同じなのは意図で、
そこまでで**モジュールもパターンも入れ子の関数も消えている**からです。

この章の主張は1行です。**[6章](6-join.md)の join point は、SSA の φ 関数でした。**

## 用語

| | |
|---|---|
| SSA | どの値もちょうど1箇所で定義される形 |
| 値 SSA (value SSA) | 名前を経由せず、値そのものを指す書き方 |
| 基本ブロック | 分岐のない命令の並び。1つの終端子で終わる |
| φ 関数 | 合流点で「どの道から来たか」によって値を選ぶもの |
| 支配 (dominate) | 入口からその点へ行く道が必ず通ること |
| 支配木 | 直近の支配者を親とする木 |
| 逆後行順 (RPO) | 支配者が必ず先に来るブロックの並び |

## 1. 同じ関数を、2つの形で

[6章](6-join.md)の `inline` です。左が Core、右が SSA。

```sml
fun inline b = "it is " ^ (if b then "yes" else "no")
```

```
$ skunk --dump-core tests/join.sk        $ skunkc --dump-ssa tests/join.sk
let inline = fn a1.21 : bool =>          func inline$3:
  let b.3 : bool = a1.21                   b0:
                                             v0 = param              ; a1.21
                                             v1 = const "yes"
                                             v2 = const "no"
                                             v3 = const "it is "
  join k (v : string) =                      switch v0 [true -> b2, false -> b1]
    let t.62 = ^("it is ", v)              b1:              ; preds b0
    ret t.62                                 jump b3
  switch b.3 of                            b2:              ; preds b0
  | true =>                                  jump b3
      jump k ("yes")                       b3:              ; preds b2 b1
  | false =>                                 v4 = phi [b2: v1, b1: v2]   ; v
      jump k ("no")                          v5 = prim ^ v3, v4          ; t.62
                                             ret v5
```

指で追えます。`join k (v)` が `b3` と `v4 = phi […]` に、`jump k ("yes")` が
「b2 から b3 への辺」と「φ の第1引数」に。木が graph になっただけです。

`;` のあとは Flat の束縛名で、読むためのコメントです。SSA の側に名前はありません。

## 2. 値 SSA — 名前がない

教科書の SSA の説明は「変数 `x` を `x₁`, `x₂` に版分けする」から入ります。ここでは
版分けする変数がありません。

```ocaml
type value = {
  mutable vid : int;
  mutable op : op;
  mutable args : value list;   (* 使っている値そのものへの参照 *)
  mutable home : block;
  mutable uses : int;
  origin : string;             (* もとの Flat の名前。印字用 *)
}
```

**値とは、演算とそれが使う値の組**です。`v5 = prim ^ v3, v4` の `v3` と `v4` は
スコープで引く名前ではなく、その演算が産んだ値そのものです。定数も値なので
（`v1 = const "yes"`）、オペランドは常に他の値です。

こうすると単一代入は**維持するものではなくなります**。値が1箇所でしか定義されないのは、
値が*その場所そのもの*だからです。そして3つが1歩で済むようになります。

- **def-use。** ある値を別の値で置き換えるのは1回の走査。使用回数はフィールド1つ。
- **共通部分式除去。** 同じ演算で同じ引数値なら、同じ値。
- **命令選択。** DP タイラーは「使用回数が2以上の値」で DAG を木に切ります。
  その回数がここにあります。

## 3. 変換は、ほとんど形の入れ替え

| Flat | SSA |
|---|---|
| コードブロック | 関数と、その入口ブロック |
| `let x = rhs` | ブロックに積まれる値1つ |
| `join j (x) = …` | 新しいブロックと、そのブロックの φ |
| `jump j (a)` | 終端子と、φ の引数1つ |
| `switch` | 終端子と、枝ごとの新しいブロック |

φ の引数は jump に出会うたびに集まるので、`join` は**本体より先に継続を変換します** —
jump は継続の側にあるからです。

素直でないのは2箇所だけです。

### 定数は値になる

Flat のオペランドはアトムで、リテラルはその場に書かれています。ここでは何もかもが値
なので、リテラルは `Const` 値になります。置き場所は**入口ブロック**です。入口は全部を
支配するので、どのブロックからでも使えます。ついでにハッシュコンスしてあるので、
プログラム中の `0` は、いくつのブロックが使っても1つの値です。

### 再帰する閉包は、確保と充填に割れる

```sml
fun parity n =
  let fun even 0 = true | even k = odd (k - 1)
      and odd 0 = false | odd k = even (k - 1)
  in even n end
```

`even` は `odd` を捕獲し、`odd` は `even` を捕獲します。**SSA は定義の循環を書けません** —
どちらを先に書いても、もう片方がまだない。

```
func parity$1:
  b0:
    v0 = param                             ; a1.19
    v1 = mkclos even$2, 1                  ; even
    v2 = mkclos odd$3, 1                   ; odd
    setcap 0, v1, v2
    setcap 0, v2, v1
    tailcall v1, v0
```

まず両方を確保し、それから中身を書きます。[7章](7-closure.md)の3節で機械が実行時に
やっていたことと同じですが、あちらは「そうすると書きやすい」で、こちらは**形がそれを
強制します**。SSA の性質が実装を決めた、数少ない場所です。

## 4. 支配木は作る。ただし有名な用途のためではない

`d` が `b` を**支配する**とは、入口から `b` へ行く道が必ず `d` を通ることです。直近の
支配者を親にすると木になります。

作り方は反復アルゴリズムです。逆後行順でブロックを回り、述語たちの支配者を交わらせ、
変化がなくなるまで繰り返す。漸近的に最速ではありません（Lengauer–Tarjan がそれです）が、
1ページで書けて実際には速く、読んで分かるように書かれたほうです。

**そして SSA の教科書で支配木がいちばん有名な用途 — 支配辺境による φ の配置 — は
ここでは走りません。** Cytron らのアルゴリズムは「可変変数を持つグラフから始めて、
φ をどこに置くか計算する」ものです。ここでは置き場所が既に書いてあります。join point の
引数として。

支配木が要るのは、その下にある2つのためです。

- **検証**（次の節）
- **レジスタ割り付け**。SSA の干渉グラフは弦グラフなので、支配木の前順走査で貪欲に
  彩色すれば最適になります。これはまだ書いていません。

## 5. 主張を検査にする

「ANF ＋ join point はもう SSA だ」は気持ちのよい主張ですが、気持ちのよい主張ほど
確かめるべきです。検証器が見るのは2つです。

- **すべての使用が、その定義に支配されているか。** 同じブロック内なら定義が先か。
- **φ の引数の数が、そのブロックの述語の数と合っているか。** そして i 番目の引数が
  i 番目の述語の終わりまで届いているか（φ は自分のブロックの先頭ではなく、**辺の上**で
  評価されるものだからです）。

これはテストに入っていて、リポジトリの全プログラムで走ります。

```sh
dune test        # examples とテストの全部が SSA を作り、全部が検証を通る
```

`--no-verify` で外せますが、外す理由はいまのところありません。

## 6. ここで止まっている

`skunkc` は SSA を作って、検査して、印字するところまでです。残りはこの順です。

1. **表現の低下。** 多相なので値は1ワード。整数にタグを付け、レコード・閉包・構成子を
   確保と load/store に落とす。ここで `field v0, 1` がオフセットになります。
2. **DP による命令選択。** 値グラフを木に切り（使用回数が2以上、ブロックをまたぐ、
   副作用がある、で切る）、タイル文法に対する動的計画法で木ごとに最適に敷き詰める。
   amd64 でこれが効くのはアドレッシングモードがあるからです。
3. **レジスタ割り付け。** SSA の干渉グラフは弦グラフ。支配木の前順で貪欲に彩色。
4. **SSA からの脱出。** φ を並列コピーに直す。lost-copy 問題と swap 問題。
5. **出力。** `.s` を吐いて `cc` でリンクする。x86-64 の上で走っているので、
   エミュレータは要りません。

## していないこと

- **最適化パスがありません。** 定数畳み込みも CSE も DCE も、値 SSA なら書きやすい
  はずですが、まだありません。
- **関数内にループがありません。** join point は自分より外側にしか跳べないので、
  関数の CFG は DAG です。ループは末尾呼び出しとして現れます。自己末尾呼び出しを
  入口ブロックへの jump に変えれば（contification）本物のループができて、そこで
  レジスタ割り付けが面白くなります。
- **メモリを SSA に載せていません。** ブロックは命令の順序つきリストなので、副作用の
  順序はリスト順です。載せる流儀（Go）もありますが、教科書はこちらです。
- **臨界辺を分割していません。** SSA から出るときに要ります。

## 参考文献

- Ron Cytron, Jeanne Ferrante, Barry Rosen, Mark Wegman, Kenneth Zadeck,
  "Efficiently Computing Static Single Assignment Form and the Control
  Dependence Graph", *TOPLAS* 13(4), 1991. SSA と、支配辺境による φ の配置。
  4節が「使わない」と言っているのがこれです。
- Richard Kelsey, "A Correspondence between Continuation Passing Style and
  Static Single Assignment Form", *IR* 1995.
- Andrew Appel, "SSA is Functional Programming", *SIGPLAN Notices* 33(4), 1998.
  この章の主張の出典。φ は関数の引数である。
- Keith Cooper, Timothy Harvey, Ken Kennedy, "A Simple, Fast Dominance
  Algorithm", 2001. 4節の実装。
- Fabrice Rastello, Florent Bouchez Tichadou (eds.), *SSA-based Compiler
  Design*, Springer, 2022. 以降の章が拠るところ。特に9章（SSA でのレジスタ割り付け）
  と3章（SSA からの脱出）。

## 実装の地図

| ファイル | 何が |
|---|---|
| `src/compiler/ssa.ml` | `value`/`block`/`func`（2節）、`reverse_postorder`・`renumber`・`recount`、印字 |
| `src/compiler/build.ml` | `go`（3節）、定数のハッシュコンス（3節）、`Fix` の確保と充填（3節） |
| `src/compiler/dom.ml` | `build`（4節）、`dominates`、`check`（5節） |
| `src/compiler/skunkc.ml` | コマンドライン |

---

[← 9. 言語リファレンス](9-language.md) ・ [目次](index.md)
