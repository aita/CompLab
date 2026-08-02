# 3. 辞書

辞書は連結リストです。ノードは辞書空間の中に、他のデータと混ざって、定義された
順に並んでいます。

```
 nt                                             xt
  |                                              |
  ▼                                              ▼
 +----------+---+---------+---------+----------+----------+
 |   link   |f+l|  name   | padding |   code   |  body    |
 |  1 cell  | 1 | len ﾊﾞｲﾄ| 整列まで |  1 cell  |   ...    |
 +----------+---+---------+---------+----------+----------+
       |      |
       |      +-- imm 0x80 | hidden 0x40 | compile-only 0x20 | len 0x1f
       +-- 1つ前の語の nt。0 が鎖の端
```

`link` は1つ前の語の `nt`。鎖の端は 0。`LATEST` は最後に作られた語の `nt` を
持つ変数です。

## 1バイトに3つのフラグと長さ

2番目のフィールドは1バイトで、上位3ビットがフラグ、下位5ビットが名前の長さです。

| ビット | 意味 |
|---|---|
| 0x80 | immediate — コンパイル中でも実行される（[5章](05-compiler.md)） |
| 0x40 | hidden — `FIND-NAME` から見えない |
| 0x20 | compile-only — インタプリタ状態で実行するとエラー |
| 0x1f | 名前の長さ |

名前は最大 31 文字で、それより長い名前は `HEADER,` が先頭 31 文字だけを取ります。
これは古典的な Forth の振る舞いそのままです。

実際のバイトを見ます。

```
$ ./ermine
: sq dup * ;
latest @ 48 dump
00B310: 00 B2 00 00 00 00 00 00 02 73 71 00 00 00 00 00
00B320: 00 00 00 00 00 00 00 00 A0 44 00 00 00 00 00 00
00B330: 80 46 00 00 00 00 00 00 18 44 00 00 00 00 00 00
```

```
  0xB310  00 B2 00 00 00 00 00 00    link = 0xB200、1つ前の語      ← nt
  0xB318  02                         フラグなし、長さ 2
  0xB319  73 71                      "sq"
  0xB31B  00 00 00 00 00             整列のための詰め物
  0xB320  00 00 00 00 00 00 00 00    DOCOL                        ← xt
  0xB328  A0 44 00 00 00 00 00 00    dup  の xt   ┐
  0xB330  80 46 00 00 00 00 00 00    *    の xt   ├ スレッド（2章）
  0xB338  18 44 00 00 00 00 00 00    exit の xt   ┘
```

xt はヘッダの長さから計算します。だから `nt` から `xt` は引き算ですが、
`xt` から `nt` は逆に辿れません — 名前が先にあるので、xt の手前に何バイトの
詰め物があったかが分からないからです。`SEE` が必要とする「xt → 名前」は、
辞書を頭から探して一致する xt を見つけることで解いています（[9章](09-see.md)）。

```forth
: nt>len ( nt -- u ) cell+ c@ f_lenmask and ;
: nt>name ( nt -- c-addr u ) dup cell+ 1+ swap nt>len ;
: nt>xt ( nt -- xt ) dup cell+ 1+ swap nt>len + aligned ;
```

## この形を知っているのは2箇所だけ

ヘッダの形を知っているコードは、`core.erm` の上の6語と、C の
`create_header` / `nt_to_xt` / `find_word` だけです。**同じ形式が2回実装されて
いる**のは、C 側が自分のプリミティブのヘッダを作らなければならず、そのときには
まだ Forth 側の `HEADER,` が存在しないからです。この重複はブートストラップの
継ぎ目そのもので、それ以上の意味はありません。

Forth 側は次のようになっています。

```forth
: header, ( c-addr u -- )
  f_lenmask min
  align here >r
  latest @ ,          \ link
  dup c,              \ flags+length
  here swap dup allot move
  align
  r> latest ! ;
```

`,` も `C,` も `ALLOT` も `ALIGN` も、この時点ですでに Forth で定義済みです
（`core.erm` の最初の 10 行）。だから `HEADER,` を書くのに新しい道具は要りません。
そしてこれが書けた瞬間に `:` が書けます（[4章](04-outer.md)）。

## 探索

```forth
: find-name ( c-addr u -- nt | 0 )
  latest @
  begin dup while
    >r 2dup r@ nt-matches? if 2drop r> exit then r> @
  repeat nip nip ;
```

新しいものから順に見ていくので、**同じ名前を再定義すると新しい方が見つかります**。
古い方は消えず、鎖の先で生き続けます。これが Forth の「再定義」で、古い定義を
参照していた既存の語は古い方を呼び続けます。

```forth
: shadowed 1 ;
: shadowed shadowed 1 + ;
shadowed .          \ 2
```

```
  2行目をコンパイルしている最中の鎖（新しいものが左）

  LATEST ─▶ +----------+     +----------+     +----------+
            | shadowed |     | shadowed |     |   ...    |
            |  hidden  | ──▶ |          | ──▶ |          |
            +----------+     +----------+     +----------+
                 ▲                 ▲
                 |                 +-- FIND-NAME はこちらを返す
                 +-- 飛ばされる。RECURSE だけが LATEST 経由で届く
```

2行目の `shadowed` が1行目のものを指せるのは、定義中の語が **hidden** になって
いるからです。`:` が `HIDE` を呼び、`;` が `REVEAL` を呼びます。

```forth
: hide   latest @ cell+ dup c@ f_hidden or swap c! ;
: reveal latest @ cell+ dup c@ f_hidden invert and swap c! ;
```

隠れている間は自分の名前で自分を呼べないので、再帰には別の語が要ります。

```forth
: recurse latest @ nt>xt , ; immediate compile-only
```

`FIND-NAME` を経由せず `LATEST` から直接 xt を取って積むだけです。「名前で探すと
見つからないが、`LATEST` を見れば分かる」という状況を、そのまま利用しています。

## 名前トークンは値である

`nt` も `xt` も、ただのアドレスです。だから辞書を歩くのはユーザーの語で書けます。

```forth
: words ( -- )
  0 latest @
  begin dup while
    dup nt-hidden? 0= if dup nt>name type space swap 1+ swap then
    @
  repeat drop
  cr . ." words" cr ;
```

```
$ echo 'words bye' | ./ermine | tail -1
293 words
```

`MARKER` も同じ性質の上に乗っています。`HERE` と `LATEST` を覚えておいて、
実行されたら両方を書き戻すだけ。それだけで、それ以降に定義された語が
**自分自身も含めて**辞書から消えます。

```forth
: marker here latest @ create , , does> dup @ latest ! cell+ @ dp ! ;
```

次は[4章 — 外側インタプリタと STATE](04-outer.md)。
