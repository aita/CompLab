# 7. CATCH と THROW

例外処理は Forth で7行です。C 側に `setjmp` に当たるものはありません。

```forth
variable handler

: catch ( xt -- exc | 0 )
  sp@ >r handler @ >r rp@ handler !
  execute
  r> handler ! r> drop 0 ;

: throw ( n -- )
  ?dup if
    handler @ 0= if (uncaught) then
    handler @ rp! r> handler !
    r> swap >r sp! drop r>
  then ;
```

必要な道具は `SP@ SP! RP@ RP!` の4つだけです。それは[1章](01-image.md)のとおり、
両方のスタックがイメージの中の配列で、そのポインタがただのセルだからです。

## ハンドラはリターンスタックポインタである

`CATCH` が走ると、リターンスタックはこうなります。

```
        ...
        CATCH の呼び出し元へ戻るアドレス
        CATCH に入る前のデータスタックポインタ     ← sp@ >r
        1つ外側のハンドラ                          ← handler @ >r
  rp →                                            ← rp@ handler !
```

`handler` はこの位置を指します。**「ハンドラ」として保存されている情報は
リターンスタックポインタ1つだけで、残りはその指す先に置いてある**、というのが
この実装の全部です。

`THROW` はまず `handler @ rp!` でリターンスタックをそこまで巻き戻します。
すると `R>` が拾えるのは、順に「1つ外側のハンドラ」「保存したデータスタック
ポインタ」、そしてその下にあるのは **`CATCH` の呼び出し元へ戻るアドレス**です。

- `r> handler !` — 外側のハンドラを復元
- `r> swap >r sp! drop r>` — データスタックを `CATCH` に入る直前まで戻し、
  そのとき積まれていた xt を捨て、投げられた値を積む
- `THROW` の最後の `EXIT` — リターンスタックのトップはもう
  `CATCH` の呼び出し元なので、**`CATCH` から2回目の復帰**をする

`CATCH` が「値を返す場所」を2つ持っている、と言い換えてもよい。何事もなければ
最後まで走って 0 を返し、`THROW` が来ればその途中を全部飛ばして値を返します。
呼び出し側から見れば区別は返り値だけです。

```forth
: risky ( n -- n ) 10 swap / ;
: try dup . ." -> " ['] risky catch ?dup if ." threw " .throw else . then cr ;
```

```
$ ./ermine examples/tour.erm | sed -n '/5\./,/^$/p'
--- 5. errors are values
5 -> 2
0 -> threw division by zero
```

## データスタックは空にされない

`THROW` が戻すのは `CATCH` を実行した時点のデータスタックです。空ではありません。
これはテストに書いてあります。

```forth
: deep-thrower 1 2 3 4 5 9 throw ;
T{ 7 ' deep-thrower catch -> 7 9 }T
```

`7` は `CATCH` より前に積まれていたので残り、`deep-thrower` が積んだ5つは消えます。
`CATCH` は「そこまで巻き戻す」のであって「片付ける」のではありません。

## カーネルからの投擲

プリミティブが見つけるエラー（0除算、範囲外アドレス、スタックの底抜け、
不正なオペコード）は、C から Forth の `THROW` を呼ぶわけにいきません。
かわりに**次に実行される語を `THROW` にします**（[2章](02-inner.md)）。

```c
static void do_throw(cell code) {
  ...
  push(code);
  ip = THROW_TRAMP;      /* [ THROW の xt ][ stop ] */
}
```

`THROW` の xt は最初の1回だけ辞書から引いて、ブートレコードのトランポリンに
書き込んでおきます。だからカーネルは `THROW` の**名前**しか知らず、その中身には
関与しません。逆に言えば、`CATCH` を Forth 側で書き換えれば、カーネルのエラーの
捕まり方もそれに従います。

```forth
: div0 1 0 / ;         T{ ' div0 catch -> -10 }T
: bad-address -1 @ ;   T{ ' bad-address catch -> -9 }T
: underflows drop drop drop drop ;  T{ ' underflows catch -> -4 }T
: overflows begin 1 again ;         T{ ' overflows catch -> -3 }T
: r-overflows recurse ;             T{ ' r-overflows catch -> -5 }T
```

スタックが壊れた状態から `CATCH` に戻れるのは、[1章](01-image.md)のガードバンドの
おかげです。あふれた側のポインタを底に戻してから投げるので、`THROW` 自身が
使う数セルは必ず確保されています。

## ハンドラがないとき

`handler` が 0 のとき、`0 RP!` をやると何もかも壊れます。だから `THROW` は
その手前で `(UNCAUGHT)` を呼びます。これはメッセージを出して C 側へ longjmp する
プリミティブで、`core.erm` を読んでいる最中なら異常終了、そうでなければ
`QUIT` をやり直します。

普段この道は通りません。`QUIT` が毎行 `CATCH` しているからです。

```forth
: quit
  r0 rp! 0 state !
  begin refill while
    ['] interpret catch ?dup if error then
    ...
```

ファイルを読んでいるときは `INCLUDED` が捕まえ、場所を控えてから外へ投げ直します。

```forth
: included ( c-addr u -- )
  (push-file) throw
  ['] run-source catch ?dup if note-where (pop-source) throw then
  (pop-source) ;
```

`(PUSH-FILE)` の返り値をそのまま `THROW` に渡しているのは、`THROW` が 0 なら
何もしない語だからです。「成功なら 0」という C の慣習と、そのまま噛み合います。

## メッセージ

投げられる値はただの整数で、意味は `.THROW` という1つの語が持っています。

```forth
: .throw ( n -- )
  dup  -1 = if drop ." aborted" exit then
  dup  -2 = if drop exit then
  dup  -3 = if drop ." stack overflow" exit then
  ...
  ." throw " . ;
```

`-2` が何も言わないのは、`ABORT"` がもうメッセージを出しているからです。

```forth
: (abort") rot if type cr -2 throw else 2drop then ;
: abort" postpone s" postpone (abort") ; immediate compile-only
```

`-13`（未定義語）と `-14`（compile-only）は、名前を1つ控えてから投げるので、
メッセージにそれが出ます。

```
$ ./ermine /tmp/e.erm
/tmp/e.erm:1: undefined word: nosuchword
```

次は[8章 — 数の出入り](08-numbers.md)。
