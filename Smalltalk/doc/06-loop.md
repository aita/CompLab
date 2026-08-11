# 6. 1つのループ — `vm.py` の `_run` / `_loop` ／ `vm.cppm` の `run`

この本の中心の章です。**Smalltalk のメッセージ送信で、ホストの関数を再帰的に
呼ばない。** 送信は「活性化を1つ作って、いま見ているものをそれに差し替える」だけで、
ループは回り続けます。

## 1. 差し替えるだけ

```python
ctx = self._method_frame(method, receiver, args)
self.active_context = ctx
code = ctx.method.code
literals = ctx.method.literals
stack = ctx.stack
```

戻りは逆向きです。

```python
sender = ctx.sender
self.active_context = sender
if sender is boundary:
    return value
sender.stack.append(value)
ctx = sender
code = ctx.method.code
literals = ctx.method.literals
stack = ctx.stack
```

C++ 側は同じことをラムダ1つにまとめています。

```cpp
auto load_ctx = [&](Context* c) {
    ctx = c;
    active_context_ = c;
    code = &code_of(c->method);
    lits = &literals_of(c->method);
    stk = &c->stack;
};
```

**`code` / `literals` / `stack` をループの外に持っているのは速さのためです。**
毎回 `ctx->method->code` を辿らずに済みます。差し替えのたびに3つとも張り直します。

## 2. `boundary` — このループが誰まで面倒を見るか

駆動部は「この活性化が戻ったら終わり」を知る必要があります。それが `boundary` です。

```python
def _run(self, root: Frame) -> Any:
    boundary = root.sender
    self.active_context = root
    while True:
        try:
            return self._loop(boundary)
        except NonLocalReturn as nlr:
            ...
```

`boundary` は `root` の呼び出し元です。`RETURN` したときの行き先が `boundary` なら、
**このループの仕事は終わり**なので値を返します。そうでなければ差し替えて続けます。

```python
sender = ctx.sender
self.active_context = sender
if sender is boundary:
    return value
```

C++ 側も同じ形です。

```cpp
if (target == boundary) {
    active_context_ = boundary;
    return value;
}
target->stack.push_back(value);
load_ctx(target);
```

**`boundary` があるので、駆動部を入れ子にできます。** Python 側はそれを使います
（[7章](07-return.md)）。C++ 側は入れ子にしません。

## 3. 効果 — 深さがヒープに乗る

```smalltalk
sum: n
    n = 0 ifTrue: [^0].
    ^n + (self sum: n - 1)
```

```
$ python: recursionlimit = 1000
$ python: Deep new sum: 20000    => 200010000
$ python: Deep new sum: 100000   => 5000050000
```

**10万段の Smalltalk 再帰が、CPython の再帰上限1000の下で走ります。** 深さは
`sender` の鎖としてヒープに積まれるからです。

## 4. どこでホストが再帰するか

Python 側にも再帰は残っています。**VM に再入するプリミティブ**です。

```python
b.prim(Boolean, "ifTrue:", lambda vm, r, a: vm.run_block(a[0], []) if r else nil)
b.prim(Number, "to:do:", lambda vm, r, a: _to_do(vm, r, a[0], 1, a[1]))
```

`run_block` は新しい `_run` を始めます。**そこが1段のホスト再帰です。**

Python 側の `kernel.py` には `run_block` の呼び出しが48箇所あります。

```
$ grep -c "run_block" st/kernel.py
48
```

`value` / `value:` も同じです。だから次の式が割れます。

```smalltalk
| f | f := [:k | k = 0 ifTrue: [0] ifFalse: [k + (f value: k - 1)]]. f value: 100000
```

```
$ python: f value: 100    => 5050
$ python: f value: 300    !! RecursionError
$ cpp:    f value: 100000 => 5000050000
```

**同じ言語、同じプログラムで、片方は300段で落ち、もう片方は10万段を通ります。**
メソッドの再帰（3節）では差が出ず、ブロックの再帰では出ます。

## 5. C++ 側が再入をなくした方法

2つあります。

**（1）`value` 送信をループの中で扱う。**

```cpp
if (ins.op == Op::Send) {
    if (Block* blk = as<Block>(receiver)) {
        if (is_value_selector(ins.name, argc)) {
            Context* nc = make_block_frame(blk, args);
            if (errored_) return nil();
            stk->resize(sp_base - 1);
            nc->sender = ctx;
            load_ctx(nc);
            break;
        }
    }
}
```

**メソッド呼び出しと同じ扱いです。** `value` はプリミティブではなく、VM の命令の
一部になっています。

**（2）反復するライブラリを Smalltalk で書く。**

```cpp
{"SequenceableCollection",
 "do: aBlock\n"
 "  | i n | i := 1. n := self size.\n"
 "  [i <= n] whileTrue: [aBlock value: (self at: i). i := i + 1]"},
```

`do:` がプリミティブでなくなれば、`do:` の中でホストが再帰することもありません。
これが[10章](10-prelude.md)です。

```
$ grep -c "send_message" src/kernel.cppm
0
```

**C++ 側のプリミティブは1つも VM に再入しません。**

## 6. 再入をなくすと、例外が要らなくなる

C++ 側は `-fno-exceptions` で建ちます。エラーは旗です。

```cpp
void fail(std::string msg) {
    if (errored_) return;
    errored_ = true;
    error_ = std::move(msg);
}
```

ループが要所で見ます。

```cpp
case Op::PushVar:
    stk->push_back(read_var(ins.name));
    if (errored_) return nil();
    break;
```

**ループが1つしかないので、旗を見る場所も1つです。** 途中に C++ のフレームが挟まって
いたら、そこを通り抜ける手段（例外か、全部の呼び出しの戻り値検査）が要りました。

`^` も同じ理屈で例外を使いません（[7章](07-return.md)）。

## 7. GC はループの頭でだけ走る

```cpp
while (true) {
    if (heap_.should_collect()) gc();
    Instr& ins = (*code)[ctx->ip++];
```

```cpp
// GC はループの頭でだけ走る。そこでは生きている値がすべて、走っている
// コンテキストかグローバルから到達できる。
void gc() {
    std::vector<Value> roots;
    roots.reserve(globals_.size() + 1);
    for (auto& [name, v] : globals_) roots.push_back(v);
    if (active_context_ != nullptr) roots.push_back(ref(active_context_));
    heap_.collect(roots);
}
```

**根が2つで済みます。** グローバルと、走っているコンテキスト。オペランドスタックも
ローカルも `Context` の中にあり、`sender` の鎖で全部辿れるからです
（[5章](05-context.md)・[9章](09-memory.md)）。

命令の途中で GC が走らないので、**C++ のローカル変数に一時的に持った `Value` が
消える心配がありません。** 影スタックのような仕掛けが要らないのは、ループが1つで、
その頭でだけ収集するからです。

## 8. ディスパッチの順序（Python 側だけの話）

```python
# 熱い順に並べてある。enum に対する match は CPython では逐次比較になるので、
# よく出る命令（送信・ローカル・戻り・リテラル・分岐）を先に見る。
match ins.op:
    case Op.SEND | Op.SEND_SUPER: ...
    case Op.PUSH_LOCAL: ...
    case Op.RETURN | Op.BLOCK_RETURN: ...
    case Op.PUSH_LITERAL: ...
    case Op.STORE_LOCAL: ...
    case Op.JUMP_FALSE: ...
```

**この並べ替えが、Python 側の最適化のうち単独でいちばん効きました。**
C++ 側の `switch` は既に飛び先表になるので、並べ替える意味がありません
（[11章](11-fast.md)）。

## していないこと

**Python 側の再入をなくしていません。** 4節のとおり48箇所あります。なくすには
C++ 側と同じ2手（`value` を命令にする、ライブラリを Smalltalk で書く）が要り、
それは Python 側の `kernel.py` 1092行の大半を書き換えることを意味します。

**計算的ディスパッチ（computed goto）を使っていません。** Python にはありません。
C++ 側はラベルアドレスを使えますが、`switch` で足りています。

**命令をバイト列にしていません。** [2章](02-bytecode.md)のとおり構造体の配列です。

**スタックの深さを制限していません。** ヒープが尽きるまで積めます。無限再帰は
`sum: n` を負に走らせればメモリを食い尽くします。

## 参考文献

- A. Goldberg, D. Robson, *Smalltalk-80*, §27–28。Blue Book の VM も
  「送信は新しい `MethodContext` を作って `activeContext` を差し替える」と書きます。
  この章はその素直な実装です。
- L. P. Deutsch, A. Schiffman, [*Efficient Implementation of the Smalltalk-80
  System*][ds84], POPL 1984。逆に、活性化をホストのスタックに置いて速くする道。
  この処理系が採らなかったほうです。
- CPython の `match` 文が逐次比較になること（PEP 634 の実装）。8節の並べ替えの
  根拠です。

[ds84]: https://doi.org/10.1145/800017.800542

## 実装の地図

| Python | |
|---|---|
| `st/vm.py` 288行 | `_run` — `boundary` を決める |
| `st/vm.py` 316行 | `_manages` |
| `st/vm.py` 346行 | `_loop` — ディスパッチ |
| `st/vm.py` 367行 | 熱い順の `match` |
| `st/vm.py` 399–403行 | 差し替え（送信） |
| `st/vm.py` 412–421行 | 差し替え（戻り） |
| `st/vm.py` 283行 | `run_block` — ここが再入 |

| C++ | |
|---|---|
| `src/vm.cppm` 225行 | `run` |
| `src/vm.cppm` 233行 | `load_ctx` |
| `src/vm.cppm` 242行 | GC はループの頭で |
| `src/vm.cppm` 216行 | `gc` — 根は2つ |
| `src/vm.cppm` 350–359行 | `value` 送信をループ内で |
| `src/vm.cppm` 38行 | `fail` — 例外の代わりの旗 |

---

[← 5. 活性化を物にする](05-context.md) ／ [目次](index.md) ／ [7. `^` →](07-return.md)
