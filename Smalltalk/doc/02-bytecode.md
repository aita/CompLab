# 2. 命令セットとコンパイル済みコード — `bytecode`

命令は22個です。この章はその一覧と、命令列が守っている1つの不変条件の話です。

## 1. 22個

| 命令 | arg | 動作 |
|---|---|---|
| `PUSH_LITERAL` | 添字 | 定数プールの値を積む |
| `PUSH_SELF` | — | レシーバを積む |
| `PUSH_CONTEXT` | — | いまの活性化を積む（`thisContext`） |
| `PUSH_NIL` / `PUSH_TRUE` / `PUSH_FALSE` | — | それぞれを積む |
| `PUSH_LOCAL` / `STORE_LOCAL` | スロット | いまの活性化のローカル |
| `PUSH_OUTER` / `STORE_OUTER` | (深さ, スロット) | 外側の活性化のローカル |
| `PUSH_VAR` / `STORE_VAR` | 名前 | 実行時に解決するもの |
| `POP` / `DUP` | — | スタック操作 |
| `SEND` / `SEND_SUPER` | (セレクタ, 引数の数) | メッセージ送信 |
| `PUSH_BLOCK` | 添字 | `CompiledBlock` からクロージャを作る |
| `MAKE_ARRAY` | 個数 | `{ ... }` |
| `JUMP` / `JUMP_TRUE` / `JUMP_FALSE` | 番地 | 分岐（条件は絶対 Boolean） |
| `RETURN` | — | `^` |
| `BLOCK_RETURN` | — | ブロックの正常終了 |

C++ 側は2つ多く24個で、増えているのは `PushIvar` / `StoreIvar` です。インスタンス
変数がコンパイル時にスロット番号になっているためで、Python 側はそこを `PUSH_VAR` で
名前解決します（[4章](04-scope.md)）。

## 2. `STORE_*` は pop しない

```python
case Op.STORE_LOCAL:
    ctx.locals[ins.arg] = stack[-1]
```

**代入が式だからです。** `a := b := 0` が書けて、`x := (y := 3) + 1` も書けます。
文の区切りでは、コンパイラが `POP` を出して中間結果を捨てます。

```
$ | i | i := 1. [i <= 3] whileTrue: [i := i + 1]. i
  0  PUSH_LITERAL 0 (1)
  1  STORE_LOCAL  0
  2  POP              ← 文の区切り
```

## 3. 不変条件は1つ

**どの文列も、最後の式の値をスタックにちょうど1つ残す。**

コンパイラの `_sequence_value` がそれを守ります。

```python
for i, stmt in enumerate(stmts):
    last = i == len(stmts) - 1
    if isinstance(stmt, ast.ReturnNode):
        self._expr(stmt.value)
        self.g.emit(Op.RETURN)
        return
    self._expr(stmt)
    if not last:
        self.g.emit(Op.POP)
```

これが守られていると、[3章](03-inline.md)のインライン展開が単純になります。
`ifTrue:` の両枝が「値を1つ残す」ので、合流点でスタックの高さが揃います。

値を残さない枝には `PUSH_NIL` を足します。

```python
if true_b is not None:
    self._inline_block_body(true_b)
else:
    g.emit(Op.PUSH_NIL)
```

ループも同じで、`whileTrue:` は本体の値を `POP` で捨て、最後に `PUSH_NIL` を1つ
残します。**`whileTrue:` は `nil` を返すメッセージだからです。**

```
 11  POP                   ← 本体の値を捨てる
 12  JUMP         3
 13  PUSH_NIL              ← whileTrue: の結果
```

## 4. メソッドの末尾には暗黙の `^self`

```python
self._sequence_value(node.body, is_method_body=True)
# implicit ^self
self.g.emit(Op.PUSH_SELF)
self.g.emit(Op.RETURN)
```

`^` を書かないメソッドはレシーバを返す、という Smalltalk の規則がこの2行です。
`^` で終わるメソッドでは到達しません。

```
$ firstEven: c
      c do: [:x | x even ifTrue: [^x]].
      ^nil
  0  PUSH_LOCAL   0
  1  PUSH_BLOCK   0 (...)
  2  SEND         ('do:', 1)
  3  POP
  4  PUSH_NIL
  5  RETURN           ← ^nil
  6  PUSH_SELF        ← 暗黙の ^self（ここは到達しない）
  7  RETURN
```

DoIt（ワークスペースの式）だけは違って、**最後の文の値がそのまま結果**です。

```python
if not seq.statements:
    self.g.emit(Op.PUSH_NIL)
self.g.emit(Op.RETURN)
```

## 5. カスケードは `DUP` と `POP`

```
$ OrderedCollection new add: 1; add: 2; yourself
  0  PUSH_VAR     'OrderedCollection'
  1  SEND         ('new', 0)
  2  DUP
  3  PUSH_LITERAL 0 (1)
  4  SEND         ('add:', 1)
  5  POP              ← add: の結果を捨て、複製したレシーバが残る
  6  DUP
  7  PUSH_LITERAL 1 (2)
  8  SEND         ('add:', 1)
  9  POP
 10  SEND         ('yourself', 0)
 11  RETURN
```

**最後のメッセージだけ `DUP` されず、その結果が残ります。** レシーバ（`new` の結果）は
1回しか評価されません。

## 6. 定数プールは重複を畳む、ただし可変なものは畳まない

```python
def literal(self, value: object) -> int:
    # ハッシュ可能で不変なリテラルは共有し、可変なもの（配列・コンパイル済みブロック）は
    # 毎回新しい項目にして、出現どうしが状態を共有しないようにする。
    try:
        hash(value)
    except TypeError:
        self.literals.append(value)
        return len(self.literals) - 1
    for idx, existing in enumerate(self.literals):
        if type(existing) is type(value) and existing == value:
            return idx
    ...
```

`type(existing) is type(value)` の確認があるのは、Python では `1 == True` かつ
`1 == 1.0` だからです。これがないと `PUSH_LITERAL` が `1` のつもりで `True` を
積みます。

リテラル配列を畳まないのは、`#(1 2 3)` が2回書かれたときに同じ配列オブジェクトを
共有すると、片方への破壊的変更がもう片方に見えてしまうからです。

## 7. コンパイル済みコードが持つもの

```python
@dataclass
class CompiledMethod:
    selector: str
    params: list[str]
    local_names: list[str]  # params + temps living in the method frame
    code: list[Instr] = field(default_factory=list)
    literals: list[Any] = field(default_factory=list)
    source: str = ""
    defined_in: Any = None  # STClass the method is installed in (for super)
```

`local_names` は**活性化時に `nil` で用意するスロットの数**を決めます。名前を持って
いるのは診断と IDE のためで、実行には要りません。

`defined_in` は `super` のためだけにあります。`super foo` の探索は「いま実行中の
メソッドが定義されたクラスの上」から始まるので、実行時にそれを知る必要があります
（[8章](08-objects.md)）。

`source` は IDE がメソッドを編集するときに読み戻すテキストです（[12章](12-ide.md)）。

## 8. C++ 側の `Instr` は太い

```cpp
struct Instr {
    Op op;
    int arg = 0;
    int arg2 = 0;      // Send: 特殊セレクタ番号 / *Outer: スロット
    std::string name;  // Send* のセレクタ、*Var の変数名

    void* ic_class = nullptr;
    void* ic_method = nullptr;
    void* ic_class2 = nullptr;
    void* ic_method2 = nullptr;
    std::uint64_t ic_version = 0;

    void* sel = nullptr;   // インターンされたセレクタ（Symbol*）
};
```

**命令1つが実行時の状態を持っています。** `ic_*` が2way インラインキャッシュ、
`sel` がコンパイル時にインターンされたセレクタ、`arg2` が算術の速い道のための番号です
（[11章](11-fast.md)）。

`void*` なのは、この partition をオブジェクトモデルから独立に保つためです。VM が
`Class*` / `Method*` にキャストします。

命令列は `std::vector<Instr>` で、VM は**非 const 参照**で読みます。

```cpp
Instr& ins = (*code)[ctx->ip++];  // non-const: inline cache is mutated
```

## していないこと

**バイト列ではありません。** `Instr` は構造体で、`code` はその配列です。1バイト
1命令に詰めれば局所性が上がりますが、`arg` が可変長になり、逆アセンブラと
バックパッチが複雑になります。

**スーパー命令がありません。** `PUSH_LOCAL 0; PUSH_LITERAL 0; SEND '+'` のような
頻出の並びを1命令にまとめていません。

**定数畳み込みをしません。** `2 + 3` は実行時に足されます。

**行番号表がありません。** バイトコードからソースの位置に戻れないので、実行時
エラーは「どのメソッドか」までしか言えません。

**逆アセンブラは Python 側にしかありません。** C++ 側は `disassemble` に相当する
ものを持たないので、この本の逆アセンブル出力はすべて Python 側のものです。命令の
意味は同じです。

## 参考文献

- A. Goldberg, D. Robson, *Smalltalk-80*, 第III部 §27。Blue Book の命令セットは
  256個の1バイト命令で、この22個はその意味論を圧縮せずに並べたものです。
- T. Kalibera ら, [*The Design and Implementation of Modern Object-Oriented
  Virtual Machines*][vmbook] 的な流れの入口として、
  R. Nystrom, [*Crafting Interpreters*][ci] "Chunks of Bytecode"。
  スタックマシンの不変条件（3節）の扱い方。

[ci]: https://craftinginterpreters.com/chunks-of-bytecode.html
[vmbook]: https://doi.org/10.1145/2647508.2647517

## 実装の地図

| Python | |
|---|---|
| `st/bytecode.py` 19行 | `Op` — 22個 |
| `st/bytecode.py` 45行 | `Instr` |
| `st/bytecode.py` 56行 | `CompiledBlock` |
| `st/bytecode.py` 70行 | `CompiledMethod` |
| `st/bytecode.py` 90行 | `disassemble` |
| `st/compiler.py` 77行 | `literal` — 重複を畳む条件 |
| `st/compiler.py` 150行 | `_sequence_value` — 不変条件 |
| `st/compiler.py` 115–118行 | 暗黙の `^self` |
| `st/compiler.py` 235行 | `_cascade` |

| C++ | |
|---|---|
| `src/bytecode.cppm` 10行 | `Op` — 24個（`PushIvar`/`StoreIvar` が増えている） |
| `src/bytecode.cppm` 38行 | `Instr` — インラインキャッシュを抱える |
| `src/vm.cppm` 243行 | 命令を非 const で読む理由 |

---

[← 1. 3種類のメッセージ](01-syntax.md) ／ [目次](index.md) ／ [3. 制御構文をジャンプに畳む →](03-inline.md)
