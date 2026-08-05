# 11. Flat から LLVM IR へ

`lower.ml` は 500 行あり、そのうち半分は「LLVM が知りようのないこと」を書いています。
残りの半分は形の変換で、変換表は6行です。

```
コードブロック  ->  関数と入口ブロック
let             ->  埋めているブロックに命令を1つ足す
join            ->  新しいブロック。引数は φ 節点
jump            ->  br と、各 φ への (値, 出どころ) 1組
switch          ->  switch と、腕ごとに新しいブロック
tailcall        ->  musttail call と、その直後に要る ret
```

| | |
|---|---|
| 基本ブロック | 分岐で終わる命令の直線。LLVM の関数はこれの集まり |
| φ 節点 (phi) | ブロックの先頭で「どの先行ブロックから来たか」で値を選ぶ命令 |
| 終端命令 | ブロックを終える命令。`ret` `br` `switch` `unreachable` |
| `musttail` | 末尾呼び出しが必ずジャンプになることを要求する印 |
| verifier | LLVM の検査。支配・φ の数・`musttail` の形を見る |

## 1. φ を置く仕事が存在しない

SSA を作る教科書的な手順は「支配辺境を計算して、そこに φ 関数を置き、変数を改名する」
です。この処理系はそれを一度も走らせません。**引数を持つ join point が、φ 節点を持つ
ブロックそのもの**だからです。

```sml
fun f (x, y) = (case x of 1 => y | 2 => y + 1 | _ => y + 2) + 100
```

`--dump-flat` は join point を見せます。`case` の結果を使う人がいるので、その続きが
ラベルになりました（[6章](06-join.md)）。

```
  join k (v) =
    let t.62 = +(v, 100)
    ret t.62
  switch x.12 of
  | 1 =>
      jump k (y)
  | 2 =>
      let t.60 = +(y, 1)
      jump k (t.60)
  | _ =>
      let t.61 = +(y, 2)
      jump k (t.61)
```

`--emit-llvm -O0` は同じものを LLVM の語彙で見せます。

```llvm
"join.k":
  %"v" = phi i64 [ %_4, %"arm" ], [ %_6, %"arm.0" ], [ %_8, %"default" ]
  %_9 = add i64 %"v", 201
  %_10 = sub i64 %_9, 1
  ret i64 %_10
```

`join k (v)` が `join.k` に、`v` が `phi` に、3つの `jump` が3つの incoming になった。
それだけです。名前が引用符に入っているのは、front end が作った形のまま出すためです
（[10章](10-llvm.md)の5節）。

順序にひとつ約束があります。**join の継続を、本体より先に下ろします。**

```ocaml
| F.Join (j, ps, body, rest) ->
    let entered = here c in
    let jb = block_named c ("join." ^ j) in
    let phis = List.map (fun p -> Ir.phi g jb ~ty:Ir.i64 ~name:p) ps in
    ...
    Ir.position g entered;
    block c rest;          (* jump はこの中にある *)
    Ir.position g jb;
    block c body
```

`jump` は継続の側にあるので、継続を先に歩けば、本体を書き始めるころには φ は自分の
incoming を全部知っています。φ は空のレコードとして作られ、`jump` に出会うたびに1組ずつ
増えて、関数が終わったときに1行になります — テキストは一度書いたら書き換えられないので、
ブロックはそこまで溜められます（[10章](10-llvm.md)の6節）。

支配木は作りません。「どの使用も定義に支配されているか」は LLVM の verifier が答える
質問で、`.ll` を読ませればそれを通ります。`tests/dune` の `verify.out` は何も比較
しません — 全部のプログラムで clang が黙ることが試験です。

## 2. 末尾呼び出しは希望ではない

この言語には**ループがありません**。join point は外側にしか跳べないので、関数の
制御フローは非巡回で、繰り返しは全部末尾呼び出しです。

```sml
fun loop (n, acc) = if n = 0 then acc else loop (n - 1, acc + n)
```

これが跳ばずに積まれたら `loop (20000000, 0)` は落ちます。LLVM の sibling call
最適化は `-O1` から走りますが、`-O0` では走りません。だから頼むのではなく**要求します**。

```llvm
  %_23 = musttail call i64 %_22(i64 %_19, i64 %_15)
  ret i64 %_23
```

`musttail` は守れなければ翻訳を失敗させる印です。守れる条件のうち効いているのは
「呼び出し元と呼び出し先の型が一致すること」で、この処理系はそれを設計で満たしています
— **どのコードブロックも `i64 (i64, i64)`** です。クロージャと引数を取って値を返す。

同じ1つの型が3つのことを同時に可能にしています。

- クロージャから読んだ語を関数として呼べる（型が1つしかないので迷わない）
- `musttail` が合法になる（呼び出し元と呼び先が同じ型）
- 束縛の本体も同じ型で書ける（誰も呼ばないが、末尾呼び出しは含む）

`-O0` の実行ファイルで2000万回まわしても、スタックは1フレームのままです。

## 3. 値は全部 `i64`

整数も塊の番地も `i64` です。φ が「あるときは整数、あるときはポインタ」とは言えない以上、
どちらでもある1つの型が要ります。だからフィールドを読むのは `inttoptr` と
バイト単位の `getelementptr` になります。

```llvm
  %_0 = inttoptr i64 %arg to ptr
  %_1 = getelementptr i8, ptr %_0, i64 8
  %_2 = load i64, ptr %_1, align 8
```

`inbounds` を付けていません。記述子は語 −1 にあり、それは値が指している塊の**外**だから
です。

```ocaml
let word t v i =
  let p = Ir.inttoptr t.ir v in
  if i = 0 then p else Ir.gep t.ir p (8 * i)
```

同じ `inttoptr` が何度も出るのは `-O0` の話で、`-O2` の GVN が畳みます。ここで畳まないのは、
畳んでよいかが支配の質問だからです — それを聞ける道具を持っている側に任せます。

## 4. case は3種類ある

`switch` の腕の鍵は3つあります（[5章](05-matching.md)）。

**整数** はタグ付きのまま比較します。`2n + 1` は1対1なので、`case n of 0 =>` は
`i64 1` の case です。

**構成子** はタグを比較します。タグは記述子の中にあるので、値から1語戻って記述子を読み、
その語5を読みます。

```llvm
  %_1 = getelementptr i8, ptr %_0, i64 -8      ; 記述子へ
  %_2 = load i64, ptr %_1, align 8
  %_3 = inttoptr i64 %_2 to ptr
  %_4 = getelementptr i8, ptr %_3, i64 40      ; その中のタグへ
  %_5 = load i64, ptr %_4, align 8
  switch i64 %_5, label %"nomatch" [ i64 0, label %"arm" i64 1, label %"arm.0" ]
```

小さい整数の `switch` なので、腕が増えれば LLVM が跳び先表を作るかどうかを決めます。
この処理系はそれを決めません。

**文字列** だけは `switch` になりません。文字列の等値はバイトの走査なので、比べるものが
ありません。腕は呼び出しと分岐の鎖になります。

## 5. `true` は塊である、という問題

`bool` は構成子が2つの直和型で、`if` は `case` の書き方のひとつです（[0章](00-pipeline.md)
の4節）。つまり `n = 0` は**塊を作る**演算で、そのすぐ後ろの `case` は作った塊から記述子を
たどってタグを読み直します。素直に下ろすと、`if n = 0 then` は

1. 比較して `i1` を得る
2. `i1` から `true` か `false` の番地を選ぶ
3. その番地から1語戻って記述子を読む
4. 記述子から タグを読む
5. タグで分岐する

になります。1で分かっていたことを、3回のメモリ参照で聞き直しています。記述子を
`constant` にすれば LLVM が畳めますが、それは別の理由でできません
（[12章](12-abi.md)の6節）。

そこで `lower.ml` は比較が作った `i1` を名前ごと覚えておきます。

```ocaml
  (* For a name a comparison bound: the `i1` the comparison actually produced,
     beside the `true` or `false` block it had to be turned into. *)
  bits : (string, Ir.value) Hashtbl.t;
```

`case` がその名前を `bool` の構成子で分けるなら、`i1` のほうを `switch` します。

```llvm
"done":
  %"bit" = phi i1 [ %_7, %"fast" ], [ %_9, %"slow" ]
  %_10 = select i1 %"bit", i64 <true の番地>, i64 <false の番地>
  switch i1 %"bit", label %"nomatch" [ i1 1, label %"arm" i1 0, label %"arm.0" ]
```

塊のほうを作る `select` は残しますが、誰も読まなければ DCE が消します。読む人がいる
とき — `val b = x < y` のように `bool` が値として使われるとき — は残ります。**どちらか
を選ばずに両方書いて、要らないほうを消してもらう**のが、最適化器を持っている側の書き方
です。

`fib` のアセンブリで、この節の前後はこうなります。

```
  movq	$skunk_true_blk+8, %rax                ┐ 塊を選び
  movq	-8(%rax), %rax                         │ 記述子を読み
  movq	40(%rax), %rax                         │ タグを読み
  testq	%rax, %rax                             ┘ 分岐する
```

```
  cmpq	$5, %rbx
  jl	.LBB31_4
```

## 6. `Fix` — 互いを持つクロージャ

`Fix` は互いを捕獲するクロージャの組です。SSA では書けません — 定義の輪をどの順に
書いても、まだ無いものを使うことになります。

答は「先に全部確保して、後から埋める」です。

```ocaml
let made = List.map (fun (name, F.Closure (label, caps)) ->
    let cl = alloc_closure c label (List.length caps) in
    Hashtbl.replace c.names name cl; (cl, caps)) defs in
List.iter (fun (cl, caps) -> fill_closure c cl caps) made
```

クロージャは `Let` のときも同じ2段で作ります。捕獲は確保より前に計算しなければならず
（[13章](13-gc.md)）、そうすると再帰の場合との違いは「間に何が挟まるか」だけになるから
です。

## 7. 収集器のために書いていること

`skunk_alloc` は呼び出しで、その中で回収が起きることがあります。だから確保をまたいで
生きていなければならない値は、LLVM から見ても生きていなければなりません。

```ocaml
| F.Record fs ->
    let ls = List.map fst fs in
    (* The fields are computed before the allocation is asked for, because the
       allocation may collect and the collector has to be able to see them. *)
    let vs = List.map (fun (_, a) -> atom c a) fs in
    let r = Lay.alloc c.t (Lay.record_desc c.t ls) (List.length vs) in
    List.iteri (fun i v -> Lay.set_field c.t r i v) vs;
```

フィールドの値は確保の**前**に計算されて、確保の**後**に使われます。LLVM は呼び出しを
またいで生きる値を callee-saved レジスタかフレームに置くしかなく、収集器はその両方を
見ます。順序を逆に書くと、確保の時点でその値がまだ「これから計算されるもの」になり、
どこにも無いことがありえます。

これは規約であって、検査されません。`gc.sk` が3ヒープ分のごみを作って回るのが、
守れているかを聞く唯一の場所です。

## 8. していないこと

- **インライン展開がありません。** 呼び出しはどれもクロージャ越しなので、`lower.ml` に
  「呼び先が誰か」は分かりません。分かる場所はクロージャ変換の**前**で、そこには
  このバックエンドは居ません。何を失っているかは[14章](14-opt.md)で測ります。
- **`Array.sub` が呼び出しのままです。** 実行時ライブラリの関数を1つ呼びます。境界検査を
  展開して `load` にすることはできますが、そのためには「この呼び出しが `Array.sub`
  である」と言える誰かが要ります。同じ理由です。
- **real がありません。** `AReal` に出会うと翻訳を断ります。値の表現が決まっていないから
  で、決めれば済む話です（[12章](12-abi.md)の6節）。
- **`switch` の腕の順序を選んでいません。** Flat の順です。頻度を知らないので、選ぶ根拠が
  ありません。

---

[← 10. LLVM の呼び方](10-llvm.md) ・ [12. ABI リファレンス →](12-abi.md)
