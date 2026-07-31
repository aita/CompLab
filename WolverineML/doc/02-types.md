# 2. 型検査とエスケープ解析

`types.py` と `typecheck.py`。

型は単相で、推論はありません。この章の見どころは型のほうではなく**副産物**です。
型検査は木を1度たどるので、そのついでに「この変数はレジスタに住めるか」まで決めて
しまいます。後段はその答えを使うだけです。

---

## 用語

| | |
|---|---|
| 単相 (monomorphic) | 型変数がない。`'a list` のようなものは書けない |
| 公称的 (nominal) | 型が名前で決まる。同じ形でも名前が違えば別の型 |
| 逃げる (escape) | ある変数が、それを束縛した関数より内側の関数から読まれること |
| 静的入れ子深さ | 関数が構文上いくつ入れ子になっているか。トップレベルの本体が 0 |

---

## 2.1 推論がない、という設計

`fun` に結果型を書かなければ**手続き**で、`unit` を返します。Tiger と同じ規則です。

```sml
fun square (n : int) : int = n * n         (* 結果型を書いた。int を返す *)
fun greet (who : string) = print (who)     (* 書かない。unit を返す *)
```

引数の型は必ず書きます。この2つを合わせると、**どの関数の型も本体を読む前に確定
します**。だから相互再帰も推論なしで検査できます。

```sml
fun even (n : int) : bool = if n = 0 then true else odd (n - 1)
and odd  (n : int) : bool = if n = 0 then false else even (n - 1)
```

`fun` の群はまず全部の署名を環境に入れ、それから本体を1つずつ見ます。Hindley-Milner
の単一化も、レベルも、一般化も要りません。推論があるのは `val x = e` の1箇所だけで、
それは「`e` の型をそのまま使う」以上のことをしません。

`nil` だけが例外で、どのレコード型にもなれるので文脈が要ります。

```sml
val a = nil            (* 型検査エラー: `a` needs a type annotation to hold `nil` *)
val a : point = nil    (* よい *)
```

---

## 2.2 レコードは公称的、配列は構造的

```sml
type p = { x : int } and q = { x : int }
```

`p` と `q` は**別の型**です。同じフィールドを持っていても混ざりません。一方
`int array` はどこに書いても `int array` です。

```python
def same(a: Type, b: Type) -> bool:
    match a, b:
        case RecordT(), RecordT():
            return a is b          # 名前で決まる = 同一性で決まる
        case ArrayT(), ArrayT():
            return same(a.elem, b.elem)
        case _:
            return type(a) is type(b)
```

レコードを公称にすると、生成のときに型名が要ります（`point { x = 1, y = 2 }`）。
そのぶん構文が少しうるさくなりますが、フィールドの並び順を型が決めてくれるので、
下げるときに「このフィールドは何番目か」が一意に決まります。実際、型検査は
`RecordLit` のフィールドを**宣言順に並べ替えて**から返します。後段はもう順序を
考えません。

再帰型と相互再帰型は、レコードの箱を先に作って後から中身を埋めることで通します。

```sml
type tree = { key : int, left : tree, right : tree }
type a = b array and b = { next : a }
```

---

## 2.3 逃げる変数

これがこの章の本題です。判定は本当に1行です。

```python
def var(self, e: ast.Var) -> Type:
    sym = self.lookup_val(e.name, e.span)
    ...
    if sym.depth < self.depth:
        sym.escapes = True
```

`sym.depth` はその変数を束縛した関数の深さ、`self.depth` はいま読んでいる場所の
深さ。**深さをまたいで読まれたら、その変数は逃げた**。

なぜそれで居場所が決まるのか。内側の関数は、外側の関数の変数に実行時に**静的リンクを
たどって**届きます。届く先はメモリでなければなりません —— レジスタは各活性化のもの
ではなく機械のものなので、たどれません。だから逃げた変数はフレームのスロットに置き、
逃げていない変数だけがレジスタ割り当ての対象になります（[3章](03-lower.md)）。

`emit -s ast` が答えを見せます。

```
$ uv run python -m wolv emit -s ast esc.wol
fun outer(n (escapes)) : int
  let : int
    var kept (escapes)
      int 1
    val plain
      int 2
    fun inner() : int
      + : int
        var kept : int
        var n : int
```

`kept` と仮引数 `n` は `inner` から読まれるので逃げました。`plain` は誰にも読まれて
いないので逃げていません —— レジスタに住めます。

判定が保守的すぎないことに注意してください。「内側の関数が存在するから全部逃げる」
ではなく、「実際に読まれた変数だけ」です。同じ `let` の中で、逃げる変数と逃げない
変数が隣り合います。

---

## 2.4 検査の規則

| 式 | 規則 |
|---|---|
| `+ - * / mod` | `int × int → int` |
| `^` | `string × string → string` |
| `< <= > >=` | `int` か `string` の同型どうし → `bool` |
| `= <>` | 互いに適合する型どうし。`unit` は比較できない |
| `andalso` `orelse` | `bool × bool → bool` |
| `if` | 条件は `bool`。`else` がなければ枝は `unit` |
| `while` `for` | 本体は `unit` |
| `break` | ループの中にあること |
| `a[i]` | `a` は配列、`i` は `int` |
| `r.f` | `r` はレコード、`f` はそのフィールド |
| `x := e` | `x` は代入可能で、型が一致すること |

`array (n, init)` と `length (a)` だけは多相的な扱いが要るので、呼び出しの検査に
特別扱いが1箇所あります。`array` の要素型は `init` の型から取ります。だから
`array (3, nil)` は「どのレコードか分からない」と断ります。

`break` の型は `unit` です。Tiger は「どんな型にもなる」としますが、ここでは
`if c then break` のような使い方に必要な範囲だけにしてあります。

---

## 2.5 何を後段に渡すか

型検査を過ぎた木には、次の3つが書き込まれています。

| 書き込み先 | 何 |
|---|---|
| `e.ty` | 各式の型。下げるときにレコードの大きさや文字列比較の判断に使う |
| `Var.sym`, `ValDecl.sym`, `Param.sym`, `For.sym` | 変数の実体（深さ・可変か・逃げたか） |
| `Call.sym` | 呼ぶ関数の実体（ラベル・深さ・組み込みか） |
| `Field.offset` | フィールドが何番目か |

下げるパスはもう名前を引きません。木に貼られた `sym` をたどるだけです。

---

## していないこと

- 多相はありません。`fun id (x : int) : int` と `fun id (x : string) : string` は
  別の関数です。
- 部分型も、型クラスも、モジュールもありません。
- 網羅性検査がありません（パターンマッチ自体がないので）。
- `val` の型注釈は検査にしか使いません。推論を助けるのは `nil` の場合だけです。

---

## 参考文献

- Andrew Appel, *Modern Compiler Implementation in ML*, 5章（型検査）と 6章
  （エスケープ解析とフレーム）.

---

## 実装の地図

| | |
|---|---|
| `types.py` | `Type`、`same`/`compatible`、`VarSym`、`FunSym` |
| `typecheck.py` | `Checker`。`var()` の3行がエスケープ解析 |
| `typecheck.BUILTIN_SIGS` | 標準ライブラリの署名 |
