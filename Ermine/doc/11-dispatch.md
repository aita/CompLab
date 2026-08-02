# 11. ディスパッチを2つ作って測る

`ermine` と `ermine-switch` は同じソースからできています。違うのは
`-DERMINE_SWITCH` 1つで、それが変えるのは「1つの語から次の語へどうやって行くか」
だけです。プリミティブも `core.erm` も同じなので、差はディスパッチの差です。

```makefile
ermine: src/ermine.c
	$(CC) $(CFLAGS) $(NOMERGE) -o $@ $<
ermine-switch: src/ermine.c
	$(CC) $(CFLAGS) $(NOMERGE) -DERMINE_SWITCH -o $@ $<
```

## 2つの形

`switch` の方は、ループの頭で命令を取り出して1つの `switch` に入ります。
ハンドラの末尾は `break` で、そこからループの頭に戻ります。

```c
for (;;) {
  if (!stacks_ok()) { stack_fault(); continue; }
  w = fetch(ip); ip += CELL;
run:
  op = fetch(w);
  switch (op) {
    case OP_DUP: { push(fetch(sp)); } break;
    ...
  }
}
```

computed goto の方は、ハンドラの末尾に**次の命令を取り出して飛ぶところまで
丸ごと**書きます。

```c
#define DISPATCH                                        \
  do {                                                  \
    if (!stacks_ok()) { stack_fault(); goto next; }     \
    w = fetch(ip); ip += CELL;                          \
    ...                                                 \
    op = fetch(w);                                      \
    goto *labels[op];                                   \
  } while (0)

L_DUP: { push(fetch(sp)); } DISPATCH;
```

ここが要点です。**computed goto の利点は間接ジャンプそのものではありません** —
`switch` も間接ジャンプ1つにコンパイルされます。利点は、間接ジャンプが
**60 箇所に分かれている**ことです。プロセッサの分岐予測は「この分岐は次にどこへ
飛ぶか」を分岐ごとに覚えるので、`DUP` の末尾にある分岐は「`DUP` の次に来やすい
語」を覚えられます。分岐が1つしかなければ、覚えられるのは「どの語の次にでも
来やすい語」だけです。

ディスパッチを共有してしまうと、この利点はまるごと消えます。ハンドラの末尾を
`goto next;`（共有の1箇所へ）にすると、間接ジャンプは1つに戻り、`switch` に
対する優位もなくなります — 余分なジャンプがある分、むしろ遅くなります。

生成コードで確かめられます。

```
$ gcc -O2 -fno-crossjumping -S -o goto.s src/ermine.c
$ gcc -O2 -fno-crossjumping -S -DERMINE_SWITCH -o sw.s src/ermine.c
$ awk '/^inner:/,/\.size\tinner/' goto.s | grep -c 'jmp\t\*'
63
$ awk '/^inner:/,/\.size\tinner/' sw.s   | grep -c 'jmp\t\*'
1
```

`-fno-crossjumping` が要るのは、GCC が末尾の同じコードを見つけると畳んで
しまうからです。何もしなければ 60 箇所のディスパッチは 9 箇所にまとめられ、
複製した意味の大半が失われます。`Makefile` はこのフラグを受け付けるかどうかを
コンパイラに聞いてから付けます。

## 検査は小さくなければならない

[1章](01-image.md)のスタック検査は 1 命令に 1 回走ります。それが 60 箇所に
インライン展開されるので、**小ささが正しさと同じくらい要件**になります。

```c
static inline int stacks_ok(void) {
  return (ucell)(sp0 - sp) <= (ucell)(DSTACK_CELLS * CELL) &&
         (ucell)(rp0 - rp) <= (ucell)(RSTACK_CELLS * CELL);
}
static void stack_fault(void) { ... }
```

判定と、失敗したときの処理（ポインタを底に戻して `THROW` を仕掛ける）が同じ
関数に入っていると、GCC は 60 箇所すべてでインライン化を諦めます。すると
ディスパッチのたびに関数呼び出しが入り、`ip` `sp` `rp` はグローバル変数なので
呼び出しをまたぐたびにレジスタから追い出されます。それだけで computed goto の
方が 40% 遅くなります — つまりこの分割は、読みやすさのためではなく速度のために
あります。

## 測る

```
$ make bench
dispatch: computed goto
3M iterations of DO         156011 us
fib 28, recursively          19445 us
2M stack shuffles           116343 us
dispatch: switch
3M iterations of DO         266410 us
fib 28, recursively          30563 us
2M stack shuffles           248691 us
```

| | computed goto | switch | 比 |
|---|---:|---:|---:|
| `DO ... LOOP` 300 万回 | 156.0 ms | 266.4 ms | 1.71 |
| `fib 28`（再帰） | 19.4 ms | 30.6 ms | 1.57 |
| スタック操作 200 万回 | 116.3 ms | 248.7 ms | 2.14 |

3つ目の差が大きいのは、`DUP` `SWAP` `DROP` `OVER` のような、**1命令あたりの
仕事が最も小さい**列だからです。ディスパッチの費用が相対的に大きく、
また命令の並びが規則的なので分岐予測がよく効きます。逆に `fib` は
`DOCOL`/`EXIT` の往復が多く、飛び先が呼び出し元によって変わるので、
予測しにくいぶん差が縮みます。

測定は[`examples/bench.erm`](../examples/bench.erm)で、時刻は `TICKS`
（マイクロ秒）というプリミティブ1つから取っています。

```forth
variable t0
: start ticks t0 ! ;
: report ( c-addr u -- ) dup >r type 26 r> - spaces ticks t0 @ - 8 .r ."  us" cr ;
```

## どちらのイメージも同じ

`(DISPATCH)` はどちらのカーネルで走っているかを返すプリミティブで、
バナーと `examples/tour.erm` がそれを出します。

```
$ ./ermine -e '." dispatch " (dispatch) . cr bye'
dispatch 1
$ ./ermine-switch -e '." dispatch " (dispatch) . cr bye'
dispatch 0
```

これはカーネルの性質であって、イメージの性質ではありません。だから片方で
保存したイメージをもう片方で起動でき、`(DISPATCH)` はその場で走っている
カーネルの答えを返します（[10章](10-save.md)）。

[目次に戻る](index.md)。
