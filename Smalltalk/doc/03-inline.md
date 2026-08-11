# 3. 制御構文をジャンプに畳む — `compiler`

Smalltalk では `ifTrue:` は Boolean へのメッセージで、`whileTrue:` は Block への
メッセージです。素直に実装すると、`if` 1つにつき送信が1回とブロック起動が1回かかり
ます。コンパイラはそれを**条件ジャンプに畳みます**。

畳む条件は1つだけです。**引数がリテラルの0引数ブロックとして書かれていること。**

## 1. 畳む対象

```python
_COND = {"ifTrue:", "ifFalse:", "ifTrue:ifFalse:", "ifFalse:ifTrue:"}
_LOGIC = {"and:", "or:"}
_LOOP = {"whileTrue:", "whileFalse:", "whileTrue", "whileFalse", "repeat"}
```

C++ 側はこれに2つ足します。

```cpp
if (s == "to:do:") return inline_to_do(n);
if (s == "timesRepeat:") return inline_times(n);
```

**この2つの差が[11章](11-fast.md)の数値に効きます。**

## 2. 条件分岐 — 前方ジャンプと後埋め

```
$ 5 > 2 ifTrue: ['big'] ifFalse: ['small']
  0  PUSH_LITERAL 0 (5)
  1  PUSH_LITERAL 1 (2)
  2  SEND         ('>', 1)
  3  JUMP_FALSE   6          ← false なら false 枝へ
  4  PUSH_LITERAL 2 ('big')  ← true 枝
  5  JUMP         7          ← 合流点へ
  6  PUSH_LITERAL 3 ('small')← false 枝
  7  RETURN                  ← 合流。値が1つ残る
```

飛び先はまだ分からないので、`arg=None` で命令を出しておいて後から埋めます。

```python
self._expr(node.receiver)
j_false = g.emit(Op.JUMP_FALSE, None)
if true_b is not None:
    self._inline_block_body(true_b)
else:
    g.emit(Op.PUSH_NIL)
j_end = g.emit(Op.JUMP, None)
g.code[j_false].arg = g.here()      # ← 後埋め
```

4つのセレクタを2つの枝に正規化してから同じ骨を通します。

```python
if sel == "ifTrue:":
    true_b, false_b = blocks[0], None
elif sel == "ifFalse:":
    true_b, false_b = None, blocks[0]
elif sel == "ifTrue:ifFalse:":
    true_b, false_b = blocks[0], blocks[1]
else:  # ifFalse:ifTrue:
    true_b, false_b = blocks[1], blocks[0]
```

**`ifFalse:ifTrue:` は引数を入れ替えるだけ**で、命令の形は同じです。

`JUMP_FALSE` は真偽値以外を拒みます。

```python
case Op.JUMP_FALSE:
    match stack.pop():
        case False: ctx.ip = ins.arg
        case True: pass
        case _: raise STError("condition must be a Boolean")
```

**`nil` も `0` も条件になりません。** Smalltalk に真偽値以外の「偽っぽいもの」が
ないという規則が、この3行です。

## 3. `and:` の短絡

```
$ true and: [false]
  0  PUSH_TRUE
  1  JUMP_FALSE   4     ← レシーバが false なら…
  2  PUSH_FALSE         ← [false] の中身をインライン
  3  JUMP         5
  4  PUSH_FALSE         ← …短絡して false
  5  RETURN
```

引数のブロックが評価されないことが、次の式で見えます。

```
$ (3 > 2) or: [1/0]
true
```

`1/0` はゼロ除算エラーになるはずですが、**そこに行きません**。

## 4. ループ — 後方ジャンプ

```
$ | i | i := 1. [i <= 3] whileTrue: [i := i + 1]. i
  0  PUSH_LITERAL 0 (1)
  1  STORE_LOCAL  0
  2  POP
  3  PUSH_LOCAL   0      ← ループ先頭
  4  PUSH_LITERAL 1 (3)
  5  SEND         ('<=', 1)
  6  JUMP_FALSE   13     ← 条件が false なら脱出
  7  PUSH_LOCAL   0
  8  PUSH_LITERAL 0 (1)
  9  SEND         ('+', 1)
 10  STORE_LOCAL  0
 11  POP                 ← 本体の値を捨てる
 12  JUMP         3      ← 後方ジャンプ
 13  PUSH_NIL            ← whileTrue: の結果
 14  POP
 15  PUSH_LOCAL   0
 16  RETURN
```

**`whileTrue:` はレシーバもブロックです。** レシーバのブロックが条件、引数のブロックが
本体で、どちらもその場に展開されます。ここではブロックが1つも作られず、
`SEND` は `<=` と `+` の2つだけです。

## 5. 畳めないときは普通の送信に落ちる

```
$ | flag b | flag := true. b := ['yes']. flag ifTrue: b
  ...
  6  PUSH_LOCAL   0
  7  PUSH_LOCAL   1
  8  SEND         ('ifTrue:', 1)
  9  RETURN
```

引数が変数なので畳めません。**`ifTrue:` が本物のメッセージ送信になり**、
`Boolean>>ifTrue:` というプリミティブがブロックを `value` します。

```python
b.prim(Boolean, "ifTrue:", lambda vm, r, a: vm.run_block(a[0], []) if r else nil)
```

畳めないときのために**プリミティブは必ず用意されています**。畳むのは最適化であって
言語の定義ではない、という関係がここに出ています。

`_zero_arg_block` が門番です。

```python
def _zero_arg_block(self, node: ast.ExprNode) -> ast.BlockNode | None:
    if isinstance(node, ast.BlockNode) and not node.params:
        return node
    return None
```

**構文木の形だけを見ます。** 「この変数には常にブロックが入る」というような解析は
しません。

## 6. 畳まれたブロックには枠がない

これが意味論に見える帰結です。

```smalltalk
inlined      true ifTrue: [^thisContext printString]. ^'no'
notInlined   | b | b := [thisContext printString]. ^b value
```

```
$ P new inlined     => 'a MethodContext (P>>inlined)'
$ P new notInlined  => 'a BlockContext'
```

畳まれたブロックは活性化を作らないので、その中の `thisContext` は**メソッドの
コンテキスト**です。これは本物の Smalltalk とも同じ振る舞いです。

同じ理由で、畳まれたブロックの一時変数は外側のスコープに宣言されます。

```python
def _inline_block_body(self, block: ast.BlockNode) -> None:
    # インライン化されたブロックの一時変数は、外側の活性化を共有する
    for name in block.temps:
        self.scope.declare(name)
    self._sequence_value(block.body, is_method_body=False)
```

**コンパイラのスコープの入れ子が、実行時のフレームの鎖とぴったり一致します。**
これがないと `PUSH_OUTER (深さ, 番号)` の深さが合いません（[4章](04-scope.md)）。

## 7. C++ 側が `to:do:` を畳む理由

Python 側では `to:do:` はプリミティブです。

```python
b.prim(Number, "to:do:", lambda vm, r, a: _to_do(vm, r, a[0], 1, a[1]))
```

`_to_do` はループを回して `vm.run_block(block, [i])` を呼びます。つまり
**繰り返しごとにホストの再帰が1段深くなって戻る**。

C++ 側はそれを畳みます。

```cpp
bool inline_to_do(MessageExpr* n) {
    BlockExpr* body = one_block(n->args[1].get());
    if (body == nullptr) return false;
    int i_slot = scope_->declare(body->params[0]);
    int limit_slot = gentemp();
    expr(n->receiver.get());
    emit(Op::StoreLocal, i_slot);
    ...
}
```

**1引数のブロックを畳むので、ループ変数を受け取る枠が要ります。** それを
`scope_->declare(body->params[0])` で外側の活性化のスロットとして確保し、
上限のための無名の一時変数を `gentemp()` で足します。あとは `whileTrue:` と
同じ骨です。

```
$ ./build/st_bench
  to:do: sum 1..3,000,000                169.0 ms
  timesRepeat: 3,000,000                 170.5 ms
```

Python 側の同じ形（30万回）が 653 ms なので、1回あたり 2.18 µs 対 0.056 µs です。
**39倍のうちのかなりの部分がこの畳み込みです** — 残りは[11章](11-fast.md)。

## していないこと

**`ifNil:` を畳んでいません。** どちらの実装でもプリミティブで、ブロックを
`value` します。畳むには「レシーバが nil かどうか」の分岐命令が要ります。

**`ifTrue:` の引数が変数のときに何もしません。** 5節のとおり普通の送信です。
型の情報がないので、畳んでよいか分かりません。

**`to:by:do:` を畳んでいません。** C++ 側でも `to:do:` と `timesRepeat:` だけです。
`by:` があると増分が負になりうるので、比較の向きが実行時に決まります。

**畳んだあとに何も見ていません。** ジャンプの連鎖（`JUMP` の先がまた `JUMP`）を
潰していませんし、到達しない命令も残ります（[2章](02-bytecode.md)4節の
暗黙の `^self` がその例）。

## 参考文献

- A. Goldberg, D. Robson, *Smalltalk-80*, §27。Blue Book のコンパイラも
  `ifTrue:` などを「特別セレクタ」としてジャンプに畳みます。この章はその再現です。
- L. P. Deutsch, A. Schiffman, [*Efficient Implementation of the Smalltalk-80
  System*][ds84], POPL 1984。畳み込みとインラインキャッシュを合わせた最初期の報告。
  7節の判断はここまで含めて Blue Book の後継です。

[ds84]: https://doi.org/10.1145/800017.800542

## 実装の地図

| Python | |
|---|---|
| `st/compiler.py` 96–98行 | 畳む対象の3集合 |
| `st/compiler.py` 274行 | `_try_inline` |
| `st/compiler.py` 284行 | `_zero_arg_block` — 門番 |
| `st/compiler.py` 289行 | `_inline_block_body` — 一時変数を外側へ |
| `st/compiler.py` 295行 | `_inline_cond` — 4セレクタを2枝に正規化 |
| `st/compiler.py` 326行 | `_inline_logic` — 短絡 |
| `st/compiler.py` 348行 | `_inline_loop` |
| `st/kernel.py` 366–381行 | 畳めないときのプリミティブ |
| `st/kernel.py` 430行 | `to:do:` プリミティブ |
| `st/vm.py` 426行 | `JUMP_FALSE` — Boolean 以外を拒む |

| C++ | |
|---|---|
| `src/compiler.cppm` 325行 | `try_inline` — 2つ多い |
| `src/compiler.cppm` 339行 | `inline_cond` |
| `src/compiler.cppm` 386行 | `inline_while2` |
| `src/compiler.cppm` 425行 | `inline_to_do` — ループ変数をスロットに束縛 |
| `src/compiler.cppm` 454行 | `inline_times` |

---

[← 2. 命令セット](02-bytecode.md) ／ [目次](index.md) ／ [4. 変数をコンパイル時に解く →](04-scope.md)
