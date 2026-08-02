# 4. 外側インタプリタと STATE

外側インタプリタは、名前を1つ切り出して、辞書を引いて、実行するかコンパイルするか
を決める、それだけのループです。Ermine ではこう書いてあります。

```forth
: interpret
  begin
    parse-name dup 0= if 2drop exit then
    2dup find-name ?dup if
      >r 2drop r>
      dup nt-immediate? state @ 0= or if
        dup nt-compile-only? state @ 0= and if (compile-only) then
        nt>xt execute
      else nt>xt , then
    else
      2dup ?number if
        >r 2drop r> state @ if postpone literal then
      else
        (undefined)
      then
    then
  again ;
```

言語全体がこの中に折り畳まれています。**`STATE` が 0 なら実行し、1 ならコンパイル
する。ただし immediate な語はどちらでも実行する。** Forth の「コンパイル時と
実行時」の区別は、この1つの変数と1つの `or` で全部です。

`QUIT` はこれを行ごとに呼ぶだけです。

```forth
: quit
  r0 rp! 0 state !
  begin refill while
    ['] interpret catch ?dup if error then
    tty? if state @ 0= if ."  ok" cr then then
  repeat
  bye ;
```

`R0 RP!` で自分の戻り先を捨てているので、`QUIT` は決して返りません。だから
ループの後ろに `BYE` が要ります。

## 入力ソース

`INTERPRET` が読むのは「今の入力ソース」で、それは3語で表されます。

| | |
|---|---|
| `SOURCE ( -- c-addr u )` | 現在の行 |
| `>IN` | その行のどこまで読んだか |
| `REFILL ( -- f )` | 次の行を読む。もう無ければ偽 |

ソースは C 側に16段のスタックがあり、ファイルを開く／文字列を差し込む／1段戻る
がプリミティブになっています。`>IN` は積むときに保存され、戻すときに復元されます。
これだけあれば `INCLUDED` も `EVALUATE` も Forth で書けます。

```forth
: run-source begin interpret refill 0= until ;
: included ( c-addr u -- )
  (push-file) throw
  ['] run-source catch ?dup if note-where (pop-source) throw then
  (pop-source) ;
```

`(PUSH-FILE)` の直後、行はまだ空です。だから `RUN-SOURCE` は「まず解釈して
（何もない）、次に `REFILL`」という順で回れます。文字列ソースでは逆に、行は
最初から埋まっていて `REFILL` が偽を返します。**同じループが両方に効く**のは
この順番のおかげです。

エラーが起きた場所は、そのソースを閉じる**前に**控えておかなければなりません。
閉じたあとでは誰にも聞けないからです。

```
$ ./ermine /tmp/e.erm
/tmp/e.erm:1: undefined word: nosuchword
```

## `:` が2回定義される

`core.erm` の前半 200 行をコンパイルしているのは、C の中にある `:` と `;` です。

```c
CASE(COLON) {
  cell a, n;
  if (!parse_name(&a, &n)) fatal(...);
  create_header((const char *)(mem + a), (size_t)n, F_HIDDEN);
  comma(OP_DOCOL);
  store(v_state, 1);
}
```

これがなければ `core.erm` の1語目も定義できません。C の外側インタプリタも同じ
理由で存在します — `INTERPRET` を Forth で書くには `FIND-NAME` が要り、
`FIND-NAME` を書くにはループが要り、ループを書くには `IF` が要り、`IF` を書くには
`:` が要る。

しかし `HEADER,` が書けた時点で、その依存はすべて解けています。だから
`core.erm` は `:` と `;` を**もう一度**定義します。

```forth
: : parse-name header, docol , hide ] ;
: ; [ ' exit ] literal , reveal 0 state ! ; immediate compile-only
```

これ以降、`FIND-NAME` が先に見つけるのはこちらです。**あなたが打ち込む定義を
コンパイルしているのは Forth で書かれた `:` の方で**、C の `:` は起動時の
200 行のためだけに存在します。C 版はもちろん辞書に残っていますが、
名前が同じなので二度と引かれません。

この2行には、この章の内容がほとんど全部入っています。

- `PARSE-NAME` — 入力から名前を切り出す。同じ語を `INTERPRET` も使います。
- `HEADER,` — [3章](03-dictionary.md)の形をそのまま置く。
- `DOCOL ,` — コードフィールドを書く。これで「コロン定義」というクラスになる。
- `HIDE` — 名前で自分を引けなくする。
- `]` — `STATE` に 1 を書く。

そして `;` の側は、`EXIT` を1つ書き、`REVEAL` し、`STATE` に 0 を戻します。
最後の部分が `[` ではなく `0 state !` になっているのには理由があります。
`[` は immediate なので、`;` の本体を**コンパイルしている最中に**実行されて
しまい、`;` の中には何も残りません。immediate な語を本体に入れたいときは
`POSTPONE` を使うのが定石ですが、`POSTPONE` はまだこの時点では定義されて
いません。だからここは `STATE` に直接書きます。

`]` の方は immediate では**ない**ので、そのままコンパイルされて `:` の一部に
なります。同じ対に見える2語が違う扱いになるのは、そういう理由です。

## `PARSE-NAME` は区切りの空白まで食べる

```forth
: parse-name ( -- c-addr u )
  skip-blanks
  source drop >in @ + 0
  begin source-left 0> while
    source-char bl <= if 1 >in +! exit then
    1+ 1 >in +!
  repeat ;
```

名前の後ろの空白を1つ消費するのは、`S"` と `."` のためです。これらは自分の名前が
切り出された直後の位置から文字列を読み始めるので、区切りの空白が残っていると
それが文字列の先頭に入ってしまいます。C 側の `parse_name` も同じ規則で動きます
— 片方だけが空白を残すと、`core.erm` の中で書いた `." x"` と、あなたが打った
`." x"` の結果が違ってしまいます。

次は[5章 — コンパイラは語である](05-compiler.md)。
