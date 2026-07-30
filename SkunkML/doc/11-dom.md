# 11. 支配木

SSA を作ったと[10章](10-ssa.md)で言いました。この章はそれを**確かめる**話で、
そのために必要な道具が支配関係です。

道具のほうが有名です。支配辺境による φ 配置は SSA の教科書の目玉で、Cytron らの
論文の中心でもあります。ここではそれを**実装して、走らせません**。走らせない理由が
この章のいちばん面白いところです。

## 用語

| | |
|---|---|
| 支配 (dominate) | 入口からその点へ行く道が、必ずそこを通ること |
| 厳密支配 | 支配していて、かつ自分自身ではない |
| 直近支配者 (immediate dominator) | 厳密支配しているもののうち、いちばん近いもの |
| 支配木 | 直近支配者を親とする木。根は入口 |
| 逆後行順 (RPO) | 深さ優先の後行順を逆にした並び。支配者が必ず先に来る |
| 支配辺境 (dominance frontier) | 「届くが、所有はしていない」ブロックの集まり |
| pruned SSA | 本当に必要な φ しか置かない SSA |

## 1. 支配とは何か

ブロック `d` が `b` を**支配する**とは、入口から `b` へ行くどの道も `d` を通ることです。

[10章](10-ssa.md)の `both` の CFG で見ます。

```sml
fun both (true, 1) = "yes"
  | both _ = "no"
```

```
        b0                 b0: 1列目を検査
       /  \
     b2    b1              b2: 1列目は true。2列目を検査
    /  \     \             b1: 1列目が違った
  b5    b3    |
         \    |            b5: どちらも合った  -> "yes"
          b4 <'            b3: 2列目が違った
                           b4: 合わなかったほう -> "no"
```

- `b0` は全部を支配します。入口だから当たり前です。
- `b2` は `b5` と `b3` を支配します。そこへ行く道は `b2` を通るしかない。
- `b2` は `b4` を**支配しません**。`b0 → b1 → b4` という道があるからです。

なぜこれが要るのか。**SSA の意味そのものだから**です。「値 v を使ってよい」とは
「どんな実行経路をたどってもここに来る前に v が定義されている」ということで、それは
「v を定義したブロックが、使っているブロックを支配する」と同じ意味です。

## 2. 直近支配者と支配木

`b` を厳密支配するものは複数あります（`b3` を支配するのは `b0` と `b2`）。そのうち
いちばん近いものが**直近支配者**で、これを親にすると木になります。

```
$ skunkc --dump-dom tests/join.sk
func both$4:
  reverse postorder  b0 b1 b2 b3 b4 b5
  b0    idom -     frontier {  }
  b1    idom b0    frontier { b4 }
  b2    idom b0    frontier { b4 }
  b3    idom b2    frontier { b4 }
  b4    idom b0    frontier {  }
  b5    idom b2    frontier {  }
```

`b4` の親が `b2` ではなく `b0` なのが読みどころです。`b4` へは `b1` からも `b3` からも
来られるので、両方に共通する支配者まで登らないといけません。

## 3. 反復アルゴリズム

支配木の作り方はこれです。

```ocaml
let rec intersect a b =
  if a.bid = b.bid then a
  else if n a > n b then intersect (idom a) b
  else intersect a (idom b)
```

2つのブロックから支配木を**上へ登って、出会うまで**。`n` は逆後行順での位置です。

そして全体は「変化がなくなるまで繰り返す」だけです。

```ocaml
while !changed do
  changed := false;
  List.iter (fun b ->
    if b <> entry then
      match 既に idom の分かっている先行ブロックたち with
      | [] -> ()
      | first :: rest ->
          let d = List.fold_left intersect first rest in
          if idom b <> d then (idom b <- d; changed := true))
    rpo
done
```

**逆後行順が効いています。** RPO では「支配者は必ず先に来る」ので、`b` を処理する
ときには先行ブロックの答が（たいてい）もう出ています。だから2〜3周で止まる。`intersect` が
「番号の大きいほうを登らせる」のも同じ理由で、番号が小さいほうが根に近いからです。

漸近的にはこれが最速ではありません。Lengauer–Tarjan が almost-linear です。それでも
反復のほうを選んだのは、**1ページで書けて読んで分かる**から。実測でも反復のほうが
速いことが多い、というのが Cooper–Harvey–Kennedy の論文の主張です。

## 4. 支配辺境 — φ の置き場所を求める道具

`b` の**支配辺境**とは、「`b` から届くが、`b` が支配してはいない」ブロックの集まりです。
言い換えると、**`b` を通ってきた道と、通っていない道が合流する場所**。

上の出力で `b1` の辺境が `{ b4 }` なのがそれです。`b1` から `b4` へは行けますが、
`b4` には `b3` 経由でも来られるので `b1` は `b4` を支配していません。

求め方は Cytron らのやり方で、ループが1つです。

```ocaml
List.iter (fun j ->
  if List.length j.preds > 1 then
    List.iter (fun p ->
      (* p から j の直近支配者まで登り、途中に j を足す *)
      let rec up r = if r <> idom j then (add r j; up (idom r)) in
      up p)
    j.preds)
  blocks
```

先行ブロックが2つ以上あるブロック `j` だけが誰かの辺境になれます。合流していない場所は、
定義から辺境になりようがないからです。

**そしてこれが「φ をどこに置くか」の答です。** 変数 `v` が `b1` と `b3` で定義されて
いるなら、`v` の φ は `b1` と `b3` の支配辺境に置く。そこが「どちらの定義で来たか
分からなくなる場所」だからです。置いた φ 自身が新しい定義なので、辺境を取る操作を
不動点まで繰り返します（iterated dominance frontier）。

これが SSA 構築アルゴリズムで、`ssa.ml` は**一度も呼びません**。

## 5. なぜ走らせないのか

Cytron らのアルゴリズムが答える問いは「可変変数を持つプログラムのどこに φ を置くか」
です。ここにはその問いがありません。**φ の置き場所は join point として既に書いて
ある**からです（[6章](06-join.md)・[10章](10-ssa.md)）。

書いてあるだけでなく、**同じ場所**です。それを確かめられます。

```
func inline$3:
  reverse postorder  b0 b1 b2 b3
  b0    idom -     frontier {  }
  b1    idom b0    frontier { b3 }
  b2    idom b0    frontier { b3 }
  b3    idom b0    frontier {  }   1 phi
```

`b1` の辺境も `b2` の辺境も `{ b3 }`。そして φ を持っているのは `b3` です。
**アルゴリズムが置きたかった場所に、join point が既に置いていました。**

検証器はこれを全プログラムで確かめます。

```ocaml
List.iter (fun b ->
  if b.phis <> [] then
    List.iter (fun p ->
      if not (List.mem b (frontier p)) then
        complain "b%d has phis but is not in the frontier of b%d" b p)
      b.preds)
  blocks
```

## 6. しかも pruned

`both$4` のほうをもう一度見てください。

```
  b1    idom b0    frontier { b4 }
  b2    idom b0    frontier { b4 }
  b3    idom b2    frontier { b4 }
  b4    idom b0    frontier {  }        ← φ がない
```

`b4` は3つのブロックの支配辺境にいる、れっきとした合流点です。それなのに φ が
1つもありません。**そこで選ばなければならない値が何もない**からです — `"no"` を返す
腕は引数を取らないので、どの道から来ても同じことをする。

Cytron らの構築が作るのは **minimal SSA** で、これは「定義が届く合流点すべてに φ を
置く」ものです。そこには使われない φ が混じるので、実用の処理系はさらに生存解析を
かけて **pruned SSA** にします。

join point から来る φ は**最初から pruned です**。生存解析はどこにも走っていません。
join point の引数は「腕が実際に必要とした値」だけだからで、それを決めたのは
[5章](05-matching.md)のパターンマッチのコンパイラでした。

## 7. もうひとつの検証 — 定義は使用を支配するか

支配木の本当の使い道はこちらです。

- すべての使用について、**その定義が使用を支配しているか**。同じブロック内なら、
  定義のほうが先に書かれているか。
- φ の引数の数が、そのブロックの先行ブロックの数と合っているか。そして i 番目の引数は
  **i 番目の先行ブロックの終わりまで**届いているか — φ はブロックの先頭ではなく**辺の上**で
  評価されるものなので、自分のブロックではなく先行ブロックのほうを見ます。

`dune test` がこれをリポジトリの全プログラムで走らせます。「ANF ＋ join point は
もう SSA だ」は気持ちのよい主張ですが、気持ちのよい主張ほど確かめるべきです。

```sh
$ skunkc --dump-ssa examples/tour.sk    # 黙って通れば SSA
$ skunkc --no-verify …                  # 外せる。外す理由はいまのところない
```

## 8. ここで止まっている

`skunkc` は SSA を作って、検査して、印字するところまでです。残りはこの順です。

1. **表現の低下。** 多相なので値は1ワード。整数にタグを付け、レコード・閉包・構成子を
   確保と load/store に落とす。ここで `field v0, 1` がオフセットになります。
2. **DP による命令選択。** 値グラフを木に切り（使用回数が2以上、ブロックをまたぐ、
   副作用がある、で切る）、タイル文法に対する動的計画法で木ごとに最適に敷き詰める。
   amd64 でこれが効くのはアドレッシングモードがあるからです。
3. **レジスタ割り付け。** SSA の干渉グラフは**弦グラフ**なので、支配木の前順走査で
   貪欲に彩色すれば最適になります。一般のグラフ彩色が NP 困難なのに対して、SSA だと
   多項式で解ける — 支配木をここで作っておく2つ目の理由です。
4. **SSA からの脱出。** φ を並列コピーに直す。lost-copy 問題と swap 問題。
5. **出力。** `.s` を吐いて `cc` でリンクする。x86-64 の上で走っているので、
   エミュレータは要りません。

## していないこと

- **iterated dominance frontier を計算していません。** 1周ぶんの辺境だけです。
  φ を置くのではなく置き場所を確かめるのが目的なので、繰り返す必要がありません。
- **支配木を明示的な木として持っていません。** 親（`idom`）の表だけです。前順走査が
  要るのはレジスタ割り付けからで、そのときに作ります。
- **後支配 (post-dominance) がありません。** 使う予定がまだありません。
- **Lengauer–Tarjan ではありません。** 3節のとおりです。

## 参考文献

- Keith Cooper, Timothy Harvey, Ken Kennedy, "A Simple, Fast Dominance
  Algorithm", Rice University, 2001. 3節はこの論文の図そのものです。
- Thomas Lengauer, Robert Tarjan, "A Fast Algorithm for Finding Dominators in a
  Flowgraph", *TOPLAS* 1(1), 1979. 速いほう。
- Cytron, Ferrante, Rosen, Wegman, Zadeck, *TOPLAS* 13(4), 1991. 支配辺境と
  φ 配置。4節と5節が扱っているのはこれです。
- Vugranam Sreedhar, Guang Gao, "A Linear Time Algorithm for Placing
  phi-Nodes", *POPL* 1995. 辺境を作らずに置く方法。
- Sebastian Hack, Daniel Grund, Gerhard Goos, "Register Allocation for Programs
  in SSA Form", *CC* 2006. 8節の3つ目、弦グラフの話。

## 実装の地図

| ファイル | 何が |
|---|---|
| `src/compiler/dom.ml` | `build`（3節）、`dominates`（1節）、`frontier`（4節）、`frontier_ok`（5節）、`check`（7節）、`to_string`（`--dump-dom`） |
| `src/compiler/ssa.ml` | `reverse_postorder`（3節） |
| `src/compiler/skunkc.ml` | `--dump-dom`、`--no-verify` |

---

[← 10. 値 SSA を作る](10-ssa.md) ・ [目次](index.md)
