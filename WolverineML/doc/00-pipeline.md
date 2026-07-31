# 0. パイプライン

`driver.py`。この章は地図で、以降の章はその一区画ずつです。

主張は1行で言えます。**各段は次の段に「もう気にしなくてよいこと」を渡す。** 型検査を
過ぎたら型は出てこないし、SSA 構築を過ぎたら「同じレジスタが2回書かれる」ことは
起きないし、命令選択を過ぎたら「この機械にない演算」は残っていない。どの段も、その
保証を**検証器で言える**ようにしてあります（[10章](10-verify.md)）。

---

## 0.1 段と、その段が捨てるもの

| 段 | 入力 | 出力 | この段を過ぎたら考えなくてよいこと |
|---|---|---|---|
| 字句・構文解析 | 文字列 | 構文木 | 優先順位、結合方向 |
| 型検査 | 構文木 | 型付き構文木 | 型。そして「どの変数が逃げたか」が決まる |
| 下げる | 型付き構文木 | 三番地 CFG | 式の入れ子、スコープ、静的リンクの深さ |
| SSA 構築 | 三番地 CFG | SSA | 「同じレジスタが2回書かれる」 |
| 最適化 | SSA | SSA | 定数、無駄なコピー、届かないブロック |
| 命令選択 | SSA | 機械 IR | この機械にない演算 |
| レジスタ割り当て | 機械 IR | 色つき機械 IR | 仮想レジスタが無限にあること |
| 生成 | 色つき機械 IR | アセンブリ | φ、フレームの寸法 |

順序で1つだけ説明の要るところがあります。**命令選択が割り当ての前**にあることです。
逆順もありえます（先に色を塗ってから命令を選ぶ）が、選択は命令の**個数**を変える
——`madd` は2命令を1命令にする——ので、レジスタ圧が選択の後でしか確定しません。
だから選択が先です。これは実測でも効いていて、選択を入れる前と後で同じ割り当て器の
出力が3288命令から3225命令になりました（[6章](06-select.md)）。

---

## 0.2 パイプラインは一箇所に書く

ダンプ（`emit -s ssa` など）は「パイプラインを途中で止めたもの」であって、順序を
書いた**二つ目の場所**ではありません。ここは一度失敗しています。`compile_module` と
`stage` が順序を別々に持っていたので、命令選択を足したときに両方へ足す必要が
ありました。いまは1本です。

```python
def compile_module(source: str, opts: Options, upto: str = "asm") -> ir.Module:
    mod = to_ir(source, opts)
    if upto == "ir":
        return mod
    ssa.construct_module(mod)
    if upto == "ssa":
        return mod
    ...
```

`stage` は「止めて表示する」だけになります。段を足すときに直す場所は1つです。

---

## 0.3 分岐が2つある

図で唯一分かれるのは割り当てのところです。

```
    機械 IR（φ つき、SSA）
      ├──▶ chordal   SSA のまま彩色し、φ は生成器がエッジ上のコピーにする
      └──▶ graph     先に SSA を出て φ をコピーにし、干渉グラフを彩色する
```

`--regalloc` で選びます。どちらを選んでも**同じ出力を印字しなければならない**という
のがテストの言い分で、7本のプログラムをそれぞれ8通りの設定でコンパイルして
比べています。

分岐が割り当てのところに来るのは偶然ではありません。ここより上（構文・型・SSA・
選択）はどちらの方式にも同じものが要るからです。実際、両方の割り当て器が共有して
いるものはかなりあります。

| 共有しているもの | どこ |
|---|---|
| 生存解析 | `liveness.py` |
| スピルの書き換えとコスト | `allocator/spill.py` |
| ABI の希望（どの色を望むか） | `allocator/hints.py` |
| レジスタファイル | `registers.py` |
| 検証器 | `allocator.verify` |

違うのは**色の決め方だけ**です。

---

## 0.4 IR が2つある

`ir.py` に三番地コード、`mach.py` に機械命令。共有しているのは「命令でないもの」
——レジスタ、ブロック、グラフ、フレーム——と、もともと機械語レベルだった数個
（呼び出し、コピー、フレームスロット、φ、3つの終端）です。

分けられるのは、命令が自分について答えるからです。

```python
class Instr:
    def defs(self) -> Reg | None: ...
    def uses(self) -> list[Reg]: ...
    def map_uses(self, f: Rewrite) -> None: ...
    def set_def(self, r: Reg) -> None: ...
    def has_effect(self) -> bool: ...
    def show(self, name: Name) -> str: ...
```

パスが命令に訊くのはこの6つだけです。だから生存解析も両方の割り当て器も検証器も、
`madd` が何かを知らないまま両方のレベルで動きます。`ir.py` は `mach.py` を import
しません。

---

## 0.5 走らせてみる

10段すべてが出せます。

```sh
$ uv run python -m wolv emit -s tokens prog.wol
$ uv run python -m wolv emit -s asm --regalloc graph prog.wol
$ uv run python -m wolv run prog.wol
```

以降の章はほぼ全部、次の関数1つを追いかけます。

```sml
fun count (n : int) : int =
  let var i = 0
      var total = 0
  in
    while i < n do (total := total + i; i := i + 1);
    total
  end
```

最後にこうなります。

```
.Lwol_count_test1:
	cmp x9, x1
	b.ge .Lwol_count_done3
.Lwol_count_body2:
	add x0, x0, x9
	add x9, x9, #1
	b .Lwol_count_test1
```

ループ本体が3命令、`mov` は1つもありません。ここに至るまでに、φ が2つ立って消え、
定数が1つ即値になり、比較がフラグになり、コピーが4本合体しています。それを順に見て
いきます。

---

## 実装の地図

| ファイル | 章 |
|---|---|
| `lexer.py`, `parser.py` | [1章](01-syntax.md) |
| `types.py`, `typecheck.py` | [2章](02-types.md) |
| `ir.py`, `lower.py` | [3章](03-lower.md) |
| `ssa.py` | [4章](04-ssa.md) |
| `opt.py` | [5章](05-opt.md) |
| `dag.py`, `select.py`, `mach.py` | [6章](06-select.md) |
| `liveness.py`, `allocator/chordal.py` | [7章](07-chordal.md) |
| `outofssa.py`, `allocator/graph.py` | [8章](08-graph.md) |
| `emit.py`, `copies.py`, `registers.py`, `runtime/runtime.c` | [9章](09-emit.md) |
| `tests/` | [10章](10-verify.md) |
