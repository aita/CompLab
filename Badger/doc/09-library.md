# 9. ライブラリを Prolog で書く — `prelude.ml`

`append/3` から `setof/3` まで、ライブラリは Prolog のソースです。OCaml の文字列1つに入っていて、
起動時に他のファイルと同じ経路で consult されます。

```ocaml
let source =
  {prolog|
append([], List, List).
append([H|T], List, [H|Rest]) :- append(T, List, Rest).
...
|prolog}
```

OCaml で書けたはずのものを書かなかった理由は2つあります。**節として書いたほうが短くて読める**
から。そして**言語で書かれたライブラリが、その言語が動くことの一番の証拠**だから。

`badger -d` がライブラリを除くのはこのためです — ライブラリは「プログラム」の側にいます。

## 1. 何が OCaml 側に残るか

境目は「項の構造を歩く必要があるか」です。

| OCaml 側 | 理由 |
|---|---|
| `length/2` `msort/2` `sort/2` `keysort/2` | 標準順序と、O(n log n) が要る |
| `findall/3` | 継続の中でコピーを取る必要がある |
| `functor/3` `arg/3` `=../2` `copy_term/2` | 項の構造そのもの |
| `=@=` | 変数の対応表を持つ |

| Prolog 側 | 理由 |
|---|---|
| `append/3` `member/2` `select/3` `permutation/2` | 節2つで書けて、しかも全方向に走る |
| `maplist/2..5` `foldl/4,5` `include/3` `exclude/3` | `call/N` の上に乗るだけ |
| `bagof/3` `setof/3` | `findall/3` と `keysort/2` の組み合わせ（§3） |
| `predsort/3` | 比較がゴールなので、Prolog で書くほうが自然（§2） |
| `phrase/2,3` | 2行 |

## 2. `predsort/3` — 比較がゴールであること

```prolog
predsort(_, [], []) :- !.
predsort(P, [H|T], Sorted) :- predsort(P, T, Rest), '$pred_insert'(P, H, Rest, Sorted).

'$pred_insert'(_, X, [], [X]) :- !.
'$pred_insert'(P, X, [Y|Ys], Sorted) :-
    call(P, Order, X, Y),
    (   Order = (<)
    ->  Sorted = [X,Y|Ys]
    ;   Order = (=)
    ->  Sorted = [Y|Ys]
    ;   Sorted = [Y|Rest], '$pred_insert'(P, X, Ys, Rest)
    ).
```

挿入ソートです。O(n²) を選んだのは、**比較が述語だから**です。比較は束縛するかもしれず、
失敗するかもしれず、投げるかもしれず、しかも `=` を返したら**片方を捨てろ**という意味です。
そういう比較を OCaml の `List.stable_sort` に渡すことはできません（渡すと、比較の副作用が
何回起きるかが実装依存になります）。

```
$ badger examples/lists.pl
predsort(by_length,[[1,2,3],[1],[1,2]],A)     predsort(by_length,[[1,2,3],[1],[1,2]],[[1],[1,2],[1,2,3]])
```

`Order = (<)` の括弧は[2章](02-read.md) §4 の話です。`<` は演算子なので、単独で書くには括弧が
要ります。

## 3. `bagof/3` — `findall/3` との本当の違い

`findall/3` はゴールの変数を全部潜在的に量化します。**`bagof/3` は、テンプレートにも `^` にも
現れない変数を量化せず、その束縛ごとに1組ずつ報告します。**

```
$ echo 'findall(V, pair(K,V), L).'      pair(a,1).  pair(b,2).  pair(a,3).
L = [1,2,3].                            ← K は消える

$ echo 'bagof(V, pair(K,V), L).'
K = a,
L = [1,3] ;                             ← K ごとに1組
K = b,
L = [2].

$ echo 'bagof(V, K^pair(K,V), L).'
L = [1,2,3].                            ← ^ で量化すれば findall と同じ
```

空のときの振る舞いも違います。**`findall/3` は空リストで成功し、`bagof/3` は失敗します。**

```
$ echo 'bagof(V, pair(z,V), L).'
false.
$ echo 'findall(V, pair(z,V), L).'
L = [].
```

匿名変数も自由変数です。これは間違いではなく仕様です。

```
$ echo 'setof(K, pair(K,_), L).'
L = [a] ;                               ← _ = 1 のとき
L = [b] ;                               ← _ = 2 のとき
L = [a].                                ← _ = 3 のとき
```

### 実装は findall と keysort

```prolog
bagof(Template, Goal, Bag) :-
    '$strip_carets'(Goal, Plain, Existential),
    term_variables(Template-Existential, Quantified),
    term_variables(Plain, All),
    '$free_vars'(All, Quantified, Free),
    (   Free == []
    ->  findall(Template, Plain, Bag), Bag \== []
    ;   Witness =.. [w|Free],
        findall(Witness-Template, Plain, Pairs),
        Pairs \== [],
        keysort(Pairs, Sorted),
        '$group_pairs'(Sorted, Groups),
        member(Witness-Bag, Groups)
    ).

setof(Template, Goal, Set) :- bagof(Template, Goal, Bag), sort(Bag, Set).
```

5段です。**`^` を剥がす**（`'$strip_carets'/3`、OCaml 側の10行）、**自由変数を求める**
（量化された変数を `==` で引く）、**証人つきで集める**、**証人で並べて group する**、
**組を1つずつ返す**。最後の `member/2` が bagof を非決定的にします。

group する側は `=@=` を使います。`findall/3` がコピーを返すので、同じ証人でも変数の同一性は
失われているからです（[1章](01-term.md) §6）。

```prolog
'$group_pairs'([], []).
'$group_pairs'([K-V|Rest], [K-[V|Vs]|Groups]) :-
    '$same_witness'(K, Rest, Vs, Tail),
    '$group_pairs'(Tail, Groups).
'$same_witness'(K, [K1-V|Rest], [V|Vs], Tail) :- K =@= K1, !, '$same_witness'(K, Rest, Vs, Tail).
'$same_witness'(_, Rest, [], Rest).
```

`aggregate_all/3` は素直に `findall/3` の上に乗ります。第一引数の形で節を選ぶので、
`count` と `count(T)` は[4章](04-db.md)の第一引数の鍵で区別されます。

```prolog
aggregate_all(count, Goal, Count)    :- findall(x, Goal, Xs), length(Xs, Count).
aggregate_all(count(T), Goal, Count) :- findall(T, Goal, Xs), length(Xs, Count).
aggregate_all(sum(E), Goal, Sum)     :- findall(E, Goal, Xs), sum_list(Xs, Sum).
...
```

## 4. Prolog で書いた Prolog

`clause/2` がプログラムに自分の節を渡すので、Prolog のインタプリタは Prolog で数行です。

```prolog
solve(true) :- !.
solve((A, B)) :- !, solve(A), solve(B).
solve((A -> B ; C)) :- !, ( solve(A) -> solve(B) ; solve(C) ).
solve((A ; B)) :- !, ( solve(A) ; solve(B) ).
solve((A -> B)) :- !, ( solve(A) -> solve(B) ).
solve(\+ A) :- !, \+ solve(A).
solve(!) :- !, throw(cut_not_supported).
solve(Goal) :- predicate_property(Goal, built_in), !, call(Goal).
solve(Goal) :- clause(Goal, Body), solve(Body).
```

`predicate_property(Goal, built_in)` があるので「自分で解釈するもの」と「エンジンに任せるもの」
の線が引けます。それが無いと `clause/2` が `permission_error` を投げるところで場合分けする
ことになります。

**カットは解釈できません。** そして解釈できない理由は[6章](06-cut.md)そのものです — カットは
自分を含む述語のフレームに届かなければならず、解釈されたカットが知っているのは
インタプリタのフレームだけです。`solve/1` は嘘をつくかわりに投げます。

```
$ badger examples/meta.pl
...
interpreting a cut: cut_not_supported
```

同じ骨組みを少し変えると別のものになります。証明木を作る版:

```prolog
prove(true, true) :- !.
prove((A, B), (PA, PB)) :- !, prove(A, PA), prove(B, PB).
prove(Goal, fact(Goal)) :- predicate_property(Goal, built_in), !, call(Goal).
prove(Goal, proof(Goal, Sub)) :- clause(Goal, Body), prove(Body, Sub).
```

```
$ badger examples/meta.pl
a proof of ancestor(tom, jim):
  ancestor(tom,jim)
    parent(tom,bob)
    ancestor(bob,jim)
      parent(bob,ann)
      ancestor(ann,jim)
        parent(ann,jim)
```

深さを制限する版は、**書いたつもりの論理と、走らせたときの手続きが違う**場合を見つけます。

```prolog
solve(_, Depth) :- Depth < 0, !, fail.
...
loops(X) :- loops(X).            % 論理としては真、手続きとしては無限ループ
```

```
$ badger examples/meta.pl
loops/1 found no proof within depth 20
```

### 解釈するといくらかかるか

```
$ badger examples/meta.pl
inferences spent interpreting ancestor/2: 40
```

同じ質問をエンジンに直接させると9です（[0章](00-overview.md) §8）。**4倍強** — 解釈された節の
探索1回につき `clause/2` 1回と、`solve/1` 自身の節の走査が乗ります。

## していないこと

**`yall` のラムダ（`[X]>>Goal`）がありません。** `maplist/3` に渡せるのは名前のついた述語か、
部分適用された項だけです。`>>` を書ける演算子として足すのは1行ですが、変数のコピーの規則
（どの変数が呼び出しごとに新しくなるか）を決める必要があり、そこは言語設計の話になります。

**`assoc` も `pairs` 以上のデータ構造もありません。** `library(assoc)` の AVL 木は Prolog で
書けるものの代表ですが、入れていません。

**`sort/4` がありません。** 鍵と順序を指定する SWI の版です。`predsort/3` で書けます。

**`between/3` 以外の反復子がありません。** `forall/2` と `aggregate_all/3` で足りています。

**ライブラリの読み込みを選べません。** モジュールが無いので、`prelude.ml` は常に全部入ります。
名前が衝突したら、ユーザのプログラムが「組み込みでない述語の再定義」として通ってしまい、
どちらの節も残ります（`-d` で見えます）。

## 参考文献

- L. Byrd, [*Understanding the control flow of Prolog programs*][byrd], Logic Programming
  Workshop 1980。4つのポート（[5章](05-solve.md)）の出どころで、§4 の meta-interpreter が
  もともと何のためのものだったかの説明でもあります。
- ISO/IEC 13211-1:1995, §8.10.2 が `bagof/3`、§8.10.3 が `setof/3`。「自由変数」の定義と
  `^/2` の扱いは §8.10.2.1。
- R. A. O'Keefe, *The Craft of Prolog*, MIT Press 1990。第2章が meta-interpreter を
  少しずつ変えていく話で、`examples/meta.pl` の3つの版はこの並びです。

[byrd]: https://www.cs.ox.ac.uk/people/lawrence.byrd/

## 実装の地図

| | |
|---|---|
| `prelude.ml` 8–10行 | `source` — Prolog のソースを OCaml の `{prolog|...|prolog}` に入れる |
| `prelude.ml` 16–151行 | リスト述語 |
| `prelude.ml` 153–164行 | `predsort/3` — §2 |
| `prelude.ml` 172–199行 | `bagof/3`・`setof/3`・`'$free_vars'`・`'$group_pairs'` — §3 |
| `prelude.ml` 201–207行 | `aggregate_all/3` |
| `prelude.ml` 211–212行 | `phrase/2,3` |
| `builtins.ml` 526行 | `'$strip_carets'/3` — `^` を剥がす |
| `badger.ml` 160–165行 | ライブラリを consult するところ。`-d` の除外リストもここで取る |
| `examples/meta.pl` | §4 の3つの meta-interpreter |

---

[← 8. 文法](08-dcg.md) ／ [目次](index.md) ／ [10. WAM まであとどれくらいか →](10-wam.md)
