# 対応構文

このドキュメントは、字句解析 (`st/lexer.py`) と構文解析 (`st/parser.py`) が
受理する構文をまとめます。関連: [オブジェクトモデル](objects.md) /
[バイトコード](bytecode.md)。例の `=>` はワークスペースでの評価結果です。

## コメント

`"` で囲みます。`""` で `"` 自身をエスケープ。

```smalltalk
"これはコメント。"" は二重引用符。"
```

## リテラル

### 数値

| 記法 | 例 | 結果クラス |
|---|---|---|
| 整数 | `42` | `SmallInteger` |
| 基数付き整数 | `16rFF` → 255、`2r1010` → 10 | `SmallInteger` |
| 浮動小数 | `3.14` | `Float` |
| 指数 | `1e3` → 1000.0、`1.5e-2` → 0.015 | `Float` |

> **負のリテラルは未対応**。`-5` は二項メッセージ `-` として解釈され構文エラー
> になります。`5 negated` や `0 - 5` を使ってください（`#(-1 2)` も `#-`（シンボル）
> と誤読されます）。

### 文字列・シンボル・文字

| 記法 | 例 | 備考 |
|---|---|---|
| 文字列 | `'hello'`、`'it''s'` | `''` で `'` をエスケープ。**不変** |
| シンボル | `#foo`、`#at:put:`、`#+` | インターンされる |
| 引用シンボル | `#'hello world'` | 空白等を含められる |
| 文字 | `$a`、`$ `（空白も可） | `Character` |

### 真偽・nil（擬似変数）

`true` / `false` / `nil`。`self` / `super` / `thisContext` も擬似変数
（`thisContext` は未モデル化で `nil`）。

### リテラル配列 `#(...)`

コンパイル時に確定する配列。要素は数値・文字列・シンボル・文字・入れ子配列・
`true`/`false`/`nil`。**裸の識別子はシンボルになります**。

```smalltalk
#(1 2 3)                  => (1 2 3 )
#(1 $a 'x' #sym true nil) => (1 $a 'x' #sym true nil )
#(1 (2 3) 4)              => (1 (2 3 ) 4 )     "入れ子は # を省略できる"
#(foo bar)                => (#foo #bar )       "裸の語はシンボル"
```

### 動的配列 `{...}`

`.` 区切りの**式**を実行時に評価して配列を作ります。

```smalltalk
{1 + 1. 2 * 3. 10 - 1}    => (2 6 9 )
```

## 変数と代入

変数名は識別子。代入は `:=`。代入は式で、格納した値を返します。

```smalltalk
x := 3
y := x := 0        "多重代入も可"
```

メソッド/ブロック内の一時変数は先頭で `| ... |` に宣言します。ワークスペースでは
未宣言の変数への代入は自動的にグローバル（ワークスペース変数）になります。

```smalltalk
| a b | a := 3. b := 4. a * a + (b * b)   => 25
```

## メッセージ式

3種類。**優先順位は 単項 > 二項 > キーワード**。同レベルは左から右へ。

| 種別 | 例 | 説明 |
|---|---|---|
| 単項 | `3 factorial`、`x isNil` | 引数なし。最も強く結合 |
| 二項 | `3 + 4`、`a <= b`、`#a -> 1` | 記号1個の引数1つ |
| キーワード | `arr at: 1 put: 2` | `key:` の並び。最も弱い |

```smalltalk
3 + 4 * 2        => 14   "二項は左結合： (3+4)*2"
3 factorial + 1  => 7    "単項が先： (3 factorial) + 1"
1 max: 2 + 5     => 7    "キーワードは最弱： 1 max: (2+5)"
```

丸括弧 `( ... )` で優先順位を変えられます。

```smalltalk
3 + (4 * 2)      => 11
```

## カスケード `;`

同じレシーバへ複数のメッセージを送り、**最後のメッセージの結果**を返します。
レシーバは「最初のセミコロン直前のメッセージのレシーバ」です。

```smalltalk
OrderedCollection new add: 1; add: 2; add: 3; yourself   => OrderedCollection (1 2 3 )
Transcript show: 'a'; show: 'b'; show: 'c'                "abc を出力"
```

## ブロック `[ ... ]`

無名関数（クロージャ）。引数は `:name`、本体との区切りは `|`。一時変数も持てます。

```smalltalk
[42]                    "0引数"
[:x | x + 1]            "1引数"
[:a :b | a + b]         "2引数"
[:x | | t | t := x*x. t + 1]   "引数＋一時変数"
```

呼び出しは `value` 系メッセージ。

```smalltalk
[:a :b | a + b] value: 3 value: 4    => 7
```

ブロックは定義時の環境を捕捉します（クロージャ）。

```smalltalk
| make add | make := [:n | [:x | x + n]]. add := make value: 10. add value: 5   => 15
```

制御構文はブロックを使います。引数がリテラルの0引数ブロックのとき、コンパイラは
これらを[条件ジャンプにインライン化](bytecode.md#制御構文のインライン化)します。

```smalltalk
n > 0 ifTrue: ['+'] ifFalse: ['-']
(a > 0) and: [b > 0]
[i <= 10] whileTrue: [i := i + 1]
1 to: 10 do: [:each | sum := sum + each]     "to:do: は非インライン（プリミティブ）"
5 timesRepeat: [n := n + 1]
```

## 文と返り値

文は `.` で区切ります。式列の値は最後の式の値です。

メソッド内の `^expr` はメソッドから即座に戻ります。ブロック内の `^` は
**非局所リターン**（ホームメソッドから戻る）。`^` の後ろに文は書けません
（構文エラー）。

```smalltalk
firstEven: c
    c do: [:x | x even ifTrue: [^x]].    "見つけたら即 firstEven: から返る"
    ^nil
```

## メソッド定義

メソッドは「メッセージパターン＋本体」。IDE のシステムブラウザ、または
API `Smalltalk.define_method(class_name, source, class_side=False)` で定義します
（`!`-chunk 形式のファイル構文は未対応）。

```smalltalk
"単項"        greet          ^'hello'
"二項"        + other        ^Point x: x + other x y: y + other y
"キーワード"  side: n        side := n
```

本体先頭に一時変数 `| ... |` を置けます。

```smalltalk
distanceTo: p
    | dx dy |
    dx := x - p x.
    dy := y - p y.
    ^(dx * dx + (dy * dy)) sqrt
```

`super` はスーパークラスの実装を呼びます。

```smalltalk
speak    ^'woof and ', super speak
```

## クラス定義

ソース構文ではなく API / IDE で行います。

- `Smalltalk.define_class(name, superclass='Object', instance_vars=[...])`
- IDE の **New Class** ボタン

```python
st.define_class("Counter", "Object", ["count"])
st.define_method("Counter", "increment  count := count + 1")
```

## 対応していない主なもの

- 負の数値リテラル（`-5`）→ `negated` を使う
- `!`-chunk 形式のソースファイル読み込み
- `#[...]`（バイト配列）、`ScaledDecimal`、`Fraction`
- 可変な `String`（`at:put:`）
- `thisContext`、メタクラス階層
- 例外の再開（resumable exception）

実行時に利用できるセレクタの一覧は `st/kernel.py` を参照してください。
