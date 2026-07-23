# バイトコード

このドキュメントは、コンパイラが生成しVMが実行する**バイトコード**を解説します。
関連: [オブジェクトモデル](objects.md) / [対応構文](syntax.md)。

## パイプライン

```
ソース ──lexer──▶ tokens ──parser──▶ AST ──compiler──▶ バイトコード ──VM──▶ 値
```

- `st/compiler.py` … AST → バイトコード
- `st/bytecode.py` … 命令 (`Instr`)・命令セット (`Op`)・コンパイル済みコード (`CompiledMethod` / `CompiledBlock`)・逆アセンブラ (`disassemble`)
- `st/vm.py` … スタックマシン (`VM.interpret`)

VMは**スタックマシン**です。式は「値をオペランドスタックに積み、メッセージ送信で消費して結果を積む」命令列に変換されます。

## コンパイル済みコードの構造

`CompiledMethod` / `CompiledBlock` は次を持ちます。

| フィールド | 意味 |
|---|---|
| `code` | 命令 `Instr(op, arg)` のフラットな列 |
| `literals` | 定数プール。`PUSH_LITERAL` / `PUSH_BLOCK` が添字で参照 |
| `local_names` | この活性化フレームに置くローカル変数名（引数＋一時変数＋巻き上げたブロック一時変数） |
| `params` | 引数名（`local_names` の先頭部分） |
| `defined_in` | (メソッドのみ) インストール先クラス。`super` の探索起点計算に使う |

`local_names` はVMが活性化時に環境へ `nil` で用意し、`PUSH_VAR` / `STORE_VAR` が**名前で**解決します（[変数解決](#変数解決)参照）。

## 命令セット

`st/bytecode.py` の `Op`（`Instr` は `op` と任意の `arg` の組）。

| 命令 | arg | 動作 |
|---|---|---|
| `PUSH_LITERAL` | 添字 | `literals[arg]` を積む |
| `PUSH_SELF` | — | レシーバ（`self`）を積む |
| `PUSH_CONTEXT` | — | 現在の活性化フレームを積む（`thisContext`） |
| `PUSH_NIL` / `PUSH_TRUE` / `PUSH_FALSE` | — | `nil` / `true` / `false` を積む |
| `PUSH_VAR` | 変数名 | 変数を解決して積む |
| `STORE_VAR` | 変数名 | スタックトップを**覗いて**（pop しない）変数に格納 |
| `POP` | — | スタックトップを捨てる |
| `DUP` | — | スタックトップを複製 |
| `SEND` | `(selector, argc)` | 引数 `argc` 個とレシーバを降ろし、メッセージ送信の結果を積む |
| `SEND_SUPER` | `(selector, argc)` | `super` 送信（探索を定義クラスの上位から開始） |
| `PUSH_BLOCK` | 添字 | `literals[arg]` の `CompiledBlock` からクロージャ (`STBlock`) を生成して積む |
| `MAKE_ARRAY` | 個数 | スタックから `n` 個を降ろし `Array`（Pythonリスト）にして積む |
| `JUMP` | 命令番地 | 無条件ジャンプ（arg は絶対添字） |
| `JUMP_TRUE` | 命令番地 | トップを降ろし `true` ならジャンプ（`false` 以外なら Boolean 型エラー） |
| `JUMP_FALSE` | 命令番地 | トップを降ろし `false` ならジャンプ（`true` 以外ならエラー） |
| `RETURN` | — | メソッドから戻る。ブロックフレーム内なら**非局所リターン**（[後述](#クロージャと非局所リターン)） |
| `BLOCK_RETURN` | — | ブロックの正常終了。トップの値をブロックの呼び出し元へ返す |

`STORE_VAR` が pop せず覗くだけなのは、Smalltalk の代入が**式**（値を返す）だからです。文の区切りでは `POP` が中間結果を捨てます。

## 実行モデル（非再帰）

実行は `VM._run(root)` が駆動する**単一ループ**です（`_loop` がディスパッチ本体）。
Smalltalk 同士のメッセージ送信では**ホストの再帰を使いません**。

- `Frame` … レシーバ・コード・環境 (`Environment`)・オペランドスタック・命令ポインタ `ip`・ブロックか否か・ホームフレーム・`sender`
- **コンパイル済みメソッドへの送信**は、新しい `Frame`（`sender` ＝呼び出し元）を積んで
  `active_context` を差し替え、**そのままループを続行**します。戻り（`RETURN` /
  `BLOCK_RETURN`）は `active_context` を `sender` に戻し、戻り値を送り手のスタックへ積みます。
- **プリミティブ**は Python 関数を直接呼びます。`value` / `do:` のように VM に再入する
  プリミティブだけが `_run` を1段ネストします（ここはホスト再帰）。

オペランドスタックは各 `Frame` が持ち、VM 自体は持ちません。フレームは
[reify されたコンテキスト](objects.md#コンテキストthiscontext)でもあり、`active_context`
と `sender` リンクが**コールスタックそのもの**です。

この設計の効果として、メソッドの自己再帰・相互再帰は**ヒープ上のコンテキスト
スタック**に積まれるため、CPython の再帰上限（既定約1000）に縛られません
（例: `sum: 20000` が動く）。`^`（ブロックからの非局所リターン）は
`NonLocalReturn` として送出され、ホーム活性化を所有する `_run` が解決します
（`value`/`do:` のネストや `ensure:` を貫いて正しく戻ります）。

各文列は「最後の式の値をスタックに1つ残す」不変条件でコンパイルされます。メソッド末尾には暗黙の `^self`（`PUSH_SELF; RETURN`）が付きます。

## 式のコンパイル規則（実例）

以下はすべて `disassemble(compile_doit(parse_sequence(src)))` の実出力です。

### 算術と優先順位

単項 > 二項 > キーワード。同じレベルは左結合。

```smalltalk
3 + 4 factorial
```
```
  0  PUSH_LITERAL 0 (3)
  1  PUSH_LITERAL 1 (4)
  2  SEND         ('factorial', 0)
  3  SEND         ('+', 1)
  4  RETURN
```

`4 factorial`（単項）が先に評価され、その結果と `3` に `+` が送られます。

### カスケード

`;` はレシーバを1回だけ評価して使い回します。`DUP` でレシーバを複製→送信→`POP` で結果を捨てる、を繰り返し、最後のメッセージだけ結果を残します。

```smalltalk
OrderedCollection new add: 1; add: 2; yourself
```
```
  0  PUSH_VAR     'OrderedCollection'
  1  SEND         ('new', 0)
  2  DUP
  3  PUSH_LITERAL 0 (1)
  4  SEND         ('add:', 1)
  5  POP
  6  DUP
  7  PUSH_LITERAL 1 (2)
  8  SEND         ('add:', 1)
  9  POP
 10  SEND         ('yourself', 0)
 11  RETURN
```

## 制御構文のインライン化

`ifTrue:` / `ifFalse:` / `ifTrue:ifFalse:` / `ifFalse:ifTrue:` / `and:` / `or:` /
`whileTrue:` / `whileFalse:` / `whileTrue` / `whileFalse` / `repeat` は、**引数が
リテラルの0引数ブロック**のとき、メッセージ送信ではなく**条件ジャンプ**に展開されます。
これにより Boolean/Block へのメッセージ送信とブロック起動のコストを避けます。

前方ジャンプは、まず `arg=None` で命令を出し、枝を出し終えてから飛び先番地
（`_CodeGen.here()`）を**後埋め（バックパッチ）**します。

### ifTrue:ifFalse:

```smalltalk
5 > 2 ifTrue: ['big'] ifFalse: ['small']
```
```
  0  PUSH_LITERAL 0 (5)
  1  PUSH_LITERAL 1 (2)
  2  SEND         ('>', 1)
  3  JUMP_FALSE   6          ← false なら false 枝(番地6)へ
  4  PUSH_LITERAL 2 ('big')  ← true 枝
  5  JUMP         7          ← 合流点(番地7)へ
  6  PUSH_LITERAL 3 ('small')← false 枝
  7  RETURN                  ← 合流。値が1つ残る
```

### and: の短絡

`a and: [b]` は「a が false なら b を評価せず false」。だから `JUMP_FALSE` で
b を飛ばして `PUSH_FALSE` に落とします。式 `(3 > 2) or: [1 / 0]` がゼロ除算せず
`true` になるのはこの仕組みです。

```smalltalk
true and: [false]
```
```
  0  PUSH_TRUE
  1  JUMP_FALSE   4     ← 受け手が false なら…
  2  PUSH_FALSE         ← [false] の中身をインライン
  3  JUMP         5
  4  PUSH_FALSE         ← …短絡して false
  5  RETURN
```

### whileTrue: ループ（後方ジャンプ）

条件も本体もその場に展開し、末尾から先頭へ後方ジャンプします。ループ本体の値は
`POP` で捨て、`whileTrue:` 自体は `nil` を返します。

```smalltalk
| i | i := 1. [i <= 3] whileTrue: [i := i + 1]. i
```
```
  0  PUSH_LITERAL 0 (1)
  1  STORE_VAR    'i'
  2  POP
  3  PUSH_VAR     'i'      ← ループ先頭(start)
  4  PUSH_LITERAL 1 (3)
  5  SEND         ('<=', 1)
  6  JUMP_FALSE   13       ← 条件が false なら脱出
  7  PUSH_VAR     'i'
  8  PUSH_LITERAL 0 (1)
  9  SEND         ('+', 1)
 10  STORE_VAR    'i'
 11  POP                   ← 本体の値を捨てる
 12  JUMP         3        ← 後方ジャンプ
 13  PUSH_NIL              ← whileTrue: の結果
 14  POP                   ← 文の区切り（次の i を残すため）
 15  PUSH_VAR     'i'
 16  RETURN
```

インラインできない場合（例 `flag ifTrue: aBlock` のように引数がブロックリテラル
でない）は通常の `SEND` にフォールバックし、ブロックは本物のクロージャとして
`ifTrue:` / `value` プリミティブ経由で実行されます。

## クロージャと非局所リターン

インライン対象でないブロックリテラルは、独立した `CompiledBlock` にコンパイルされ、
定数プールに入り、`PUSH_BLOCK` で**クロージャ**として実体化されます。ブロックは
定義時の環境（`Environment`）とホームフレームを捕捉するので、外側の変数を参照できます。

```smalltalk
[:x | x + 1]
```
```
  0  PUSH_BLOCK   0 (CompiledBlock params=['x'] ...)
  1  RETURN
```
ブロック本体（別コード）:
```
  0  PUSH_VAR     'x'
  1  PUSH_LITERAL 0 (1)
  2  SEND         ('+', 1)
  3  BLOCK_RETURN     ← ブロックの正常終了（局所的に値を返す）
```

ブロック内の `^`（`RETURN`）は**メソッドからの非局所リターン**です。VMは
`RETURN` 実行時、フレームがブロックなら `NonLocalReturn(home, value)` を送出し、
ホームメソッドの活性化がそれを捕捉して値を返します（`value` プリミティブや
中間フレームを Python 例外機構で貫いて戻る）。

```smalltalk
firstEven: c
    c do: [:x | x even ifTrue: [^x]].
    ^nil
```
メソッド本体:
```
  0  PUSH_VAR     'c'
  1  PUSH_BLOCK   0 (...)
  2  SEND         ('do:', 1)
  3  POP
  4  PUSH_NIL
  5  RETURN           ← ^nil
  6  PUSH_SELF        ← 暗黙の ^self（この例では ^nil の後で到達不能）
  7  RETURN
```
渡すブロック `[:x | x even ifTrue: [^x]]`:
```
  0  PUSH_VAR     'x'
  1  SEND         ('even', 0)
  2  JUMP_FALSE   6
  3  PUSH_VAR     'x'
  4  RETURN           ← ここが非局所リターン。firstEven: から x を返す
  5  JUMP         7
  6  PUSH_NIL
  7  BLOCK_RETURN
```
`x even` が真の要素で `^x` が発火すると、`do:` のループ（Python側のプリミティブ）
ごと巻き戻して `firstEven:` の呼び出し元へ `x` を返します。

## super 送信

`super foo` は `PUSH_SELF`（レシーバは `self` のまま）＋ `SEND_SUPER`。探索の起点を
1つ上のクラスにする必要があり、それは実行時に「いま実行中のメソッドが定義された
クラス」(`CompiledMethod.defined_in`) の `superclass` から求めます。

## 変数解決

`PUSH_VAR` / `STORE_VAR` は変数名だけを持ち、VMが実行時に次の順で解決します。

1. 環境チェイン（メソッド/ブロックの引数・一時変数、外側スコープ）
2. レシーバのインスタンス変数（`STObject` の場合）
3. グローバル（クラス名や `Transcript` など）

読み取りでどれにも該当しなければ「未宣言変数」エラー。書き込みで該当しなければ、
**グローバル（ワークスペース変数）として自動宣言**します。だから REPL で
`x := 3` の後に `x + 4` が書けます。

インライン展開されたブロックは新フレームを作らないため、その中の一時変数は
外側のメソッドフレームへ「巻き上げ」られます（`_CodeGen.hoisted` →
`local_names`）。

## 性能上の工夫

ツリーウォークではなくバイトコード＋非再帰ループである点に加え、次の最適化があります。

- **メソッド探索キャッシュ** … `STClass.lookup` / `lookup_class_method` は解決結果
  （ミスも含む）をクラスごとにメモ化。クラス階層やメソッド辞書を変更したら
  `VM.flush_method_caches()` で一括無効化（`define_class` / `define_method` が呼ぶ）。
- **インスタンス変数レイアウトのメモ化** … `all_instance_variables()` を
  クラスごとにキャッシュ（同じく flush で無効化）。
- **数値二項演算の高速パス** … `+ - * < > <= >= =` は、両オペランドが素の
  `int`/`float` のとき、探索・プリミティブ呼び出しを飛ばして `_loop` 内で直接計算。
  ユーザが数値クラス（`SmallInteger`/`Float` の祖先）でこれらを上書きすると
  `VM.optimize_arithmetic` が下りて自動的に無効化されます。
- **フレーム/型判定の軽量化** … 活性化フレームの環境は `dict.fromkeys` で構築、
  `class_of` は高頻度の素の型（`STObject`/`int`/`str`）を先頭で分岐。

参考: `fib: 28` ＋ `whileTrue:` ループ 20 万回で、上記導入により素朴実装比
約 1.3 倍高速。次の一手は変数アクセスのレキシカルアドレッシング（名前引き →
添字アクセス）です。

## 逆アセンブラ

`st.bytecode.disassemble(compiled)` が上記のような番地付きリストを返します。
手元で確認するには:

```python
from st.parser import parse_sequence
from st.compiler import compile_doit
from st.bytecode import disassemble

print(disassemble(compile_doit(parse_sequence("3 + 4 factorial"))))
```
