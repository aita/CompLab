# 7. 組み込み述語と例外 — `builtins.ml`, `arith.ml`

組み込み述語は `Solve.solve` と同じ形をしています。引数と継続を渡され、解1つにつき継続を
1回呼びます。

```ocaml
type builtin = Db.t -> Term.term array -> Engine.cont -> unit
```

制御構文（`,` `;` `->` `!` `\+`）はここにありません。あれらは呼び出し側のバリアを必要とするので
[5章](05-solve.md)と[6章](06-cut.md)に居ます。**ここにあるものは全部カットに不透明で、`call/1` が
こちら側にあるのはそのためです。**

## 1. 決定的なものと、そうでないもの

ほとんどの組み込み述語は成否を返すだけなので、包みを1つ用意します。

```ocaml
let det name arity fn = def name arity (fun db args sk -> if fn db args then sk ())
```

これで `=/2` は1行です。

```ocaml
det "=" 2 (fun _ args ->
    if !Flags.occurs_check then Term.unify_oc args.(0) args.(1) else Term.unify args.(0) args.(1));
```

**失敗した `det` が残した束縛は掃除しません。** [1章](01-term.md) §3 のとおり、掃除するのは
選択肢を出した人の仕事です。

非決定的なものは自分で選択肢を出すので、**自分のマークまで巻き戻す責任を負います**。
`between/3` がその一番小さい例です。

```ocaml
| Term.Var _ ->
    let m = Term.mark () in
    let i = ref low in
    while !i <= high do
      Term.undo_to m;
      if Term.unify args.(2) (Term.Int !i) then sk ();
      incr i
    done;
    Term.undo_to m
```

節を順に試す `Solve.predicate` と同じ形です。**「候補ごとにマークまで巻き戻してから試す」
という1つの規則が、節にも組み込み述語にも同じように当てはまります。**

## 2. 逆向きに走る組み込み述語

Prolog の組み込み述語は、引数のどれが束縛されているかで別の仕事をします。

```
$ echo 'findall(X-Y, atom_concat(X, Y, ab), S).'
S = [''-ab,a-b,ab-''].
```

`atom_concat/3` は前2つが束縛されていれば繋ぎ、そうでなければ**分けかたを全部数え上げます**。

```
$ echo 'findall(B-L, sub_atom(abc, B, L, _, _), S).'
S = [0-0,0-1,0-2,0-3,1-0,1-1,1-2,2-0,2-1,3-0].
```

`sub_atom/5` は部分文字列が分かっていれば出現位置を探し、分かっていなければ開始位置と長さの
組を全部数え上げます。10個は3文字のアトムの部分文字列の数（空文字列を含む）です。

`length/2` は3つのモードを持ちます。真正なリストなら長さを測り、開いたリストと数が与えられて
いればその長さまで伸ばし、両方が未束縛なら**長さを 0, 1, 2, … と数え上げます**（だから
`length(L, N)` は止まりません — これは正しい振る舞いです）。

`arg/3` `clause/2` `retract/1` `current_predicate/1` `current_op/3` `repeat/0`
`predicate_property/2` も非決定的です。

## 3. `catch/3` — 継続渡しの落とし穴

`catch(G, C, R)` は `G` が投げたものを捕まえます。**`catch/3` が成功したあとに、その後ろで
投げられたものは捕まえません** — それは `catch/3` の仕事ではないからです。

```prolog
catch(( catch(true, inner, write(wrong)), throw(outer) ), Ball, true)
```

内側の `catch(true, inner, _)` は成功し、そのあと `throw(outer)` が投げます。`outer` は
**外側**の catch のものです。

ところが継続渡しで書くと、内側の `catch/3` の継続は内側の OCaml の `try` の**中**で走ります。
素朴に書けば内側が `outer` を捕まえてしまいます。

そこで深さの数を1つ持ちます。

```ocaml
let catch_depth = ref 0

def "catch" 3 (fun db args sk ->
    let outer = !catch_depth in
    let mark = Term.mark () in
    let protected_sk () =
      catch_depth := outer;          (* 継続はこの catch の外である *)
      sk ();
      catch_depth := outer + 1       (* 正常に戻った。また中に居る *)
    in
    catch_depth := outer + 1;
    let outcome =
      try Engine.call_goal db args.(0) protected_sk; `Done
      with
      | Term.Prolog_error ball when !catch_depth > outer -> `Caught ball
      | e -> catch_depth := outer; raise e
    in
    ...
```

**`sk ()` を呼ぶ直前に数を戻し、`sk ()` が正常に返ってきたら上げ直します。** `sk ()` の中で
例外が飛んだときは上げ直す行に到達しないので、数は `outer` のままで、`when !catch_depth > outer`
の番が偽になり、この `catch/3` は捕まえません。

```
$ echo 'catch(( catch(true, inner, write(wrong)), throw(outer) ), Ball, true).'
Ball = outer.
```

`features.pl` の `catch_does_not_catch_its_continuation` がこれです。**選んだ実装方式のせいで
必要になった仕掛けで、この処理系で唯一そういうものです。**

捕まえたら、まず `undo_to mark` します。投げた場所からここまでのあいだに作られた束縛は
消えます — だから `throw/1` は**投げる球をコピーします**（[1章](01-term.md) §7）。

## 4. 例外の3層

OCaml の例外は3つだけです。

| | 何 | 誰が止めるか |
|---|---|---|
| `Term.Prolog_error of term` | `throw/1` と全部のエラー | `catch/3`、または一番外側 |
| `Engine.Cut of int` | カット | 番号が一致する述語呼び出し |
| `Term.Halt of int` | `halt/0,1` | `main` |

`Engine.Found` もありますが、これは `once` の中だけで生まれて死にます。

Prolog のエラーは全部 `Prolog_error` の中の項です。**エラーの種類ごとに OCaml の例外を作らない**
ので、`catch/3` は単一化1回で済みます。

```
$ echo 'catch(X is 1 + a, error(E,_), true).'
E = type_error(evaluable,a/0).
```

## 5. 算術 — `arith.ml`

`is/2` は項を評価して数を返します。整数と浮動小数点数を分けて持つので、**どこで境を越えるかを
言い切る**必要があります。

```
$ echo 'X is 7/2, Y is 6/2, Z is 7//2, W is 2**3, V is 2^3.'
X = 3.5,                 ← 割り切れないので浮動小数点数
Y = 3,                   ← 割り切れるので整数
Z = 3,                   ← // は必ず整数
W = 8.0,                 ← ** は必ず浮動小数点数
V = 8.                   ← ^ は整数同士なら整数
```

整数の除算が4つあるのは、丸めと剰余の符号の組み合わせが4通りあるからです。

| | 丸め | 剰余の符号 | `-7` と `3` |
|---|---|---|---|
| `//` | 0方向 | — | `-2` |
| `div` | −∞方向 | — | `-3` |
| `rem` | — | 被除数 | `-1` |
| `mod` | — | 除数 | `2` |

OCaml の `/` と `mod` は0方向・被除数の組なので、`//` と `rem` はそのままで、`div` と `mod` が
補正です。

```ocaml
let int_div a b =
  if b = 0 then zero_divisor ()
  else if (a < 0) <> (b < 0) && a mod b <> 0 then (a / b) - 1
  else a / b
```

評価できない関数は `type_error(evaluable, Name/Arity)` です。**未定義の関数と、数でない項の
区別を、エラーの種類でする**のが ISO のやりかたです。

## 6. `format/2`

書式は文字ごとに解釈します。対応するのは `~w ~p ~q ~a ~d ~D ~e ~f ~g ~s ~n ~c ~r ~i ~t ~| ~+ ~~`
と、数を引数から取る `~*`。

```
$ badger fmt.pl
a b|a b|'a b'|42|12.34|1,234,567          ~a ~w ~q ~d ~2d ~D
1.500000e+00|3.14|0.5|abc|hi|ff|...|~     ~e ~2f ~g ~s ~c~c ~16r ~*c ~~
[left       |]                            ~w~t~12|
```

`~2d` は「整数を、右から2桁目に小数点を打って書く」— 通貨の書き方です。`~D` は3桁ごとの
区切り。`~16r` は基数16。`~*c` は「引数から取った回数だけこの文字を繰り返す」。

`format/3` は出力ではなく項に書きます。

```
$ echo "format(atom(A), \"~q\", [f('X', \"s\", 0'a)]), writeq(A), nl."
'f(\'X\',[115],97)'
```

これが `with_output_to/2` の代わりで、`features.pl` の書き出しの検査は全部これを通しています。

## 7. 組み込み述語の一覧はどこにあるか

`Builtins.table` はハッシュ表で、鍵は名前とアリティです。`Solve` が引くのはここだけなので、
**「組み込み述語かどうか」は表に居るかどうか**です。同じ判定を3箇所が使います。

- `Solve.solve` — ユーザ述語より先に引く
- `Load.add_clause` — 組み込み述語の上に節を書けない
- `predicate_property/2` — `built_in` を答える

制御構文は表に居ないので、`control` というリストで別に数え上げてあります。そうしないと
`:- p :- q.` のような節を拒否できません。

## していないこと

**ストリームがありません。** 出力は標準出力、入力は標準入力だけです。`format/3` の
`atom(A)` があるので `with_output_to/2` の用途はほぼ埋まりますが、ファイルは開けません。

**文字列型がありません。** `atom_length/2` などが受け取る「テキスト」は、アトム・数・
符号のリスト・文字のリストの4つです（`text_of`）。SWI の `string` は無いので `split_string/4`
のような述語もありません。

**`atomic_list_concat/3` の分割は1文字の区切りだけです。** 複数文字の区切りで分けるには
本物の文字列探索が要り、それは文字列ライブラリの仕事です。

**`~t` は無視します。** 桁揃えは `~N|` が左に空白を詰めるだけで、`~t` の位置に埋め草を
分配しません。表を作るぶんには足ります。

**多倍長整数がありません。** [1章](01-term.md)の「していないこと」と同じです。

## 参考文献

- ISO/IEC 13211-1:1995, §8 が組み込み述語の全部。§7.8.4 の note に「`catch/3` の
  ゴールの実行が終わったあとに投げられたものは捕まえない」という、§3 の仕掛けが必要になる
  規定があります。§9 が算術で、4つの整数除算は §9.1.3 の表です。
- ISO/IEC 13211-1:1995, §8.11 が入出力。この処理系がストリームを持たないので、実装したのは
  暗黙のストリーム版だけです。
- SWI-Prolog の `format/2` の[マニュアル][swi-format]。ここの書式指定はこれの部分集合です。

[swi-format]: https://www.swi-prolog.org/pldoc/man?predicate=format/2

## 実装の地図

| | |
|---|---|
| `builtins.ml` 16–24行 | `table`・`def`・`det` |
| `builtins.ml` 26–28行 | `control` — 表に居ない制御構文の一覧 |
| `builtins.ml` 57行 | `text_of` — テキストとして通るもの4種 |
| `builtins.ml` 157行 | `between/3` — 一番小さい非決定的組み込み述語 |
| `builtins.ml` 292行 | `atom_concat/3` — 分けかたを数え上げる |
| `builtins.ml` 312行 | `sub_atom/5` — 部分文字列が既知なら位置を探す |
| `builtins.ml` 445行 | `length/2` — 3つのモード |
| `builtins.ml` 537–553行 | `call/1..8` |
| `builtins.ml` 556–597行 | `catch/3` と `catch_depth` — §3 |
| `builtins.ml` 653–663行 | `clause/2` |
| `builtins.ml` 664–679行 | `retract/1` — スナップショットの上を歩く |
| `builtins.ml` 825行 | `run_format` — 書式1つを解釈する |
| `arith.ml` 17–33行 | 4つの整数除算 |
| `arith.ml` 66–78行 | `eval` — 項から数へ |
| `arith.ml` 128–136行 | `/` — 整数か浮動小数点数かを決めるところ |

---

[← 6. カットとバリア](06-cut.md) ／ [目次](index.md) ／ [8. 文法 →](08-dcg.md)
