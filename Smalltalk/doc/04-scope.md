# 4. 変数をコンパイル時に解く — `compiler.Scope`

変数参照は3段で解かれます。**いまの活性化のスロット、外側の活性化のスロット、
それ以外**。最初の2つはコンパイル時に番号になり、3つ目だけが名前のまま残ります。

## 1. `Scope` は宣言順のスロット表

```python
class Scope:
    """1つの活性化（メソッド、または畳まれなかったブロック）の字句スコープ。

    スロットは宣言順に振る。引数が先、次に一時変数、最後に畳まれたブロックから
    巻き上げられた一時変数。畳まれたブロックはスコープを作らない — その一時変数は
    外側のスコープに宣言される — ので、コンパイラのスコープの入れ子が実行時の
    フレームの鎖とぴったり一致する。"""
```

最後の1文がこの章の要です。**[3章](03-inline.md)で畳まれたブロックはフレームを
作らないので、スコープも作らない。** 作ってしまうと `PUSH_OUTER` の深さが1ずれます。

解決は外へ向かって歩き、歩数を数えます。

```python
def resolve(self, name: str) -> tuple[int, int] | None:
    scope: Scope | None = self
    depth = 0
    while scope is not None:
        slot = scope.index.get(name)
        if slot is not None:
            return depth, slot
        scope = scope.parent
        depth += 1
    return None
```

`None` は「ローカルではない」で、そのとき初めて名前ベースに落ちます。

```python
def _load(self, name: str) -> None:
    match name:
        case "self" | "super":
            self.g.emit(Op.PUSH_SELF)
        case "thisContext":
            self.g.emit(Op.PUSH_CONTEXT)
        case _:
            loc = self.scope.resolve(name)
            if loc is None:
                self.g.emit(Op.PUSH_VAR, name)  # インスタンス変数 / グローバル
            elif loc[0] == 0:
                self.g.emit(Op.PUSH_LOCAL, loc[1])
            else:
                self.g.emit(Op.PUSH_OUTER, loc)
```

`self` と `super` が同じ命令なのがここで見えます。**`super` はレシーバを変えず、
探索の起点だけを変える**ので、値としては `self` です（[8章](08-objects.md)）。

## 2. 深さは `outer` を辿る回数

```
$ | a | a := 1. [:x | [:y | a + x + y]]
  ...
  -- block ['x'] locals=['x'] --
    0  PUSH_BLOCK   0 (...)
    1  BLOCK_RETURN
    -- block ['y'] locals=['y'] --
      0  PUSH_OUTER   (2, 0)    ← a：2段外のスロット0
      1  PUSH_OUTER   (1, 0)    ← x：1段外のスロット0
      2  SEND         ('+', 1)
      3  PUSH_LOCAL   0         ← y：自分のスロット0
      4  SEND         ('+', 1)
      5  BLOCK_RETURN
```

3つの変数が3段の別々の場所にいて、**どれもコンパイル時に番号になっています**。
実行時の名前引きはありません。

VM 側は素直です。

```python
case Op.PUSH_OUTER:
    depth, index = ins.arg
    f = ctx.outer
    for _ in range(depth - 1):
        f = f.outer
    stack.append(f.locals[index])
```

`depth - 1` なのは、`ctx.outer` を取った時点で1段進んでいるからです。

## 3. ローカルは平らな配列

```python
locals_ = [nil] * len(method.local_names)
locals_[: len(args)] = args  # 引数が先頭のスロットを占める
```

**辞書でもチェインでもありません。** `local_names` の長さがそのままスロットの数で、
引数が先頭に入ります。宣言順にスロットを振ったのは、この1行のためです。

## 4. 3段目 — 名前のまま残るもの

`resolve` が `None` を返したものは `PUSH_VAR` / `STORE_VAR` になります。Python 側の
VM はそれを2段で解きます。

```python
def _read_var(self, frame: Frame, name: str) -> Any:
    recv = frame.receiver
    if type(recv) is STObject and name in recv.st_class.all_instance_variables():
        return recv.ivars.get(name, nil)
    if name in self.globals:
        return self.globals[name]
    raise STError(f"undeclared variable {name!r}")
```

**インスタンス変数が先、グローバルが後。** 書くほうは、インスタンス変数でなければ
**グローバルとして自動宣言**します。

```python
def _write_var(self, frame: Frame, name: str, value: Any) -> None:
    ...
    # ワークスペースの名前空間へ自動宣言
    self.globals[name] = value
```

これでワークスペースが使えます。

```
$ zz := 3      => 3
$ zz + 4       => 7
$ qq + 1       !! STError undeclared variable 'qq'
```

**書けば宣言され、読むだけなら誤り。** 対称でないのは意図で、綴り間違いを捕まえる
ためです。

## 5. C++ はインスタンス変数もスロットにする

Python 側はインスタンス変数を名前で解きます。

```
$ Acc >> add: n
      total := total + n. ^total
  0  PUSH_VAR     'total'
  1  PUSH_LOCAL   0
  2  SEND         ('+', 1)
  3  STORE_VAR    'total'
  ...
```

`total` を読むたびに `all_instance_variables()`（キャッシュ済みのリスト）に対する
`in` と、`ivars` 辞書の引きが走ります。

C++ 側はコンパイラがクラスを受け取るので、そこで番号に変えられます。

```cpp
CompiledMethod* m = comp.compile_method(p.value, std::string(src), c);
```

```cpp
// インスタンス変数はコンパイル時にスロットへ解かれる（PushIvar / StoreIvar）。
// PushVar / StoreVar が届くのはグローバルだけ。
Value read_var(const std::string& name) {
    auto g = globals_.find(name);
    if (g != globals_.end()) return g->second;
    fail("undeclared variable " + name);
    return nil();
}
```

VM 側は配列アクセス1回です。

```cpp
case Op::PushIvar:
    stk->push_back(static_cast<Instance*>(as_obj(ctx->receiver))->slots[ins.arg]);
    break;
```

`Instance` は辞書ではなく平らなベクタを持ちます。

```cpp
Instance* new_instance(Class* c) {
    Instance* inst = make<Instance>(c);
    inst->slots.assign(c->ivar_count(), nil());
    return inst;
}
```

**オブジェクト生成が約36%速くなった**のがこの変更です（[11章](11-fast.md)）。

代価は、**メソッドがクラスに縛られること**です。同じソースを別のクラスに入れるには
コンパイルし直す必要があります。Python 側は名前で解くので入れ替えられます。

## 6. ブロックはメソッドのインスタンス変数に届く

```cpp
Compiler sub(heap_);
sub.begin(&block_scope);
sub.cls_ = cls_;  // ブロックはホームメソッドのインスタンス変数に届く
```

ブロックのコンパイラにも同じクラスを渡します。**ブロックの中の `total` も
スロットになります。** 実行時には `ctx->receiver` を見るので、ブロックの
`receiver` がホームの `receiver` と同じであることが要ります。

```cpp
ctx->receiver = b->home != nullptr ? b->home->receiver : nil();
```

## していないこと

**未使用の変数を報告しません。** 宣言してスロットだけ取られます。

**シャドウイングを禁じていません。** ブロックの引数がメソッドの一時変数と同じ名前でも
通り、内側が勝ちます。

**インスタンス変数とローカルの衝突を報告しません。** ローカルが勝ちます。3段の
順序がそのまま優先順位です。

**Python 側でインスタンス変数をスロットにしていません。** 5節のとおり、できます
（C++ 側がやっています）が、メソッドがクラスに縛られる代価を Python 側では
払っていません。IDE がメソッドを付け替える操作を素直に書けるほうを採っています。

**グローバルの読みだけ厳しいのは非対称です。** 4節のとおり意図的ですが、
`x := x + 1` を新しい名前で書くと右辺で落ちます。

## 参考文献

- A. Goldberg, D. Robson, *Smalltalk-80*, §27。Blue Book では一時変数は
  「temporary frame」の添字で、インスタンス変数もオブジェクトの添字です。
  5節の C++ 側はそちらに近く、Python 側は名前引きを残しています。
- R. Nystrom, [*Crafting Interpreters*][ci] "Closures" の upvalue。深さと添字で
  外側の変数に届く形。ここでは upvalue を作らず、活性化そのものを鎖で辿ります
  （[5章](05-context.md)）。

[ci]: https://craftinginterpreters.com/closures.html

## 実装の地図

| Python | |
|---|---|
| `st/compiler.py` 30行 | `Scope` — 畳まれたブロックはスコープを作らない |
| `st/compiler.py` 44行 | `declare` |
| `st/compiler.py` 52行 | `resolve` — 深さを数える |
| `st/compiler.py` 211行 | `_load` — 3段 |
| `st/compiler.py` 226行 | `_store` |
| `st/compiler.py` 394行 | `_block_literal` — 子スコープを作る |
| `st/vm.py` 243行 | ローカルの平らな配列 |
| `st/vm.py` 328行 | `_read_var` — ivar が先、グローバルが後 |
| `st/vm.py` 336行 | `_write_var` — 自動宣言 |
| `st/vm.py` 446行 | `PUSH_OUTER` — `depth - 1` |

| C++ | |
|---|---|
| `src/compiler.cppm` 484行 | `block_literal` — `cls_` を引き継ぐ |
| `src/vm.cppm` 205行 | `read_var` — グローバルだけ |
| `src/vm.cppm` 265行 | `PushIvar` — 配列アクセス |
| `src/heap.cppm` 51行 | `new_instance` — スロットを確保 |
| `src/system.cppm` 84行 | `compile_method` にクラスを渡す |

---

[← 3. 制御構文をジャンプに畳む](03-inline.md) ／ [目次](index.md) ／ [5. 活性化を物にする →](05-context.md)
