# 7. レジスタ割り当て(1) 支配木彩色

`liveness.py` と `allocator/chordal.py`。

主張は1行で言えます。**SSA の干渉グラフは弦グラフで、支配木の preorder はその完全消去順序
である。** だからグラフを作る必要も、消去順序を探す必要もありません。彩色は木を
1回たどるだけです。

---

## 用語

| | |
|---|---|
| 生きている | いまの地点より後で読まれる可能性があること |
| 干渉する | 2つの値が同時に生きていること。同じレジスタに入れられない |
| 弦グラフ | 長さ4以上の閉路に必ず弦がある。完全消去順序を持つ |
| 完全消去順序 | その順に消していくと、各頂点の残りの近傍が常に完全グラフになる並び |
| 圧力 (pressure) | ある地点で同時に生きている値の数。最大値が maxlive |
| 偏り彩色 | 「できればこの色」という希望を優先して塗ること |

---

## 7.1 なぜ弦グラフなのか

定理が1つあれば済みます。

> **Gavril (1974)**: グラフが弦グラフである ⇔ ある木の部分木の交差グラフである。

SSA では定義が生存範囲全体を支配します。つまり**生存範囲は支配木の部分木**です。
だから干渉グラフ（生存範囲の交差グラフ）は弦グラフ —— 定理の直接の帰結です。

非 SSA だとこうなりません。`if c then x := a else x := b` の `x` は、定義が2つの
別々の枝にあるので部分木になりません。弦のない閉路ができて、消去順序を探す羽目に
なります。**SSA 化は、その閉路を φ で切って部分木に戻す操作**です。

弦グラフの完全消去順序は支配木の preorder の逆になっているので、preorder に塗れば
貪欲で足ります。しかも使う色数はちょうど maxlive です。**k 色で足りるなら必ず
成功する**、という保証が付きます。Chaitin にはこれがありません。

---

## 7.2 生存解析

普通の後ろ向きデータフローです。ただし φ は特別で、**φ は自分の場所で引数を読み
ません**。辺で読みます。だから引数はその先行ブロックの live-out に入り、φ のある
ブロックの中では生きていません。

```python
out = ∪ over succ s:  live_in[s] ∪ {phi.args[この辺] for phi in s.phis}
live_in[b] = use[b] ∪ (out - def[b])        # def[b] は φ の行き先も含む
```

これを間違えると、φ に関係する値どうしが「同時に生きている」ことになり、決して同じ
色を取れなくなります。coalescing が効かない、という形で症状が出ます。

---

## 7.3 彩色

```python
for label in preorder(dominator tree):
    alive = live_in[label]                 # ここに来る時点で全部塗り終わっている
    for phi in block.phis:
        assign(phi.dst, alive); alive.add(phi.dst)
    for instr in block.instrs:
        for r in instr.uses():
            if ここが最後の使用 and r not in live_out:
                alive.discard(r)
        if d := instr.defs():
            assign(d, alive); alive.add(d)
```

`live_in` の値が「もう塗り終わっている」と言えるのは、定義が支配し、支配木を
preorder でたどっているからです。これがこのアルゴリズムの全部です。

死ぬ使用を**定義に色を付ける前に**外していることには意味があります。`add x0, x0, x9` の
ように、死んだオペランドのレジスタを結果が再利用できます。

---

## 7.4 同じ走査で片づく3つ

### 呼び出し規約

呼び出しをまたいで生きている値は、**caller-saved を取れません**。取れると `bl` の
向こうで壊れます。生存解析のついでに集めておいて、色の候補を callee-saved に絞る
だけです。

```python
allowed = self.machine.callee if reg in self.across else self.machine.anywhere
```

これで「呼び出しの周りで何かを退避する」コードが1つも要らなくなります。プロローグで
保存するのは、実際に使った callee-saved だけです。

### 希望

引数の位置・戻り値・仮引数の位置は「その色が欲しい」という希望になります
（`allocator/hints.py`。両方の割り当て器が共有しています）。希望が空いていれば取る、
というだけです。これで `x2` に入るべき値が最初から `x2` にいることが多くなり、
呼び出し前のコピーが消えます。

### coalescing（ただし弱い）

φ とその引数は「同じ色だと嬉しい」関係です。塗るときにその色を優先します。

```python
for hint in self.hints.get(reg, []):
    colour = self.colours.get(hint, self.preferred.get(hint))
    if colour is not None and colour not in taken and colour in allowed:
        self.colours[reg] = colour
        return
```

まだ塗られていない相手については、**その相手が望んでいる色**を見ます。これが無いと、
入口の値を塗る時点では φ がまだ塗られていないので希望が伝わりません。

そしてこれが**この方式の弱点**です。コピーを消すとは2つの値を同一視することであり、
それは SSA が「この2つは別だ」と言っていることに他なりません。だからノードを融合
できず、偏り彩色という貪欲な近似で止まります。答えは再彩色（Hack & Goos, PLDI 2008）ですが、ここには実装
していません。代わりに[8章](08-graph.md)があります。

---

## 7.5 塗った結果を見る

```
$ uv run python -m wolv emit -s ra --no-checks count.wol
fun wol_count(%0:0, %1:1)  ; depth 1, 0 slots
entry:
    %2:9 = const #0
    %4:0 = const #0
    jmp test1
test1:  ; preds: entry, body2
    %12:9 = phi [entry: %2:9, body2: %9:9]
    %13:0 = phi [entry: %4:0, body2: %7:0]
    cmp %12:9, %1:1
    br lt? body2 : done3
body2:  ; preds: test1
    %7:0 = add %13:0, %12:9
    %9:9 = addi %12:9, #1
    jmp test1
done3:  ; preds: test1
    ret %13:0
```

`%12:9` は「仮想レジスタ12、色は x9」。φ の引数が全部 φ 本体と同じ色になっています
（`%2:9`/`%9:9` と `%12:9`、`%4:0`/`%7:0` と `%13:0`）。だから辺に置かれるコピーは
「自分から自分へ」になり、生成器が落とします。ループの中に `mov` は1つも残りません。

`%13` が `x0` なのは `ret` の希望が効いたからです。おかげで戻り値の `mov` も要りません。

---

## 7.6 スピル

定義に空いた色が無ければ、値を1つメモリに落として最初からやり直します。落とし方は
両方の割り当て器で共通です（`allocator/spill.py`）。

- 定義の直後に `StoreSlot`
- 使用の直前に `LoadSlot`（新しいレジスタを1つ定義する）
- φ の引数なら、その先行ブロックの末尾でリロード

リロードが**新しい定義**なので、書き換えても SSA のままです。そして生存区間が
「ロードとその1つ下」だけになるので、圧力が下がります。

どれを落とすかは、参照回数をループの深さで重み付けした値が最小のものです。深さは
支配関係から求めます（`h` が `b` を支配する辺 `b → h` が後ろ向き辺）。

```python
scale = float(10 ** min(depth[block.label], 4))
```

**リロードは二度と選びません。** 選ぶと同じものをまたロードする命令が生えるだけで、
書き換えが終わりません。落とすものが他に無くなったら、その命令が機械のレジスタ数
より多くを同時に要求している、ということなので、そう言って止まります。

`--max-regs 5` で `count` を潰してみます。

```
fun wol_count(%0:9, %1:10)  ; depth 1, 0 slots
entry:
    %2:9 = const #0
    %4:11 = const #0
    ...
```

この関数は同時に3つしか生きていないので、5本でもスピルしません。色の選び方だけが
変わります（`limited(5)` は callee-saved を2本、caller-saved を3本にします）。

---

## していないこと

- Belady の MIN を CFG に持ち上げたスピル（Braun & Hack, CC 2009）はしていません。
  「参照が最も少ない値を丸ごと落とす」だけです。
- 生存区間の分割 (live-range splitting) をしません。落とすか、落とさないかです。
- 再彩色による coalescing をしません（7.4）。
- 固定レジスタ制約 (precolouring) を割り当て器が直接扱いません。呼び出し規約は
  生成器の並列コピーと希望で回避しています。

---

## 参考文献

- Hack, Grund, Goos, *Register Allocation for Programs in SSA-Form*, CC 2006.
- Sebastian Hack, *Register Allocation for Programs in SSA Form*, 博士論文 2007.
- Pereira, Palsberg, *Register Allocation via Coloring of Chordal Graphs*, APLAS 2005.
- Gavril, *The intersection graphs of subtrees in trees are exactly the chordal
  graphs*, JCTB 1974.
- Braun, Hack, *Register Spilling and Live-Range Splitting for SSA-Form Programs*,
  CC 2009.
- Hack, Goos, *Copy Coalescing by Graph Recoloring*, PLDI 2008.

---

## 実装の地図

| | |
|---|---|
| `liveness.analyse` | 生存解析。φ は辺で読む |
| `liveness.across_calls` | 呼び出しをまたぐ値 |
| `liveness.pressure` | maxlive |
| `allocator/chordal.py` | 支配木 preorder の走査 |
| `allocator/hints.py` | ABI の希望（両方が使う） |
| `allocator/spill.py` | スピルの書き換えとコスト（両方が使う） |
