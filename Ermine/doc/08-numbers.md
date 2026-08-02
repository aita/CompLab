# 8. 数の出入り

Forth には数のリテラルという構文がありません。**辞書を引いて見つからなかった
語**を、数として読もうとするだけです（[4章](04-outer.md)）。だから
`?NUMBER` は普通の語で、`BASE` は普通の変数です。

```forth
T{ s" 42" ?number -> 42 -1 }T
T{ s" $ff" ?number -> 255 -1 }T
T{ s" %1011" ?number -> 11 -1 }T
T{ s" 'z'" ?number -> 122 -1 }T
T{ s" 12x" ?number -> 0 }T
```

この順序には見落としやすい帰結があります。

```forth
16 base ! 10 base !
```

2つ目の `10` は 16 進で読まれるので、`BASE` は 10 進に戻りません。`DECIMAL` が
語として用意されているのはそのためで、それは `BASE` が 10 だったときにコンパイル
された `10 base !` だからです。

```forth
: hex 16 base ! ;
: decimal 10 base ! ;
```

## `<# # #S #>` は逆から作る

数を文字にするのは、下の桁から出てきます。だから Forth の数値整形は
**バッファの終わりから前に向かって**書きます。

```forth
create num-buf 66 allot
: num-end num-buf 66 + ;
variable hld
: <# num-end hld ! ;
: hold ( c -- ) hld @ 1- dup hld ! c! ;
: # ( ud -- ud' ) base @ ud/mod rot digit hold ;
: #s ( ud -- 0 0 ) begin # 2dup or 0= until ;
: #> ( ud -- c-addr u ) 2drop hld @ num-end over - ;
```

`#>` は「今どこまで書いたか」と「終わり」の差を長さにします。この向きのおかげで、
**符号は数字を全部出したあとに置けます**。

```forth
: . ( n -- ) dup >r abs 0 <# #s r> sign #> type space ;
```

`SIGN` は `HOLD` を1回呼ぶだけの語で、書かれる位置は自動的に数字の左になります。
桁数を数えたり、あとから前に詰めたりする必要はありません。

```
$ ./ermine tests/golden.erm | sed -n '/--- printing/,/^--- strings/p'
--- printing
<3> 1 2 3
-1 0 1 1000000
255 18446744073709551615
FF
   7
  -7
|  0|12345|
4 3 2 1 0
```

`-1 U.` が `18446744073709551615` になるのは、`#` が `UD/MOD` を通していて、
そこから下が全部符号なしだからです。`.R` の右詰めは、出来上がった文字列の長さと
幅の差だけ空白を出すだけです。

```forth
: .r ( n width -- ) >r dup >r abs 0 <# #s r> sign #> r> over - spaces type ;
```

## 除算が2つある

カーネルが持っている除算は1つだけで、C の `/` と `%` そのもの、つまり
**0 方向への切り捨て**です。

```forth
T{  7  3 s/rem ->  1  2 }T
T{ -7  3 s/rem -> -1 -2 }T
T{  7 -3 s/rem ->  1 -2 }T
T{ -7 -3 s/rem -> -1  2 }T
```

Forth の `/MOD` `/` `MOD` は**床方向**に丸めます。剰余の符号が除数に揃うので、
配列の添字を巡回させるのに使えます。

```forth
T{  7  3 /mod ->  1  2 }T
T{ -7  3 /mod ->  2 -3 }T
T{  7 -3 /mod -> -2 -3 }T
T{ -7 -3 /mod -> -1  2 }T
```

[`examples/life.erm`](../examples/life.erm) の盤面が端でつながるのは、これだけの
理由です。

```forth
: ix ( x y -- offset ) h mod w * swap w mod + ;
```

`-1 20 MOD` が 19 になるので、境界の判定が1つも要りません。

床方向は切り捨てから作れます。剰余が 0 でなく、その符号が除数と違うときに、
商を1つ減らして剰余に除数を足す。

```forth
: fm/mod
  dup >r sm/rem
  over 0<> if over 0< r@ 0< <> if 1- swap r@ + swap then then
  r> drop ;
: /mod >r s>d r> fm/mod ;
```

## 2セルぶんの積

`UM*` と `UM/MOD` がカーネルにあるのは、倍長整数型のためではありません。
**途中結果があふれないようにするため**です。

```forth
: */mod >r m* r> fm/mod ;
: */ */mod nip ;
```

`a b */ c` は `a*b` を2セルで持ってから `c` で割るので、`a*b` が 64 ビットを
超えても正しい答えが出ます。[`examples/mandel.erm`](../examples/mandel.erm) の
固定小数点乗算はこれ1語です。

```forth
1024 constant one
: f* ( a b -- a*b ) one */ ;
```

数値整形の `#` も同じ理由で `UD/MOD` を通ります。`Ermine` に倍長のリテラルも
`2VARIABLE` もないのは、倍長が「型」ではなく「桁あふれを避ける手段」として
だけ要るからです。

次は[9章 — SEE](09-see.md)。
