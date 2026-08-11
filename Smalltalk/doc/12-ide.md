# 12. IDE — 走っている処理系を編む — `ide/app.py`

Smalltalk の IDE は、処理系の外にあるエディタではありません。**同じ生きたイメージを
3つの窓から見るもの**です。System Browser でメソッドを直せば、その瞬間から
Workspace の式がそれを使います。359行でその形が作れます。

Python 側にだけあります。C++ 側にはありません。

## 1. 3つの窓と1つのイメージ

```python
"""PySide6 で作った最小の Smalltalk IDE。

配置: 左が System Browser（クラス → メソッド → ソース、Accept でメソッドを
コンパイル）、右が Workspace（Do it / Print it）とその下の共有 Transcript。
どの窓も1つの生きた Smalltalk を相手にしているので、ブラウザでクラスを定義すれば
すぐにワークスペースで使える。"""
```

**`Smalltalk` のインスタンスは1つです。** それが「イメージ」の役目をします。

```sh
uv run python main.py          # IDE
uv run python main.py repl     # ターミナルの REPL
```

## 2. Do it と Print it

```python
def _selected_source(self) -> str:
    cursor = self.editor.textCursor()
    text = cursor.selectedText().replace(" ", "\n")
    return text if text.strip() else self.editor.toPlainText()
```

**選択があれば選択、なければ全部。** Smalltalk の作法どおりです。

```python
def print_it(self) -> None:
    src = self._selected_source()
    try:
        result = self.window.st.eval_to_string(src)
    except (STError, ParseError) as e:
        self.window.report_error(e)
        return
    cursor = self.editor.textCursor()
    cursor.clearSelection()
    cursor.insertText(" " + result)
```

**結果をエディタに書き戻します。** 別の窓に出すのではありません。書いたものと
その答えが同じテキストの上に並ぶ、というのが Print it の意味です。

`Do it` は結果を捨てます。副作用のために走らせる形です。

## 3. Accept — メソッドをその場でコンパイルする

```python
def accept_method(self) -> None:
    cls = self._current_class()
    if cls is None: ...
    source = self.source.toPlainText()
    try:
        method = self.window.st.define_method(
            cls.name, source, class_side=self.class_side.isChecked()
        )
    except (ParseError, STError, ValueError) as e:
        self.window.report_error(e)
        return
    self.window.transcript.log(
        f"Compiled {cls.name}...>>{method.selector}"
    )
```

**`define_method` はファサードの1メソッドです**（[0章](00-send.md)）。IDE が
特別なことをしているのではなく、REPL やテストが呼ぶのと同じ入口です。

```python
def define_method(self, class_name, source, class_side=False):
    cls = self.vm.classes.get(class_name)
    node = parser.parse_method(source)
    method = compile_method(node, source)
    method.defined_in = cls
    ...
    self.vm.flush_method_caches()
    return method
```

最後の `flush_method_caches()` が、**編集した瞬間にキャッシュを捨てる**部分です
（[11章](11-fast.md)）。これがないと、Accept したのに古いメソッドが動きます。

クラス名がソースに書かれていないので（[1章](01-syntax.md)6節）、**どのクラスに
入れるかはブラウザの選択が決めます。** メソッドはテキストの断片であって、
クラスに置かれるもの、という Smalltalk の形がここに出ています。

## 4. ソースを読み戻せるのは `source` を持っているから

```python
@dataclass
class CompiledMethod:
    ...
    source: str = ""
```

コンパイルするときにソースを一緒に入れておくので、ブラウザがメソッドを選んだときに
元のテキストを出せます（[2章](02-bytecode.md)7節）。

**バイトコードから逆生成しているのではありません。**

## 5. Transcript は差し替えられた出力先

```python
# Transcript の出力先。IDE が捕まえるためにここを差し替える。
# sys.stdout は遅延解決するので、テストのキャプチャやリダイレクトも効く。
self.output: Callable[[str], None] = lambda s: sys.stdout.write(s)
```

IDE はこれを窓に向けます。

```python
def write(self, text: str) -> None:
    self.view.moveCursor(self.view.textCursor().MoveOperation.End)
    self.view.insertPlainText(text)
```

**`vm.output` という差し込み口が1つあるだけです。** `Transcript show:` の
プリミティブはそれを呼ぶだけなので、REPL では端末に、IDE では窓に、テストでは
キャプチャに出ます。

## 6. New Class

ブラウザからクラスも足せます。名前・スーパークラス・インスタンス変数を聞いて
`define_class` を呼び、クラス一覧を作り直します。

**Smalltalk のコードとしてクラスを定義する構文はありません**（[1章](01-syntax.md)）。
本物なら `Object subclass: #Foo instanceVariableNames: 'a b' ...` というメッセージ
送信ですが、ここではホスト側の API です。だから IDE の New Class は
「Smalltalk の式を組み立てて評価する」のではなく、直接 `define_class` を呼びます。

## 7. 色付け

`ide/highlighter.py` が73行あります。`QSyntaxHighlighter` の派生で、
キーワードメッセージ・シンボル・文字列・コメント・数値を正規表現で塗ります。

**字句解析器を使っていません。** 塗るだけなら正規表現で足り、途中まで書かれた
（構文としては壊れている）テキストでも壊れないほうが望ましいからです。

## していないこと

**デバッガがありません。** これが本物の Smalltalk との最大の差です。活性化は
オブジェクトとして見えている（[5章](05-context.md)）のに、それを止めて覗いて
再開する仕組みがありません。再開には[14章](14-next.md)の「コンテキストを再開する」
が要ります。

**インスペクタがありません。** オブジェクトの中身を開いて見る窓がありません。

**イメージの保存がありません。** IDE を閉じれば定義したクラスは消えます。
保存するには、クラスとメソッドのソースを書き出して読み直す（ファイルアウト／
ファイルイン）か、状態ごと直列化することになります。

**逆アセンブル表示がありません。** ブラウザに `disassemble_hint` という関数が
ありますが、いまはプリミティブかどうかを言うだけです。`disassemble`
（[2章](02-bytecode.md)）を呼べば命令列を出せます。

**検索がありません。** 「このセレクタを送っているメソッド」「このメソッドの
実装者」を探す機能（senders / implementors）は、本物の Smalltalk の中核ですが
ありません。

**C++ 側に IDE がありません。** ターミナルの REPL だけです。

## 参考文献

- D. Ingalls, [*Design Principles Behind Smalltalk*][ingalls], BYTE, 1981。
  「システムはユーザに、自分自身を変える手段を提供すべきである」。3節の Accept が
  その最小形です。
- A. Goldberg, *Smalltalk-80: The Interactive Programming Environment*,
  Addison-Wesley, 1984。System Browser・Workspace・Transcript・Inspector・
  Debugger の設計。この IDE は前の3つだけを作っています。

[ingalls]: https://www.cs.virginia.edu/~evans/cs655/readings/smalltalk.html

## 実装の地図

| Python | |
|---|---|
| `main.py` 12行 | `repl` |
| `main.py` 31行 | `main` — 引数で IDE か REPL か |
| `ide/app.py` 57行 | `Workspace` |
| `ide/app.py` 82行 | `_selected_source` |
| `ide/app.py` 96行 | `print_it` — 結果を書き戻す |
| `ide/app.py` 111行 | `SystemBrowser` |
| `ide/app.py` 225行 | `new_class` |
| `ide/app.py` 256行 | `accept_method` |
| `ide/app.py` 286行 | `Transcript` |
| `ide/app.py` 306行 | `MainWindow` |
| `ide/highlighter.py` | 色付け |
| `st/vm.py` 113行 | `output` — 差し込み口 |
| `st/system.py` 66行 | `define_method` |

---

[← 11. 速くする](11-fast.md) ／ [目次](index.md) ／ [13. 二度書いて分かったこと →](13-twice.md)
