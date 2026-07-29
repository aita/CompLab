# 5. 導出 — 継続で書く探索 — `solve.ml`, `engine.ml`

エンジンの型はこれです。

```ocaml
val solve : Db.t -> Term.term -> int -> (unit -> unit) -> unit
```

**ゴールを解くとは、解が1つ見つかるたびに継続を呼び、解が尽きたら return する呼び出しである。**

この1行から出てくることが3つあります。バックトラックは継続が return してくることになる。
選択点スタックは OCaml のスタックそのものになる。そして**選択点を明示的に捨てる手段が
なくなる** — それが[6章](06-cut.md)です。

## 1. 4つのポートで見る

`-T` を付けると、述語呼び出しの4つのポートが標準エラーに出ます。

```
$ echo 'member(X, [a,b]), \+ X = a.' | badger -T
Call: (0) member(_G323,[a,b])
Exit: (0) member(a,[a,b])          ← 第1節。解が1つ、継続へ
Redo: (0) member(a,[a,b])          ← 継続が return してきた。\+ X = a が失敗した
  Call: (1) member(_G323,[b])      ← 第2節の本体
  Exit: (1) member(b,[b])
Exit: (0) member(b,[a,b])
Redo: (0) member(b,[a,b])
  Redo: (1) member(b,[b])
    Call: (2) member(_G323,[])
    Fail: (2) member(_G323,[])     ← [] に合う節がない
  Fail: (1) member(_G323,[b])
Fail: (0) member(_G323,[a,b])
X = b.
```

**`Exit` は継続が呼ばれること、`Redo` はその継続が return してくることです。** バックトラックと
いう別の機構はありません。`Exit` から `Redo` までの区間が「解を1つ持って外に出ていた時間」で、
その区間のあいだ OCaml のスタックには未試行の節を持ったフレームが積まれたままです。

`Fail` のところではトレイルがすでに巻き戻っているので、ゴールは呼ばれたときの姿
（`member(_G323,[b])`）に戻っています。`Redo` のところではまだ束縛が残っています
（`member(b,[b])`）。この2行の差が[1章](01-term.md)のトレイルです。

トレーサの実装は継続を1枚包むだけです。**バックトラックが起きる場所が1つしかないので、
仕掛ける場所も1つしかありません。**

```ocaml
let traced_sk () =
  Engine.trace_depth := depth;
  Engine.port "Exit" goal;
  sk ();
  Engine.port "Redo" goal;
  Engine.trace_depth := depth + 1
in
let sk = if !Engine.tracing then traced_sk else sk in
```

## 2. 制御構文は項の形での分岐

```ocaml
let rec solve db goal barrier sk =
  match Term.deref goal with
  | Term.Atom "true" -> sk ()
  | Term.Atom ("fail" | "false") -> ()
  | Term.Atom "!" -> sk (); raise (Engine.Cut barrier)
  | Term.Struct (",", [| first; second |]) ->
      solve db first barrier (fun () -> solve db second barrier sk)
  ...
```

**`true` は継続を1回呼ぶこと、`fail` は何もせず return すること。** これが「成功」と「失敗」の
定義で、他に状態はありません。

**連言は継続の入れ替えです。** `a, b` を解くとは、`a` を解いて、その継続で `b` を解くこと。
`a` に解が3つあれば継続が3回呼ばれ、そのたびに `b` が解かれます。ネストした二重ループが、
ネストした関数呼び出しとして出ています。

**選言はトレイルの巻き戻しを挟んで2回解くことです。**

```ocaml
| _ ->
    let m = Term.mark () in
    solve db left barrier sk;
    Term.undo_to m;
    solve db right barrier sk
```

左を解き切ってから、左が残した束縛をマークまで消して、右を解きます。[1章](01-term.md) §3 の
「選択肢を出すものは巻き戻す」がここです。

## 3. `->` は条件を1回しか解かない

```ocaml
| Term.Struct (";", [| left; right |]) -> (
    match Term.deref left with
    | Term.Struct ("->", [| condition; then_ |]) ->
        let m = Term.mark () in
        if Engine.once db condition then solve db then_ barrier sk
        else begin
          Term.undo_to m;
          solve db right barrier sk
        end
```

`Engine.once` は「解が1つあるか」を答え、**あった場合はその束縛を残します**。

```ocaml
exception Found

let once db goal =
  try
    call_goal db goal (fun () -> raise Found);
    false
  with Found -> true
```

継続の中から例外で脱出します。脱出すると途中のフレームの `undo_to` が飛ぶので束縛が残る、
というのがここでは**欲しい**振る舞いです（`->` の条件が then 節に値を渡せるため）。
残したくない `\+` のほうは、外側で明示的に巻き戻します。

```ocaml
let provable db goal =
  let m = Term.mark () in
  let result = once db goal in
  Term.undo_to m;
  result
```

`\+ G` は `if not (provable db goal) then sk ()` です。**否定は「証明できない」であって
「偽である」ではない**という有名な話が、この実装のこの1行そのものです。

条件は `call_goal` を通るので、条件の中のカットは条件の中で止まります。then 節と else 節は
`barrier` をそのまま渡すので止まりません。この違いは[6章](06-cut.md)。

## 4. `*->` — 条件の解を全部使う軟らかいカット

```ocaml
| Term.Struct ("*->", [| condition; then_ |]) ->
    let m = Term.mark () in
    let any = ref false in
    Engine.call_goal db condition (fun () ->
        any := true;
        solve db then_ barrier sk);
    if not !any then begin
      Term.undo_to m;
      solve db right barrier sk
    end
```

`->` は条件を1回しか解きませんが、`*->` は全部解いて、そのたびに then 節を解きます。
else 節に行くのは条件に解が**1つもなかった**ときだけで、それを `any` という参照が覚えて
います。継続の中で書き換えるのだから、継続の外から読めばいい — CPS で書いているとこの種の
「解があったか」は素直に取れます。

```
$ echo 'findall(X, (member(X,[1,2]) *-> true ; X = none), L).'
L = [1,2].
$ echo 'findall(X, (fail *-> true ; X = none), L).'
L = [none].
```

## 5. 述語呼び出し

制御構文でなければ、名前とアリティで組み込み述語の表を引きます。

```ocaml
| goal -> (
    let indicator = Term.indicator_of goal "call/1" in
    match Builtins.find indicator with
    | Some builtin -> builtin db (Term.args_of goal) sk
    | None -> predicate db goal indicator sk)
```

**組み込み述語が先で、ユーザ述語が後です。** [4章](04-db.md) §6 が組み込み述語の上に節を足すのを
拒否するのはこの順序のためです。

ユーザ述語は、節を順に試します。

```ocaml
let attempt (clause : Db.clause) =
  if Db.compatible clause.key goal_key then begin
    Term.undo_to mark;
    let frame = Db.frame_for clause in
    if Term.unify (Db.instantiate clause.head frame) goal then begin
      Engine.trace_depth := depth + 1;
      solve db (Db.instantiate clause.body frame) my sk;
      Engine.trace_depth := depth
    end
  end
in
let clauses = p.clauses in
(try List.iter attempt clauses with Engine.Cut b when b = my -> ());
Engine.trace_depth := depth;
Term.undo_to mark;
Engine.port "Fail" goal
```

**節ごとに `undo_to mark` が先に来ます。** 前の節が残した束縛を消してから次を試す、という
だけの規則で、これが選択点の役割を果たしています。

節が尽きたら `undo_to mark` して return する。それが `Fail` です。

## 6. 節が無い述語

```ocaml
| None ->
    if !Flags.unknown_error then
      Term.existence_error "procedure" (Term.indicator_term indicator) ...
```

データベースに項目が無ければ `existence_error`。`:- dynamic foo/1.` で宣言されていれば
項目はあって節が空なので、**単に失敗します**。ISO の `unknown` フラグで、エラーではなく失敗に
することもできます。

```
$ echo 'foo(bar).'
ERROR: existence_error(procedure,foo/1) ('foo/1')
$ echo 'set_prolog_flag(unknown, fail), foo(bar).'
false.
```

## 7. 数えられる仕事 — `inferences`

`Solve.predicate` に入るたびに1つ増える数です。組み込み述語も単一化も数えません。

```
$ echo 'statistics(inferences,A), findall(W, ancestor(tom,W), L), statistics(inferences,B), C is B-A.'
A = 0,
L = [bob,ann],
B = 9,
C = 9.
```

[9章](09-library.md)の meta-interpreter を通すと、同じ質問が何倍になるかが見られます。

## していないこと

**最終呼び出し最適化がありません。** これが継続渡しでスタックを借りたことの代価です。
決定的な再帰でも、**深さに比例して OCaml のスタックが伸び続けます**。

借りているのは OS のスタックではなく OCaml 5 のファイバのスタックで、こちらはヒープ上にあって
必要に応じて伸びます。だから上限は `ulimit -s` ではなく OCaml の `l` 実行時パラメータ
（スタックの最大語数）です。既定では 100万段の非末尾再帰が通ります。

```
$ badger d1.pl -g 'numlist(1,1000000,L), sum(L,_)'          sum([], 0).
                                                            sum([N|Ns], T) :- sum(Ns, R), T is R + N.
（成功する）

$ OCAMLRUNPARAM=l=100k badger d1.pl -g 'numlist(1,20000,L), sum(L,_)'
ERROR: stack overflow (runaway recursion?)
```

高い天井ではありますが、天井があること自体は消えません。消すには継続を OCaml の関数ではなく
明示的なデータ構造（ゴールスタック）にして、トランポリンで回す必要があります。それは
[10章](10-wam.md)で言う「WAM に一歩近づく」ことの半分です。

**深さ制限も推論数の上限もありません。** 止まらない質問は止まりません（`Ctrl-C` は
OCaml の既定どおり効きます）。

**トレースに `skip` も `retry` もありません。** 4つのポートを印字するだけで、対話的な
デバッガではありません。フィルタも無いので、`-T` を付けるとライブラリの中まで全部出ます。

**組み込み述語をトレースしません。** ポートは `Solve.predicate` にしかないので、
`is/2` や `=/2` は出てきません。出したい場合の置き場所は `Builtins.find` の直後です。

## 参考文献

- M. Carlsson, [*On implementing Prolog in functional programming*][carlsson], New
  Generation Computing 2(4), 1984。成功継続と失敗継続で Prolog を書く、という形の出どころ。
  ここでは失敗継続を「return する」ことで表しているので、継続は1つしかありません。
- R. Kowalski, [*Predicate logic as programming language*][kowalski], IFIP 1974。
  SLD 導出を「プログラム」として読む話。この章の `solve` は深さ優先・左から右の SLD です。
- ISO/IEC 13211-1:1995, §7.8 が制御構文。`*->` は ISO にはありませんが、どの実装にもあります。

[carlsson]: https://doi.org/10.1007/BF03037325
[kowalski]: https://www.doc.ic.ac.uk/~rak/papers/IFIP%2074.pdf

## 実装の地図

| | |
|---|---|
| `engine.ml` 23行 | `cont` — `unit -> unit` |
| `engine.ml` 45–55行 | トレーサ。`port` が1行印字する |
| `engine.ml` 57行 | `solve` の参照。`Solve.install` が埋める |
| `engine.ml` 63行 | `call_goal` — 新しいバリアでゴールを走らせる |
| `engine.ml` 70行 | `once` — `Found` で脱出。束縛は残す |
| `engine.ml` 78行 | `provable` — `once` して巻き戻す。`\+` の中身 |
| `engine.ml` 86行 | `collect` — `findall/3` の中身 |
| `solve.ml` 16–19行 | `true`・`fail` — 成功と失敗の定義 |
| `solve.ml` 26行 | `,` — 継続の入れ替え |
| `solve.ml` 28–52行 | `;` と、その中の `->` `*->` |
| `solve.ml` 54–58行 | else のない `->` と `*->` |
| `solve.ml` 59行 | `\+` |
| `solve.ml` 65行 | 組み込み述語の表を引く |
| `solve.ml` 71–117行 | `predicate` — 節を順に試す。4つのポートもここ |
| `badger.ml` 49行 | `run_query` — 解を1つ遅らせて印字する |

---

[← 4. 節をしまう](04-db.md) ／ [目次](index.md) ／ [6. カットとバリア →](06-cut.md)
