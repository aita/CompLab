# 5. 活性化を物にする — `vm.Frame` ／ `objects.cppm` の `Context`

処理系がメソッド呼び出しのために持つ構造体を、そのまま Smalltalk のオブジェクトに
します。**フレームを作ってからオブジェクトに包み直す段がありません。** フレームが
`MethodContext` です。

## 1. フレームが持つもの

```python
class Frame:
    __slots__ = (
        "receiver",   # self
        "method",     # CompiledMethod | CompiledBlock
        "locals",     # 引数 + 一時変数（平らな配列）
        "outer",      # 字句的に外側の活性化（クロージャ）
        "stack",      # オペランドスタック
        "ip",
        "is_block",
        "home",       # ブロックなら、それを作ったメソッドの活性化
        "sender",     # 呼び出し元
        "st_class",   # MethodContext / BlockContext
    )
```

**リンクが3本あります。** `outer` は字句的な外側、`sender` は動的な呼び出し元、
`home` は非局所リターンの行き先です。3本とも別の役目です。

C++ 側も同じ形で、こちらは `Object` を継承します。

```cpp
// メソッドまたはブロックの活性化。クロージャがこれを生かし続けられるように、
// オブジェクトとして具現化されている。
struct Context : Object {
    static constexpr Tag TAG = Tag::Context;
    Value receiver = nil();
    Object* method = nullptr;  // CompiledMethod* または CompiledBlock*
    std::vector<Value> locals;
    std::vector<Value> stack;
    Context* outer = nullptr;
    Context* sender = nullptr;
    Context* home = nullptr;
    int ip = 0;
    bool is_block = false;
};
```

**オペランドスタックはフレームが持ちます。** VM は持ちません。だから活性化を1つ
取り出せば、その途中の計算の状態もそこに全部あります。

## 2. `sender` の鎖が呼び出しスタック

VM が持つのは「いまどの活性化か」だけです。

```python
# いま走っている活性化。具現化された呼び出しスタックの先端。
# thisContext がこれを読み、sender リンクがこれを辿る。
self.active_context: Frame | None = None
```

`sender` は活性化を作るときに繋がれます。

```python
return Frame(
    receiver, method, locals_,
    outer=None, is_block=False, home=None,
    sender=self.active_context,
    st_class=self.classes.get("MethodContext"),
)
```

**呼び出しスタックはヒープ上の連結リストです。** ホストのスタックではありません。
これが[6章](06-loop.md)を可能にします。

## 3. Smalltalk から見える

```python
def _install_context(b: _Builder) -> None:
    C = b.vm.classes["Context"]
    b.prim(C, "receiver", lambda vm, r, a: r.receiver)
    b.prim(C, "sender", lambda vm, r, a: r.sender if r.sender is not None else nil)
    b.prim(C, "home", lambda vm, r, a: r.home if r.home is not None else r)
    b.prim(C, "selector", lambda vm, r, a: _ctx_selector(r))
    b.prim(C, "pc", lambda vm, r, a: r.ip)
    b.prim(C, "isBlockContext", lambda vm, r, a: r.is_block)
    b.prim(C, "printString", lambda vm, r, a: _ctx_print(r))
```

**プリミティブが属性を読むだけです。** 変換も複製もありません。

だから呼び出しの深さが Smalltalk で書けます。

```smalltalk
depth
    | n c | n := 0. c := thisContext.
    [c isNil] whileFalse: [n := n + 1. c := c sender]. ^n
```

```
$ Probe new depth   => 2
$ Probe new a       => 4      "a → b → depth → DoIt"
```

`2` は `depth` 自身と、それを呼んだ DoIt です。`a` 経由なら `a` と `b` が挟まって
4になります。

`printString` はメソッドがどのクラスに入っているかまで出します。

```
$ P new inlined     => 'a MethodContext (P>>inlined)'
$ P new notInlined  => 'a BlockContext'
```

## 4. クラスは3つ

```python
Context = b.cls("Context", Object)
b.cls("MethodContext", Context)
b.cls("BlockContext", Context)
```

`st_class` を活性化を作るときに入れるので、`class_of` は Frame を見たらそれを返します。

```python
case Frame():
    return value.st_class or c["Context"]
```

## 5. ブロックが活性化を捕まえる

```python
@dataclass
class STBlock:
    node: Any          # bytecode.CompiledBlock
    outer: Any         # vm.Frame — ブロックを作った活性化
    home_context: Any  # vm.Frame (MethodContext) | None
```

```python
case Op.PUSH_BLOCK:
    tmpl = literals[ins.arg]
    home = ctx if not ctx.is_block else ctx.home
    stack.append(STBlock(tmpl, ctx, home))
```

**`outer` はいまの活性化、`home` はブロックの中なら親のホーム。** ブロックの中の
ブロックでも、`home` は同じメソッドの活性化を指し続けます。

だから閉包は変数のスナップショットではなく**活性化そのもの**を持ちます。
[4章](04-scope.md)の `PUSH_OUTER (深さ, 番号)` は、この `outer` を深さ回だけ
辿ってスロットを読みます。

C++ 側では、`Context` が GC オブジェクトであることが直接効きます。

```cpp
case Tag::Block: {
    auto* b = static_cast<Block*>(o);
    push(work, b->tmpl);
    push(work, b->outer);
    push(work, b->home);
    break;
}
```

**閉包が生きているかぎり、それが捕まえた活性化も生きます**（[9章](09-memory.md)）。
メソッドから戻ったあとでも、返されたブロックがその枠を保ちます。

## 6. 具現化の代価

活性化がオブジェクトなので、**呼び出しごとにヒープ割り付けが1回**起きます。
C++ 側では `heap_.new_context()`、Python 側では `Frame(...)` です。

これが `fib:` のような呼び出しの多いプログラムで効きます。

```
$ ./build/st_bench
  fib: 30  (recursion, dispatch)         371.8 ms
  ackermann 3,7  (deep recursion)        101.7 ms
```

呼び出しを平らな配列上のスタックにすれば割り付けは消せますが、そのとき
`thisContext` を返すには枠をヒープへ写す段（本物の Smalltalk がやっていること）が
要ります。**この処理系は最初から写しません。**

## していないこと

**コンテキストを再開できません。** `Context` を保存しておいて後から続きを走らせる
ことはできません。`sender` を書き換えるプリミティブもありません。継続もコルーチンも
`Process` もないのはこのためです（[14章](14-next.md)）。

**`isDead` が常に偽です。**

```python
b.prim(C, "isDead", lambda vm, r, a: False)
```

活性化が既に戻ったかどうかを覚えていないので、答えようがありません。
[7章](07-return.md)の「死んだコンテキストへの非局所リターン」は、`sender` の鎖を
歩いて見つからないことで検出します。

**C++ 側に Context のプロトコルがありません。** `Context` クラスは登録されて
いますが、`sender` などのプリミティブがないので、`thisContext` を受け取っても
`an Object` としか出ません。

```
$ ./build/smalltalk
st> thisContext
an Object
```

**コンテキストをプールしていません。** 呼び出しのたびに新しく作り、GC に任せます。

## 参考文献

- A. Goldberg, D. Robson, *Smalltalk-80*, §27。`thisContext`・`MethodContext`・
  `BlockContext` の意味づけの出どころ。Blue Book では活性化は最初からオブジェクト
  です。
- L. P. Deutsch, A. Schiffman, [*Efficient Implementation of the Smalltalk-80
  System*][ds84], POPL 1984。活性化をホストのスタックに置き、`thisContext` を
  求められたときだけオブジェクトに写す（context hazards）という手。6節で
  「やっていない」と言っているのがこれです。

[ds84]: https://doi.org/10.1145/800017.800542

## 実装の地図

| Python | |
|---|---|
| `st/vm.py` 53行 | `Frame` — 3本のリンク |
| `st/vm.py` 107行 | `active_context` |
| `st/vm.py` 235行 | `_method_frame` — `sender` を繋ぐ |
| `st/vm.py` 256行 | `_block_frame` |
| `st/vm.py` 442行 | `PUSH_BLOCK` — `outer` と `home` |
| `st/objects.py` 202行 | `STBlock` |
| `st/kernel.py` 205–207行 | `Context` / `MethodContext` / `BlockContext` |
| `st/kernel.py` 1083行 | `_install_context` |

| C++ | |
|---|---|
| `src/objects.cppm` 308行 | `Block` |
| `src/objects.cppm` 319行 | `Context` — `Object` を継承 |
| `src/vm.cppm` 126行 | `make_method_frame` |
| `src/vm.cppm` 141行 | `make_block_frame` |
| `src/vm.cppm` 286行 | `PushBlock` |
| `src/heap.cppm` 164行 | `Context` の走査 |

---

[← 4. 変数をコンパイル時に解く](04-scope.md) ／ [目次](index.md) ／ [6. 1つのループ →](06-loop.md)
