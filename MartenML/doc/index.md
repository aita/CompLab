# MartenML — ML から RISC-V まで

ML ふうの言語を RISC-V（RV64I/M）へコンパイルする処理系の解説です。1章が1パスに対応し、
どの章も**実際に動かした出力**を載せています。ダンプも警告も測定値も、手で書いたものは
ありません。

コンパイラそのものは[コンパイラの README](../compiler/README.md) に、言語の仕様と使い方が
まとまっています。

## 目次

**[0. プログラムが機械語になるまで](pipeline.md)** — 1本のプログラムが全パスを通り抜ける
までを、各パス1段落ずつで追います。まずここを読むと、以降の章がどこの話か分かります。

### 前半 — 構文から中間表現へ

| | | |
|---|---|---|
| 1 | [構文解析](syntax.md) | `lexer.mll`・`parser.mly`・`brace_*`。1つの言語を2通りに書ける |
| 2 | [名前解決](modules.md) | `modules.ml`。モジュールとファンクタを、名前を付け替えるだけで消す |
| 3 | [型推論](typing.md) | `typing.ml`・`types.ml`。単一化と、レベルによる一般化 |
| 4 | [パターンマッチ](matching.md) | `match_check.ml`・`match_compile.ml`。網羅性の検査と決定木 |
| 5 | [K正規化とその後](knormal.md) | `knormal.ml`・`alpha.ml`・`inline.ml`・`optim.ml`。中間結果に名前を付け、一意にし、展開し、畳む |
| 6 | [クロージャ変換](closure.md) | `closure.ml`。入れ子の関数をトップレベルへ |

### 後半 — 機械語へ

| | | |
|---|---|---|
| 7 | [線形IRと命令選択](selection.md) | `linear.ml`・`cfg.ml`・`selection.ml`・`liveness.ml`。木をグラフにしてから機械に落とす |
| 8 | [レジスタ割り付け](regalloc.md) | `regalloc.ml`・`bitset.ml`。グラフ彩色と反復融合。この処理系の中心 |
| 9 | [のぞき穴最適化と出力](emit.md) | `peephole.ml`・`emit.ml`。呼び出し規約と実行時表現も |

### 付録

| | | |
|---|---|---|
| A | [言語リファレンス](language.md) | 書ける形の一覧。字句、型、式、優先順位、パターン、モジュール、brace 形式 |

## 読み方

**言語そのものを知りたいなら** [付録A](language.md)です。1章から6章はそれをどう処理するかの
話なので、何が書けるのかは付録にまとめてあります。

**通して読むなら** 0章から順に。前半は構文木を均していく話、後半は機械の都合が入ってくる
話で、境目は7章の中、`linear.ml` と `selection.ml` のあいだです。

**1つだけ読むなら** [8章のレジスタ割り付け](regalloc.md)です。他の章はここに食わせる形を
作るために存在していて、8章だけが「与えられた資源をどう割り当てるか」という別種の問題を
扱っています。実例（§7）は1つの関数を8つの値・3レジスタで最後まで追ったもので、
`tests/walkthrough.exe` の出力から起こしてあります。

**手元で確かめるなら** 各章のダンプは次のコマンドで再現できます。

```sh
./martenml -S examples/sum.mml                            # 最終アセンブリ
martenmlc --dump-knf      -o /dev/null examples/sum.mml   # K正規形（5章）
martenmlc --dump-closure  -o /dev/null examples/sum.mml   # クロージャ変換後（6章）
martenmlc --dump-linear   -o /dev/null examples/sum.mml   # 線形IR（7章）
martenmlc --dump-riscv    -o /dev/null examples/sum.mml   # 割り付け前（7章）
martenmlc --dump-regalloc -o /dev/null examples/sum.mml   # 割り付けの結果（8章）
martenmlc --check-knf     -o /dev/null examples/sum.mml   # 正規形の検査（5章）
martenmlc --check-linear  -o /dev/null examples/sum.mml   # 線形IRの検査（7章）
martenmlc --check-cfg     -o /dev/null examples/sum.mml   # 閉路がないことの検査（7章）
dune exec tests/walkthrough.exe                   # 割り付けを1手ずつ（8章 §7）
```

## 各章の作り

どの章も同じ並びです。

- 本文（節番号つき）
- **していないこと** — 入れていない最適化や機能と、その理由（ある章だけ）
- **参考文献** — その章が拠っている論文
- **実装の地図** — どのファイルの何行目に何があるか

図は `figures/` の `.dot` から生成しています。編集したら `figures/render.sh` を走らせて、
出てきた `.png` ごとコミットしてください。graphviz が要ります。
