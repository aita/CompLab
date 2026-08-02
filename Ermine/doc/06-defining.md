# 6. CREATE ... DOES>

`CREATE` は名前を1つ作り、辞書に3つの部品を置きます。

```forth
: create parse-name header, dovar , 0 , ;
```

コードフィールドに `DOVAR`、`DOES>` のための空きに 0、そのあとが本体です。
`CREATE` した語を実行すると、本体のアドレスが積まれます。

```forth
create buf 64 allot
buf 64 erase
```

`DOES>` は、そのコードフィールドを**あとから書き換える**語です。

```forth
: my-constant create , does> @ ;
299792458 my-constant c
c .        \ 299792458
```

`my-constant` を実行すると `CREATE` が `c` を作り、`,` が値を本体に書き、
それから `DOES>` の仕掛けが `c` のコードフィールドを `DODOES` に、空きの1セルを
「`DOES>` の後ろにある `@` の位置」に書き換えます。以降 `c` を実行すると、
[2章](02-inner.md)の `DODOES` が本体のアドレスを積んでそこへ呼び出すので、
`@` が走って値が出ます。

```
  create の直後の c            (does>) が走ったあとの c

  xt ─▶ +-----------+          xt ─▶ +-----------+
        |   DOVAR   |                |  DODOES   |
        +-----------+                +-----------+
        |     0     | ← DOES> の      |   addr    | ── A
        +-----------+    ための空き    +-----------+
 >body ▶| 299792458 |         >body ▶| 299792458 |
        +-----------+                +-----------+

  my-constant のスレッド

  +--------+--------+--------+---------+--------+--------+
  | DOCOL  | create |   ,    | (does>) |   @    |  exit  |
  +--------+--------+--------+---------+--------+--------+
                                  |        ▲
                                  |        A ← addr が指すのはここ
                                  +--------+
                                  (does>) の R> が返すアドレス
```

## `(DOES>)` は自分の戻り先を奪う

仕掛けは Forth の1行です。

```forth
: (does>) r> latest @ nt>xt dodoes over ! cell+ ! ;
: does> [ ' (does>) ] literal , ; immediate compile-only
```

`DOES>` はコンパイル時に `(DOES>)` の xt を1つ書くだけです。実行時、
`(DOES>)` の中で `R>` が返すのは「`my-constant` のスレッドにおける
`(DOES>)` の次のセル」、つまり `DOES>` の後ろに続くコードの先頭アドレスです。
それを新しい語の空きセルに書き、コードフィールドを `DODOES` にする。

そして `(DOES>)` は自分の戻りアドレスをもう消費してしまっているので、
続く `EXIT` が返るのは **`my-constant` の呼び出し元**です。だから
`DOES>` の後ろのコードは、定義しているその瞬間には実行されません。

「戻りアドレスを奪って別の意味に使う」というのは、[2章](02-inner.md)の `(S")` と
まったく同じ手です。リターンスタックが呼び出し規約として素直だから、
こういうことが1行で書けます。

## これだけで何ができるか

`CONSTANT` と `VALUE` はコードフィールドを差し替えるだけで済みます
（`DOES>` を通すより1段速く、`TO` がクラスを見分けられます）。

```forth
: variable create 0 , ;
: constant create , docon latest @ nt>xt ! ;
: value    create , doval latest @ nt>xt ! ;
: to ' >body state @ if postpone literal ['] ! , else ! then ; immediate
```

`TO` が immediate なのは、コンパイル中なら「アドレスを積んで `!`」を書き、
インタプリタ中ならその場で書き込む、という2つの振る舞いが要るからです。
その分岐は `STATE @` を見るだけで、[4章](04-outer.md)の外側インタプリタと
同じ判断基準です。

添字付き配列は `DOES>` の代表例です。

```forth
: array create cells allot does> swap cells + ;
5 array a5
11 0 a5 !   22 3 a5 !
0 a5 @ .  3 a5 @ .      \ 11 22
```

2次元でも同じことで、幅を本体の先頭に置いておけば実行時に読めます。

```forth
: matrix ( w h "name" -- )
  create over , * cells allot
  does> ( x y a -- addr ) dup @ rot * rot + cells swap cell+ + ;
3 3 matrix m
```

```
$ ./ermine examples/tour.erm | sed -n '/3\./,/^$/p'
--- 3. a data structure with a run-time action
   0   0   0
   0   1   2
   0   2   4
```

`DEFER` は本体に xt を持たせて、実行時にそれを `EXECUTE` します。

```forth
: defer create ['] abort , does> @ execute ;
: is ' >body state @ if postpone literal ['] ! , else ! then ; immediate

defer greet
:noname ." hi" cr ; is greet
greet          \ hi
```

`MARKER` は `HERE` と `LATEST` を本体に入れておき、実行時に両方を書き戻します
（[3章](03-dictionary.md)）。

```forth
: marker here latest @ create , , does> dup @ latest ! cell+ @ dp ! ;
```

`CREATE` の前に `HERE` を読んでいるので、巻き戻し先は `MARKER` が作る語の
**手前**です。つまりこの語は、実行されると自分自身も辞書から消します。

## `>BODY` と DOES> が渡すアドレスは同じ

`CREATE` が必ず2セル取るおかげで、語のクラスに関わらず本体は `xt+16` です。

```forth
: peeker create 1234 , does> ;
peeker peek
peek @ .                    \ 1234
peek ' peek >body = .       \ -1
```

`DOES>` の直後に何も書かなければ、`peek` は「本体のアドレスを積む語」のまま
残ります。`DOVAR` と `DODOES` の違いは、そこに何か続くかどうかだけです。

次は[7章 — CATCH と THROW](07-errors.md)。
