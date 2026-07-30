# 8. 文法 — `dcg.ml`, `load.ml`

`-->` は制御構文ではありません。**節が読まれた瞬間に施される変換**です。エンジンは `-->` を
知りません。

規則は1つだけです。**非終端記号に引数を2つ足す** — 自分より前のトークン列と、自分より後の
トークン列。あとはそれを本体に通すだけです。

## 1. 変換された姿

```prolog
greeting(N) --> [hello], name(N).
name(badger) --> [badger].
```

```
$ badger -d g.pl
% greeting/3
  [any, 4 vars] greeting(_L0,_L1,_L2) :- ','(=(_L1,'.'(hello,_L3)),name(_L0,_L3,_L2)).

% name/3
  [badger, 2 vars] name(badger,_L0,_L1) :- =(_L0,'.'(badger,_L1)).
```

読みやすい形にすると:

```prolog
greeting(N, S0, S) :- S0 = [hello|S1], name(N, S1, S).
name(badger, S0, S) :- S0 = [badger|S].
```

**終端記号は消費します** — `S0 = [hello|S1]` が「先頭が hello で、残りが S1」。
**非終端記号は残りを引き継ぎます** — `name(N, S1, S)`。

`listing/1` は同じものを人の側から見せます。

```
$ echo 'listing(greeting/3).' | badger g.pl -t
greeting(A,B,C) :-
    B=[hello|D],
    name(A,D,C).
```

## 2. 変換の全部

```ocaml
let rec body t s0 s =
  match Term.deref t with
  | Term.Struct (",", [| x; y |]) ->
      let mid = Term.fresh_var () in
      conj (body x s0 mid) (body y mid s)
  | Term.Struct ((";" | "|"), [| x; y |]) -> Term.Struct (";", [| body x s0 s; body y s0 s |])
  | Term.Struct ("->", [| x; y |]) ->
      let mid = Term.fresh_var () in
      Term.Struct ("->", [| body x s0 mid; body y mid s |])
  | Term.Struct ("\\+", [| x |]) ->
      conj (Term.Struct ("\\+", [| body x s0 (Term.fresh_var ()) |])) (eq s0 s)
  | Term.Atom "!" -> conj (Term.Atom "!") (eq s0 s)
  | Term.Atom "[]" -> eq s0 s
  | Term.Struct ("{}", [| goal |]) -> conj goal (eq s0 s)
  | Term.Struct ("call", args) -> Term.Struct ("call", Array.append args [| s0; s |])
  | (Term.Struct (".", [| _; _ |]) as list) -> eq s0 (with_tail list s)
  | nonterminal -> add_args nonterminal [| s0; s |]
```

10行です。読み方は**「この構文はトークンを消費するか」**の一点だけです。

| 書いたもの | 消費 | 変換 |
|---|---|---|
| `a, b` | 両方 | 中間の変数を1つ作って繋ぐ |
| `a ; b` | どちらか | 両枝が同じ `S0` と `S` を持つ |
| `a -> b` | 両方 | `,` と同じく繋ぐ |
| `[a,b]` | する | `S0 = [a,b|S]` |
| `[]` | しない | `S0 = S` |
| `{G}` | しない | `G, S0 = S` |
| `!` | しない | `!, S0 = S` |
| `\+ a` | しない | `\+ a(S0,_), S0 = S` |
| `call(G)` | 引数2つ足す | `call(G, S0, S)` |
| それ以外 | 非終端記号 | 引数2つ足す |

**消費しないものは `S0 = S` と言うだけ**で、それが `{}/1` と `!` と `[]` の全部です。

```
$ badger -d g2.pl                          either   --> ( [a] ; [b] ).
% either/2                                 optional --> \+ [x], [y].
  [any, 2 vars] either(_L0,_L1) :- ;(=(_L0,'.'(a,_L1)),=(_L0,'.'(b,_L1))).

% optional/2
  [any, 4 vars] optional(_L0,_L1) :- ','(','(\+(=(_L0,'.'(x,_L2))),=(_L0,_L3)),=(_L3,'.'(y,_L1))).
```

`either//0` の2つの枝が同じ `_L0` と `_L1` を持っているのが、「どちらかが消費する」ということ
です。`optional//0` の `\+` は `_L2` という捨てる変数を作り、そのあと `_L0 = _L3` で
「何も消費しなかった」と言っています。

## 3. カットは変換されるが、意味は変換されない

`!` は `!, S0 = S` になります。カット自身はそのまま残るので、**変換後の節のカットとして働きます**
— つまり切るのは非終端記号の述語です。DCG のカットが「この非終端記号の残りの規則を捨てる」に
なるのは、これで正しい振る舞いです。

```
$ badger -d g2.pl        digits([D|T]) --> [D], { code_type(D, digit(_)) }, !, digits(T).
% digits/3
  [./2, 8 vars] digits('.'(_L0,_L1),_L2,_L3) :-
    ','(=(_L2,'.'(_L0,_L4)),
      ','(','(code_type(_L0,digit(_L5)),=(_L4,_L6)),
        ','(','(!,=(_L6,_L7)),
          digits(_L1,_L7,_L3)))).
```

`!, _L6 = _L7` の並びが読めます。`,` の入れ子が右に深いのは、変換が `,` を右結合のまま
組み立てるからです。

## 4. `phrase/2,3` は変換を実行時にも使う

`phrase(Body, List, Rest)` の `Body` は非終端記号でなくてもよく、文法の本体そのものでも
かまいません。だから**同じ変換を実行時に呼べる必要があります**。

```prolog
phrase(Body, List) :- phrase(Body, List, []).
phrase(Body, List, Rest) :- '$dcg_body'(Body, List, Rest, Goal), call(Goal).
```

`'$dcg_body'/4` は `Dcg.body` を1回呼ぶだけの組み込み述語です。

```
$ echo 'phrase(([a],[b]), [a,b]).'
true.
$ echo 'phrase(({1<2}), [], []).'
true.
$ echo 'phrase(([a] ; [b]), [b]).'
true.
```

## 5. 同じ文法が解析と生成の両方をする

DCG は述語なので、引数のどれが束縛されているかを選べます。入力を未束縛の開いたリストにすると、
**その非終端記号が受理する文字列を数え上げます**。

```prolog
bits([])     --> [].
bits([B|Bs]) --> [B], { member(B, [0,1]) }, bits(Bs).
```

```
$ badger examples/dcg.pl
...
every three-bit string bits//1 accepts:
  [[0,0,0],[0,0,1],[0,1,0],[0,1,1],[1,0,0],[1,0,1],[1,1,0],[1,1,1]]
```

`{ member(B, [0,1]) }` が中で生成しているので、これは動きます。`{ code_type(C, digit(_)) }` は
`C` が未束縛だと `instantiation_error` を投げるので、動きません — **生成に使えるかどうかは、
波括弧の中のゴールが逆向きに走れるかどうか**で決まります。

## 6. 左再帰は書けない

```prolog
expr(X) --> expr(A), "+", term(B), { X is A + B }.     % 止まらない
```

変換すると `expr(X, S0, S) :- expr(A, S0, S1), ...` で、`S0` が減らないまま自分を呼びます。
深さ優先の探索なので止まりません。`examples/dcg.pl` は普通の逃げかたをしています — 被演算子を
1つ食べてから、残りを尾部の非終端記号で処理する。

```prolog
expr(V)           --> term(V0), expr_tail(V0, V).
expr_tail(Acc, V) --> ws, "+", !, term(N), { Acc1 is Acc + N }, expr_tail(Acc1, V).
expr_tail(V, V)   --> [].
```

同じ文法を、値を計算するかわりに項を組み立てるように書くと構文木が出ます。違いは波括弧の中だけ
です。

```
$ badger examples/dcg.pl
input         value       tree
'1+2*3'       7           1+2*3
'(1+2)*3'     9           (1+2)*3
' 2 * -3 '    -6          2* - 3
'10/4'        2.5         10/4
'1+'          no parse    -
'42'          42          42
```

`tree` の列は `writeq/1` の出力です。`2* - 3` に空白があるのは[3章](03-write.md) §4 の話で、
これは `*(2, -(3))` — 単項マイナスであって負数の `-3` ではない — という項です。

## していないこと

**押し戻しリストがありません。** `H, PB --> B`（頭部で消費しなかったものを押し戻す）は
`domain_error(dcg_head, ...)` にします。ISO の DCG 標準にはあります。

**`call//N` 以外の高階な非終端記号がありません。** `call(G)` は引数2つを足すと分かっているので
特別扱いしますが、`maplist//2` のような述語はありません。

**文字列リテラルの扱いは `double_quotes` フラグ次第です。** `"+"` が符号のリストなので
`examples/dcg.pl` は符号のリストを解析しています。`chars` にすれば文字のリストの文法になり、
同じ規則がそのまま動きます（`code_type/2` を `char_type/2` に替える必要はあります）。

**変換の結果を検査しません。** `-->` の本体に数を書くと、変換は通って `call/3` で失敗する
節ができます。`Dcg.add_args` は変数と数だけ弾きます。

## 参考文献

- A. Colmerauer, [*Metamorphosis grammars*][meta], in *Natural Language Communication with
  Computers*, LNCS 63, 1978。DCG の元になった形式。
- F. Pereira, D. H. D. Warren, [*Definite clause grammars for language analysis*][dcg],
  Artificial Intelligence 13(3), 1980。`-->` を「引数2つを足す変換」として定式化した論文で、
  §2 の表はここに載っている変換規則です。
- ISO/IEC DTR 13211-3, *Definite clause grammar rules*。押し戻しリストと `call//N` の規定。

[meta]: https://doi.org/10.1007/BFb0031371
[dcg]: https://doi.org/10.1016/0004-3702(80)90003-X

## 実装の地図

| | |
|---|---|
| `dcg.ml` 19行 | `add_args` — 非終端記号に引数を足す |
| `dcg.ml` 30行 | `with_tail` — `[a,b]` に `S` を継ぎ足す |
| `dcg.ml` 36–53行 | `body` — §2 の表そのもの、10行 |
| `dcg.ml` 55行 | `translate` — `H --> B` を節に。頭部のカンマを拒否するのもここ |
| `load.ml` 83–85行 | 読めた項に `translate` を試すところ |
| `builtins.ml` 523行 | `'$dcg_body'/4` — `phrase/2,3` のために変換を実行時に呼ぶ |
| `prelude.ml` | `phrase/2` と `phrase/3`、2行 |
| `examples/dcg.pl` | 電卓と構文木、そして生成 |

---

[← 7. 組み込み述語と例外](07-builtins.md) ／ [目次](index.md) ／ [9. ライブラリを Prolog で書く →](09-library.md)
