# 4. SSA 構築

`ssa.py`。

主張は1行で言えます。**変数が書かれるブロックの支配辺境に φ を置き、支配木を1回歩いて名前を
配れば、どの読みも到達する定義がちょうど1つになる。** Cytron らの構成で、教科書
そのままです。凝ったことはしていません。

---

## 用語

| | |
|---|---|
| 支配する | A が B を支配する ⇔ 入口から B へのどの道も A を通る |
| 直接支配者 (idom) | B を支配するもののうち B に最も近いもの |
| 支配木 | 各ブロックを idom につないだ木 |
| 支配辺境 (DF) | A が支配するが、その**後継**は支配しないブロックの集合。「A の影響が終わる境目」 |
| φ | 「どの道から来たかによって、この名前の中身はこれ」という擬似命令 |
| 最小 SSA | 支配辺境が言う場所すべてに φ を置く。生きているかは見ない |

---

## 4.1 支配木

Lengauer-Tarjan は使いません。Cooper・Harvey・Kennedy の反復法です。逆後行順に
並べて、変わらなくなるまで回します。

```python
def intersect(a: str, b: str) -> str:
    while a != b:
        while rank[a] > rank[b]:
            a = idom[a]
        while rank[b] > rank[a]:
            b = idom[b]
    return a
```

「両方を、順位が同じになるまで木の上へ引き上げる」だけです。密なビット集合も、
番号の付け替えも要りません。この処理系の関数の大きさなら、これで十分速く、
そして読めます。

支配辺境はそこから直接出ます。

```python
for label in order:
    block = func.blocks[label]
    if len(block.preds) < 2:
        continue
    for pred in block.preds:
        runner = pred
        while runner != idom[label] and runner in idom:
            frontier[runner].add(label)
            runner = idom[runner]
```

1行目の `if len(block.preds) < 2: continue` は、「合流点だけが誰かの支配辺境に
なれる」ということです。

---

## 4.2 どのレジスタが「変数」か

下げた直後のレジスタは2種類あります。1度しか書かれないもの（すでに SSA）と、
2度以上書かれるもの（変数）。φ が要るのは後者だけです。

数えるのは**定義の個数**であって、定義のあるブロック数ではありません。

```python
@dataclass(slots=True)
class _Defs:
    blocks: dict[ir.Reg, set[str]]
    count: dict[ir.Reg, int]

    def variables(self) -> set[ir.Reg]:
        return {r for r, n in self.count.items() if n > 1}
```

ここは一度間違えました。ブロック数で数えると、`var x = 0; x := 1` のように**同じ
ブロックで2回**書かれる変数が「変数ではない」と判定され、番号が付かないまま2つの
定義が残ります。SSA の壊れ方としては最悪の部類で、検証器がなければ気づけません。

---

## 4.3 φ を置き、名前を配る

置き方は教科書どおりのワークリストです。生きているかどうかは**見ません**（最小
SSA。pruned ではない）。死んだ φ は最適化の DCE が落とします（[5章](05-opt.md)）。

配るほうは支配木を preorder で歩き、変数ごとにスタックを持ちます。再帰ではなく
明示的なスタックにしてあります（深い関数で Python の再帰上限に当たらないため）。

`count` を通した結果です。

```
$ uv run python -m wolv emit -s ssa --no-checks count.wol
fun wol_count(%0, %1)  ; depth 1, 0 slots
entry:
    %2 = 0
    %10 = %2
    %4 = 0
    %11 = %4
    jmp test1
test1:  ; preds: entry, body2
    %12 = phi [entry: %10, body2: %15]
    %13 = phi [entry: %11, body2: %14]
    %6 = %12 < %1
    br %6 ? body2 : done3
body2:  ; preds: test1
    %7 = %13 + %12
    %14 = %7
    %8 = 1
    %9 = %12 + %8
    %15 = %9
    jmp test1
done3:  ; preds: test1
    ret %13
```

[3章](03-lower.md)で2回書かれていた `%3` と `%5` が、`%10/%12/%15` と
`%11/%13/%14` に割れ、`test1` に φ が2つ立ちました。φ は先行ブロックの**名前で**
引数を持ちます（位置ではなく）。ブロックを分割したり刈ったりしても壊れないためです。

### スタックは、ブロックを出るときに戻す

ここでもう一度間違えています。φ の分だけを積んで戻し、**命令の定義で積んだぶんを
戻していませんでした**。

```python
for instr in block.instrs:
    instr.map_uses(self.use)
    d = instr.defs()
    if d is not None and d in self.variables:
        instr.set_def(self.rename(d))
        mine.append(d)          # ← これが無かった
```

症状は「兄弟の枝で定義された名前が漏れて、別の枝から見える」です。捕まえたのは
検証器で、`%32 does not reach done3 through then6` と言われました。最適化を有効に
すると偶然直ってしまう種類のバグなので、`--no-opt` でも検証するようにしてあります。

---

## 4.4 検証器

このパスの主張は3つで、そのまま `ssa.verify` になっています。

```python
assert d not in definition, f"%{d} defined twice"                       # 1つの定義
assert dom.dominates(where, block.label), "%… does not dominate its use" # 支配する
assert set(phi.args) == set(block.preds), "phi names …"                  # 辺と一致
assert dom.dominates(where, pred), "%… does not reach … through …"       # 各辺で届く
```

テストは構築の直後だけでなく、**最適化のあと**にも、**命令選択のあと**にも同じことを
言わせます。どのパスも SSA を壊さない、というのがこの処理系の言い分だからです。

---

## 4.5 未定義の読み

どの道でも書かれていない変数が読まれることが、原理的にはありえます（この言語では
起きませんが、下げ方の細部に頼りたくない）。名前を配るときにスタックが空だったら、
入口ブロックに `Const 0` を1つ植えて、それを配ります。

```python
def undef(self, v: ir.Reg) -> ir.Reg:
    """A variable read on a path that never wrote it reads zero."""
```

入口に植えるのは名前配りが終わってからです。歩いている最中にそのブロックの命令列を
書き換えると、走査が壊れます。

---

## 4.6 臨界辺を割る

φ をコピーに変えるとき、コピーを置ける場所が要ります。出口が2つあるブロックから
入口が2つあるブロックへの辺には、置く場所がありません。だから割ります。

```python
def split_critical_edges(func: ir.Func) -> None:
```

この処理系では**φ を持つブロックへ入る辺は全部**割ります（臨界でなくても）。おかげで
生成器は「φ のコピーは `jmp` の直前にしか出ない」と言い切れます（[9章](09-emit.md)）。
条件分岐の直前にコピーを置く、という面倒な場合が消えます。

---

## していないこと

- pruned SSA ではありません（生存解析を先に走らせません）。死んだ φ は DCE 任せです。
- 半pruned でもありません。
- 支配木は Lengauer-Tarjan ではありません。
- SSA を出るのは[8章](08-graph.md)のグラフ彩色のときだけで、支配木彩色は SSA の
  ままレジスタを割り当てます。

---

## 参考文献

- Cytron, Ferrante, Rosen, Wegman, Zadeck, *Efficiently Computing Static Single
  Assignment Form and the Control Dependence Graph*, TOPLAS 1991.
- Cooper, Harvey, Kennedy, *A Simple, Fast Dominance Algorithm*, 2001.

---

## 実装の地図

| | |
|---|---|
| `ssa.dominance` | idom・支配木の子・支配辺境 |
| `ssa.place_phis` | 支配辺境に φ を置くワークリスト |
| `ssa._Renamer` | 名前配り。`run` が明示スタック、`block` が1ブロック |
| `ssa.verify` | 上の4つの表明 |
| `ssa.split_critical_edges` | φ のコピーの置き場所を作る |
