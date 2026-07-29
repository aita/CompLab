# 6. カットとバリア — `solve.ml`, `engine.ml`

カットは Prolog で唯一、論理の話ではない構文です。**探索の話**です。

[5章](05-solve.md)の実装方式には、これと正面から噛み合わないところがあります。カットは
「積まれている選択肢を捨てろ」という命令ですが、この処理系で積まれているのは OCaml の
スタックフレームで、**return してしまったフレームは元に戻せず、まだ return していない
フレームは捨てられません**。

できることは1つだけです。例外で抜けること。

## 1. カットは3行

```ocaml
| Term.Atom "!" ->
    sk ();
    raise (Engine.Cut barrier)
```

カットは**まず継続を呼びます**。カットの後ろにあるものは全部、その継続の中にあるからです。

継続が return してくるということは、カットの後ろが失敗したということです。そのときカットが
すべきことは「自分より後ろの選択肢を全部消して、この述語を失敗させる」ことで、それは
`barrier` という番号を持った例外です。

受け止めるのは述語呼び出しです。

```ocaml
let my = Engine.new_barrier () in
...
(try List.iter attempt clauses with Engine.Cut b when b = my -> ());
```

**自分の番号のときだけ捕まえ、静かに return します。** 番号が違えば通り過ぎるので、
そのカットは自分のものではありません。

## 2. 見えているカット

カットのある `first/1` と、無い `q/1` を並べます。

```
$ echo 'first(X).' | badger -T c.pl -t          first(X) :- q(X), !.
Call: (0) first(_G328)
  Call: (1) q(_G328)
  Exit: (1) q(1)
Exit: (0) first(1)
Redo: (0) first(1)
Fail: (0) first(_G328)              ← Redo: (1) q(1) が無い
X = 1.
```

```
$ echo 'findall(X, q(X), L).' | badger -T c.pl -t
Call: (0) q(_G328)
Exit: (0) q(1)
Redo: (0) q(1)                      ← カットが無ければ、ここから2つめを探しに行く
Exit: (0) q(2)
Redo: (0) q(2)
Exit: (0) q(3)
Redo: (0) q(3)
Fail: (0) q(_G328)
L = [1,2,3].
```

**差は `Redo: (1) q(1)` という1行の有無だけです。** カットは `q/1` の残りの節を試させません。
`q/1` の `List.iter` はまだ第1節のところにいるのに、その `List.iter` が例外で飛ばされます。

## 3. バリアは「どの述語のカットか」

バリアは述語呼び出しごとに配られる連番です。何のためにあるかは、`call/1` と並べると分かります。

```
$ echo 'findall(X, opaque(X), L).' | badger -T c.pl -t     opaque(X) :- q(X), call(!).
Call: (0) opaque(_G328)
  Call: (1) q(_G328)
  Exit: (1) q(1)
Exit: (0) opaque(1)
Redo: (0) opaque(1)
  Redo: (1) q(1)                    ← カットが効いていない
  Exit: (1) q(2)
Exit: (0) opaque(2)
...
L = [1,2,3].
```

`call(!)` のカットは `q/1` の選択肢を消しません。`call/1` が**自分のバリアを配る**からです。

```ocaml
let call_goal db goal sk =
  let barrier = new_barrier () in
  try !solve db goal barrier sk with Cut b when b = barrier -> ()
```

カットが投げる番号は `call/1` のもので、`call/1` 自身が捕まえます。`opaque/1` の
`List.iter` には届きません。**「`call/1` はカットに不透明である」という仕様が、
バリアを1つ配ることそのものです。**

## 4. 透明なものと不透明なもの

`solve` が `barrier` をそのまま渡す構文は透明で、`Engine.call_goal` を通す構文は不透明です。
それだけの区別です。

| | カットは | なぜ |
|---|---|---|
| `,` の左右 | 透明 | `solve db first barrier ...` — `barrier` をそのまま渡す |
| `;` の両枝 | 透明 | 同じ |
| `->` の then 節・else 節 | 透明 | 同じ |
| `->` の**条件** | 不透明 | `Engine.once` → `call_goal` |
| `\+` の中 | 不透明 | `Engine.provable` → `once` → `call_goal` |
| `call/1..8` | 不透明 | `call_goal` |
| `findall/3`・`bagof/3`・`forall/2`・`catch/3` | 不透明 | `collect` / `call_goal` |

`examples/cut.pl` はこの表を全部確かめます。

```
$ badger examples/cut.pl
q/1               3 solution(s): [q(1),q(2),q(3)]
first/1           1 solution(s): [first(1)]
opaque/1          3 solution(s): [opaque(1),opaque(2),opaque(3)]
in_condition/1    3 solution(s): [in_condition(1),in_condition(2),in_condition(3)]
member_once/2     1 solution(s): [member_once(a,[a,b,c])]
```

`in_condition/1` は `q(X), ( ! -> true ; true )` です。カットが `->` の**条件**にあるので
局所的で、`q/1` の3つの解は全部出ます。同じカットを選言に置くと局所的ではありません。

```
$ echo 'findall(X, (q(X), (! ; true)), L).'
L = [1].
```

## 5. トレイルの巻き戻しは例外に耐える

例外で飛ばされたフレームは `undo_to` を実行できません。それでも束縛が漏れないのは、
**トレイルがスタックだから**です。

`Cut` を捕まえた `predicate` は自分のマークまで巻き戻します。そのマークは飛ばされた
フレームたちのマークより**前**なので、それらの分もまとめて消えます。

```ocaml
(try List.iter attempt clauses with Engine.Cut b when b = my -> ());
Engine.trace_depth := depth;
Term.undo_to mark;                 (* 飛ばされたフレームの分もここで消える *)
Engine.port "Fail" goal
```

同じ理屈で `throw/1` も安全です。飛ばしたフレームの束縛は残りますが、それを止める `catch/3` が
自分のマークまで巻き戻し、そのマークは残っている束縛より前にあります。**「例外を止める人が
巻き戻す」だけで足りる**というのが、トレイルを1本のスタックにしたことの見返りです。

## 6. `!` は述語呼び出しとして数えられない

カットもゴールですが、`Solve.predicate` を通らないので `inferences` には出ません。同じことは
`,` `;` `->` `\+` `true` `fail` にも当てはまります。**`inferences` が数えているのは
「節を探しに行った回数」で、制御構文はそこに入りません。**

## していないこと

**`!` のトレースポートがありません。** カットが選択肢を消した瞬間は、トレースには
「`Redo` が来ないこと」としてしか現れません（§2 のとおり、それでも読めます）。SWI は
`Cut` という5つめのポートを持っています。

**`Cut` 例外の番号は再利用しません。** `new_barrier` は単調増加の連番で、リセットされません。
`int` が尽きるのは 2^62 回の述語呼び出しの後で、これは現実的な心配ではありません。

**カットの局所性を静的に検査しません。** 節の中のカットがどのバリアを切るかは実行時に決まる
番号なので、「このカットは効かない」と読む前に言うことはできません。[9章](09-library.md)の
meta-interpreter がカットを解釈できないのは、これと同じ理由の裏側です。

## 参考文献

- D. H. D. Warren, [*Implementing Prolog — compiling predicate logic programs*][warren77],
  DAI Research Report 39/40, 1977。カットが「選択点を捨てる」ことだという読みの出どころ。
  WAM の `cut` 命令は選択点スタックのポインタを1つ書き戻すだけで、ここの例外はそれを
  ホストのスタック上で真似たものです。
- ISO/IEC 13211-1:1995, §7.8.4 が `!`、§7.8.5 が「cut parent」— この章の barrier です。
  どの構文がカットに透明かは §7.8 の各項に書かれていて、§4 の表はそれを写したものです。
- R. A. O'Keefe, *The Craft of Prolog*, MIT Press 1990。第3章がカットの使いかた。
  `examples/cut.pl` が並べている形はここから来ています。

[warren77]: https://era.ed.ac.uk/handle/1842/3121

## 実装の地図

| | |
|---|---|
| `engine.ml` 25行 | `exception Cut of int` |
| `engine.ml` 27–33行 | `new_barrier` — 単調増加の連番 |
| `engine.ml` 63行 | `call_goal` — 新しいバリアを配り、自分の番号を捕まえる |
| `engine.ml` 70行 | `once` — `call_goal` の上に立つので、条件のカットは局所的 |
| `engine.ml` 78行 | `provable` — `\+` の中身 |
| `solve.ml` 20–25行 | `!` — 継続を呼んでから投げる |
| `solve.ml` 26–58行 | 透明な構文。`barrier` をそのまま渡しているところ |
| `solve.ml` 85行 | `my` — この述語呼び出しのバリア |
| `solve.ml` 113–116行 | `Cut` を捕まえて、巻き戻して、`Fail` |
| `builtins.ml` 537–553行 | `call/1..8` — `call_goal` を呼ぶだけ |
| `examples/cut.pl` | この章の表を全部確かめるプログラム |

---

[← 5. 導出](05-solve.md) ／ [目次](index.md) ／ [7. 組み込み述語と例外 →](07-builtins.md)
