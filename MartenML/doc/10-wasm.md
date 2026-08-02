# 10. もう1つのバックエンド — `wasm.ml`

クロージャ変換の出口から、RISC-V へ行かずに WebAssembly へ抜ける道です。**7章から9章の
9ファイル・2224行が、ここでは1ファイル・515行になります。** 減った理由は最適化を諦めたから
ではなく、**やる必要のある仕事が減ったから**です。何が減ったのかを見ていきます。

```sh
martenmlc -run -target wasm examples/tour.mml       # 走らせる
martenmlc -target wasm examples/tour.mml    # wat を印字して止まる
```

## 1. 木がグラフにならない

[7章](07-selection.md)の `linear.ml` が存在する理由は、冒頭の注釈にそのまま書いてあります。

> Closure-converted code is still a tree: an `if` carries its two arms inside
> it, and the value of a function is whatever its body evaluates to.  Machine
> code is a graph: blocks that end in a terminator naming their successors.
> Somebody has to turn one into the other, and this is that pass.

**WebAssembly は機械語ではありません。** 制御フローが構造化されていて、`if` / `else` /
`end` は入れ子になり、ブロックの途中へ飛び込む方法がありません。つまり「2つの枝を中に抱えた
`if`」は、**そのまま対象言語の書き方**です。

だから木は出力まで生き残ります。制御フローグラフが存在しないので、`cfg.ml` も、閉路の検査
（`--check-cfg`）も、ブロックの並べ替えも要りません。

`examples/sum.mml` の `sum` はこうなります。

```wat
$ martenmlc -target wasm examples/sum.mml
  (func $martenml_sum_18 (param $wasm.env i64) (param $l.19 i64) (result i64)
    (local $t.8.21 i64)
    ...
    local.get $l.19
    i32.wrap_i64
    i64.load offset=0        ← タグ
    local.set $t.8.21
    i64.const 0
    local.set $t.9.22
    local.get $t.8.21
    local.get $t.9.22
    i64.eq
    if (result i64)          ← ブロックにならない。if のまま
      i64.const 0
    else
      local.get $l.19
      i32.wrap_i64
      i64.load offset=8      ← x
      local.set $fld.6.23
      local.get $l.19
      i32.wrap_i64
      i64.load offset=16     ← rest
      local.set $fld.7.24
      i64.const 0 ;; no environment
      local.get $fld.7.24
      call $martenml_sum_18
      local.set $t.10.27
      local.get $fld.6.23
      local.get $t.10.27
      i64.add
    end
  )
```

7章の同じ関数（`.Lthen36` と `.Lelse37` の2ブロック）と見比べてください。ラベルが1つも
ありません。

### 合流点は `if (result i64)` そのもの

`linear.ml` の不変条件の注釈は、このIRが SSA からどれだけ離れているかをこう書いています。

> `let x = if c then a else b` puts one definition of x in each arm, and neither
> arm dominates the block that reads it (...) A phi node in the join block is
> what would, and the day one exists this check becomes a dominance check.

**その φ が、ここでは `if (result i64)` です。** どちらの枝も値を1つスタックに残し、`end`
の直後にはその値が1つある。誰が定義したかを別の仕組みで言い直す必要がありません。
`linear.ml` が枝ごとに `Jump join` を出し、`selection.ml` が「両方の枝が同じレジスタへ
書く」ように `define` で辻褄を合わせていた部分が、まるごと消えます。

## 2. レジスタ割り付けが要らない

wasm の関数はローカル変数を好きなだけ宣言でき、実レジスタへの割り当てはエンジンがやります。
だから **Closure が名前を付けた値は、全部そのままローカル**です。α変換が名前を一意にして
あるので、宣言リストは解析ではなく走査で作れます。

```wat
    (local $t.8.21 i64)
    (local $t.9.22 i64)
    (local $fld.6.23 i64)
    (local $fld.7.24 i64)
    (local $t.10.27 i64)
```

[8章](08-regalloc.md)が買っていたもの — 値をレジスタに載せる、callee-saved を使うぶんだけ
退避する、`mv` を融合で消す — は、そっくりエンジンの仕事になります。干渉グラフは一度も
作られません。

正直に言うと、**出てくるコードは冗長です。** K正規化が作った中間結果が1つ残らずローカルに
なり、`local.set` してすぐ `local.get` する列が並びます。8章のアロケータならここで融合して
消していたものです。この冗長さを取り除くのは、この段階では意味がありません — エンジンが
どうせもう一度同じことをやるからです。

なお **8引数の上限は残ります。** wasm の関数は引数を好きなだけ取れますが、この検査は
`typing.ml` にあり、`Riscv.max_args` で書かれています。**どちらの対象に向かうプログラムでも
同じ理由で受理・拒否される**ほうが言語として正しいので、対象ごとに緩めてはいません。

## 3. 書き換えが要った3つ

データの形は変わりません。値は64ビット1ワード、タプルもコンストラクタも文字列も
クロージャも、[9章 §4](09-emit.md#4-実行時表現)の表のとおりのバイト配置です。置き場所が
プロセスのヒープからリニアメモリになっただけです（アドレスが32ビット幅で、それを収める語が
64ビットなので、ロードとストアのたびに `i32.wrap_i64` が挟まります）。

書き換えが要ったのは3つだけです。

### コードポインタはアドレスではない

**wasm の関数はリニアメモリに存在しません。** だからクロージャの第0語には、コードのアドレス
ではなく**モジュールの関数テーブルのスロット番号**が入り、クロージャ経由の呼び出しは
`call_indirect` になります。

```wat
  (table 2 funcref)
  (elem (i32.const 0)
    $martenml_add_8_16
    $martenml_main
  )
```

```wat
    i64.const 16
    call $martenml_alloc
    local.set $add.8.16        ← クロージャのブロック
    local.get $add.8.16
    i32.wrap_i64
    local.set $wasm.block
    local.get $wasm.block
    i64.const 0 ;; martenml_add_8_16   ← アドレスではなくスロット番号
    i64.store
    local.get $wasm.block
    local.get $t.2.10          ← 捕獲した n
    i64.store offset=8
```

呼ぶ側はその語を読んでテーブルを引きます。

```wat
    local.get $add.8.16        ← 環境（クロージャ自身）
    local.get $t.3.12          ← 引数
    local.get $add.8.16
    i32.wrap_i64
    i64.load                   ← 第0語 = スロット番号
    i32.wrap_i64
    call_indirect (type $fn1)
```

### 環境は全関数の引数になる

RISC-V ではクロージャを `t6` で渡します。引数レジスタの列の外にある1本なので、**関数の
引数リストには手を触れずに済みます**（[9章 §3](09-emit.md#3-呼び出し規約)）。

wasm ではそうはいきません。`call_indirect` は**呼び先の型全体**を呼び出し側が書いた型と
照合するので、環境が型の中に入っていなければなりません。そして呼び出し側は、これから入る
関数が何かを捕獲しているかどうかを知りません。だから**全関数が環境を第1引数に取り**、
直接呼び出しは 0 を渡します。

```wat
    i64.const 0 ;; no environment
    local.get $fld.7.24
    call $martenml_sum_18
```

型は使われるアリティごとに1つ書き出します。

```wat
  (type $fn0 (func (param i64) (result i64)))
  (type $fn1 (func (param i64) (param i64) (result i64)))
```

### リンカがない

RISC-V 側は、生成した `.s` と `runtime/martenml_runtime.c` を `gcc` に渡して繋いでもらい
ます。wasm にはそれに当たるものがありません。だから
`runtime/martenml_runtime.wat` は `(module ...)` を持たない**断片**として書いてあり、
`wasm.ml` がそれを出力の中へ写します。**リンクとは、ここでは1つのファイルに続けて印字する
ことです。**

`gcc` にランタイムを渡すのと同じように、`martenmlc` にはパスを渡します。`-runtime` を
省くと、このリポジトリでの置き場所である `runtime/martenml_runtime.wat` を読みます。

```sh
martenmlc -target wasm -o a.wat a.mml
martenmlc -target wasm -runtime path/to/martenml_runtime.wat -o a.wat a.mml
```

## 4. ランタイム — `runtime/martenml_runtime.wat`

`martenml_runtime.c` と同じヒープと同じプリミティブを、wat で書き直したものです。外の世界と
の接点は WASI の3つの import — `fd_write`、`fd_read`、`proc_exit` — だけです。

メモリの先頭1ページはランタイムのもので、コンパイラの静的データは 4096 から始まります。

| | |
|---|---|
| 0 | `fd_write` / `fd_read` に渡す iovec |
| 8 | ホストが実際に転送したバイト数 |
| 16 | `print_int` の桁。後ろから埋める |
| 64 | 標準出力のバッファ（1 KiB） |
| 1152 | 標準入力のバッファ（1 KiB） |
| 2560 | エラーメッセージ |
| 4096 | ここからコンパイラの領分 |

C版と違うところが2つあります。

**出力をこちら側でバッファします。** ホストに任せると、途中で死んだプログラムがそこまでの
出力を落とすからです。`fatal` は標準エラーへ何か書く前に必ず `flush` します — C版の
`fflush(stdout)` と同じ理由、同じ順序です。

**ヒープは伸びます。** C版は起動時に 256 MiB を確保して終わりですが、こちらは足りなく
なったら `memory.grow` でホストに追加を頼みます。どちらも解放はしません。GCを入れるには
コンパイラがポインタの在処を記述する必要があり、それは別のプロジェクトです。

ゼロ除算だけは、wasm 自身の罠に任せず自分で検査します。`i64.div_s` は 0 で割ると trap
しますが、報告される内容も終わり方も言語のエラーとは別物になるからです。定数の除数が
0 でないと分かっている場合は検査を出しません — `linear.ml` が定数を追いかけているのと
同じ理由、同じ場合分けです。

## 5. 末尾呼び出しは本物のまま

このコンパイラの末尾呼び出しは飾りではありません。`examples/tour.mml` の
`count 1 1000000 0` は末尾再帰で書いたループで、スタックを消費しないことを前提にしています。

wasm では `return_call` と `return_call_indirect` がそれに当たります。

```wat
    local.get $t.17.35
    return_call $martenml_print_newline
```

`wat2wasm --enable-tail-call` が要ります。テストスクリプトと `martenmlc -run --wasm` が
付けています。クロージャ経由の相互再帰も同じで、`return_call_indirect` を200万回踏んでも
スタックは伸びません。

## 6. 同じ答えであること

**wasm のゴールデンファイルは1つもありません。** 18本のプログラムを、RISC-V 側が使うのと
**同じ `.expected` ファイル**と突き合わせます。

```
(rule
 (with-stdout-to
  tour.wasm.out
  (run %{exe:runner.exe} wasm %{exe:../src/martenmlc.exe}
    %{dep:../runtime/martenml_runtime.wat} %{dep:../runtime/martenml_wasm.mjs}
    %{dep:../examples/tour.mml})))

(rule
 (alias runtest)
 (action
  (diff tour.expected tour.wasm.out)))
```

比べているのは標準出力だけではありません。`tests/runner.ml` はどちらの対象でも同じ形で、
警告・標準出力・標準エラー・終了ステータスを順に流します。だから
`tests/cases/match_failure.mml` は、**両方の対象で同じ位置で落ち、同じ
`martenml: match failure` を出し、同じ 2 で終わる**ことまで検査されます。

`wat2wasm`（wabt）と `node` が要ります。

## していないこと

**最適化を1つも入れていません。** のぞき穴に当たるものも、`local.set` の直後の
`local.get` を畳むことすらしていません。エンジンが同じことをやるので、ここでやると
二度手間になるだけです。

**深い再帰の限界が対象によって違います。** 末尾呼び出しでない再帰はスタックを食い、その
上限はホストが決めます。実測で、`node --stack-size=6000`（KB）は40000段は通り60000段は
通らず、qemu 上の RISC-V は200000段は通り1000000段は通りません。どちらも言語の性質では
なくホストの都合ですが、**wasm 側のほうが早く尽きます** — V8 の既定値だと数千段で尽きる
ので、`martenmlc -run --wasm` と `tests/runner.ml` は `--stack-size` を明示的に上げています。

**`i64.div_s` の1箇所だけ、答えが違います。** 最小の整数を −1 で割ると RISC-V は
そのまま最小の整数を返し、wasm は trap します。どちらも64ビット2の補数では表せない
値を要求されている場合で、規格が別々の答えを選んでいます。検査を足せば揃えられますが、
除算1つごとにもう1本分岐が増えます。

**GC も、リニアメモリの解放もありません。** C版と同じバンプアロケータです。

**バイナリ形式は出しません。** 出るのは wat（テキスト形式）で、`.wasm` にするのは
`wat2wasm` の仕事です。wat は wasm にとってアセンブリに当たるもので、
[9章](09-emit.md)の `emit.ml` が RISC-V に対して印字しているものと同じ位置にあります。

**ホストは WASI 固定です。** 出てくるのは `_start` を export し `fd_write`・`fd_read`・
`proc_exit` を import する WASI コマンドモジュールで、ブラウザで動かすなら import を
自分で用意することになります。`runtime/martenml_wasm.mjs` が node で走らせる例ですが、
wasmtime でも wasmer でも preview1 を実装していれば同じファイルが動きます。

## 参考文献

- A. Haas ほか、[*Bringing the Web up to Speed with WebAssembly*][wasm]、PLDI 2017。
  構造化制御フローが選ばれた理由（検証が1パスで済み、飛び込みがないので実行前に
  型が付けられる）はこの論文の §2 と §3 です。
- [WebAssembly Core Specification][spec]。命令と検証規則。
- [WebAssembly tail calls][tailcall]（提案、Phase 4）。`return_call` と
  `return_call_indirect`。
- [WASI preview1][wasi]。`fd_write`、`fd_read`、`proc_exit`。

[wasm]: https://doi.org/10.1145/3062341.3062363
[spec]: https://webassembly.github.io/spec/core/
[tailcall]: https://github.com/WebAssembly/tail-call
[wasi]: https://github.com/WebAssembly/WASI/blob/main/legacy/preview1/docs.md

## 実装の地図

| | |
|---|---|
| `wasm.ml` | Closure の木から wat へ。このパスの全部 |
| `wasm.ml` `generate` | 木を降りる本体。`tail` が変えるのは呼び出しだけ |
| `wasm.ml` `conditional` | `if (result i64)` — 分岐と合流 |
| `wasm.ml` `locals_of` | 本体が束縛する名前を集めてローカル宣言に |
| `wasm.ml` `layout_statics` | 定数コンストラクタと文字列リテラルを 4096 から並べる |
| `wasm.ml` `copy_runtime` | ランタイムを写す。ここでのリンク |
| `runtime/martenml_runtime.wat` | ヒープ、`print_*`、文字列、`read_int`、`fatal` |
| `runtime/martenml_wasm.mjs` | node + WASI で走らせる |
| `martenmlc.ml` `compile` | `-target` でここが分岐する |
| `tests/runner.ml` | ゴールデンテストの駆動。両対象で同じ形の出力を作る |
| `src/toolchain.ml` | 外部ツールの起動。`martenmlc -run` と共用 |

---

[← 9. のぞき穴最適化と出力](09-emit.md) ／ [目次](index.md) ／ [付録A. 言語リファレンス →](A-language.md)
