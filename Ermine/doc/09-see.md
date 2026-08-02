# 9. SEE — スレッドを読み戻す

コロン定義は xt を並べた配列です（[2章](02-inner.md)）。だから逆アセンブラは、
その配列を1セルずつ読んで名前に直すだけで書けます。復元も推測も要りません。

```
$ ./ermine
: square dup * ;
see square
: square dup * ;
```

## xt から名前へ

[3章](03-dictionary.md)のとおり、ヘッダは名前がコードフィールドより前にあるので、
xt から名前へは直接戻れません。辞書を頭から歩いて、xt が一致するものを探します。

```forth
: xt>nt ( xt -- nt | 0 )
  latest @
  begin dup while
    2dup nt>xt = if nip exit then
    @
  repeat nip ;
```

語の数だけの線形探索で、それがセルの数だけ走るので `SEE` は O(語数 × 定義長) です。
293 語の辞書では気になりません。

## スレッドの中の非トークン

例外は4つだけです。`(LIT)` `(BRANCH)` `(0BRANCH)` `(S")` は、直後のセルを
データとして持っています。それを知っていれば、残りは全部 xt です。

```forth
: see-cell ( start a -- start a' )
  dup @
  dup 'lit = if drop cell+ dup @ . cell+ exit then
  dup 'branch = if drop cell+ ." branch>" over over @ .offset space cell+ exit then
  dup '0branch = if drop cell+ ." 0branch>" over over @ .offset space cell+ exit then
  dup ['] (s") = if
    drop cell+ [char] s emit [char] " emit space
    dup count 2dup type [char] " emit space + aligned nip exit
  then
  .xt space cell+ ;
```

分岐先は絶対アドレスで書かれていますが、そのまま出しても読めないので、
定義の先頭からのセル数に直します。

```forth
: .offset ( start target -- ) swap - cell / 0 .r ;
```

```
$ ./ermine tests/golden.erm | head -4
: square dup * ;
: signum dup 0< 0branch>9 drop -1 branch>18 0> 0branch>16 1 branch>18 0 ;
: greet s" hello" type cr ;
: classify 1 over = 0branch>12 drop s" one" type branch>28 2 over = 0branch>24 drop s" two" type branch>28 s" many" type drop ;
```

読み方が分かる出力です。

- `signum` の `IF ... ELSE ... THEN` が、2つの `0branch` と2つの `branch` に
  なっています。飛び先の 9・18・16 は本体先頭からのセル番号。
- `greet` の `." hello"` は `s" hello" type` そのもの。[5章](05-compiler.md)の
  `."` の定義がそう書いてあるので、`SEE` は嘘をついていません。
- `classify` の `CASE` は、`over = 0branch ... drop`（= `OF`）と `branch`
  （= `ENDOF`）の並びです。最後の `drop` が `ENDCASE` の1語。
  **`CASE` は `IF` の略記である**という[5章](05-compiler.md)の主張が、
  そのまま画面に出ています。

`(DOES>)` は名前どおりに出ます。

```
$ ./ermine
: my-constant create , does> @ ;
see my-constant
: my-constant create , (does>) @ ;
```

`DOES>` がコンパイルするのは `(DOES>)` の xt 1つだけなので、これは正確です
（[6章](06-defining.md)）。

## SEE が見せないもの

`SEE` はコロン定義しか読めません。

```forth
: see ( "name" -- )
  ' dup @ docol <> if drop ." not a colon definition" cr exit then
  ...
```

プリミティブには本体がなく、`CREATE` した語の本体はデータであって命令ではない
からです。逆に言えば、コードフィールドを1つ見るだけで「読めるかどうか」が
分かる、ということでもあります。

同じことは `.S` や `WORDS` や `DUMP` にも言えます。どれもイメージの中身を
読むだけの普通の語で、カーネルの助けは要りません。

```forth
: .s ( -- )
  [char] < emit depth 0 .r [char] > emit space
  depth 0 ?do depth i - 1- pick . loop ;
```

`PICK` があるのでスタックの中身が読める、`LATEST` があるので辞書が歩ける、
`@` があるのでイメージが読める。デバッガに特別な権限は要りません。

次は[10章 — イメージを保存する](10-save.md)。
