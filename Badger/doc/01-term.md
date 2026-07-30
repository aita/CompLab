# 1. 項と束縛とトレイル — `term.ml`

Prolog のデータ構造は項だけで、変数は「まだ決まっていない項」です。**決めることと、決めたのを
取り消すこと**の両方を、可変セル1つとスタック1本で持ちます。この章はその2つと、その上に載る
比較の話です。

## 1. 項は5つ

```ocaml
type term =
  | Atom of string
  | Int of int
  | Float of float
  | Var of var
  | Struct of string * term array
  | Local of int

and var = {
  v_id : int;
  mutable v_value : term option;   (* None のあいだが未束縛 *)
}
```

リストは項です。`[a,b]` は `'.'(a,'.'(b,[]))` で、空リストはアトム `[]` です。専用の
コンストラクタは持ちません。

**アリティ0は必ず `Atom` で、`Struct (f, [||])` とは書きません。** 1つの項に2通りの表現が
あると、比較と標準順序がそれを両方考えなければならなくなります。`Term.struct_` がその不変条件を
守る唯一の入口です。

`Local` は6つめですが、実行時の項には現れません。格納された節の中で「この節の i 番目の変数」を
表すためだけにあり、[4章](04-db.md)の話です。単一化や印字に `Local` が届いたらそれは実装の
バグなので、`Term.bug` で落とします — プログラムのエラーではないので、Prolog の例外にはしません。

## 2. 束縛はセルへの代入、取り消しはスタックからの pop

```ocaml
let trail : var Dynarray.t = Dynarray.create ()
let mark () = Dynarray.length trail

let bind v t =
  v.v_value <- Some t;
  Dynarray.add_last trail v

let undo_to m =
  while Dynarray.length trail > m do
    let v = Dynarray.pop_last trail in
    v.v_value <- None
  done
```

これで全部です。**束縛したセルを片っ端からトレイルに積み、巻き戻しはマークまで pop して
セルを空にする。** マークは整数1つで、これが WAM の選択点が覚えているものと同じものです。

`deref` は束縛の鎖を末端までたどります。鎖は縮めません（union-find の経路圧縮に相当する
ことをしない）。縮めると巻き戻しのときに「誰が誰を指していたか」を復元できなくなるからです。

## 3. 単一化は後始末をしない

```ocaml
let rec unify a b =
  match (deref a, deref b) with
  | Var v, Var w when v == w -> true
  | Var v, t | t, Var v -> bind v t; true
  | Atom x, Atom y -> String.equal x y
  | Int x, Int y -> x = y
  | Float x, Float y -> Float.equal x y
  | Struct (f, xs), Struct (g, ys) ->
      String.equal f g && Array.length xs = Array.length ys && unify_args xs ys 0
  | _ -> false
```

**失敗した単一化は、途中まで作った束縛をトレイルに置いたまま返ります。** `f(X,2)` と `f(1,3)`
なら、`X = 1` が積まれてから第2引数で失敗します。

掃除しないのは、掃除する人が必ずいるからです。**選択肢を出す構文はどれも、次の候補を試す前に
自分のマークまで巻き戻します** — 節を順に試す `Solve.predicate`、`;` の2つの枝、`between/3` の
反復。マークはスタックなので、外側のマークまで巻き戻せば内側の分も一緒に消えます。

```
$ echo '(f(X,2) = f(1,3) ; true), var(X).'
true.                    ← ; の右の枝に入る前に X の束縛は消えている
```

この分業のおかげで `unify` に例外安全な後始末の経路が要らず、代わりに「選択肢を出すものは
巻き戻す」という不変条件が1つ増えます。WAM が選択点とトレイルで強制しているのはまさにこれです。

## 4. occurs check は既定で切ってある

```
$ echo 'X = f(X), atom(X).'
false.
$ echo '\+ unify_with_occurs_check(X, f(X)).'
true.
```

`X = f(X)` は成功して、`X` は自分を含む循環項になります。項を1つ束縛するたびに相手の項を
全部歩くのは高すぎるので、どの Prolog も既定では検査しません。`unify_with_occurs_check/2` と
`set_prolog_flag(occurs_check, true)` で入れられます。

作れてしまう循環項は、印字も比較もできません。ライタも `compare_terms` も再帰なので、
**スタックを溢れさせて止まります**（トップレベルはそれを `ERROR: stack overflow` として
報告します）。循環項を扱うと決めるなら、印字側に「訪問済み」の表が必要になります。

## 5. 標準順序 — 変数 @< 数 @< アトム @< 複合項

`compare_terms` はこの順序を実装します。`sort/2`・`msort/2`・`keysort/2`・`@<` と、
[9章](09-library.md)の `bagof/3` の証人のまとめ上げが全部これに乗っています。

```
$ echo 'sort([b,1,a,f(x),1.0,"s"], L).'
L = [1.0,1,a,b,f(x),[115]].
```

`1.0` が `1` より前にいます。**値が等しい浮動小数点数と整数では、浮動小数点数が先** という
規則です（"s" は既定で符号のリストなので、複合項として最後に来ています）。

```
$ echo 'compare(O, 1, 1.0).'
O = >.
```

これは `is/2` の比較とは別物です。算術の `=:=` は値だけを見るので `1 =:= 1.0` は真ですが、
標準順序は**項として区別できるものを区別する**ので `1 == 1.0` は偽です。

複合項どうしは**アリティが先、次に名前、それから引数を左から**です。名前より先にアリティを
見るので `f(a,b) @> g(a)` になります。

```
$ echo 'compare(O, f(a,b), g(a)).'
O = >.
```

変数どうしは `v_id` — 生成順の連番 — で比べます。ISO は「実装依存だが安定した順序」しか
要求していません。

## 6. 項を歩く3つ

**`copy_term`** は変数だけを付け替えます。同じ変数が2回出てきたら、コピーでも同じ1つの変数に
なります。

```
$ echo 'T = f(A,B,A), copy_term(T, C), writeq(C), nl.'
f(_G345,_G346,_G345)     ← 1番目と3番目が同じ
```

`findall/3` は解が見つかるたびにテンプレートをこれでコピーします。**コピーしてからトレイルを
巻き戻す**ので、集めたものは巻き戻しの影響を受けません。

**`term_variables`** は深さ優先・左から右・初出優先で変数を集めます。順序まで規定されている
述語です。

```
$ echo 'term_variables(f(A, g(B), A, C), Vs).'
Vs = [A,B,C].
```

**`variant`**（`=@=`）は「変数の1対1の付け替えで一致するか」です。2方向の対応表を持って歩き、
両方向で一貫していることを要求します。

```
$ echo 'f(_,_) =@= f(_,_).'
true.
$ echo 'f(A,A) =@= f(_,_).'
false.                   ← 左は2つが同じ、右は違う。付け替えでは一致しない
```

`bagof/3` が証人をまとめるのにこれを使います。`==` ではなく `=@=` なのは、`findall/3` が
コピーを返すので、同じ証人が別の変数として出てくるからです。

## 7. エラーは項である

```ocaml
let throw formal context = raise (Prolog_error (error_term formal context))
let instantiation_error who = throw (Atom "instantiation_error") (context_atom who)
let type_error kind culprit who = throw (Struct ("type_error", [| Atom kind; culprit |])) (context_atom who)
```

ISO のエラーはどれも `error(Formal, Context)` という項で、`catch/3` がそれを捕まえるのは
ただの単一化です。だから OCaml 側は例外1つ（`Prolog_error of term`）しか持ちません。

```
$ echo 'catch(X is a+1, error(E, C), true).'
E = type_error(evaluable,a/0),
C = 'is/2'.
```

`Context` に入れているのは述語指示子の文字列です。ISO は実装依存としているところで、これが
あるとエラーメッセージが「どの組み込み述語が文句を言っているか」を言えます。

## していないこと

**多倍長整数がありません。** `Int of int` は OCaml のネイティブ整数、つまり63ビットです。
`2^62` を超えると黙って巻きます。`zarith` を足せば済む話ですが、それは「Prolog を作る」
とは別の作業なので入れていません。

**属性つき変数がありません。** `var` にフックを1つ足せば `freeze/2` や CLP(FD) の足場に
なりますが、束縛の側（`bind`）に「フックが付いていたら起こす」判断が入り、`undo_to` にも
対称の処理が要ります。トレイルが「セルの列」でなく「巻き戻し操作の列」になる変更で、
この処理系はそこまで行っていません。

**セルの世代管理がありません。** WAM は「選択点より新しい変数はトレイルに積まなくてよい」
（どうせ選択点ごと捨てられるから）という最適化をします。それには変数に生成時のヒープ位置が
必要で、ここでは変数が OCaml のヒープに散らばっているので比較ができません。全部積んでいます。

## 参考文献

- A. Colmerauer, [*Prolog in 10 figures*][fig], CACM 28(12), 1985。項と単一化を、この
  順序で図にしたもの。
- H. Aït-Kaci, [*Warren's Abstract Machine: A Tutorial Reconstruction*][wam], MIT Press
  1991（[PDF][wam-pdf]）。§2.3 が束縛のトレイルと、上の「していないこと」の3つめ
  — 条件つきトレイル — の説明です。
- ISO/IEC 13211-1:1995, §7.2 が標準順序、§7.3 が単一化。§5 が `error/2` の形。

[fig]: https://doi.org/10.1145/4547.4553
[wam]: https://mitpress.mit.edu/9780262510585/
[wam-pdf]: http://wambook.sourceforge.net/wambook.pdf

## 実装の地図

| | |
|---|---|
| `term.ml` 9–25行 | `term` と `var`。`Local` の役割はここのコメント |
| `term.ml` 32行 | `struct_` — アリティ0は `Atom`、という不変条件の入口 |
| `term.ml` 43行 | `deref` — 鎖をたどる。縮めない |
| `term.ml` 50–61行 | トレイル。`mark`・`bind`・`undo_to` の3つで全部 |
| `term.ml` 73–91行 | ISO のエラー項を作る7つ |
| `term.ml` 97–116行 | `unify`。後始末をしない理由は114行のコメント |
| `term.ml` 118–142行 | `occurs` と `unify_oc` |
| `term.ml` 146行 | `copy_term` |
| `term.ml` 165行 | `term_variables` — 順序が規定されている |
| `term.ml` 187–222行 | `rank`・`compare_numbers`・`compare_terms` — 標準順序 |
| `term.ml` 226行 | `variant` — `=@=`。2方向の対応表 |
| `term.ml` 253–287行 | リストとの往復。`expect_list` は未束縛の尾を instantiation_error に振り分けます |

---

[← 0. 質問が探索になるまで](00-overview.md) ／ [目次](index.md) ／ [2. 読み取り →](02-read.md)
