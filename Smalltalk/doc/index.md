# small Smalltalk — 制御を1つのループに集める

小さな Smalltalk と、そのバイトコード処理系2つ（Python と C++23）の解説です。
1章が1つの関心に対応し、どの章にも**実際に動かした出力**を載せています。逆アセンブルも
測定値も、手で書いたものはありません。

この処理系の主張は1行で書けます。

> **Smalltalk のすべての制御を、ホストの制御に降ろさず、1つのループに集める。**

Smalltalk では `ifTrue:` も `whileTrue:` も `do:` も**メッセージ送信**です。素直に
実装すると、条件分岐がブロックへの送信になり、ブロックの起動がホストの再帰呼び出しに
なり、ループ1回ごとにホストのスタックが伸び縮みします。この処理系はそれを3つの手で
畳みます。

1. **コンパイラが制御構文をジャンプに畳む**（[3章](03-inline.md)）
2. **VM がメソッド送信で再帰しない**（[6章](06-loop.md)）
3. **反復するライブラリを Smalltalk 自身で書く**（[10章](10-prelude.md)）

3つ目がいちばん効きます。C++ 側の `do:` / `collect:` / `inject:into:` は Smalltalk で
書かれていて、**プリミティブが VM に再入する箇所が0**です。Python 側は同じものを
Python で書いていて、再入が48箇所あります。この差が、[7章](07-return.md)の
非局所リターンの実装を二度とも違うものにしました。

言語の使い方は [Smalltalk/README](../README.md)、Python 版の参照文書は
[`python/docs/`](../python/docs/README.md) にあります。ここはその中身の話です。

## 目次

**[0. `3 + 4 factorial` が 27 になるまで](00-send.md)** — 1つの式が字句解析から値まで
通り抜ける道筋を、部品1つずつ1段落で追います。まずここを読むと、以降の章がどこの話か
分かります。

### 前半 — バイトコードができるまで

| | | |
|---|---|---|
| 1 | [3種類のメッセージしかない](01-syntax.md) | `lexer` ・`parser`。優先順位が構文のすべて |
| 2 | [命令セットとコンパイル済みコード](02-bytecode.md) | `bytecode`。22個の命令 |
| 3 | [制御構文をジャンプに畳む](03-inline.md) | `compiler`。`ifTrue:` が送信でなくなるとき |
| 4 | [変数をコンパイル時に解く](04-scope.md) | `compiler.Scope`。スロット・外側・名前の3段 |

### 中盤 — 走らせる

| | | |
|---|---|---|
| 5 | [活性化を物にする](05-context.md) | フレームが `thisContext` そのものであること |
| 6 | [1つのループ](06-loop.md) | 非再帰の駆動部。**この本の中心** |
| 7 | [`^` — 例外を使う実装と、使わない実装](07-return.md) | 二度書いて割れた1箇所 |
| 8 | [オブジェクトモデルと値の表現](08-objects.md) | 探索の3段と、NaN ボクシング |
| 9 | [メモリ — 借りる 対 書く](09-memory.md) | Python の収集器に乗る 対 mark-sweep を書く |

### 後半 — 育てる

| | | |
|---|---|---|
| 10 | [ライブラリを Smalltalk で書く](10-prelude.md) | 48 対 0。再入をなくすということ |
| 11 | [速くする](11-fast.md) | インラインキャッシュ・算術の速い道・スロット ivar |
| 12 | [IDE — 走っている処理系を編む](12-ide.md) | System Browser / Workspace / Transcript |

### 全体について

| | | |
|---|---|---|
| 13 | [二度書いて分かったこと](13-twice.md) | 何が言語で、何が実装言語だったか |
| 14 | [していないこと](14-next.md) | メタクラスも継続もプロセスもない |

## 読み方

**言語を使いたいだけなら** [README](../README.md) と
[対応構文](../python/docs/syntax.md) です。

**通して読むなら** 0章から順に。前半（1〜4章）は「テキストからバイトコードまで」、
中盤（5〜9章）は「それを走らせる機械」、後半（10〜12章）は「その上に何を積むか」です。
境目は3章と6章 — **どちらも「制御をどこへ置くか」の話**で、片方はコンパイル時、
もう片方は実行時の答えです。

**1つだけ読むなら** [6章の1つのループ](06-loop.md)です。他の章はそこへ向かうか、
そこから出てきます。

**二度書くことに興味があるなら** [7章](07-return.md)と[13章](13-twice.md)。
`^` の実装は、Python 側がホストの例外を使い、C++ 側が使いません。使わずに済んだ理由が
[10章](10-prelude.md)にあります。

**手元で確かめるなら** 各章の出力は次のコマンドで再現できます。

```sh
cd python
uv sync
uv run python main.py repl          # ターミナル REPL
uv run python main.py               # IDE（12章）
uv run pytest                       # 55本

cd ../cpp
cmake -S . -B build -G Ninja        # 既定で Release (-O3)
cmake --build build
./build/smalltalk                   # デモ + REPL
./build/st_bench                    # ベンチ（11章）
ctest --test-dir build
```

逆アセンブルは Python 側から出せます。

```python
from st.parser import parse_sequence
from st.compiler import compile_doit
from st.bytecode import disassemble

print(disassemble(compile_doit(parse_sequence("3 + 4 factorial"))))
```

## 全体像

```
ソース
  │  lexer      識別子・キーワード（`at:`）・二項セレクタ・リテラル
  ▼
トークン
  │  parser     単項 > 二項 > キーワード。再帰下降
  ▼
構文木
  │  compiler   制御構文をジャンプへ畳む。変数をスロットへ解く
  ▼
バイトコード     CompiledMethod / CompiledBlock
  │  VM         1つのループ。活性化は Context オブジェクト
  ▼
値
```

コンパイラを抜けた時点で、**バイトコードの中に `ifTrue:` という送信は残っていません**
（引数がリテラルブロックなら）。変数参照も名前ではなくスロット番号です。VM が実行時に
問うのは「このセレクタはどのメソッドか」だけになります。

| ファイル（Python） | 行数 | 役割 |
|---|---:|---|
| `st/lexer.py` | 234 | 字句解析 |
| `st/parser.py` | 342 | 再帰下降 |
| `st/ast.py` | 97 | 構文木 |
| `st/bytecode.py` | 101 | 命令セットとコンパイル済みコード |
| `st/compiler.py` | 416 | 構文木 → バイトコード |
| `st/vm.py` | 484 | 非再帰のスタックマシン |
| `st/objects.py` | 228 | オブジェクトモデル |
| `st/kernel.py` | 1092 | 基底クラスとプリミティブ |
| `st/system.py` | 89 | ファサード |
| `ide/app.py` | 359 | IDE |

| ファイル（C++） | 行数 | 役割 |
|---|---:|---|
| `src/lexer.cppm` | 357 | 字句解析 |
| `src/parser.cppm` | 407 | 再帰下降 |
| `src/ast.cppm` | 99 | 構文木 |
| `src/bytecode.cppm` | 62 | 命令セット |
| `src/compiler.cppm` | 505 | 構文木 → バイトコード（`to:do:` も畳む） |
| `src/vm.cppm` | 451 | 非再帰のスタックマシン + インラインキャッシュ |
| `src/objects.cppm` | 406 | NaN ボクシングされた `Value` と全オブジェクト型 |
| `src/heap.cppm` | 179 | mark-and-sweep |
| `src/kernel.cppm` | 496 | 基底クラスとプリミティブ |
| `src/system.cppm` | 164 | ファサード + Smalltalk の prelude |

`kernel` だけが 1092 対 496 と開いています。**その差が[10章](10-prelude.md)です** —
Python 側で Python で書かれている反復メソッドが、C++ 側では Smalltalk で書かれて
`system.cppm` に移っています。

## 各章の作り

どの章も同じ並びです。

- 本文（節番号つき）
- **していないこと** — 入れていない機能と、その理由（ある章だけ）
- **参考文献** — その章が拠っているもの
- **実装の地図** — どちらの実装の、どのファイルの何行目に何があるか

---

[0. `3 + 4 factorial` が 27 になるまで →](00-send.md)
