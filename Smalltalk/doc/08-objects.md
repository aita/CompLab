# 8. オブジェクトモデルと値の表現 — `objects.py` ／ `objects.cppm`

「すべてはオブジェクトである」を実装するとき、最初に決めるのは**整数をどう持つか**
です。二度書いて、そこが最も大きく割れました。

## 1. Python — ホストの型を借りる

```python
"""設計: Smalltalk の素の値は、実用になる範囲でホストの Python の型をそのまま使う
（int, float, bool, String としての str）。Python に忠実な相当物がないものだけ
包む（Symbol, Character, nil, Block）。ユーザレベルの普通のオブジェクトは
STObject で、自分の STClass への参照とインスタンス変数の辞書を持つ。"""
```

包むのは4つだけです。

```python
nil = _Nil()                     # 唯一の nil
class STSymbol(str): ...         # str の派生。Symbol クラスへ振り分けるため
@dataclass(frozen=True)
class STChar: ...                # $a
@dataclass
class STBlock: ...               # クロージャ
```

`STSymbol` が `str` の派生なのは、**インターンされた文字列として振る舞いつつ、
`class_of` で String と区別される**ためです。この2つを両立させる書き方が
Python にはこれしかありません。

代わりに `class_of` が型で振り分けます。

```python
t = type(value)
if t is STObject: return value.st_class
if t is int: return c["SmallInteger"]
if t is str: return c["String"]
match value:
    case _ if value is nil: return c["UndefinedObject"]
    case True: return c["True"]
    case False: return c["False"]
    case STSymbol():  # str より先。STSymbol は str の派生
        return c["Symbol"]
    ...
    case int():       # bool より後。bool は int の派生
        return c["SmallInteger"]
```

**順序がすべてです。** `STSymbol` は `str` より先、`int` は `bool` より後。
Python の型階層をそのまま借りた代価が、この並べ方に出ています。

借りたおかげで、整数は**任意精度**です。

```
$ 100 factorial
93326215443944152681699238856266700490715968264381621468592963895217599993229915608941463976156518286253697920827223758251185210916864000000000000000000000000
```

## 2. C++ — 8バイトに詰める

```cpp
// Smalltalk の値。8バイトに NaN ボクシングされている。本物の double はそのまま
// 入り、それ以外は quiet NaN のペイロードに符号化される。**2ビット**（50-51）を
// 立てることを要求するので、普通のハードウェア NaN や無限大（51 だけ）は
// double として読み戻せる。
inline constexpr std::uint64_t kQNaN    = 0x7ffc000000000000ULL;
inline constexpr std::uint64_t kSign    = 0x8000000000000000ULL;
inline constexpr std::uint64_t kIntTag  = 0x0002000000000000ULL;      // bit 49
inline constexpr std::uint64_t kPtrMask = 0x0000ffffffffffffULL;      // bits 0-47
inline constexpr std::uint64_t kNilBits   = kQNaN | 1;
inline constexpr std::uint64_t kFalseBits = kQNaN | 2;
inline constexpr std::uint64_t kTrueBits  = kQNaN | 3;
```

| 種類 | 表し方 |
|---|---|
| `double` | そのまま（`(bits & QNAN) != QNAN`） |
| オブジェクト | 符号 + QNaN、下位48ビットがポインタ |
| 整数 | QNaN + 整数タグ、49ビットの符号付き |
| nil / true / false | QNaN + 小さな定数 |

`Value` が `std::variant` から8バイトの class になって、**足跡が半分**になりました。

代価は整数の幅です。

```cpp
inline constexpr std::int64_t kSmallIntMax = (1LL << 48) - 1;
inline constexpr std::int64_t kSmallIntMin = -(1LL << 48);
```

```
$ cpp: 281474976710655 + 1
Error: SmallInteger overflow
$ cpp: 1000000000000000 * 1000
Error: SmallInteger overflow
$ python: 1000000000000000 * 1000
1000000000000000000
```

**黙って巻き戻さずに誤りにします。** 巻き戻すと、任意精度の Python 側と
「同じプログラムが違う答えを出す」ことになるからです。誤りなら少なくとも気づけます。

符号の復元がひと工夫です。

```cpp
inline std::int64_t as_int(const Value& v) {
    std::uint64_t p = v.bits() & kIntPayload;  // 49ビット、符号はビット48
    return static_cast<std::int64_t>(p << 15) >> 15;
}
```

左に15、右に15。**符号ビットを最上位まで押し上げてから算術右シフトで戻す**、
という定番の符号拡張です。

## 3. クラスは辞書2つ

```python
@dataclass
class STClass:
    name: str
    superclass: STClass | None = None
    instance_variables: list[str] = field(default_factory=list)
    methods: dict[str, Method] = field(default_factory=dict)
    class_methods: dict[str, Method] = field(default_factory=dict)
```

**インスタンス側とクラス側で辞書が別です。** メタクラスはありません
（[14章](14-next.md)）。

```
$ 3 class          => SmallInteger
$ 3 class class    => Class
```

本物の Smalltalk なら `SmallInteger class` という**メタクラス**が出るところです。

探索は上へ歩き、結果を覚えます。

```python
def lookup(self, selector: str) -> Method | None:
    cache = self.method_cache
    hit = cache.get(selector, _UNRESOLVED)
    if hit is not _UNRESOLVED:
        return hit
    cls: STClass | None = self
    while cls is not None:
        method = cls.methods.get(selector)
        if method is not None:
            cache[selector] = method
            return method
        cls = cls.superclass
    cache[selector] = None
    return None
```

**ミス（`None`）も覚えます。** `_UNRESOLVED` という番兵があるのはそのためで、
「まだ引いていない」と「引いたら無かった」を区別します。

無効化は一括です。

```python
def flush_method_caches(self) -> None:
    for cls in self.classes.values():
        cls.method_cache.clear()
        cls.class_method_cache.clear()
        cls._ivars_cache = None
```

C++ 側はさらにインラインキャッシュがあるので、版番号を1つ上げるだけで済みます
（[11章](11-fast.md)）。

## 4. 送信の3段

```python
def _lookup(self, receiver, selector, super_start):
    if super_start is not None:
        return super_start.lookup(selector)
    if isinstance(receiver, STClass):
        method = receiver.lookup_class_method(selector)
        if method is None:
            # クラスも Class の普通のインスタンスメッセージを理解する
            method = self.classes["Class"].lookup(selector)
        return method
    return self.class_of(receiver).lookup(selector)
```

1つ目が `super`、2つ目がクラスがレシーバのとき、3つ目が普通です。

**`super` は「レシーバはそのまま、起点だけ1つ上」**です。起点は
「いま実行中のメソッドが定義されたクラス」から取ります。

```python
defined_in = ctx.method.defined_in
start = defined_in.superclass if defined_in is not None else None
```

```
$ Otter >> kind   ^'otter (', super kind, ')'
$ Otter new describe   => 'a otter (animal)'
```

`describe` は `Animal` に定義されていて `self kind` を呼びます。`self` は Otter の
インスタンスなので `Otter>>kind` が動き、その中の `super kind` が `Animal>>kind` を
呼びます。**`defined_in` がないと、この2段が無限ループになります。**

見つからなければ誤りです。

```
$ 3 fly
!! SmallInteger does not understand #fly
```

## 5. 等値と同一性

```
                          Python    C++
'ab' == 'ab'              true      false
('a', 'b') == 'ab'        false     false
('a', 'b') = 'ab'         true      true
#ab == #ab                true      true
```

**`'ab' == 'ab'` が割れます。** C++ 側はリテラルを評価するたびに `String`
オブジェクトを1つ作るので、2つは別物です。Python 側はホストの `str` を借りていて、
CPython が短い文字列リテラルをインターンするので同じ物になります。

**これは意図した設計ではなく、ホストの型を借りたことの染み出しです。**
`=`（内容の比較）は両方とも同じ答えを出すので、実害はここに留まります。

シンボルはどちらもインターンされます。

```python
class STSymbol(str):
    _interned: dict[str, STSymbol] = {}
```

```cpp
Symbol* intern_symbol(const std::string& s) {
    auto it = interned_.find(s);
    if (it != interned_.end()) return it->second;
    Symbol* obj = make<Symbol>(s);
    interned_.emplace(s, obj);
    return obj;
}
```

C++ 側では**インターンがメソッド辞書の鍵にも効きます**。辞書は `Symbol*` で引くので、
ハッシュするのは文字列ではなくポインタです（[11章](11-fast.md)）。

## 6. インスタンスの中身

```python
@dataclass
class STObject:
    st_class: STClass
    ivars: dict[str, Any] = field(default_factory=dict)
```

```cpp
struct Instance : Object {
    Class* st_class;
    std::vector<Value> slots;
};
```

**辞書 対 平らなベクタ。** [4章](04-scope.md)5節の帰結で、C++ 側はインスタンス変数を
コンパイル時にスロット番号に解いているのでベクタで足ります。

## していないこと

**メタクラスがありません。** 3節のとおりクラス側は別の辞書です。本物の Smalltalk では
`Foo class` がオブジェクトで、それにもクラス（`Metaclass`）があります。

**`become:` がありません。** オブジェクトの同一性を入れ替える操作は、参照を全部
書き換える必要があるので入れていません。

**インスタンス変数の追加でオブジェクトを移し替えません。** クラスに ivar を足しても、
既に作られたインスタンスは古いレイアウトのままです。C++ 側はスロット番号が
ずれるので、既存のインスタンスは壊れます。

**弱参照もファイナライザもありません。**

**Python 側の整数の幅と C++ 側の幅が違います。** 2節のとおりで、`100 factorial` は
片方で通り、もう片方で誤りになります。

**文字列の同一性がホスト依存です。** 5節のとおりです。

## 参考文献

- A. Goldberg, D. Robson, *Smalltalk-80*, 第II部。クラス・メタクラス・
  `doesNotUnderstand:` の設計。3節でメタクラスを持たないと決めた基準はここに
  照らしたものです。
- D. Gudeman, [*Representing Type Information in Dynamically Typed
  Languages*][gudeman], 1993。即値をどう詰めるかの整理。2節の NaN ボクシングは
  そこで言う "NaN-space" の使い方です。
- R. Nystrom, [*Crafting Interpreters*][ci] "Optimization" の NaN ボクシングの節。
  2ビットを要求してハードウェア NaN と衝突しない、という細部の出どころ。

[gudeman]: https://www.researchgate.net/publication/2422427
[ci]: https://craftinginterpreters.com/optimization.html

## 実装の地図

| Python | |
|---|---|
| `st/objects.py` 27行 | `_Nil` |
| `st/objects.py` 44行 | `STSymbol` — インターンする `str` 派生 |
| `st/objects.py` 62行 | `STChar` |
| `st/objects.py` 102行 | `STClass` |
| `st/objects.py` 133行 | `all_instance_variables` |
| `st/objects.py` 148行 | `lookup` — ミスも覚える |
| `st/objects.py` 191行 | `STObject` |
| `st/vm.py` 141行 | `class_of` — 型の並べ方 |
| `st/vm.py` 188行 | `_lookup` — 3段 |
| `st/vm.py` 221行 | `does_not_understand` |
| `st/vm.py` 122行 | `flush_method_caches` |

| C++ | |
|---|---|
| `src/objects.cppm` 39–46行 | NaN ボクシングの定数 |
| `src/objects.cppm` 48–52行 | `fits_smallint` |
| `src/objects.cppm` 54行 | `Value` |
| `src/objects.cppm` 95行 | `as_int` — 15ビット押し上げて戻す |
| `src/objects.cppm` 106行 | `Tag` |
| `src/objects.cppm` 164・174行 | `ValueHash` / `ValueEq` |
| `src/heap.cppm` 63行 | `intern_symbol` |
| `src/vm.cppm` 76行 | `class_of` |
| `src/vm.cppm` 178行 | `lookup` |

---

[← 7. `^`](07-return.md) ／ [目次](index.md) ／ [9. メモリ →](09-memory.md)
