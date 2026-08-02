# 5. コンパイラは語である

`IF` はキーワードではありません。フラグが立った辞書エントリです。

```forth
: if '0branch , here 0 , ; immediate compile-only
: then here swap ! ; immediate compile-only
```

`IF` は2セル書きます。`(0BRANCH)` の xt と、飛び先を入れるための空きです。
そして**空きのアドレスをデータスタックに積んで**帰ります。`THEN` はそれを取って
`HERE` を書き込みます。それだけです。

```
: abs dup 0< if negate then ;

              IF が書く2セル
              +----------+----------+
  +-----+-----+          |          +--------+
  | dup | 0<  | (0branch)|   ????   | negate |          ← ここが THEN の時点の HERE
  +-----+-----+----------+----------+--------+
                              ▲                             |
                              |                             |
                        データスタックに ────────────────────+
                        積まれたアドレス      THEN が HERE を書き込む
```

`ELSE` は両方をやります。自分の分岐を1つ置き、その空きのアドレスを積み、
それから `IF` の空きを埋めます。

```forth
: else 'branch , here 0 , swap here swap ! ; immediate compile-only
```

後ろ向きの分岐はもっと簡単で、`BEGIN` は `HERE` を積むだけ、`UNTIL` はそれを
そのまま書き込むだけです。

```forth
: begin here ; immediate compile-only
: until '0branch , , ; immediate compile-only
: while '0branch , here 0 , ; immediate compile-only
: repeat swap 'branch , , here swap ! ; immediate compile-only
```

前向きの分岐は「穴を空けて、あとで埋める」、後ろ向きの分岐は「覚えておいて、
そのまま書く」。`BEGIN ... WHILE ... REPEAT` は両方を1つずつ使います。

```
  BEGIN が積む HERE
     |
     |  +-------+----------+-------+-------+----------+-------+
     +─▶| test  | (0branch)| ????  | body  | (branch) | dest  |
        +-------+----------+-------+-------+----------+-------+
                               ▲                          |
                               |                          |
        WHILE が積んだアドレス ─+                          |
        REPEAT が HERE を書き込む（ループの出口）          |
                                                          |
        REPEAT が BEGIN のアドレスをそのまま書き込む ──────+
```

コンパイル中、データスタックには `( dest hole )` の2つが載っているだけです。
`REPEAT` の `swap` はその順序を入れ替えるためにあります。

**コンパイラの作業台はデータスタックです。**制御構造のための専用スタックも、
構文木も、ネストの深さを数える変数もありません。入れ子が正しく閉じるのは、
スタックが後入れ先出しだからです。閉じ忘れれば、そのアドレスは残ったままになり、
次に何かがスタックを見たときに気づきます。

## IMMEDIATE

`IMMEDIATE` はフラグを1つ立てるだけの語です。

```forth
: immediate latest @ cell + dup c@ f_immediate or swap c! ;
```

`core.erm` の2行目、`\` より前にあります。`\` 自身が immediate な語だからです。

```forth
: \ source nip >in ! ; immediate
```

行コメントとは「`>IN` を行末まで進める語」のことです。

## LITERAL と POSTPONE

`LITERAL` はスタックにある値を、実行時に積まれるようにコンパイルします。

```forth
: literal ( x -- ) 'lit , , ; immediate compile-only
```

`'lit` はカーネルが定数として出している `(LIT)` の xt です。**探索なしで手に入る
xt が3つだけ必要**で（`'lit`・`'branch`・`'0branch`）、それは `IF` を書くのに
`FIND-NAME` が要り、`FIND-NAME` を書くのに `IF` が要る、という循環を切るためです。
この3つが定数として渡された時点で循環は切れ、以降は `'` と `[']` で足ります。

`POSTPONE` は「1段深いところでやってくれ」を意味します。

```forth
: postpone ( "name" -- )
  parse-name find-name ?found
  dup nt-immediate? swap nt>xt swap
  if , else 'lit , , [ ' , ] literal , then ; immediate compile-only
```

名前が immediate なら、その xt をそのままコンパイルする — すると、いま定義して
いる語が**実行される**ときにそれが走ります。immediate でなければ、
「その xt を積んで `,` する」コードをコンパイルする — すると、いま定義している語が
実行されるときに、その語が**コンパイルされる**ようになります。

この2つの場合分けが `POSTPONE` の全部で、それがあると新しい制御構造が書けます。

```forth
: unless postpone 0= postpone if ; immediate compile-only
: classify dup 0< unless ." not " then ." negative" cr ;
```

```
$ ./ermine examples/tour.erm | sed -n '/4\./,/^$/p'
--- 4. a control structure
negative
not negative
```

`UNLESS` は `IF` に仕事を渡しているだけです。分岐のアドレスは `IF` がデータ
スタックに積み、`THEN` がそれを受け取ります — `UNLESS` はその間に一切関与
しません。だから `UNLESS ... ELSE ... THEN` も何もせずに動きます。

## `[` と `]`

```forth
: [ 0 state ! ; immediate compile-only
: ] 1 state ! ;
```

`[` は immediate（コンパイル中に効かなければ意味がない）、`]` はそうではない
（インタプリタ状態で実行されるのだから）。この非対称は `STATE` の定義から
そのまま出てきます。

定義の途中で計算をしたいときに使います。

```forth
: bracketed [ 2 3 + ] literal ;   \ 本体には 5 が1つ入る
```

`core.erm` はこの形を何度も使います。`POSTPONE` がまだない場所で、
「いま探して、実行時に積む」を書きたいからです。

```forth
: does> [ ' (does>) ] literal , ; immediate compile-only
```

## compile-only

`IF` を素で打つと、埋めるべき定義がありません。フラグを1つ足して、
`INTERPRET` にそれを見させます。

```
$ printf 'if\n5 0 do i . loop\nbye\n' | ./ermine

compile only: if

compile only: do
```

これがないと、`IF` はコンパイル先のない場所に2セル書き込み、`DO` はループを
1周だけ回して `I` にごみを返します。黙って壊れるより、名前を出して止まる方が
よいので、フラグ用のビットを1つ長さから借りています（[3章](03-dictionary.md)）。

`compile-only` は `IMMEDIATE` と同じく `LATEST` に印を付ける語なので、定義の
最後に並べて書けます。

```forth
: if '0branch , here 0 , ; immediate compile-only
```

## DO ... LOOP と LEAVE

カウント付きループはリターンスタックに limit と index を積みます。`(DO)` は
Forth で書けます — ただし、自分の戻り先を一度どかす必要があります。

```forth
: (do) ( limit index -- ) r> -rot swap >r >r >r ;
```

`R>` で自分の戻りアドレスをデータスタックに出し、limit と index を積み、最後に
戻りアドレスを積み直す。すると `EXIT` は正しく返り、リターンスタックには
limit と index が残ります。`I` はそこを読むだけです。

```forth
: i rp@ cell+ @ ;
: j rp@ 3 cells + @ ;
```

`I` の中では、リターンスタックのトップは `I` 自身の戻りアドレスです。その1つ下が
index。`J` は2段ぶん深いところを見ます。だから**内側のループが外側を隠す**という
規則が、ただのオフセットとして出てきます。[`examples/sieve.erm`](../examples/sieve.erm)
の内側のループでは `I` が「消す倍数」、`J` が「消している素数」です。

`LEAVE` は前向きの分岐で、飛び先は `LOOP` になるまで分かりません。`IF` のように
データスタックに積むわけにはいきません — 間に `IF` や `CASE` が入ると混ざって
しまうからです。だから小さな配列に控えておきます。

```forth
create leaves 64 cells allot
variable #leaves
: leave [ ' unloop ] literal , 'branch , here 0 , +leave ; immediate compile-only
: loop  [ ' (loop) ] literal , '0branch , , resolve-leaves ; immediate compile-only
```

`DO` は「その時点の `#leaves`」をデータスタックに積み、`LOOP` はそこまで巻き戻し
ながら埋めます。入れ子のループが互いの `LEAVE` を拾わないのは、この境目のおかげ
です。

`?DO` の前向き分岐も同じ仕組みに乗ります — ループを1回も回らないときの飛び先は、
`LEAVE` の飛び先と同じ場所だからです。

## CASE

```forth
: case 0 ; immediate compile-only
: of 1+ >r postpone over postpone = postpone if postpone drop r> ; immediate compile-only
: endof >r postpone else r> ; immediate compile-only
: endcase postpone drop 0 ?do postpone then loop ; immediate compile-only
```

`CASE` は「まだ閉じていない `THEN` の数」を積むだけです。`OF` と `ENDOF` は
その数を `>R` で一時的にどかしてから `IF` と `ELSE` を呼び、終わったら戻します
— `IF` は自分の分岐アドレスをスタックのトップに置きたがるので、場所を空けて
やらなければならないからです。`ENDCASE` はその数だけ `THEN` を繰り返します。

つまり `CASE` は `IF` を N 回書いたものの略記で、覚えておくべきことは N だけです。

次は[6章 — CREATE ... DOES>](06-defining.md)。
