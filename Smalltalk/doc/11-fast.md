# 11. 速くする — `vm.py` ／ `vm.cppm`, `bytecode.cppm`

どちらの実装にも最適化があります。**同じ最適化が二度とも効いたわけではありません。**
何が効いたかは、ホスト言語のディスパッチの仕組みで決まりました。

## 1. 測る

```
$ cd cpp && ./build/st_bench
small Smalltalk (C++) — benchmarks (best of 3, -O3):
  fib: 30  (recursion, dispatch)        371.8 ms
  ackermann 3,7  (deep recursion)       101.7 ms
  to:do: sum 1..3,000,000               169.0 ms
  timesRepeat: 3,000,000                170.5 ms
  OrderedCollection add: 500,000         37.6 ms
  OrderedCollection do: sum 500,000     131.2 ms
  collect: 300,000                       96.9 ms
  inject:into: sum 300,000              111.4 ms
  String , concat 30,000                 74.9 ms
  Dictionary at:put: + at: 200,000       46.0 ms
  polymorphic val 400,000               225.8 ms
  object new + ivars 300,000            156.6 ms
```

Python 側は同じ形を小さい回数で。

```
small Smalltalk (Python) — benchmarks (best of 3):
  fib: 25                               854.5 ms
  whileTrue: sum 1..300,000             893.0 ms
  to:do: sum 1..300,000                 652.9 ms
  OrderedCollection add: 100,000        213.4 ms
  object new + ivars 100,000           1631.3 ms
```

1回あたりに直すと：

| | Python | C++ | 比 |
|---|---:|---:|---:|
| `to:do:` ループ1周 | 2.18 µs | 0.056 µs | 39 |
| `OrderedCollection add:` | 2.13 µs | 0.075 µs | 28 |
| オブジェクト生成 + ivar | 16.3 µs | 0.52 µs | 31 |

**25〜40倍**です。処理系の設計は同じなので、この差はホスト言語と、以下の最適化の差です。

## 2. 両方にあるもの

**メソッド探索のキャッシュ。** クラスごとに「セレクタ → メソッド」を覚えます。
ミスも覚えます（[8章](08-objects.md)3節）。

**インスタンス変数レイアウトのキャッシュ。** 継承を辿って作る ivar の並びを
クラスごとに覚えます。

**算術の速い道。** 両辺が整数なら、探索もプリミティブ呼び出しもせずにループ内で
計算します。

**レキシカルアドレッシング。** 変数がスロット番号（[4章](04-scope.md)）。

**制御構文の畳み込み。** ([3章](03-inline.md))

無効化は定義のたびに走ります。

```python
def flush_method_caches(self) -> None:
    for cls in self.classes.values():
        cls.method_cache.clear()
        cls.class_method_cache.clear()
        cls._ivars_cache = None
```

## 3. 速い道は自動で塞がれる

算術の速い道は「ユーザが `+` を上書きしていない」ことに賭けています。賭けが外れる
瞬間を捕まえます。

```python
def note_override(self, cls: STClass, selector: str) -> None:
    if selector not in ARITHMETIC_SELECTORS:
        return
    for name in ("SmallInteger", "Float"):
        num = self.classes.get(name)
        if num is not None and num.is_kind_of(cls):
            self.optimize_arithmetic = False
            return
```

```
$ before override, optimize_arithmetic = True
$ 3 + 4                       => 7
$ Number >> + other   ^'hijacked'
$ after  override, optimize_arithmetic = False
$ 3 + 4                       => 'hijacked'
```

**`SmallInteger` が継承している任意のクラスへの上書き**を見ます。`Number` に
定義しても効きます。C++ 側も同じ形です。

## 4. Python 側でいちばん効いたもの — ディスパッチの並べ替え

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

**CPython の `match` は飛び先表になりません。** 上から順に比較します。だから
22個の命令の並べ方が、そのまま平均の比較回数になります。

これらを合わせて、素朴な実装の約1.9倍です。

`class_of` も同じ理由で、頻度の高い型を先に見ます。

```python
t = type(value)
if t is STObject: return value.st_class
if t is int: return c["SmallInteger"]
if t is str: return c["String"]
match value: ...
```

`match` に入る前に3つ潰しています。

## 5. C++ 側の最適化 — 5つ

`switch` は既に飛び先表になるので、4節の並べ替えは意味がありません。効いたのは別の
5つです。

**（1）特殊セレクタ番号。** コンパイラが `Send` 命令に番号を埋め、VM は整数で分岐
します。

```cpp
if (ins.op == Op::Send && optimize_arithmetic_ && ins.arg2 != 0 && argc == 1) {
    Value& rv = *(stk->end() - 2);
    Value& av = stk->back();
    if (is_int(rv) && is_int(av)) {
        std::int64_t x = as_int(rv), y = as_int(av);
        if (ins.arg2 >= 4) {  // 比較
            bool res = ins.arg2 == 4   ? x < y
                       : ins.arg2 == 5 ? x > y
                       ...
```

**文字列比較が消えます。** 算術ループが約 4.2 s から約 3.2 s になりました。

オペランドはその場で読み書きします。`args` のベクタを作りません。

```cpp
stk->pop_back();
stk->back() = Value{r};
```

桁あふれは黙って巻き戻さず誤りにします（[8章](08-objects.md)2節）。

```cpp
bool ov = ins.arg2 == 3 ? __builtin_mul_overflow(x, y, &r) : ...;
if (ov || !fits_smallint(r)) { fail("SmallInteger overflow"); return nil(); }
```

**（2）2-way インラインキャッシュ。** 送信の命令1つずつが、直近2つの
（レシーバのクラス → メソッド）を覚えます。

```cpp
if (ins.ic_version != method_version_) {
    // 古い: 2way キャッシュを捨てて引き直す
    m = lookup(receiver, static_cast<Symbol*>(ins.sel), nullptr);
    ins.ic_class = key; ins.ic_method = m;
    ins.ic_class2 = nullptr; ins.ic_method2 = nullptr;
    ins.ic_version = method_version_;
} else if (ins.ic_class == key) {
    m = static_cast<Method*>(ins.ic_method);
} else if (ins.ic_class2 == key) {
    m = static_cast<Method*>(ins.ic_method2);
} else {
    m = lookup(receiver, static_cast<Symbol*>(ins.sel), nullptr);
    // 最近使ったものを先頭に、古い1つ目を2つ目へ落とす
    ins.ic_class2 = ins.ic_class; ins.ic_method2 = ins.ic_method;
    ins.ic_class = key; ins.ic_method = m;
}
```

**2way なのは、A と B が交互に来る場所が実際にあるからです。**
`polymorphic val 400,000` というベンチがそれで、1way だと毎回外れます。

無効化は版番号1つです。

```cpp
void flush_caches() {
    ++method_version_;
    for (auto& [name, c] : classes_) c->ivar_count_ = -1;
}
```

**全部の呼び出し箇所を一度に無効化します。** 命令を歩き回る必要がありません。

`super` とクラスがレシーバの送信は、キャッシュを使いません（起点が変わるので）。

**（3）スロット ivar。** [4章](04-scope.md)5節。オブジェクト生成が
256 ms → 165 ms（約36%）。

**（4）`std::span` の引数。** プリミティブは引数をスタック上の span で受け取ります。
送信ごとのベクタ割り付けがありません。

```cpp
std::span<Value> args(stk->data() + sp_base, argc);
```

**（5）メソッド辞書の鍵をインターン済み `Symbol*` に。** インラインキャッシュを
外したときのハッシュが、文字列ではなくポインタになります。

## 6. いちばん大きかったのは最適化ではなかった

```
CMakeLists now defaults CMAKE_BUILD_TYPE=Release
```

**それ以前のビルドは `-O0` で、約10倍遅く、5節の細かい最適化を全部覆い隠していました。**
デバッグビルドを測っていた期間があります。

`-O3` で測ると、算術ループ 3M が約 0.27 s、`OrderedCollection do:` 400k が約 0.16 s。

**Release で測ること** が、この処理系の最適化の記録に残っているいちばん大きな教訓です。

## 7. 何が残っているか

**C++ 側。** N-way の多相インラインキャッシュ、`Context` のプール、`Instr` の
縮小（いまは `std::string` と6つのポインタを抱えています、[2章](02-bytecode.md)8節）。

**Python 側。** 整数オペコード（`Op` を `IntEnum` のまま `if/elif` の連鎖にする）、
計算的ディスパッチ、あるいは Python へのコンパイル。4節の並べ替えで取れる分は
取り切っています。

どちらも**バイトコードのレベルの最適化**（スーパー命令、定数畳み込み、
ジャンプの連鎖潰し）は手つかずです。

## していないこと

**JIT がありません。**

**プロファイラがありません。** ベンチは C++ 側に1本あるだけで
（`bench/bench.cpp`）、Python 側にはありません。

**メソッドのインライン化がありません。** インラインキャッシュはメソッドを
「見つける」のを速くしますが、呼び出しそのものは消しません。

**`Context` を再利用していません。** 呼び出しのたびに割り付けます
（[5章](05-context.md)6節）。

**Python 側にインラインキャッシュがありません。** 命令が `Instr` の
データクラスなので付けられますが、CPython では属性アクセスのコストが
キャッシュの利得を食う可能性が高い。

## 参考文献

- L. P. Deutsch, A. Schiffman, [*Efficient Implementation of the Smalltalk-80
  System*][ds84], POPL 1984。インラインキャッシュの初出。5節（2）はその2way版です。
- U. Hölzle, C. Chambers, D. Ungar, [*Optimizing Dynamically-Typed
  Object-Oriented Languages with Polymorphic Inline Caches*][pic], ECOOP 1991。
  N-way に広げる話。7節で「残っている」と言っているものです。
- CPython の `match` が逐次比較になること（PEP 634）。4節の根拠。

[ds84]: https://doi.org/10.1145/800017.800542
[pic]: https://doi.org/10.1007/BFb0057013

## 実装の地図

| Python | |
|---|---|
| `st/vm.py` 31行 | `_ARITH` — 速い道の対象 |
| `st/vm.py` 122行 | `flush_method_caches` |
| `st/vm.py` 130行 | `note_override` |
| `st/vm.py` 141行 | `class_of` — 熱い型を先に |
| `st/vm.py` 367行 | 熱い順の `match` |
| `st/vm.py` 384–392行 | 算術の速い道 |
| `st/objects.py` 148行 | `lookup` — ミスも覚える |
| `st/objects.py` 133行 | `all_instance_variables` — レイアウトのキャッシュ |

| C++ | |
|---|---|
| `src/bytecode.cppm` 41行 | `arg2` — 特殊セレクタ番号 |
| `src/bytecode.cppm` 50–59行 | インラインキャッシュと `sel` |
| `src/vm.cppm` 56行 | `flush_caches` — 版番号1つ |
| `src/vm.cppm` 63行 | `note_override` |
| `src/vm.cppm` 313–340行 | 算術の速い道 |
| `src/vm.cppm` 346行 | `std::span` の引数 |
| `src/vm.cppm` 366–388行 | 2-way インラインキャッシュ |
| `src/vm.cppm` 265行 | `PushIvar` |
| `bench/bench.cpp` | ベンチ12本 |

---

[← 10. ライブラリを Smalltalk で書く](10-prelude.md) ／ [目次](index.md) ／ [12. IDE →](12-ide.md)
