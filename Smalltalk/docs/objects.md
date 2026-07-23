# オブジェクトモデル

このドキュメントは、値の表現方法・クラス・メソッド探索を解説します。
定義は `st/objects.py`、クラス群のブートストラップは `st/kernel.py`、
探索と送信は `st/vm.py`。関連: [対応構文](syntax.md) / [バイトコード](bytecode.md)。

## 基本方針：ネイティブ値の再利用

Smalltalk の値は、忠実に表せるものは**Pythonのネイティブ型をそのまま使い**、
Pythonに対応物が無いものだけラップします。これによりプリミティブの実装が簡潔になります。

| Smalltalk | Python表現 | クラス |
|---|---|---|
| 整数 | `int` | `SmallInteger` |
| 浮動小数 | `float` | `Float` |
| 文字列 | `str` | `String` |
| シンボル | `STSymbol`（`str`のサブクラス、インターン） | `Symbol` |
| 文字 | `STChar`（`value:str` を持つ dataclass） | `Character` |
| 真偽 | `True` / `False` | `True` / `False` |
| nil | `nil`（`_Nil` の唯一のインスタンス） | `UndefinedObject` |
| 配列 | `list` | `Array` |
| ブロッククロージャ | `STBlock` | `BlockClosure` |
| クラス | `STClass` | `Class` |
| その他のオブジェクト | `STObject` | 各自の `st_class` |

`STSymbol` は `str` のサブクラスなので、型ディスパッチでは必ず `str` より先に
判定します（`VM.class_of`）。同様に `bool` は `int` のサブクラスなので、`True`/
`False` を先に処理します。

## STObject — 普通のインスタンス

ユーザー定義クラスのインスタンスは `STObject` です。

```python
@dataclass
class STObject:
    st_class: STClass              # 自分のクラス
    ivars: dict[str, Any]          # インスタンス変数（名前→値）
```

インスタンス変数は名前引きの辞書です。読み出し時に未設定なら `nil` を返します。

## STClass — クラス

```python
@dataclass
class STClass:
    name: str
    superclass: STClass | None
    instance_variables: list[str]  # このクラスが導入するivarのみ
    methods: dict[str, Method]         # インスタンス側メソッド
    class_methods: dict[str, Method]   # クラス側メソッド（new など）
```

- `instance_variables` は**そのクラスが導入した分だけ**。実レイアウトは
  `all_instance_variables()` がスーパークラス連鎖を辿って合成します。
- `methods` はインスタンスがレシーバのときの振る舞い、`class_methods` はクラス
  自身がレシーバのときの振る舞い（`new`、`x:y:` など）。
- 反射補助: `lookup(selector)` / `lookup_class_method(selector)` /
  `all_instance_variables()` / `is_kind_of(other)`。

このモデルは**メタクラス階層を持ちません**。「クラスメソッド」は専用の
`class_methods` 辞書に置くだけの簡略化です。クラスに対する `class` 送信は
`Class` クラスを返します。

## メソッドの2種類

`methods` / `class_methods` の値 (`Method`) は次のいずれか。

- **`PrimitiveMethod`** — Python で実装。`fn(vm, receiver, args)` を呼ぶ。
  算術・同一性・反射・I/O・コレクション記憶など、サブセットで書けない振る舞い。
- **`CompiledMethod`** — Smalltalk ソースから[コンパイルしたバイトコード](bytecode.md)。

## メッセージ送信とメソッド探索

`VM.send(receiver, selector, args, super_start=None)` の流れ:

1. **探索起点を決める**
   - `super` 送信なら `super_start`（定義クラスの上位）から。
   - レシーバが `STClass` なら `class_methods` を連鎖探索。見つからなければ
     `Class` クラスのインスタンスメソッドにフォールバック（クラスも
     `printString` 等を理解する）。
   - それ以外は `class_of(receiver)` の `methods` を連鎖探索。
2. **見つからなければ** `doesNotUnderstand`（`STError` 送出）。
3. **プリミティブ**なら Python 関数を実行。
4. **コンパイル済み**なら新フレームを作って[VMで実行](bytecode.md#実行モデル)。

探索は `lookup` がスーパークラス連鎖を上に辿ります。最上位は `Object`。

## クラス階層（ブートストラップ）

`st/kernel.py` の `build_kernel` が構築する初期階層:

```
Object
├─ UndefinedObject          (nil)
├─ Boolean ─ True / False
├─ Class
├─ Magnitude
│  ├─ Number ─ Integer ─ SmallInteger
│  │         └─ Float
│  ├─ Character
│  └─ Association            (key, value)
├─ Collection
│  ├─ SequenceableCollection
│  │  ├─ Array
│  │  ├─ String ─ Symbol
│  │  └─ OrderedCollection   (items)
│  └─ Dictionary            (map)
├─ Point                     (x, y)
├─ BlockClosure
├─ Context ─ MethodContext / BlockContext
├─ Transcript
└─ Error                     (messageText)
```

括弧内はインスタンス変数。`OrderedCollection` は内部 `items`（Pythonリスト）、
`Dictionary` は内部 `map`（Python辞書）で記憶を持ちます。

## インスタンス生成と初期化

クラス側 `new`（`Object class` に定義、全クラスが継承）は:

1. `all_instance_variables()` を `nil` で初期化した `STObject` を作り、
2. その上で `initialize` を送る。

したがってユーザークラスは `initialize` を上書きすれば初期化できます。
`OrderedCollection` / `Dictionary` は `initialize` で内部記憶を空にします。

```smalltalk
"IDE / define_method 経由での定義例"
Counter >> initialize   count := 0
Counter >> increment    count := count + 1
Counter >> count        ^count
```

## 等値と同一性

- `==` / `~~` … 同一性（Python の `is`）。
- `=` … 既定は値等値（`_st_equal`）。数値は数値同士で比較、`STChar` は文字比較、
  シンボルはインターン済みなので同一性、文字列は文字列比較。ユーザークラスは
  `=` を上書きできます。
- シンボルはインターンされるため `#foo = #foo` は `true`、かつ `#foo == #foo` も真。

## nil・真偽の特別扱い

`nil` は `_Nil` の唯一インスタンス、`true`/`false` は Python の `True`/`False`。
`class_of` はこれらを最優先で判定します。`UndefinedObject` は `isNil`→`true`、
`ifNil:` でブロックを実行、`printString`→`'nil'` を持ちます。

## エラー

Smalltalk レベルの失敗（`doesNotUnderstand`、`self error:`、範囲外アクセス、
ゼロ除算など）は Python 例外 `STError` として送出されます。`[...] on: Error do: [:e | ...]`
は `STError` を捕捉して `Error` インスタンス（`messageText` 付き）を渡します。
`[...] ensure: [...]` は後始末を保証します。例外の再開（resumable）や `signal`
階層の細かなマッチングは未実装です。

## コンテキスト（thisContext）

メソッド/ブロックの活性化 (`Frame`) は**第一級オブジェクトとして reify** されて
います。`thisContext` で現在の活性化（`MethodContext` / `BlockContext`）が得られ、
`sender` リンクで呼び出し元を辿れます。VM は現在の活性化 `active_context` を保持し、
その `sender` 連鎖が**コールスタックそのもの**です。

```smalltalk
"sender 連鎖を辿ってバックトレースを作る"
backtrace
    | ctx names |
    names := OrderedCollection new.
    ctx := thisContext.
    [ctx notNil] whileTrue: [names add: ctx selector. ctx := ctx sender].
    ^names asArray            "=> (#backtrace #inner #outer #DoIt )"
```

`Context` のプロトコル: `receiver` / `sender` / `home` / `selector` / `pc` /
`isBlockContext` / `printString`。ただし現状は**ホスト（Python）の再帰**の上に
reify しているだけで、コンテキストを保存して後で再開する・スタックを書き換える
といった完全な操作（継続、`Process` スケジューリング、再開可能例外）は未対応です。

## 制限

- **メタクラス階層なし**（クラス側メソッドは `class_methods` 辞書）。
- **String は不変**（Python `str`）。`String>>at:put:` は未対応。
- `Fraction` / `ScaledDecimal` なし（`/` は割り切れれば整数、でなければ浮動小数）。
- コンテキストは reify 済みだが**再開・巻き戻しは不可**（ホスト再帰の上に構築）。

数値・コレクション等の具体的なセレクタは `st/kernel.py` を参照してください。
