# 0. `3 + 4 factorial` が 27 になるまで

この章は道案内です。1つの式が処理系を通り抜ける道筋を、部品1つずつ1段落で追います。
細部はすべて以降の章にあります。

```
$ cd cpp && ./build/smalltalk
small Smalltalk (C++23 modules) — v0.1.0
3 + 4 factorial  =>  27
```

27 であって 5040 でも 7 でもないところがこの式の見どころです。

## 1. 字句 — キーワードは `:` まで含めて1つ

`Lexer` が出すのは9種類ほどのトークンです。Smalltalk に固有なのは2つ。

**識別子の直後に `:` が来たら、それで1つのトークン**（`KEYWORD`）です。`at:` は
`at` と `:` ではありません。だから `at:put:` は2つのキーワードトークンになり、
セレクタを組み立てるときに繋がります。

**二項セレクタは記号の連なり**です。

```python
BINARY_CHARS = set("+-*/~<>=&|@%,?!")
```

`+` も `//` も `,` も `->` も同じ規則で1つのトークンになります。**演算子の一覧が
言語に組み込まれていません。** 記号を並べれば新しい二項セレクタになります。

## 2. 構文 — 優先順位が3段しかない

```
単項 > 二項 > キーワード
```

`3 + 4 factorial` は、まず `4 factorial`（単項）、次に `3 + それ`（二項）です。
再帰下降がそのまま3段になります。

```python
def _keyword_expr(self): ...   # 一番ゆるい
def _binary_expr(self): ...
def _unary_expr(self): ...     # 一番きつい
def _primary(self): ...
```

**同じ段の中はすべて左結合で、括弧以外に優先順位を変える手段はありません。**
`2 + 3 * 4` は 20 です。

## 3. コンパイル — 送信は送信のまま、制御はジャンプへ

```
$ python -c "...disassemble(compile_doit(parse_sequence('3 + 4 factorial')))"
  0  PUSH_LITERAL 0 (3)
  1  PUSH_LITERAL 1 (4)
  2  SEND         ('factorial', 0)
  3  SEND         ('+', 1)
  4  RETURN
```

構文木の形がそのままスタックマシンの命令列になります。**`+` も `factorial` も
本物のメッセージ送信**で、特別扱いはありません。

特別扱いされるのは制御構文だけです。

```
$ ... "5 > 2 ifTrue: ['big'] ifFalse: ['small']"
  0  PUSH_LITERAL 0 (5)
  1  PUSH_LITERAL 1 (2)
  2  SEND         ('>', 1)
  3  JUMP_FALSE   6
  4  PUSH_LITERAL 2 ('big')
  5  JUMP         7
  6  PUSH_LITERAL 3 ('small')
  7  RETURN
```

`ifTrue:ifFalse:` という送信がどこにもありません。ブロックも作られていません。
これが[3章](03-inline.md)です。**引数がリテラルの0引数ブロックのときだけ**畳まれ、
そうでなければ普通の送信に落ちます。

## 4. 変数 — コンパイル時に番号になる

```
$ ... "| i | i := 1. [i <= 3] whileTrue: [i := i + 1]. i"
  0  PUSH_LITERAL 0 (1)
  1  STORE_LOCAL  0
  2  POP
  3  PUSH_LOCAL   0        ← ループ先頭
  ...
 12  JUMP         3
```

`i` という名前はバイトコードに残っていません。スロット0です。外側のブロックの変数なら
`PUSH_OUTER (深さ, 番号)`、どこにもなければ名前のまま `PUSH_VAR` で実行時に解決
（[4章](04-scope.md)）。

## 5. 実行 — 1つのループ

VM はスタックマシンです。ここまでは普通ですが、**メソッド送信でホストの再帰を使いません。**

```cpp
Context* nc = make_method_frame(m->compiled, receiver, args);
stk->resize(sp_base - 1);
nc->sender = ctx;
load_ctx(nc);          // ← 現在の活性化を差し替えて、同じループを回り続ける
break;
```

呼び出しは「新しい `Context` を作って、いま見ている活性化をそれに差し替える」だけです。
戻りは逆に `sender` へ差し替えます。**呼び出しスタックはホストのスタックではなく、
ヒープ上の `sender` の鎖**になります（[5章](05-context.md)・[6章](06-loop.md)）。

だから深い再帰が Python の再帰上限に当たりません。

```
$ python: Deep new sum: 20000
200010000
```

## 6. 活性化は Smalltalk のオブジェクト

`sender` の鎖はプログラムから見えます。

```
$ python: thisContext
a MethodContext (DoIt)
```

```smalltalk
depth
    | n c | n := 0. c := thisContext.
    [c isNil] whileFalse: [n := n + 1. c := c sender]. ^n
```

```
Probe new depth  =>  2
Probe new a      =>  4        "a → b → depth → DoIt"
```

フレームがそのまま `MethodContext` / `BlockContext` です。VM がフレームのために
別の構造体を持っていて、それをオブジェクトに包み直す、という段はありません。

## 7. プリミティブは葉

`3 + 4` の `+` は、最後にはホストの足し算に行き着きます。

```python
b.prim(Number, "+", lambda vm, r, a: r + a[0])
```

**プリミティブは葉であるべき**です。葉でないもの——ブロックを呼ぶもの——があると、
そこでホストの再帰が始まります。Python 側にはそれが48箇所あり、C++ 側には0箇所
あります（[10章](10-prelude.md)）。

C++ 側で `do:` がどう書かれているか。

```cpp
{"SequenceableCollection",
 "do: aBlock\n"
 "  | i n | i := 1. n := self size.\n"
 "  [i <= n] whileTrue: [aBlock value: (self at: i). i := i + 1]"},
```

**Smalltalk で書かれています。** `whileTrue:` は3節で畳まれ、`aBlock value:` は
5節のとおりループ内で活性化が差し替わるだけ。**ホストは1度も再帰しません。**

## 8. 速い道

`3 + 4` のような整数演算は、探索もプリミティブ呼び出しもせずにループの中で終わります。

```cpp
if (ins.op == Op::Send && optimize_arithmetic_ && ins.arg2 != 0 && argc == 1) {
    Value& rv = *(stk->end() - 2);
    Value& av = stk->back();
    if (is_int(rv) && is_int(av)) { ... }
}
```

`ins.arg2` は**コンパイラが埋めた特殊セレクタ番号**で、VM は文字列比較ではなく整数の
分岐で済みます。この道は、ユーザが数値クラスで `+` を上書きした瞬間に自動で塞がれます
（[11章](11-fast.md)）。

## 9. 全体をもう一度

```
"3 + 4 factorial"
  │  Lexer          `factorial` は IDENT、`+` は BINARY
  ▼
トークン
  │  Parser         単項 > 二項 > キーワード
  ▼
構文木
  │  Compiler       制御構文はジャンプへ、変数はスロットへ
  ▼
PUSH_LITERAL 3 / PUSH_LITERAL 4 / SEND factorial / SEND + / RETURN
  │  VM             1つのループ。Context を差し替えて進む
  ▼
27
```

これが全部です。以降の章は、この図のどこか1箇所を拡大します。

## していないこと

**イメージがありません。** 本物の Smalltalk は処理系の状態をまるごと保存して再開
しますが、ここでは毎回クラスを定義し直します（IDE の中では生き続けます、
[12章](12-ide.md)）。

**メタクラスがありません。** クラス側のメソッドは `class_methods` という別の辞書で、
「クラスのクラス」というオブジェクトはありません（[8章](08-objects.md)）。

## 参考文献

- A. Goldberg, D. Robson, *Smalltalk-80: The Language and its Implementation*,
  Addison-Wesley, 1983（通称 Blue Book）。特に第III部が、この本が写している
  バイトコード処理系の原型です。`thisContext`・`MethodContext`・非局所リターンの
  意味づけはすべてそこにあります。
- R. Nystrom, [*Crafting Interpreters*][ci] の "A Bytecode Virtual Machine" 以降。
  木を歩く処理系からバイトコードへ移る動機と、スタックマシンの組み方。

[ci]: https://craftinginterpreters.com/a-bytecode-virtual-machine.html

## 実装の地図

| Python | |
|---|---|
| `st/lexer.py` 37行 | `BINARY_CHARS` |
| `st/parser.py` 164–192行 | `_keyword_expr` / `_binary_expr` / `_unary_expr` / `_primary` |
| `st/compiler.py` 108行 | `compile_method` |
| `st/vm.py` 288行 | `_run` — 駆動部 |
| `st/vm.py` 346行 | `_loop` — ディスパッチ |
| `st/system.py` 30行 | `eval` |

| C++ | |
|---|---|
| `src/vm.cppm` 225行 | `run` — 駆動部 |
| `src/vm.cppm` 305行 | `Send` — 差し替えて進む |
| `src/vm.cppm` 313行 | 算術の速い道 |
| `src/system.cppm` 32行 | `eval` |
| `src/system.cppm` 96行 | `install_prelude` — Smalltalk で書かれた `do:` |

---

[← 目次](index.md) ／ [1. 3種類のメッセージしかない →](01-syntax.md)
