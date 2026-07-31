# 8. レジスタ割り当て(2) グラフ彩色

`outofssa.py` と `allocator/graph.py`。`--regalloc graph`。

主張は1行で言えます。**コピーを消すには2つの値を融合するしかなく、融合できるのは
グラフの上だけである。** [7章](07-chordal.md)が偏り彩色で止まったのはそこでした。
この章はそれと引き換えに、弦グラフの保証を手放します。

---

## 用語

| | |
|---|---|
| 融合 (coalesce) | コピーの両端を1つのノードにする。コピーが消える |
| Briggs の判定 | 融合後のノードの、次数 K 以上の近傍が K 未満なら安全 |
| freeze | 融合をあきらめて、そのノードを simplify できるようにすること |
| 楽観的彩色 | 色が付かないと決めつけずにスタックへ積む。付けば儲けもの |
| 実スピル | select で本当に色が無かった値。書き換えて最初からやり直す |

---

## 8.1 まず φ を消す

グラフを作るには、φ が邪魔です。φ は命令ではないので「同時に生きている」を素直に
言えません。だから先に消します。

φ は辺の上のコピーなので、各先行ブロックの末尾にコピーを置きます。臨界辺は
[4章](04-ssa.md)で割ってあるので、置き場所は必ずあります。

```
$ uv run python -m wolv emit -s flat --regalloc graph --no-checks count.wol
fun wol_count(%0, %1)  ; depth 1, 0 slots
entry:
    %2 = const #0
    %4 = const #0
    %12 = %2
    %13 = %4
    jmp test1
test1:  ; preds: entry, body2
    cmp %12, %1
    br lt? body2 : done3
body2:  ; preds: test1
    %7 = add %13, %12
    %9 = addi %12, #1
    %12 = %9
    %13 = %7
    jmp test1
done3:  ; preds: test1
    ret %13
```

φ が消えて、コピーが4本増えました。**増えること自体は損ではありません。**
coalescing はコピーを消す仕組みなので、コピーが無ければ働きようがない —— ここで
増えたぶんが、次の段の仕事になります。

1つだけ注意が要ります。1つの辺に φ が2つあって、互いの行き先と引数が交差している
場合（自分自身が先行ブロックであるループで起きます）、コピーを順に並べると壊れます。
そのときだけ一時変数を経由します（Sreedhar らの方法）。

```python
if written & read:
    through = {dst: func.new_reg() for dst, _ in real}
    copies += [ir.Move(through[dst], src) for dst, src in real]   # 全部読んでから
    copies += [ir.Move(dst, through[dst]) for dst, _ in real]     # 全部書く
```

---

## 8.2 Chaitin のアルゴリズム

頂点が値、辺が「同時に生きている」。K 色で塗る。一般のグラフの K 彩色は NP 困難
ですが、Kempe の観察が実用にします —— **近傍が K 未満の頂点は、残りがどうなろうと
必ず塗れる**。だから

1. 近傍が K 未満の頂点を取り除いてスタックに積む（**simplify**）
2. 取り除けなくなったら、1つを「たぶん塗れない」と見て積む（**楽観的スピル**）
3. 空になったらスタックから取り出し、近傍が使っていない色を与える（**select**）
4. 色が無かった値があれば、メモリに落として最初からやり直す

Briggs の楽観的彩色が 2 と 3 の組で、「決めつけずに積んでみたら塗れた」がよく起きます。

---

## 8.3 iterated coalescing

コピーの両端を融合すればコピーは消えます。しかし融合するとノードの次数が上がり、
グラフが塗れなくなることがあります。だから**証明できるときだけ**融合します。

**Briggs の判定**: 融合後のノードの、次数が K 以上の近傍が K 未満なら安全。

そして simplify と融合は互いに次を生みます。simplify は次数を下げるので、危険だった
融合が安全になる。融合は次数を上げるので、simplify が必要になる。だから**交互に
回します**。これが "iterated" です。行き詰まったら freeze —— コピーをあきらめて、
そのノードを simplify できるようにする。

```python
while self.simplify_worklist or self.worklist_moves or (
    self.freeze_worklist or self.spill_worklist
):
    if self.simplify_worklist:
        self.simplify()
    elif self.worklist_moves:
        self.coalesce()
    elif self.freeze_worklist:
        self.freeze()
    else:
        self.select_spill()
```

George と Appel の4ワークリストそのものです。

---

## 8.4 固定レジスタを作らない

普通この方式では、機械レジスタを「無限次数の precolored ノード」としてグラフに入れ、
呼び出しが caller-saved を定義する、と書きます。ここではそうしていません。代わりに
**そのノードが取れない色の集合**を持ちます。

```python
def weight(self, r: ir.Reg) -> int:
    """The degree, counting a forbidden colour as a neighbour holding it."""
    return self.degree[r] + len(self.forbidden[r])
```

禁止色が `f` 個、近傍が `d` 個なら、`d + f < K` で「必ず塗れる」。precolored ノードを
置くのと等価で、実装がずっと小さくなります。Kempe の判定も Briggs の判定も、次数の
代わりにこの和を使うだけです。

---

## 8.5 スピルで一度つまずいた

`select_spill` は「近傍が多くて参照が少ない」値を選びます。ここに落とし穴があって、
**直前のラウンドで作ったリロードが常に最良の候補になります**。参照が1つしかないので
「安い」と判定されるからです。しかし選ぶと、同じものをまたロードする命令が生えるだけ
で、圧力は下がりません。

6本のレジスタで `busy` が割り当て不能になり、これで気づきました。Appel と同じく
リロードは候補から外します。

```python
among = sorted(self.spill_worklist - self.protected) or sorted(self.spill_worklist)
```

---

## 8.6 どれだけ違うか

例題とテストプログラム全部で測ります。

| | 命令数 | `mov` |
|---|---|---|
| `chordal`（支配木彩色） | 3275 | 425 |
| `graph`（グラフ彩色） | 3249 | 399 |

**26命令。そして26個ぜんぶが `mov` です。** つまり差は正確に「coalescing が消せて、
偏り彩色が消せなかったコピー」です。

φ を消したときに増えたコピーは、どれだけ回収できたか。

```
queens     phis    8  copies after out-of-SSA   16  left    0  coalesced 100%
sort       phis   16  copies after out-of-SSA   32  left    1  coalesced  96%
tour       phis   16  copies after out-of-SSA   30  left    1  coalesced  96%
```

96〜100%。`tour` が out-of-SSA で足した30本のうち、生き残ったのは1本です。増やして
から回収して、なお 26 命令ぶん勝っている、というのがこの方式の言い分です。

`count` に至っては、両方の割り当て器が**同じアセンブリ**を出します。φ が4本の
コピーになり、4本とも同じ色に潰れるからです。

### 希望を1箇所にまとめたら26命令減った

この 3249 という数字は、リファクタで動いています。以前は両方の割り当て器が ABI の
希望を別々に計算していて、グラフ側は**仮引数の希望をブロック走査の後に**設定して
いました。そのせいで「その仮引数が直後に第2引数として渡される」という希望を上書き
して潰していました。1箇所に集めたら（`allocator/hints.py`）自然に直り、3276 → 3249
になりました。方針の重複は、いつか必ず食い違います。

---

## 8.7 どちらが良いか

| | 支配木彩色 | グラフ彩色 |
|---|---|---|
| グラフ | 作らない | 作る |
| 彩色 | 必ず成功（maxlive ≤ k なら） | 詰まって無駄にスピルしうる |
| coalescing | 偏り彩色だけ＝弱い | 融合できる＝強い |
| 固定レジスタ | 苦手 | 素直 |
| 手間 | 木を1回たどる | 複数ラウンド |

この処理系の規模（レジスタ27本、小さいプログラム）ではスピルがほとんど起きないので、
**保証はほぼ効かず、coalescing の質だけが数字に出ます**。だからグラフ彩色が勝ちます。
レジスタが少ない機械や、圧力の高いコードなら逆転しうる、というのが理論の言い分です。

---

## していないこと

- George の判定を実装していません（precolored ノードが無いので使いどころが無い）。
- 融合の探索順を工夫していません。ワークリストは番号順です。
- 実スピルのたびに全体をやり直します。増分ではありません。

---

## 参考文献

- Chaitin ほか, *Register Allocation via Coloring*, Computer Languages 1981.
- Briggs, Cooper, Torczon, *Improvements to Graph Coloring Register Allocation*,
  TOPLAS 1994（楽観的彩色、保守的融合）.
- George, Appel, *Iterated Register Coalescing*, TOPLAS 1996.
- Sreedhar ほか, *Translating Out of Static Single Assignment Form*, SAS 1999.
- Boissinot, Darte, Rastello ほか, *Revisiting Out-of-SSA Translation*, CGO 2009.
- Bouchez, Darte, Rastello, *On the Complexity of Register Coalescing*, CGO 2007
  （彩色が多項式でも融合は NP 完全）.

---

## 実装の地図

| | |
|---|---|
| `outofssa.destruct` | φ を先行ブロックのコピーに |
| `outofssa._copy_in_parallel` | 交差するときだけ一時変数を経由 |
| `allocator/graph.py` の `run` | 4ワークリストのループ |
| `_Colouring.build` | 干渉グラフ。`Move` の両端は干渉させない |
| `_Colouring.conservative` | Briggs の判定 |
| `_Colouring.combine` | 融合 |
| `_Colouring.assign_colours` | select |
