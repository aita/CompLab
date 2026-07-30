# 10. 値 SSA を作る

ここから2つ目のバックエンドです。機械が `Flat` を走らせるのに対して、コンパイラは
同じ `Flat` から**静的単一代入形式**（SSA）を作ります。始点が同じなのは意図で、
そこまでで**モジュールもパターンも入れ子の関数も消えている**からです。

この章の主張は1行です。**[6章](06-join.md)の join point は、SSA の φ 関数でした。**

## 用語

| | |
|---|---|
| SSA | どの値もちょうど1箇所で定義される形 |
| vanilla SSA | 変数を `x₁`, `x₂` と版分けする、教科書の SSA |
| 値 SSA (value SSA) | 名前を持たず、命令そのものが値である SSA |
| 基本ブロック | 分岐のない命令の並び。1つの終端子で終わる |
| 終端子 (terminator) | ブロックの最後。次にどのブロックへ行くかを決める |
| φ 関数 | 合流点で「どの道から来たか」によって値を選ぶもの |
| ハッシュコンス | 同じものを2度作らず、既にあるほうを返すこと |

## 1. 同じ関数を、2つの形で

[6章](06-join.md)の `inline` です。左が Core、右が SSA。

```sml
fun inline b = "it is " ^ (if b then "yes" else "no")
```

```
$ skunk --dump-core tests/join.sk        $ skunkc --dump-ssa tests/join.sk
let inline = fn a1.21 : bool =>          func inline$3:
  let b.3 : bool = a1.21                   b0:
                                             v0 = param              ; a1.21
                                             v1 = const "yes"
                                             v2 = const "no"
                                             v3 = const "it is "
  join k (v : string) =                      switch v0 [true -> b2, false -> b1]
    let t.62 = ^("it is ", v)              b1:              ; preds b0
    ret t.62                                 jump b3
  switch b.3 of                            b2:              ; preds b0
  | true =>                                  jump b3
      jump k ("yes")                       b3:              ; preds b2 b1
  | false =>                                 v4 = phi [b2: v1, b1: v2]   ; v
      jump k ("no")                          v5 = prim ^ v3, v4          ; t.62
                                             ret v5
```

指で追えます。`join k (v)` が `b3` と `v4 = phi […]` に、`jump k ("yes")` が
「b2 から b3 への辺」と「φ の第1引数」に。木が graph になっただけです。

ダンプの `preds` は**先行ブロック**、つまりそのブロックへ来る辺の出どころで、
φ の引数はこの並びと位置で対応します。

`;` のあとは Flat の束縛名で、読むためのコメントです。SSA の側に名前はありません。

## 2. vanilla SSA と値 SSA — 名前があるか、ないか

SSA の教科書はこう始まります。プログラムには**変数**があり、1つの変数は何箇所からでも
代入される。それを**版に分ける** — `x` への代入ごとに `x₁`, `x₂` と名前を付け替え、
合流点では `x₃ = φ(x₁, x₂)` と書く。この、版分けした変数の SSA を
**vanilla SSA** と呼びます。Cytron らの論文も Appel も Muchnick もこれです。

1節の `inline` を版分けで書くと、こうなります。**これだけは手で書いたもの**で、この
処理系はこの形を作りません。

```
b0:
  b₁ = param
  if b₁ then b2 else b1
b1:
  v₁ = "no"
  goto b3
b2:
  v₂ = "yes"
  goto b3
b3:
  v₃ = φ(b2: v₂, b1: v₁)
  t₁ = "it is " ^ v₃
  return t₁
```

1節の出力と見比べてください。ブロックの形も φ の位置も同じで、**違うのは書かれている
ものの正体だけ**です。

違いは1つに尽きます。**オペランドが名前か、値そのものか。**

vanilla の `t₁ = "it is " ^ v₃` の `v₃` は名前で、何を指すかは表を引いて決まります。
値 SSA の `v5 = prim ^ v3, v4` の `v4` は φ が産んだ**その値**で、引くものがありません。

```ocaml
type value = {
  mutable vid : int;
  mutable op : op;
  mutable args : value list;   (* 名前ではなく、使っている値への参照 *)
  mutable home : block;
  mutable uses : int;
  origin : string;             (* もとの Flat の名前。印字用のコメント *)
}
```

ここから3つ落ちてきます。

**単一代入が、守る規則から表現の性質になる。** vanilla では「各版はちょうど1回代入
される」は*不変条件*です。パスが命令を複製したら新しい版を作らなければならず、忘れれば
壊れます。値 SSA では壊しようがありません。値が1箇所で定義されるのは、値が*その定義
そのもの*だからです。二重定義は書けません。

**def-use が別表ではなく辺になる。** vanilla で「この定義を使っているのは誰か」を知るには
名前から使用箇所への表を持ち、書き換えのたびに更新します。値 SSA では引数のリストが
そのまま使用の辺なので、表が古くなるということが起きません。だから使用回数は
維持せずに数え直せます。

```ocaml
(* 維持するのではなく、数え直す。パスが更新を忘れる余地をなくすため *)
let recount (f : func) =
  let all = List.concat_map (fun b -> b.phis @ b.values) f.blocks in
  List.iter (fun v -> v.uses <- 0) all;
  ... 各値の args と終端子をたどって +1 ...
```

**置き換えが1箇所になる。** ある計算を別の計算に取り替えるのは、vanilla では名前の
出現を全部書き換えることですが、値 SSA では使用辺をたどって差し替えることです
（LLVM が `replaceAllUsesWith` と呼ぶもの）。共通部分式除去も、`(演算, 引数の値)` を
鍵にしたハッシュ1つで済みます — 定数のハッシュコンス（3節）がその最小の例です。

失うものもあります。**番号は何も意味しません。** `v5` を見てもソースのどこから来たか
分からないので、`origin` を持って `; t.62` と註釈しています。vanilla の `v₃` が元の `v`
を残しているぶん、そこは読みやすい。

### 混同しやすい、別の軸

「φ を値にするか、ブロックの引数にするか」は**これとは独立の話**です。

| | φ が値 | ブロックが引数を取る |
|---|---|---|
| 版分けした変数（vanilla） | 教科書、Muchnick | — |
| 値 | LLVM、Go | Cranelift、MLIR、Swift SIL |

`block j(x): …` と `jump j(a)` と書く流儀（ブロック引数）は、値 SSA でも採れます。
ここは**値 SSA ＋ φ は値**という組み合わせで、φ を値にしたのは教科書の側に合わせた
からです。

そして[6章](06-join.md)の join point は、ちょうど**ブロック引数の側**の書き方です。
入力が Cranelift 寄りで、出力を教科書寄りにしている — 3節でやっている変換の一部は
その付け替えです。

### なぜここで値 SSA なのか

**版分けする変数がありません。** `Flat` の束縛は既に一意なので（[4章](04-core.md)の5節）、
「同じ名前への2回目の代入」というものが存在せず、vanilla の renaming は**何もしない
パス**になります。やることがないなら、名前ごと捨てたほうが得です。

そして後段が欲しがるものが、ちょうど値 SSA の落ちものです。DP による命令選択は
「使用回数が2以上の値」で DAG を木に切るので（[11章](11-dom.md)の8節）、その回数が
フィールド1つで手に入る形にしておきたい。

## 3. 生成アルゴリズム

`Flat` の木を1回歩くだけです。歩きながら「いま埋めているブロック」に値を積み、
終端子に出会ったらそのブロックを閉じます。

状態はこれだけです。

```ocaml
type state = {
  mutable next_value : int;
  mutable next_block : int;
  mutable blocks : S.block list;
  mutable names : S.value Map.t;             (* Flat の名前 -> 値 *)
  mutable joins : (string * S.block) list;   (* join の名前 -> ブロック *)
  mutable head : S.value list;               (* 入口に置くもの: 引数と定数 *)
  globals : (string, unit) Hashtbl.t;
}
```

`names` に**スコープの入れ子がない**のが目印です。Flat の束縛は一意なので
（[4章](04-core.md)の5節）1枚の表で足り、同じ理由でこの表が**そのまま単一代入**に
なっています。名前が1つなら値も1つです。

歩き方は形ごとに1行です。

| Flat | すること |
|---|---|
| `let x = rhs` | 値を1つ作って現在のブロックに積み、`names` に `x ↦ その値` |
| `join j (p…) = body in rest` | 新しいブロックを作り、`p` ごとに φ を置いて `joins` に登録 |
| `jump j (a…)` | `j` のブロックの先行ブロックに現在のブロックを足し、各 φ に引数を1つ足し、終端子を `Jump` に |
| `switch a of …` | 枝ごとに新しいブロックを作ってそこへ歩き、終端子を `Switch` に |
| `ret` / `tailcall` / `fail` | 終端子を置いて、そのブロックは終わり |

### 継続を本体より先に歩く

`join` のところだけ、順序が効きます。

```ocaml
| F.Join (j, ps, body, rest) ->
    let jb = new_block st in
    jb.S.phis <- List.map (fun p -> mk st ~origin:p jb S.Phi) ps;
    List.iter2 (fun p v -> bind st p v) ps jb.S.phis;
    st.joins <- (j, jb) :: st.joins;
    go st entry blk rest;      (* 継続。jump はこの中にある *)
    go st entry jb body        (* 本体 *)
```

φ の引数は「その join へ跳ぶ場所」から集まります。跳ぶのは継続の側なので、継続を先に
歩けば、本体に着いたときには φ の引数がもう揃っています。**φ を埋め直す2周目が
要らない**のはこの順序のおかげです。

引数は先行ブロックと**位置で**対応します。両方を同時に足すので、ずれようがありません。

```ocaml
let goto (from : S.block) (target : S.block) args =
  target.S.preds <- target.S.preds @ [ from ];
  List.iter2 (fun (p : S.value) a -> p.S.args <- p.S.args @ [ a ]) target.S.phis args;
  from.S.term <- S.Jump target
```

### 素直でないところ、その1 — 定数

Flat のオペランドはアトムで、リテラルはその場に書かれています。値 SSA では何もかもが
値なので、リテラルは `Const` 値になります。ではどのブロックに置くか。

**入口ブロック**です。入口はすべてのブロックを支配する（[11章](11-dom.md)）ので、
どこから使っても「定義が使用を支配する」が成り立ちます。ついでにハッシュコンスして
あるので、プログラム中の `0` はいくつのブロックが使っても1つの値です。

```ocaml
let constant st entry (c : S.const) =
  let same v = match v.S.op with S.Const c' -> c' = c | _ -> false in
  match List.find_opt same st.head with
  | Some v -> v
  | None -> emit_head st entry (S.Const c)
```

入口に積むものだけ別のリスト (`head`) に貯めてあるのは、**あとから作られた定数も
入口の先頭側に入る**ようにするためです。そうしないと、入口ブロックの中で「定義より前で
使う」ことが起こりえます。

### 素直でないところ、その2 — 循環する定義

```sml
fun parity n =
  let fun even 0 = true | even k = odd (k - 1)
      and odd 0 = false | odd k = even (k - 1)
  in even n end
```

`even` は `odd` を捕獲し、`odd` は `even` を捕獲します。**SSA は定義の循環を書けません** —
どちらを先に書いても、もう片方がまだない。

```
$ skunkc --dump-ssa parity.sk
func parity$1:
  b0:
    v0 = param                             ; a1.19
    v1 = mkclos even$2, 1                  ; even
    v2 = mkclos odd$3, 1                   ; odd
    setcap 0, v1, v2
    setcap 0, v2, v1
    tailcall v1, v0
```

そこで**確保と充填を2つの操作に割ります**。まず両方の閉包を作り、それから中身を書く。
`mkclos` は大きさだけ決まった閉包を作る演算で、`setcap` は結果を持たない文です。

[7章](07-closure.md)の3節で機械が実行時にやっていたことと同じですが、機械のほうは
「そう書くと楽」で、ここでは**形がそれを強制します**。SSA の性質が実装を決めた、
数少ない場所です。

### 最後に番号を振り直す

ブロックを逆後行順（[11章](11-dom.md)の3節）に並べ替えて、値に上から順に番号を振ります。
値は番号で識別されるので**意味は何も変わりません** — ダンプが上から下へ読めるように
なるだけです。

```ocaml
let renumber (f : func) =
  let rpo = reverse_postorder f in
  f.blocks <- rpo @ List.filter (fun b -> not (List.memq b rpo)) f.blocks;
  List.iteri (fun i b -> b.bid <- i) f.blocks;
  ...
```

できたものが本当に SSA になっているかは、[11章](11-dom.md)で確かめます。

## していないこと

- **最適化パスがありません。** 定数畳み込みも CSE も DCE も、値 SSA なら書きやすい
  はずですが、まだありません。
- **メモリを SSA に載せていません。** ブロックは値の順序つきリストなので、副作用の
  順序はリスト順です。載せる流儀（Go の mem 値）もありますが、教科書はこちらです。
- **関数内にループがありません。** join point は自分より外側にしか跳べないので、
  関数の CFG は DAG です。ループは末尾呼び出しとして現れます。
- **到達しないブロックがありません。** 作られないので、消す必要もありません。

## 参考文献

- Ron Cytron, Jeanne Ferrante, Barry Rosen, Mark Wegman, Kenneth Zadeck,
  "Efficiently Computing Static Single Assignment Form and the Control
  Dependence Graph", *TOPLAS* 13(4), 1991. SSA の出典。
- Richard Kelsey, "A Correspondence between Continuation Passing Style and
  Static Single Assignment Form", *IR* 1995.
- Andrew Appel, "SSA is Functional Programming", *SIGPLAN Notices* 33(4), 1998.
  この章の主張の出典。φ は関数の引数だという話。
- Fabrice Rastello, Florent Bouchez Tichadou (eds.), *SSA-based Compiler
  Design*, Springer, 2022.
- Steven Muchnick, *Advanced Compiler Design and Implementation*, 1997, §8.11。
  版分けした変数で書く vanilla SSA の記述（2節）。
- LLVM Language Reference（`phi` 命令）と Cranelift IR Reference（block
  parameters）。2節の表の2列が、それぞれの語彙で読めます。

## 実装の地図

| ファイル | 何が |
|---|---|
| `src/compiler/ssa.ml` | `value`/`block`/`func`・`recount`（2節）、`reverse_postorder`・`renumber`（3節）、印字 |
| `src/compiler/build.ml` | `state` と `go`（3節）、`goto`（3節）、`constant`（3節）、`Fix` の確保と充填（3節） |
| `src/compiler/skunkc.ml` | コマンドライン |

---

[← 9. 言語リファレンス](09-language.md) ・ [11. 支配木 →](11-dom.md)
