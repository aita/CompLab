# クロージャ変換 — `closure.ml`

関数をすべてトップレベルへ持ち上げます。このパスを抜けると、入れ子の関数定義は存在しません。

## 1. 2つの呼び方

関数をすべてトップレベルへ持ち上げます。このパスを抜けると、入れ子の関数定義は存在しません。

### 2つの呼び方

**何も捕獲しない関数は実行時表現を一切持ちません。** ラベルへの直接呼び出し
（`Call_direct`）になり、値としてどこかに置かれることもありません。

捕獲する関数は**ヒープブロック**になります。

```
[ コードポインタ | 捕獲した値 | 捕獲した値 | ... ]
```

呼ぶ側（`Call_closure`）は先頭からコードポインタを読んで飛び、**ブロック自体を専用レジスタ
`t6` で渡します**。呼ばれた側はそこから捕獲を読みます。`t6` を割り付けから外してあるのは
このためです（[レジスタ割り付け §1](regalloc.md#1-問題)）。

![クロージャのヒープ表現](./figures/closure-block.png)

```
$ sablec --dump-closure -o /dev/null a.sbl
sable_add_8 (x.9) capturing (n.7) =           let rec adder n =
  x.9 + n.7                                     let rec add x = x + n in
sable_adder_6 (n.7) =                           add
  let add.8 = closure sable_add_8 capturing (n.7)
  in
  add.8
sable_main () =
  ...
  let t.4.13 : int =
    call closure f.10 (t.3.14)                ← f が何かは実行時にしか分からない
  in
```

### どちらになるかの決め方

**楽観的な不動点**です。`let rec` の組を1つ見るたびに、

1. 組の全員が直接呼べると**仮定して**本体を変換する。
2. 変換した本体に、組の名前でも引数でもない自由変数が残っていないか調べる。
3. 残っていなければ仮定は当たり。全員が `Call_direct` で呼ばれ、クロージャは作られません。
4. 残っていれば**捨ててやり直します** — 今度はクロージャが要ると分かった状態で変換します。

やり直しが必要なのは、仮定が外れると**組の内側の呼び出しも変わる**からです。1回目は
`even` から `odd` をラベルで直接呼んでいましたが、クロージャが要ると分かった時点でその
呼び出しもクロージャ経由になります。`lifted` を巻き戻してから変換し直しているのはこれです。

`sum` は何も捕獲しないので、再帰呼び出しはラベルへの直接呼び出しです。

```
$ sablec --dump-closure -o /dev/null doc/sum.sbl
sable_sum_18 (l.19) =
  ...
    let t.10.27 : int =
      call sable_sum_18 (fld.7.24)   ← 直接呼び出し。クロージャなし
```

**直接呼べる関数を値として使ったとき**だけは、その場でコードポインタだけのクロージャを
作ります（`close_over`）。関数を呼ばずに渡すなら、渡せる形が要るからです。

### 自分自身と、兄弟を捕獲する

自己再帰かつ捕獲もする関数は、**自分自身を捕獲します**。自分を呼ぶ手段がそれしかない
からです。

```
sable_go_12 (k.13) capturing (go.12 n.11) =   let rec make n =
  ...                                           let rec go k =
    call closure go.12 (t.4.15)                   if k = 0 then n else go (k - 1)
                                                in go
```

相互再帰なら、互いを捕獲します。

```
sable_even_14 (k.16) capturing (n.13 odd.15) = ...
sable_odd_15 (k.20) capturing (even.14) = ...
```

`even` のブロックには `odd` のブロックのアドレスが、`odd` のブロックには `even` の
アドレスが入るので、**クロージャは互いを指す循環**になります。ブロックを1つずつ作って
中身を書き込む順では作れません。

そのために `Make_closures` は**組をまとめて受け取ります**。先に全部のブロックを確保して
名前を束縛し、それから中身を書き込みます。自己参照も兄弟への参照も、これで閉じます。

捕獲する例をまとめて見るなら `examples/queens.sbl` を同じフラグで。`safe`・`place`・
`try_column` はどれも盤面や行を捕獲するので、すべてクロージャになります。

## 実装の地図

| | |
|---|---|
| 14–46行 | `closure`・`t`・`fundef`・`program` |
| 49–78行 | `free_vars` |
| 80–88行 | `close_over` — 直接呼べる関数を値として使うときのクロージャ |
| 90–116行 | `convert_exp` — `App` が `Call_direct` か `Call_closure` かを決めるところ |
| 118–200行 | `convert_group` — 楽観的な不動点 |

## 参考文献

- E. Sumii, [*MinCaml: a simple and efficient compiler for a minimal functional
  language*][mincaml], FDPE 2005（[PDF][mincaml-pdf]）。既知関数の楽観的な判定は
  これに倣っています。

[mincaml]: https://doi.org/10.1145/1085114.1085122
[mincaml-pdf]: https://esumii.github.io/min-caml/paper.pdf

---

隣の文書：[パイプライン全体](pipeline.md)、[A正規化](anf.md)、[命令選択](selection.md)。
