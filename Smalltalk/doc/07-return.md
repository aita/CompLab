# 7. `^` — 例外を使う実装と、使わない実装

ブロックの中の `^` は、そのブロックを**作ったメソッド**から返ります。呼び出し元では
ありません。この1行の意味論が、二度書いて割れた唯一の場所です。

## 1. 何をしたいのか

```smalltalk
firstEven: c
    c do: [:x | x even ifTrue: [^x]].
    ^nil
```

```
$ R new firstEven: #(1 3 4 7 8)   => 4
$ R new firstEven: #(1 3 5)       => nil
```

`^x` が発火したとき、**`do:` のループごと巻き戻して `firstEven:` の呼び出し元へ
`x` を返す**必要があります。ブロックの活性化も、`do:` の活性化も、途中に挟まった
ものは全部捨てます。

コンパイル結果では、ブロックの中の `^` が `RETURN` になっています。

```
$ ブロック [:x | x even ifTrue: [^x]]
  0  PUSH_LOCAL   0
  1  SEND         ('even', 0)
  2  JUMP_FALSE   6
  3  PUSH_LOCAL   0
  4  RETURN           ← ここが非局所リターン
  5  JUMP         7
  6  PUSH_NIL
  7  BLOCK_RETURN     ← ブロックの正常終了
```

**`RETURN` と `BLOCK_RETURN` が別の命令であること**が、この章の全部の出発点です。

## 2. C++ — 鎖を歩いて、そこへ飛ぶ

```cpp
case Op::Return:
case Op::BlockReturn: {
    Value value = stk->back();
    stk->pop_back();
    Context* target = nullptr;
    if (ins.op == Op::Return && ctx->is_block) {
        Context* home = ctx->home;
        if (!is_live(home, boundary)) {
            fail("non-local return from a dead context");
            return nil();
        }
        target = home->sender;
    } else {
        target = ctx->sender;
    }
    if (target == boundary) { active_context_ = boundary; return value; }
    target->stack.push_back(value);
    load_ctx(target);
    break;
}
```

**`target = home->sender` の1行が非局所リターンです。** ホームの呼び出し元へ
直接飛びます。途中の活性化は何もしません。`sender` の鎖から外れるだけで、
あとは GC が引き取ります（[9章](09-memory.md)）。

生きているかの確認は鎖を歩くだけです。

```cpp
bool is_live(Context* home, Context* boundary) {
    for (Context* c = active_context_; c != nullptr && c != boundary; c = c->sender) {
        if (c == home) return true;
    }
    return false;
}
```

**これが成り立つのは、ループが1つしかないからです**（[6章](06-loop.md)）。
`active_context_` から `boundary` までの鎖が、このループが面倒を見ている活性化の
全部です。途中に C++ のスタックフレームが挟まっていないので、飛び越すものが
ありません。

## 3. Python — ホストの例外で貫く

Python 側は違います。`value` や `do:` がプリミティブで、そこでホストが再帰して
いるので（[6章](06-loop.md)4節）、**C++ ならぬ Python のスタックフレームを
通り抜ける手段が要ります。** それが例外です。

```python
class NonLocalReturn(Exception):
    """`^` の値をブロックからホームの活性化へ運ぶ。"""
    def __init__(self, home: Frame, value: Any):
        ...
```

```python
case Op.RETURN | Op.BLOCK_RETURN:
    value = stack.pop()
    if ins.op is Op.RETURN and ctx.is_block:
        if ctx.home is None:
            raise STError("non-local return with no home context")
        raise NonLocalReturn(ctx.home, value)
```

捕まえるのは、**ホームの活性化を所有している `_run`** です。

```python
while True:
    try:
        return self._loop(boundary)
    except NonLocalReturn as nlr:
        if self._manages(nlr.home, boundary):
            target = nlr.home.sender
            if target is boundary:
                self.active_context = target
                return nlr.value
            target.stack.append(nlr.value)
            self.active_context = target
            continue  # ホームの呼び出し元から実行を再開する
        if boundary is None:
            raise STError("non-local return from a dead context") from None
        raise
```

**「所有しているか」は C++ の `is_live` と同じ歩き方です。**

```python
def _manages(self, home: Frame, boundary: Frame | None) -> bool:
    ctx: Frame | None = self.active_context
    while ctx is not None and ctx is not boundary:
        if ctx is home:
            return True
        ctx = ctx.sender
    return False
```

所有していなければ**再送出**します。外側の `_run`（Python のスタックを1段外へ出た
ところにいる）が受け取ります。この再送出が、`value` / `do:` / `ensure:` の
プリミティブを貫いて戻る仕組みです。

そして所有していれば `continue` — **同じ `_run` の中で `_loop` を呼び直します。**
`target` から実行が再開されます。

## 4. `ensure:` は例外の上に乗る

```
$ R >> guarded
      [^1] ensure: [Transcript showCr: 'cleanup']. ^2

$ R new guarded
cleanup
1
```

`^1` が `NonLocalReturn` として飛び、`ensure:` のプリミティブが Python の
`try/finally` でそれを見送ってから後処理を走らせ、例外は上へ抜けます。

**ホストの例外機構をそのまま借りているので、`ensure:` が3行で書けます。**
C++ 側には `ensure:` がありません（例外がないので、`^` が通り抜けるときに
後処理を走らせる仕掛けを自分で作ることになります）。

## 5. 死んだコンテキストへ返る

```
$ R >> escaping   ^[^42]        "ブロックを返す"
$ R new escaping value
!! STError non-local return from a dead context
```

`escaping` は既に戻っているので、その活性化はもう鎖の上にいません。
`_manages` が見つけられず、`boundary` が `None`（いちばん外側）なので誤りになります。

C++ 側は `is_live` が偽を返し、`fail` します。**どちらも「鎖に見つからない」で
検出していて、活性化に「死んだ」という旗を立ててはいません。**

だから厳密には、**同じ活性化が鎖に戻ってきていれば通ってしまいます**。この処理系では
活性化を再開する手段がないので、そういう状況は作れません（[5章](05-context.md)）。

## 6. どちらが良いか

**C++ 側のほうが単純です。** `target = home->sender` の1行で、例外も、再送出も、
所有権の判定を2箇所に書くこともありません。

しかしそれは、**[10章](10-prelude.md)を先に済ませたから**です。`do:` が Smalltalk で
書かれていて、`value` が命令になっていて、プリミティブが VM に再入しない。その3つが
揃って初めて「鎖を辿れば全部ある」が成り立ちます。

Python 側は `kernel.py` に48箇所の再入があるので、**ホストのスタックを貫く手段が
必要であり、それは例外しかありません。**

言い換えると、この章の差は `^` の実装の差ではなく、**[6章](06-loop.md)と
[10章](10-prelude.md)の差の帰結です。**

## していないこと

**`ensure:` が C++ 側にありません。** 4節のとおりです。入れるには、`Return` が
活性化の鎖を外れるときに「後処理付きの活性化」を見つけて走らせる段が要ります。

**`ifCurtailed:` も `valueUninterruptably` もありません。**

**Smalltalk の例外（`on:do:` / `signal`）は Python 側だけにあります。**
`Error` クラスと `on:do:` / `ensure:` があり、実装はやはりホストの例外です。

**再開できる例外がありません。** `Exception>>resume:` は、活性化を再開する必要が
あるので作れません（[5章](05-context.md)）。

## 参考文献

- A. Goldberg, D. Robson, *Smalltalk-80*, §27。`^` がホームコンテキストから返る
  という意味論と、`BlockContext` が `home` を持つ理由。
- C. Strachey, C. Wadsworth, [*Continuations: a mathematical semantics for
  handling full jumps*][cont], 1974（再録 HOSC 13, 2000）。非局所脱出を
  「継続を捨てる」として見る枠組み。2節の `target = home->sender` はまさに
  「途中の継続を捨てる」操作です。
- J. Goodenough, [*Exception handling: issues and a proposed notation*][excn],
  CACM 18(12), 1975。3節のようにホストの例外を借りるときに何を借りているのか。

[cont]: https://doi.org/10.1023/A:1010026413531
[excn]: https://doi.org/10.1145/361227.361230

## 実装の地図

| Python | |
|---|---|
| `st/vm.py` 44行 | `NonLocalReturn` |
| `st/vm.py` 288行 | `_run` — 捕まえる・再開する・再送出する |
| `st/vm.py` 316行 | `_manages` |
| `st/vm.py` 406–411行 | `RETURN` が投げる条件 |
| `st/kernel.py` 895行あたり | `ensure:` |

| C++ | |
|---|---|
| `src/vm.cppm` 416行 | `Return` / `BlockReturn` — `home->sender` へ飛ぶ |
| `src/vm.cppm` 443行 | `is_live` |
| `src/bytecode.cppm` 34–35行 | 2つの戻り命令 |

---

[← 6. 1つのループ](06-loop.md) ／ [目次](index.md) ／ [8. オブジェクトモデル →](08-objects.md)
