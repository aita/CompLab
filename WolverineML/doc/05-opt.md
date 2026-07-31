# 5. SSA 上の最適化

`opt.py`。

主張は1行で言えます。**SSA では「この値は何か」が引き算ではなく引き当てになる。** レジスタに
定義が1つしかないので、定数畳み込みもコピー伝播も辞書引きで済み、データフロー解析が
要りません。この章の5つのパスは、そのぶんどれも短いです。

---

## 5.1 動かなくなるまで5つを回す

```python
passes = [fold_constants, propagate_copies, simplify_phis, fold_branches, dead_code]
while True:
    changes = [run(func) for run in passes]
    if not any(changes):
        return
```

毎回全部を回します。安いからでもありますが、**互いに次を生む**からです。

```
定数畳み込み  →  分岐が定数になる
分岐畳み込み  →  ブロックが到達不能になる
到達不能      →  φ の引数が減る
φ が1引数     →  ただのコピーになる
コピー伝播    →  定数が伝わる先が増える
```

`any(changes)` を `any(p(func) for p in passes)` と書かないのは、短絡すると後ろの
パスが走らない回ができてしまうからです。

---

## 5.2 定数畳み込み

定数は辞書に集めるだけです。SSA なので、この辞書は「レジスタ → 値」で衝突しません。

```python
def constants(func: ir.Func) -> dict[ir.Reg, int]:
    known: dict[ir.Reg, int] = {}
    for block in func.walk():
        for instr in block.instrs:
            match instr:
                case ir.Const(dst, value):
                    known[dst] = value
    return known
```

算術は**この言語の意味で**畳みます。64ビットで折り返し、除算はゼロ方向に切り捨て。

```python
case "/":
    value = abs(a) // abs(b) * (1 if (a < 0) == (b < 0) else -1)
case "mod":
    value = a - (abs(a) // abs(b) * (1 if (a < 0) == (b < 0) else -1)) * b
```

Python の `//` は下向き丸めなので、そのまま使うと `~7 / 2` が `-4` になります。
機械の `sdiv` は `-3` です。ここを合わせておかないと、定数の入った式だけ答えが変わる
という一番たちの悪いバグになります。乱択テストがこの一致を直接確かめています
（[10章](10-verify.md)）。

恒等式も少しだけ見ます —— `x + 0`、`x * 1`、`0 + x`。それ以上は命令選択の仕事です。

---

## 5.3 コピー伝播と φ の簡約

`Move` は全部消せます。

```python
mapping = {dst: src for すべての Move}
rewrite(func, mapping)      # 読む側を全部書き換える。φ の引数も含む
Move を落とす
```

書き換えは φ の引数にも及ぶ必要があります。命令の `map_uses` は φ の引数を触らない
（φ は辺で読むので）ので、ここだけは明示的に回します。

φ の簡約は「引数が実質1つなら、それそのもの」です。

```python
others = {r for r in phi.args.values() if r != phi.dst}
if len(others) == 1:
    mapping[phi.dst] = others.pop()
```

自分自身を指す引数を外すのは、ループの φ が `x = phi(x0, x)` の形になることがある
からです。

自分しか指さない φ（`others` が空）は**残します**。消すと、その名前を読んでいる
命令が宙に浮きます。到達不能なループの中でしか起きないので、そのまま置いておけば
DCE が片付けます。

---

## 5.4 分岐畳み込みと、到達不能の掃除

条件が定数なら `jmp` に変えます。両方の行き先が同じでも `jmp` にします。その後
`drop_unreachable` が到達しないブロックを消し、**残った φ の引数から消えた辺を
落とします**。

```python
for b in func.walk():
    for phi in b.phis:
        phi.args = {p: r for p, r in phi.args.items() if p in live}
```

これを忘れると φ が存在しない先行ブロックを名指したままになり、検証器が
`phi in … names …, preds are …` と言います。

---

## 5.5 死んだコードの除去

「使われている」を集めて、効果のない命令のうち定義が使われていないものを落とす。
落とすと使われなくなるものが出るので、変わらなくなるまで回します。

効果があるのは `Store` `StoreSlot` `Call` と終端命令です。機械命令は自分で答えます
（`Mach.effect`）。呼び出しは、結果を使わなくても残ります。

---

## 5.6 count はどこまで縮むか

[4章](04-ssa.md)の SSA と見比べてください。

```
$ uv run python -m wolv emit -s opt --no-checks count.wol
fun wol_count(%0, %1)  ; depth 1, 0 slots
entry:
    %2 = 0
    %4 = 0
    jmp test1
test1:  ; preds: entry, body2
    %12 = phi [entry: %2, body2: %9]
    %13 = phi [entry: %4, body2: %7]
    %6 = %12 < %1
    br %6 ? body2 : done3
body2:  ; preds: test1
    %7 = %13 + %12
    %8 = 1
    %9 = %12 + %8
    jmp test1
done3:  ; preds: test1
    ret %13
```

`%10 = %2` と `%11 = %4`、`%14 = %7` と `%15 = %9` の4本のコピーが消え、φ の引数が
直接 `%2` `%4` `%7` `%9` を指すようになりました。下げるときに「安全のために」出していた
コピーが、ここで代金なしに回収されています（[3章](03-lower.md)の 3.1）。

命令は 16 から 12 に減りました。この関数について最適化がすることはこれで全部です。

---

## していないこと

- 共通部分式除去 (CSE) も、値番号付け (GVN) もありません。だから `swap` のような
  関数で `add x9, x1, x2, lsl #3` が2回出ます。
- ループ不変式の巻き上げ (LICM) がありません。ループの中の定数は毎周作り直します
  ——ただし多くは即値になるので命令にはなりません（[6章](06-select.md)）。
- インライン展開がありません。
- SCCP（疎条件付き定数伝播）ではありません。定数畳み込みと分岐畳み込みを別々に
  回してから到達不能を消す、という素朴な形です。

これらが無いことは測れます。とはいえ**ここにある5つ**の効き目も測れて、例題全体で
`--no-opt` が 3675 命令、既定が 3275 命令 —— 1割ちょっとです。

---

## 参考文献

- Wegman, Zadeck, *Constant Propagation with Conditional Branches*, TOPLAS 1991
  （SCCP。ここでは採っていない）.
- Andrew Appel, *Modern Compiler Implementation in ML*, 17章.

---

## 実装の地図

| | |
|---|---|
| `opt.optimise_func` | 5つを回す固定点ループ |
| `opt.fold_constants`, `opt._arith` | 畳み込みと、この言語の算術 |
| `opt.propagate_copies`, `opt.rewrite` | コピー伝播と、φ を含む書き換え |
| `opt.simplify_phis` | φ の簡約 |
| `opt.fold_branches` | 分岐畳み込み。`ir.drop_unreachable` を呼ぶ |
| `opt.dead_code` | DCE |
