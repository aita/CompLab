# 10. ライブラリを Smalltalk で書く — `system.cppm` の `install_prelude`

`do:` をホスト言語で書くと、繰り返しのたびにホストが VM に再入します。Smalltalk で
書けば再入しません。**C++ 側は17個のメソッドを Smalltalk で書き、プリミティブからの
再入を0にしました。**

```
$ grep -c "run_block" python/st/kernel.py     48
$ grep -c "send_message" cpp/src/kernel.cppm   0
```

## 1. 何が問題なのか

Python 側の `do:` は Python の関数です。

```python
def _do(vm, coll, block):
    for x in _items(coll):
        vm.run_block(block, [x])
```

`run_block` は新しい駆動部を始めます（[6章](06-loop.md)）。つまり **1要素につき
Python のスタックが1段深くなって戻る**。500要素なら500回、それが入れ子になれば
掛け算です。

そして `^` が絡むと、その Python のフレームを**貫いて**戻る必要が出てきます。
だから[7章](07-return.md)で例外が要ります。

## 2. Smalltalk で書けば、その問題が消える

```cpp
// 高階のコレクションプロトコル。ブロック送信と非局所リターンが1つの VM ループを
// 流れるように、Smalltalk で書かれている（プリミティブが VM に再入しない）。
// SequenceableCollection に入れ、Array / String / OrderedCollection が継承して
// at: / size をプリミティブで供給する。
void install_prelude() {
    struct Def { const char* cls; const char* src; };
    static const Def defs[] = {
        {"SequenceableCollection",
         "do: aBlock\n"
         "  | i n | i := 1. n := self size.\n"
         "  [i <= n] whileTrue: [aBlock value: (self at: i). i := i + 1]"},
        ...
```

この4行の中で起きていることを分解します。

- `[i <= n] whileTrue: [...]` は[3章](03-inline.md)でジャンプに畳まれる
- `aBlock value:` は[6章](06-loop.md)5節で**命令として**扱われ、活性化が差し替わる
- `self at:` と `self size` はプリミティブだが、**葉**（ブロックを呼ばない）

**ホストは1度も再帰しません。**

## 3. 17個

```
SequenceableCollection:
  do:  do:separatedBy:  collect:  select:  reject:
  detect:  detect:ifNone:  inject:into:  includes:
  isEmpty  notEmpty  asOrderedCollection

Dictionary:
  at:ifAbsent:  at:ifAbsentPut:  keysAndValuesDo:  do:  keysDo:
```

多くが `do:` の上に積まれています。

```smalltalk
select: aBlock
    | r | r := OrderedCollection new.
    self do: [:e | (aBlock value: e) ifTrue: [r add: e]]. ^r
```

```smalltalk
inject: acc into: aBlock
    | a | a := acc.
    self do: [:e | a := aBlock value: a value: e]. ^a
```

**`do:` が1つ非再入なら、その上は全部非再入です。**

## 4. `^` がそのまま書ける

```smalltalk
detect: aBlock ifNone: noneBlock
    self do: [:e | (aBlock value: e) ifTrue: [^e]].
    ^noneBlock value
```

```
$ #(1 3 4 7 8) detect: [:x | x even] ifNone: [0]   => 4
$ #(1 3 5)     detect: [:x | x even] ifNone: [0]   => 0
```

`^e` は[7章](07-return.md)2節の `target = home->sender` で `detect:ifNone:` の
呼び出し元へ飛びます。**途中にある `do:` の活性化も、ブロックの活性化も、
`sender` の鎖から外れるだけです。** 例外は要りません。

Python 側で同じことをすると、`_do` という Python 関数を貫く必要があり、
そこで `NonLocalReturn` が使われます。

## 5. 何をプリミティブに残すか

C++ 側に残っているコレクションのプリミティブは、**ブロックを取らないもの**だけです。

```cpp
def(Array_, "size", ...);
def(Array_, "at:", ...);
def(Array_, "at:put:", ...);
def(OrderedCollection, "add:", ...);
def(OrderedCollection, "size", ...);
def(OrderedCollection, "at:", ...);
def(Dictionary, "at:put:", ...);
```

**基準は「引数にブロックが来るか」です。** 来るならホスト言語では書かず、
Smalltalk で書く。来ないならプリミティブでよい。

その結果が `kernel` の行数の差です。

| | Python | C++ |
|---|---:|---:|
| `kernel` | 1092 | 496 |
| Smalltalk の prelude | — | 60行ほど（`system.cppm` 内） |

**596行の差の多くが、Python で書かれた高階メソッドです。**

## 6. 代価

**速さです。** `do:` を Smalltalk で書くと、要素1つにつきブロックの活性化が
1つ作られます。Python 側の `_do` はホストの `for` なので、そこは速い。

```
$ ./build/st_bench
  OrderedCollection add: 500,000         37.6 ms      ← プリミティブ
  OrderedCollection do: sum 500,000     131.2 ms      ← Smalltalk の do:
  collect: 300,000                       96.9 ms
  inject:into: sum 300,000              111.4 ms
```

`add:` が要素あたり 0.075 µs、`do:` が 0.26 µs。**3倍以上の差**があります。

しかしこれは絶対的な代価ではありません。同じ `do:` を Python 側で走らせると
（500k は待てないので 100k で）、要素あたり数 µs のオーダーになります。
**ホストの `for` で回しても、その中の `run_block` が効いてしまう**からです。

**再入をなくすことは、遅くする選択ではありませんでした。**

## 7. Smalltalk で書けることの副産物

prelude は文字列です。つまり**メソッドを足すのに C++ を書き直さなくてよい**。

```cpp
{"SequenceableCollection", "isEmpty\n  ^self size = 0"},
{"SequenceableCollection", "notEmpty\n  ^self size > 0"},
```

そして Python 側の IDE（[12章](12-ide.md)）でも同じことができます。System Browser で
メソッドを書いて Accept を押せば、それはこの prelude と同じ資格のメソッドです。
**処理系を作る言語と、処理系の上で書く言語が、同じところまで来ています。**

## していないこと

**Python 側を書き直していません。** 48箇所の再入はそのままです。書き直すには
`value` を命令にし（[6章](06-loop.md)5節）、`kernel.py` の高階メソッドを
Smalltalk へ移すことになります。その結果、`^` の実装から `NonLocalReturn` を
消せます。

**prelude をファイルに置いていません。** `system.cppm` の中の文字列配列です。
外に出せば実行時に読めますが、ファイルの場所を決める必要が出ます。

**prelude を Smalltalk のクラス定義構文で書けません。** クラスは C++ 側の
`define_class` で作ります（[1章](01-syntax.md)）。

**`Set` も `Bag` も `Interval` もありません。** `SequenceableCollection` の下に
`Array` / `String` / `OrderedCollection` の3つだけです。

**ソート系がありません。** `asSortedCollection` も `sort:` もありません。
`do:` の上に書けますが、書いていません。

## 参考文献

- A. Goldberg, D. Robson, *Smalltalk-80*, 第II部の Collection の階層。
  `do:` を1つ実装すれば `collect:` `select:` `detect:` `inject:into:` が
  そこから出てくる、という設計。3節はその写しです。
- D. Ingalls, [*Design Principles Behind Smalltalk*][ingalls], BYTE, 1981。
  「システムはできるかぎりそれ自身の言語で書かれるべきである」。この章は
  その原則を、性能ではなく**制御構造の単純さ**のために採った例です。

[ingalls]: https://www.cs.virginia.edu/~evans/cs655/readings/smalltalk.html

## 実装の地図

| C++ | |
|---|---|
| `src/system.cppm` 96行 | `install_prelude` — 17個 |
| `src/system.cppm` 99–102行 | `do:` — この章の起点 |
| `src/system.cppm` 124–127行 | `detect:ifNone:` — `^` が使われる |
| `src/kernel.cppm` 342–353行 | `Array` の `size` / `at:` / `at:put:` |
| `src/kernel.cppm` 379–404行 | `OrderedCollection` の `add:` / `size` / `at:` |
| `src/vm.cppm` 350行 | `value` 送信をループ内で扱う — 2節の前提 |

| Python | |
|---|---|
| `st/kernel.py` 742–825行 | 高階メソッドのプリミティブ群 |
| `st/vm.py` 283行 | `run_block` — 48箇所から呼ばれる |

---

[← 9. メモリ](09-memory.md) ／ [目次](index.md) ／ [11. 速くする →](11-fast.md)
