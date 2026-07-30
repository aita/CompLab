# 7. クロージャ変換

`closure.ml` の話です。ラムダは「コード」と「書かれた場所から必要な値」の2つでできて
います。このパスがそれを分けます。抜けたあと、関数の中に関数はありません。

面白いのは**変換しないもの**のほうです。

## 用語

| | |
|---|---|
| 自由変数 | その項の中で使われていて、その項が束縛していない変数 |
| 捕獲 (capture) | 自由変数の値をクロージャに写し取ること |
| コードブロック | 引数1つを取る、入れ子でない関数本体 |
| 巻き上げ (hoisting) | 内側の関数定義をプログラムの先頭へ出すこと |
| グローバル | トップレベルの束縛。機械が1つの表で持つので捕獲しない |

## 1. ラムダを2つに割る

```ocaml
and make_closure st name param body =
  let free = Set.diff (Set.remove param (C.free_vars body)) st.globals in
  let caps = Set.elements free in
  let label = fresh_label name in
  let inner = conv st body in
  let body =
    List.fold_right (fun (x, i) rest -> F.Let (x, F.Capture i, rest))
      (List.mapi (fun i x -> (x, i)) caps) inner
  in
  st.codes <- st.codes @ [ { F.c_label = label; c_param = param; c_body = body } ];
  (label, List.map (fun x -> F.AVar x) caps)
```

自由変数から引数とグローバルを引いたものが捕獲するものです。コードブロックの先頭で
捕獲を**もう一度同じ名前に束縛し直す**ので、本体そのものは書き換えずに済みます。

```sml
fun adder n = fn m => n + m
```

```
$ skunk --dump-flat tests/flat.sk
code t.61$2 (x.12) =
  let n.2 = capture 0
  let m = x.12
  let t.60 = +(n.2, m)
  ret t.60

code adder$1 (a1.19) =
  let n.2 = a1.19
  let t.61 = closure t.61$2 [n.2]
  ret t.61
```

`closure t.61$2 [n.2]` が「このコードと、この値」です。`capture 0` がそれを読み返す
側。ラベルの `$2` は、ソースの名前と衝突しないようにするためです。

## 2. 捕獲しないもの

### 引数

引数は別の道で来ます。

### グローバル

トップレベルの束縛は機械が1つの表で持っています。捕獲すると、束縛される前の値を
写し取ってしまうことにもなります。

これが再帰にとって都合がよい。トップレベルの `fun fact n = ... fact ...` は
`fact` を捕獲せず、呼ぶたびにグローバル表を引きます。表に入るのはブロックが終わった
あとですが、呼ばれるのはさらにあとなので、間に合います。

```
-- val adder : int -> int -> int
let adder = closure adder$1 []
ret adder
```

捕獲リストが空なのはそのためです。

### join point

**これが本題です。**

```ocaml
| C.Join (j, ps, body, rest) ->
    F.Join (j, List.map fst ps, conv st body, conv st rest)
```

自由変数を数えもしません。数える必要がないからです。join point へ跳べるのは、それを
定義したブロックの内側からだけ（[6章](6-join.md)の4節）。跳んだ時点でその値はまだ
そこにあります。

自由変数の計算（`core.ml` にあります）のほうも、join point を素通しします。

```ocaml
| Join (_, ps, body, rest) ->
    let bound = List.map fst ps in
    Vars.union
      (List.fold_left (fun s x -> Vars.remove x s) (free_vars body) bound)
      (free_vars rest)
| ...
| Jump (_, ats) -> atoms_var ats
```

`Jump` が寄与するのは**引数だけ**です。ラベル名は変数ではありません。

出力で見るとこうなります。

```
code size$6 (a1.21) =
  let xs.13 = a1.21
  join k (v) =
    let t.70 = +(1, v)
    ret t.70
  switch xs.13 of
  | nil =>
      jump k (0)
  | :: =>
      ...
      jump k (t.69)
```

`join k` はコードブロックの外に出ていません。`size$6` の中にあります。これが
「ラベルとクロージャを区別する」ことの目に見える意味です。

## 3. 相互再帰の閉包

```sml
fun even 0 = true | even n = odd (n - 1)
and odd 0 = false | odd n = even (n - 1)
```

`even` は `odd` を捕獲し、`odd` は `even` を捕獲します。どちらも相手より先には作れません。

Flat には専用の形があります。Core の `Fix` がそのまま来たものです。

```ocaml
| Fix of (string * rhs) list * block      (* rhs はどれも Closure *)
```

機械が、まず全部のクロージャを（捕獲は空のまま）作って名前に束縛し、そのあとで捕獲を
埋めます。

```ocaml
let made = List.map (fun (name, F.Closure (label, caps)) ->
    let base = alloc w (max (List.length caps) 1) in
    (name, VClos (label, base, List.length caps), base, caps)) defs in
let env = List.fold_left (fun env (name, v, _, _) -> bind w env name v) st.env made in
List.iter (fun (_, _, base, caps) ->
    List.iteri (fun i a -> set w (base + i) (atom w env a)) caps) made;
```

番地を先に確保してから中身を書く、という順序です。ストアがあるので、これが「後から
埋める」の自然な書き方になっています（[8章](8-cesk.md)）。

トップレベルの相互再帰はグローバル表を経由するので、捕獲は空になります。

```
fix even = closure even$1 []
and odd = closure odd$2 []
```

そして**再帰していない関数はここに来ません**。`fun` は SML の綴りでは常に再帰的ですが、
自分の名前が本体に出てこなければ `Fix` にはならず、ふつうの `Let` になります
（[4章](4-core.md)の6節）。`adder` の行が `let` なのはそのためです。

## 4. 型はここで消える

Flat に型はありません。

```
$ skunk --dump-flat tests/flat.sk
code twice$3 (a1.20) =
  let f.23 = closure f.23$4 [a1.20]
  ret f.23
```

[4章](4-core.md)で型を残したのは、パターンマッチのコンパイルが必要としたからでした。
それが済んだあと、型に決めさせることは何も残っていません。値の表現は型に依らず一様で、
機械は `VInt` と `VCon` を実行時に見分けます。

型を最後まで持つ処理系（GHC の Core、TIL、FLINT）は、型に**表現を決めさせる**ため、
あるいは最適化の正しさを検査するために持ちます。ここはどちらもしていません。

## していないこと

- **既知関数の直接呼び出しがありません。** `Fix` で束縛した関数を飽和して呼ぶときも、
  クロージャを取り出してから呼びます。ラベルへ直接跳べる場合を見分ければ1段減らせます。
- **捕獲の共有がありません。** 同じ環境を捕獲する複数のクロージャが、それぞれ自分の
  ブロックを確保します。共有すればヒープが減ります（Shao–Appel のクロージャ変換の
  主題）。
- **ラムダ持ち上げ (lambda lifting) をしていません。** 自由変数を引数にしてしまう
  やり方もあり、そちらは環境を確保しませんが、呼び出し側が全部見えている必要があります。
- **捕獲の順序は名前順です。** `Set.elements` の順。決定的でありさえすればよいので。
- **未使用の捕獲を落としません。** 自由変数の計算がそのまま捕獲リストなので、実際には
  落ちています（使っていない変数は自由変数ではないので）。

## 参考文献

- Andrew Appel, *Compiling with Continuations*, 1992, 10章。クロージャ変換の教科書的な
  記述。
- Zhong Shao, Andrew Appel, "Space-Efficient Closure Representations", *LFP* 1994.
  捕獲の共有と、空間漏れ。
- Thomas Johnsson, "Lambda Lifting: Transforming Programs to Recursive Equations",
  *FPCA* 1985. もうひとつのやり方。
- Maurer et al., "Compiling without Continuations", *PLDI* 2017, §3。join point を
  クロージャ変換しない、という判断の出典。

## 実装の地図

| ファイル | 何が |
|---|---|
| `src/closure.ml` | `make_closure`（1節）、`conv_closure`（ラムダを閉じる唯一の場所）、`conv` の `C.Join`（2節）、`conv` の `C.Fix`（3節）、`program`（グローバルの受け取り） |
| `src/flat.ml` | `Closure`/`Capture`/`Fix`/`code`（1・3節）、`program_to_string`（ダンプ） |
| `src/machine.ml` | `enter`（クロージャに入る）、`F.Fix`（3節）、`eval` の `F.Closure`/`F.Capture` |
| `src/core.ml` | `free_vars`/`free_rhs`/`free_tail`（2節）。自由変数は IR のものなので IR の側に置いてあります |

---

[← 6. join point](6-join.md) ・ [8. CESK マシン →](8-cesk.md)
