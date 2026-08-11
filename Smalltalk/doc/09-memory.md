# 9. メモリ — 借りる 対 書く — `heap.cppm`

Python 側は収集器を書きませんでした。C++ 側は書きました。どちらも、**閉包と、それが
捕まえた活性化が互いを指し合う**という同じ問題に答えています。

## 1. 何が互いを指すのか

```smalltalk
make
    | c | c := 0. ^[:x | c := c + x. c]
```

`make` の活性化が `c` を持ち、返されるブロックがその活性化を `outer` として持ち、
活性化のスタックやローカルにそのブロックが載る。**環です。**

```
$ python: 環の観察（CPython の gc モジュールで数えたもの）
before:  Frame=0 STBlock=0
after:   Frame=2 STBlock=1      ← 式を1つ評価したあと。まだ残っている
collect: Frame=0 STBlock=0      ← gc.collect() で消える
```

**参照を数えるだけでは消えません。** CPython の循環収集器が回って初めて消えます。
ループで2000回作ると、途中で世代別収集が自動で走るので溜まりません。

```
x2000:   Frame=0 STBlock=0
```

## 2. Python — 何もしない

`Frame` も `STBlock` も普通の Python オブジェクトです。CPython の参照計数が大半を
引き取り、環は循環収集器が引き取ります。**処理系のコードには収集器に関する行が
1つもありません。**

払っているものが2つあります。

**（1）`gc` プロトコルがありません。** Smalltalk から「いくつ生きているか」を
聞く手段がないので、1節の観察はホスト側の `gc.get_objects()` で数えました。

**（2）収集のタイミングを制御できません。** CPython の閾値に従います。

`Frame` は `__slots__` を持ちます。

```python
__slots__ = ("receiver", "method", "locals", "outer", "stack", "ip",
             "is_block", "home", "sender", "st_class")
```

**辞書を持たないぶん軽くなります。** 呼び出しごとに1つ作るものなので効きます
（[5章](05-context.md)6節）。

## 3. C++ — mark-and-sweep を書く

```cpp
// Heap partition — mark-and-sweep のガベージコレクタ。
//
// Heap は生ポインタと侵入型リスト（gc_next）で全オブジェクトを所有する。
// collect(roots) は根（とインターンされたシンボル）から到達できるものをマークし、
// 残りを解放する。マークは反復（明示的なワークリスト）なので、深いオブジェクト
// グラフでも C++ のスタックを溢れさせない。shared_ptr も参照計数もない。例外もない。
```

割り付けはリストの先頭に繋ぐだけです。

```cpp
template <class T, class... A>
T* make(A&&... args) {
    auto* obj = new T(std::forward<A>(args)...);
    obj->gc_next = head_;
    head_ = obj;
    ++count_;
    ++since_gc_;
    return obj;
}
```

マークは11個のタグごとに「自分が生かすもの」を並べます。

```cpp
case Tag::Context: {
    auto* ctx = static_cast<Context*>(o);
    push_value(work, ctx->receiver);
    push(work, ctx->method);
    for (const Value& v : ctx->locals) push_value(work, v);
    for (const Value& v : ctx->stack) push_value(work, v);
    push(work, ctx->outer);
    push(work, ctx->sender);
    push(work, ctx->home);
    break;
}
```

**`Context` が3本のリンクを全部マークします。** [5章](05-context.md)の3本が
そのまま出てきます。`Block` も同じです。

```cpp
case Tag::Block: {
    auto* b = static_cast<Block*>(o);
    push(work, b->tmpl);
    push(work, b->outer);
    push(work, b->home);
    break;
}
```

環は問題になりません。`push` がマーク済みを弾くからです。

```cpp
static void push(std::vector<Object*>& work, Object* o) {
    if (o != nullptr && !o->marked) {
        o->marked = true;
        work.push_back(o);
    }
}
```

掃除はリストの繋ぎ替えです。

```cpp
Object** link = &head_;
while (*link != nullptr) {
    Object* o = *link;
    if (o->marked) { o->marked = false; link = &o->gc_next; }
    else { *link = o->gc_next; delete o; --count_; }
}
since_gc_ = 0;
```

## 4. 根が2つで済む

```cpp
void gc() {
    std::vector<Value> roots;
    roots.reserve(globals_.size() + 1);
    for (auto& [name, v] : globals_) roots.push_back(v);
    if (active_context_ != nullptr) roots.push_back(ref(active_context_));
    heap_.collect(roots);
}
```

**グローバルと、走っているコンテキスト。それだけです。**

ローカル変数もオペランドスタックも `Context` の中にあり、呼び出しスタックは
`sender` の鎖なので、`active_context_` 1つから全部辿れます
（[5章](05-context.md)）。

これが[6章](06-loop.md)7節の帰結です。**GC がループの頭でだけ走るので、C++ の
ローカル変数に一時的に持った `Value` を根に登録する仕掛けが要りません。**

インターンされたシンボルは無条件に生かします。

```cpp
for (auto& [text, sym] : interned_) push(work, sym);
```

メソッド辞書の鍵になっているので、消えると困るからです（[8章](08-objects.md)）。

## 5. マークはワークリストで

```cpp
while (!work.empty()) {
    Object* o = work.back();
    work.pop_back();
    trace(o, work);
}
```

再帰でマークすると、10万段の `sender` の鎖（[6章](06-loop.md)3節が実際に作ります）が
C++ のスタックを溢れさせます。**深さがヒープに乗ることの帰結が、収集器の書き方まで
及んでいます。**

## 6. いつ走るか

```cpp
static constexpr std::size_t kThreshold = 100000;
bool should_collect() const { return since_gc_ > kThreshold; }
```

**前回の収集から10万個割り付けたら**走ります。生きている量ではなく、割り付けた量です。
だから生きているデータが多いプログラムでは、収集の割合が上がっていきます。

## 7. 所有はデストラクタが引き取る

```cpp
~Heap() {
    Object* o = head_;
    while (o != nullptr) {
        Object* next = o->gc_next;
        delete o;
        o = next;
    }
}
Heap(const Heap&) = delete;
```

`System` が `Heap` を値で持つので、`System` が消えればヒープごと消えます。
**`shared_ptr` を1つも使わないという制約が、この形に落ち着きます。**

## していないこと

**世代別でも漸進的でもコンパクションもありません。** 世界を止めて全部マークし、
リスト全体を掃きます。

**`live_count()` が使われていません。** `Heap` は数を持っていますが、それを読む
コードがありません。Smalltalk から見る `gc` プロトコルを作れば使えます。

**割り付けの閾値が固定です。** 6節のとおり10万で、生存量に応じて動きません。

**弱参照もファイナライザもありません。**

**Python 側に収集の制御がありません。** 2節のとおり CPython 任せです。

**どちらの側も、収集器を測るテストがありません。** C++ 側の GC は10万回の割り付けで
初めて走るので、ほとんどのテストでは1度も動きません。

## 参考文献

- R. Jones, A. Hosking, E. Moss, *The Garbage Collection Handbook*, 2nd ed.,
  CRC Press, 2023。2章が mark-sweep、5章がワークリストによるマーク。
- D. Bacon, C. Attanasio ら, [*Java without the Coffee Breaks*][bacon] より
  むしろ、CPython の循環収集器の設計（`Modules/gcmodule.c` と PEP 442）。
  1節で見ているのはその働きです。
- A. Goldberg, D. Robson, *Smalltalk-80*, §30。Blue Book の VM は参照計数で、
  環は「そもそも作らない」という前提でした。この処理系は活性化を捕まえる閉包を
  素直に許すので、辿る収集器が要ります。

[bacon]: https://doi.org/10.1145/378795.378819

## 実装の地図

| Python | |
|---|---|
| `st/vm.py` 64行 | `Frame.__slots__` |
| （収集器のコードなし） | CPython の参照計数と循環収集器に任せる |

| C++ | |
|---|---|
| `src/heap.cppm` 22行 | `Heap` |
| `src/heap.cppm` 27行 | デストラクタが全部解放する |
| `src/heap.cppm` 36行 | `make` — 侵入型リストに繋ぐ |
| `src/heap.cppm` 63行 | `intern_symbol` |
| `src/heap.cppm` 71行 | `should_collect` |
| `src/heap.cppm` 74行 | `collect` — マークと掃除 |
| `src/heap.cppm` 101行 | `kThreshold` |
| `src/heap.cppm` 108行 | `push` — 環を止める |
| `src/heap.cppm` 118行 | `trace` — 11個のタグ |
| `src/vm.cppm` 216行 | `gc` — 根は2つ |
| `src/vm.cppm` 242行 | 収集はループの頭でだけ |

---

[← 8. オブジェクトモデル](08-objects.md) ／ [目次](index.md) ／ [10. ライブラリを Smalltalk で書く →](10-prelude.md)
