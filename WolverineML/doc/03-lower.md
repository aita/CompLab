# 3. CFG へ下げる

`ir.py` と `lower.py`。

主張は1行で言えます。**2つの枝で書かれた変数は、同じレジスタに2回書けばよい。** それを1つの
定義にするのは次のパスの仕事で、ここでするべきなのは「定義が使用に届く」ことだけです。
構造化された制御フローは、それを自動的に満たします。

---

## 用語

| | |
|---|---|
| 三番地コード | `d = a op b` の形。オペランドは全部レジスタ |
| 基本ブロック | 途中に入口も出口もない命令の列。最後は必ず終端命令 |
| 終端命令 | `jmp` `br` `ret` の3つ |
| フレームスロット | フレーム上の1語ぶんの場所。逃げた変数とスピルが住む |
| 静的リンク | 入れ子関数が受け取る、外側のフレームへのポインタ |

---

## 3.1 変数は2回書かれてよい

`count` を下げた直後です。

```
$ uv run python -m wolv emit -s ir --no-checks count.wol
fun wol_count(%0, %1)  ; depth 1, 0 slots
entry:
    %2 = 0
    %3 = %2
    %4 = 0
    %5 = %4
    jmp test1
test1:  ; preds: entry, body2
    %6 = %3 < %1
    br %6 ? body2 : done3
body2:  ; preds: test1
    %7 = %5 + %3
    %5 = %7
    %8 = 1
    %9 = %3 + %8
    %3 = %9
    jmp test1
done3:  ; preds: test1
    ret %5
```

`%3` が `i`、`%5` が `total` です。どちらも**入口とループ本体の2箇所で書かれて
います**。これは SSA ではありません。そしてここまでで正しい —— `test1` に来る
どちらの道からも、`%3` には最後に書かれた値が入っています。

φ を置こうとすると、置く場所（支配辺境）を知る必要があり、それはこのパスの仕事では
ありません。書き分けを1つの名前に畳むのは[4章](04-ssa.md)です。

`val` の束縛にも `Move` を必ず出しているのが見えます（`%3 = %2`）。これは無駄に
見えますが必要です。`var x = 1; val y = x; x := 2` で `y` が 2 になってしまわない
ためには、`y` は `x` のレジスタを共有してはいけません。SSA にしたあとコピー伝播が
安全に消します（[5章](05-opt.md)）。

---

## 3.2 制御フローの作り方

`if` はこう作ります。

```python
yes, no, join = self.fresh("then"), self.fresh("else"), self.fresh("join")
self.branch(self.value(e.cond), yes, no)
self.cur = yes;  value = self.exp(e.then);  移す;  self.jump(join)
self.cur = no;   value = self.exp(e.els);   移す;  self.jump(join)
self.cur = join
```

「移す」は、`if` が値を持つときだけ `Move(result, value)` を出すという意味です。
`result` は両方の枝で書かれる1つのレジスタ —— つまりまた「2回書く」です。

`while` は test / body / done の3ブロック。`for` は Tiger と同じで、増やす前に
上限と比べるので**オーバーフローしません**。

```
i = lo;  if i <= hi then body else done
body: …本体…;  if i < hi then step else done
step: i = i + 1;  jmp body
```

`break` は、いま入っているループの done へ跳ぶだけです。跳んだあとは「死んだ
ブロック」に切り替えて、そこに続きを出します。到達不能なので最後に消えます。

```python
def terminate(self, term: ir.Terminator) -> None:
    self.emit(term)
    self.cur = self.fresh("dead")
```

この小細工のおかげで、このパスのどこにも「もう終端したか」の判定が要りません。

---

## 3.3 変数の居場所

[2章](02-types.md)が決めた `escapes` を、ここで居場所に変えます。

```python
def bind(self, sym: VarSym, value: ir.Reg) -> None:
    if sym.escapes:
        sym.slot = self.func.new_slot()
        self.emit(ir.StoreSlot(sym.slot, value))
    else:
        sym.reg = self.reg()
        self.emit(ir.Move(sym.reg, value))
```

読み書きも同じ分岐で、3通りになります。

| 場合 | 命令 |
|---|---|
| 逃げていない | そのレジスタを直接使う |
| 逃げた・自分のフレーム | `LoadSlot` / `StoreSlot` |
| 逃げた・外側のフレーム | 静的リンクを k 回たどって `Load` / `Store` |

---

## 3.4 静的リンク

深さ1以上の関数は、隠れた第1引数として**親のフレームポインタ**を受け取り、それを
スロット0に置きます。スロット0が常に静的リンクなので、鎖は「誰のフレームか」を
知らずにたどれます。

`inner` を見ます（`outer` の中の、さらに `let` の中の関数なので深さ2）。

```
$ uv run python -m wolv emit -s ir esc.wol
fun wol_inner(%0)  ; depth 2, 1 slots
entry:
    slot0 = %0
    %1 = slot0
    %2 = [%1 + -24]
    %3 = slot0
    %4 = [%3 + -16]
    %5 = %2 + %4
    ret %5
```

`%0` が静的リンク、`slot0 = %0` がそれを自分のフレームに置く命令です。`kept` は親の
スロット2（`x29 - 24`）、`n` は親のスロット1（`x29 - 16`）。オフセットの計算はここで
確定します。

```python
def slot_offset(slot: int) -> int:
    if slot < 0:
        return 16 + WORD * (-slot - 1)   # 呼び出し側がスタックに置いた引数
    return -WORD * (slot + 1)
```

負のスロットは**9個目以降の引数**です。呼び出し規約でスタックに置かれたものは、もう
フレームの中にあるので、そこを直接読みます。エントリでレジスタに写しません。これは
見た目の問題ではなく、写すとエントリの生存値が引数の個数だけ増えてしまい、レジスタが
少ない機械でスピルが収束しなくなります（[7章](07-chordal.md)）。

### 使わない静的リンクは持たない

誰にも入れ子にされておらず、外も見ない関数は静的リンクを持ちません。このパスの最後に
確かめて、スロットごと落とし、以降のスロット番号を1つずつ詰めます。

```python
def drop_unused_static_link(self) -> None:
    slot = self.func.static_link_slot
    if slot < 0 or self.has_children:
        return
    ...
```

`count` の `; depth 1, 0 slots` はその結果です。フレームが1語ぶん小さくなり、
エントリの `str` が1つ消えます。

---

## 3.5 実行時検査

添字・`nil`・ゼロ除算の3つを検査します。検査はブロックを増やします。

```
        …添字を計算…
        len = [base + 0]
        br (idx u< len) ? ok : oob
oob:    wol_bounds_error(idx, len)     ; 戻ってこない
        jmp ok
ok:     …本当の読み書き…
```

符号なし比較 `u<` を1つ置くだけで、負の添字も同時に捕まります。`--no-checks` で
全部消せます —— この本のダンプの多くがそうしているのは、検査があると同じことを
言うのに行数が3倍要るからです。

失敗ブロックから `jmp ok` が出ているのは、CFG を「終端が必ず1つ」の形に保つためです。
実行時には戻ってきません。

---

## 3.6 ヒープの形

| 値 | 表現 |
|---|---|
| `int`, `bool` | 64ビットの語。`bool` は 0 か 1 |
| レコード | フィールド数ぶんの語。`nil` は 0 |
| 配列 | 長さ1語 ＋ 要素。ポインタは先頭を指す |
| 文字列 | 長さ1語 ＋ バイト列 ＋ NUL |

配列の要素が長さ1語ぶん後ろにあるのは、生成コードに直接見えます。

```
	add x9, x1, x2, lsl #3     ; base + i*8
	ldr x9, [x9, #8]           ; その +8
```

2命令です。この機械でこれ以下にはなりません（[6章](06-select.md)で、なぜ
scaled-index アドレッシングで1命令にならないかを見ます）。

---

## していないこと

- 末尾呼び出しの最適化はありません。
- 逃げた変数を「ループの中だけレジスタに昇格する」ようなことはしません。逃げたら
  最後までメモリです。
- ガベージコレクタはありません。割り当ては bump ポインタで、返しません。

---

## 参考文献

- Andrew Appel, *Modern Compiler Implementation in ML*, 6章（フレームと静的リンク）
  と 7章（木を下げる）.

---

## 実装の地図

| | |
|---|---|
| `ir.py` | 命令、`Block`/`Func`/`Module`、CFG のユーティリティ、`slot_offset` |
| `lower.py` | `Lowerer`（モジュール全体）と `FuncLowerer`（1関数） |
| `lower.FuncLowerer.bind` | 変数の居場所を決めるところ |
| `lower.FuncLowerer.frame_at` | 静的リンクの鎖をたどるところ |
