# 10. イメージを保存する

システム全体が1本の配列なので（[1章](01-image.md)）、保存は `fwrite` 1回です。

```c
static cell save_image(const char *path) {
  ...
  if (fwrite(mem, 1, (size_t)used, f) != (size_t)used) { ... }
}
```

`used` は保存時の `DP` です。スタックはその上にありますが、保存する時点では
どちらも空にできるので、書き出すのは辞書の末尾までで足ります。

```
$ ./ermine
: hi ." hello from an image" cr ;
s" my.img" save-image
bye
$ ls -l my.img
-rw-r--r-- 1 ryo ryo 45920 my.img
$ ./ermine --image my.img
hi
hello from an image
```

45 KB。この中に `core.erm` の 210 語と、いま定義した `hi` が入っています。
起動時に `core.erm` を読み直す処理は走りません。

## C なしで再開できるために覚えておくこと

再起動したカーネルは、辞書を作り直しません。だから**辞書を作るときに使った値**を
イメージの中から見つけられなければなりません。それがブートレコードです
（[1章](01-image.md)）。

| | |
|---|---|
| `memsize` | 何バイト確保し直すか |
| `used` | 何バイト読み込むか |
| `DP` `LATEST` `STATE` `BASE` `>IN` のアドレス | カーネル変数の本体はどこか |
| stop xt | 内側インタプリタを止める語はどこか（[2章](02-inner.md)） |
| boot xt | 何を実行して始めるか |
| primsig | 誰が作ったイメージか |

5つの変数の本体をブートレコードの中の固定アドレスに置いてあるので、実のところ
アドレスの記録は冗長です。それでも書いてあるのは、レイアウトが変わっても
古いイメージが壊れずに読めるためです。

boot xt は Forth 側が書き込みます。`core.erm` の最終行です。

```forth
' cold boot-vector !
```

`BOOT-VECTOR` はブートレコードの中のそのセルのアドレスを返す定数で、
「起動時に何が走るか」は Forth が決めています。カーネルはそこを読んで実行する
だけです。

## COLD は2度走る

`COLD` は「新しく起動したとき」と「イメージから再開したとき」の両方で走ります。
だから前回の自分が残した状態を当てにできません。

```forth
: cold
  0 arg# !
  begin arg# @ argc < while
    ['] run-arg catch ?dup if cr .where .throw cr 1 (die) then
  repeat
  tty? if banner then
  quit ;
```

`0 arg# !` がないと、保存した時点で `arg#` が 1 になっていたせいで、イメージから
起動したときに最初のコマンドライン引数が飛ばされます。**保存されるのは辞書
だけではなく、すべての変数の値です。**これはイメージの利点でもあり、
気をつけるべき点でもあります。

## 誰が作ったイメージか

イメージにはプリミティブ表のハッシュが入っています。

```c
static cell prim_signature(void) {
  ucell h = 1469598103934665603ULL;
  for (i = 0; i < OP_COUNT; i++) { ...名前とオペコード番号を混ぜる... }
}
```

プリミティブを1つ足したり、順番を入れ替えたりすると、既存のイメージの中の
コードフィールドの意味が変わります。ハッシュが違えばカーネルは読み込みを断ります。

```
$ ./ermine --image /dev/null -e 'bye'
ermine: /dev/null: truncated image
```

一方、`ermine` と `ermine-switch` はプリミティブ表が同じなので、片方が保存した
イメージをもう片方が読めます。違うのはディスパッチの仕方だけで、それは
イメージの中身に現れません — テストがそれを確かめています。

```
$ tests/run.sh | sed -n '/saved image/,$p'
saved image
  ok    --image reproduces tests/golden.out
  ok    --image passes the assertions
  ok    an image saved by one dispatch runs under the other
  ok    a file that is not an image is refused
```

次は[11章 — ディスパッチを2つ作って測る](11-dispatch.md)。
