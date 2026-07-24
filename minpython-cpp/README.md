# minpython-cpp

`jit-expt/minpython/`（Python 実装のレジスタ VM ＋トレーシング JIT）の **C++ 移植版**。
自己完結型のフロントエンド（字句解析・構文解析・コンパイル）と、[xbyak](https://github.com/herumi/xbyak) で x86-64 を吐く **method JIT**（関数単位コンパイラ）を持つ。

> 移植当初はトレーシング JIT だったが、method JIT が全ワークロードで上回った時点で削除した（経緯は[下記](#トレーシング-jit-を外した経緯)）。

姉妹プロジェクト `Smalltalk/cpp` と同様に **C++23 モジュール**（`minpython` を partition に分割）で構成し、clang++ / CMake / ninja でビルドする。標準ライブラリは **`import std;`**（`#include` は xbyak のみ）。**例外は使わない**（`-fno-exceptions -fno-rtti`）—— エラーはラッチ `Diag` で伝播し、xbyak も `XBYAK_NO_EXCEPTION` モードで使う。

> `import std;` は CMake の実験的機能。`CMAKE_EXPERIMENTAL_CXX_IMPORT_STD` の UUID は CMake のバージョン依存なので、CMake を更新して怒られたら `CMakeLists.txt` の UUID を差し替える。clang++ ＋ libstdc++（GCC の `bits/std.cc`）で検証済み。

## ビルドと実行

```sh
cmake -G Ninja -B build -DCMAKE_BUILD_TYPE=Release
ninja -C build
ctest --test-dir build            # ユニットテスト

./build/minpython examples/fib.mpy            # インタプリタで実行
./build/minpython --jit examples/collatz.mpy  # JIT を有効化
./build/minpython --tiered examples/fib.mpy   # JIT をバックグラウンドスレッドでコンパイル
./build/minpython --dis examples/fib.mpy      # 逆アセンブル
./build/mp_bench                              # interp vs JIT ベンチ

MINPYTHON_JIT_DUMP=1 ./build/minpython --jit examples/collatz.mpy  # 生成コードを見る
```

## 対応する言語

Python 版と同じサブセット。値は `int` / `bool` / `str` / `list` / `None`。

- 演算子: `+ - * // % **`, `& | ^ << >>`, 単項 `- + ~ not`, `and`/`or`（短絡）, `== != < <= > >=`（連鎖）。`+` は str/list の連結も行う。`x[i]` は str/list の添字。
- 文: 代入・累算代入・式文・`if`/`elif`/`else`・`while`・`pass`・`break`・`continue`・`def`・`return`・`global`。
- 組み込み: `print()` / `len()`。ユーザ関数（再帰可）。
- 非対応: float, dict/set/tuple, スライス, クラス, クロージャ, 内包表記, 例外, import。`/` はエラー。

## 設計

### 値表現 —— タグ付き 16 バイト POD

```
offset 0:  tag (1 byte)   None/Int/Bool/Str/List/Func
offset 8:  payload         int64（Int/Bool）または Object*（Str/List/Func）
```

`str` / `list` / 関数のペイロード（`Object`）は VM 上のアリーナが所有する。到達不能になったものは**マーク&スイープ GC**（`vm.cppm`）が回収する。ルートは module globals と全インタプリタフレーム（ネイティブ JIT コードは int しか持たず何も割り当てないので、そこはルートにならない）。GC は割り当て時（インタプリタ実行中）にのみ発火し、コンパイル時の str 定数は Program 所有なので回収対象外。

### レジスタ VM

Lua 風のレジスタ機械。`x = a + b` は 1 命令 `ADD dst, a, b`。`while` の後方ジャンプ（back-edge）だけがループ再入の場所なので、そこでプロファイルを取り、`on_backedge` フックで JIT に制御を渡す。

### JIT（xbyak）

ネイティブへの入口は 2 つ:

- **呼び出し回数**が閾値を超えたら、その関数の本体全体（両分岐込み）を機械語化して `on_call` から直接呼ぶ。
- ループしか持たない関数のために **back-edge** もカウントし、ホットになったら **OSR**（第 2 の入口）で実行中のループへ native のまま入る。

コンパイラは 2 つある。int だけで完結する関数は専用の `MethodCode`（値を linear-scan でレジスタに載せる）、str/list を触る関数はタグ付きフレーム上で動く `MixedMethodCode` が受け持つ。生成コードは `MINPYTHON_JIT_DUMP=1` で objdump 経由のダンプが出る（レジスタマップ付き）—— 以下の最適化はどれもこのダンプを見ながら決めた。

#### ネイティブ型ガード

Python 版は「リージョン入口で unbox（int64 化）」する設計上、型ガードは Python 側（`run_raw`）でしか行えなかった。C++ 版は値が**タグ付き struct の配列**としてメモリにあるので、**型ガードそのものを機械語で書ける**:

```asm
    cmp byte [regs + slot*16], Int    ; ← 型ガード（ネイティブ）
    jne slow
```

フレーム配列が**そのまま状態**なのでスナップショットは要らない —— ガードを外れたら「その時点の pc をインタプリタに返す」だけで続きが実行できる。

例: `x = x + x` は int なら倍化、str なら連結。int でコンパイルされるが、同じ関数を str で呼ぶとガードが機械語で外れ、汎用ヘルパが連結を行う（結果は常にインタプリタと一致）。

#### GC safepoint プロトコル（stack map を使わない理由）

GC が動きうるのは**ヘルパ呼び出しの瞬間だけ**。そこで:

1. 呼び出し**直前に、レジスタ常駐スロットを全部レジスタ配列へ書き戻す** —— 配列は GC ルートなので、これで全オブジェクトが確実に辿れる（かつヘルパも正しい値を読む）
2. 呼び出し**直後に、ヘルパが書いた宛先スロットだけ**レジスタへ再ロード
3. GC は**非移動**なので、レジスタに残っている他のポインタはそのまま有効 —— 他は再ロード不要

これにより **safepoint ごとの stack map / register map もネイティブフレームのアンワインドも不要**になる（HotSpot の OopMap 相当の機構を持たずに precise GC を保てる）。代償は safepoint での書き戻しコスト。

str 添字（毎回 1 文字 Object を確保）のループで GC を強制発火させても、生存オブジェクト数までインタプリタと一致する。ガード失敗時は**ガードした命令の次の pc へ復帰**する（ループ先頭に戻すと同一イテレーションで既に書いたローカルを二重適用してしまう —— 実際にバグらせて回帰テストに固定済み）。

#### レジスタ割り当て

int コンパイラは Python 版と同じ **linear-scan**（`regalloc.cppm`、Poletto & Sarkar）でライブ区間に割り当て、あふれたらスタックにスピルする。オブジェクト対応コンパイラの方は**関数全体で所有する貪欲割り当て**を使う —— こちらは safepoint での一括書き戻し／再ロード（下記）が「スロットとレジスタは 1 対 1」を前提にしているので、区間ごとにレジスタを共有する linear-scan とは噛み合わない（共有させた結果 2 つのスロットが同じレジスタを持ち、出力が壊れた。逆アセンブラを入れた直後にレジスタマップを見て判明した）。

#### int 特化コンパイラ

int だけで完結し自己再帰しかしない関数（`mdetail::feasible`）は、値を callee-saved レジスタ（再帰 `call` を跨いで生存）に linear-scan で割り当て、あふれたらスタックにスピルする。**直接自己再帰は native `call`** になる。

#### オブジェクト対応コンパイラ

str/list を触る関数はタグ付きフレーム上で機械語化する:

- **型が合わなければ「遅い経路」をネイティブのまま呼ぶ** —— int の速い経路をインラインで持ち、外れたら汎用ヘルパ（`op_binop`/`op_compare`/`op_unary`/truthiness）を呼んで**そのまま実行を継続**する。インタプリタに関数ごと落ちない。これにより文字列連結のような処理もネイティブ実行のまま進む。
- **冗長な型ガードを削除** —— CFG 前向き must 解析で「既に int と判明したスロット」を求め、再ガードを省く。入口で int 引数を一度ガードしておくことがこの解析の種になる（種が無いとループヘッダで交わりが空になり、毎イテレーション全再ガードになる）。
- **冗長なタグストアを削除** —— タグ付きフレームなので素朴に書くと結果ごとにタグバイトを書く。だが**書こうとしているバイトは既にそこにある**ことがほとんどで、整数ループではそれがメモリトラフィックの大半だった。「各スロットのメモリ上の正確なタグ」を追う 2 つ目の must 解析（`mem_tags`）を入れ、既知なら書かない。**no-op になるストアしか消さない＝メモリは 1 バイトも変わらない**ので、GC・bail・flush 側は解析の存在を知らなくてよい。純粋整数ループの本体は 29 命令 6 ストアから **21 命令 2 ストア・ロード 0** になった。
- **小さな呼び出し先はインライン展開** —— フィードバックが単相と言っている呼び出し先が十分小さければ、フレームの**別領域**に本体をそのまま貼る。領域は本物の `Value` 配列なので、GC（ルート済みの値スタック内にある）にも deopt（インタプリタがその pc から呼び出し先を再開できる）にも新しい仕組みは要らない。呼び出し先は「たぶんその関数」でしかないので**同一性をガード**し、外れたら通常の呼び出しに落ちる。leaf 呼び出しを含むループで **1.66x**。
- **自己再帰は native `call`** —— 呼び出し先の同一性をガードし、VM 値スタックからフレームをバンプ確保して自分の入口を直接呼ぶ。非自己呼び出しは VM 経由なので**相互再帰も動く**。
- 型ガードが外れて続行できない場合のみ pc を返し、**フレーム配列がそのまま状態**なのでインタプリタがその pc から続きを実行する（deopt 機構は不要）。

### 非同期（バックグラウンド）コンパイル

`TieredJIT` は method JIT を**ワーカースレッドでコンパイル**する: 関数がホットになったらジョブを投げて、**ブロックせずインタプリタを続行**。完成したらロック下で差し替え、次の呼び出しから native。差し替えられた旧コードは（実行中フレームのため）解放せず退避する。free-threaded Python 3.14 の狙いを C++ スレッドに移したもの。

#### baseline（copy-and-patch）を入れなかった理由

Python 版の baseline（stencil/copy-and-patch）は「Python でバイト列を吐くのが遅いので memcpy ベースの段が速い」ための tier。C++ は xbyak が µs でコンパイルするので、baseline は**コンパイル速度の利点が無く、コード品質が低いだけ**。実測でも call-bound の fib で baseline は method より遅かったので**外した**（tiered は method の単段バックグラウンド版に簡約）。

### 暴走再帰の境界

ネストした呼び出しはインタプリタでは C++ の再帰、コンパイル済みコードでは本物の `call` なので、**どちらもマシンスタックを無制限に食う**（実際 3 モードとも segfault していた）。VM 構築時のスタック位置から予算を取り、`do_call` と両コンパイラの入口で検査する。深さのカウントではなく予算にしたのは、実際に尽きる資源がそちらだから —— ネイティブフレームはインタプリタのそれよりずっと小さいので、コンパイル済み段が正当に深くまで進める。

### トレーシング JIT を外した経緯

当初はトレーシング JIT と method JIT を併走させていた。method JIT は再帰（fib 22x）・分岐の多いループ（collatz 7x）・list ループ（2.6x）で勝っていたが、**純粋整数ループだけ 1.6x 負けていた**。

逆アセンブラ（`MINPYTHON_JIT_DUMP=1`）で両者のループ本体を並べると、method 側は **29 命令、trace 側は 37 命令** —— 命令数では勝っている。効いていたのはストア数で、上記のタグストア削除で 2 ストアまで落として逆転した。最後に残った 1 敗（直線的な算術関数）は「遅い」のではなく**一度もコンパイルされていなかった**: xbyak の既定コードバッファ 4KB を溢れ、それがコンパイル失敗として黙ってブラックリスト行きになっていた（当該関数は実測 14KB）。AutoGrow にして全勝したので、トレーシング側を削除した。

### 未実装（Python 版にはあるもの）

SSA IR・LICM・copy-and-patch baseline。インライン展開は 1 段のみ（呼び出し先がさらに呼ぶ場合は通常の呼び出し）。

## テスト

```sh
ctest --test-dir build          # 86 アサーション（差分・GC・回帰）
tests/fuzz.py --runs 500        # ランダムプログラムで interp と JIT を突き合わせ
tests/oracle.py 400             # 同じプログラムを CPython と突き合わせ
```

オラクルは 2 種類ある。`fuzz.py` は**インタプリタを正解**として JIT を検査する（JIT のバグはこれで出る）。ただしインタプリタ自身の間違いは見えない —— 実際 `True & True` が `1` を出していた間、`fuzz.py` は何も見つけなかった。`oracle.py` は実装全体を**部分集合元の言語**と突き合わせる。生成プログラムは値を小さく保つ（定数 ≤ 50、代入ごとにマスク）ので、int64 と Python の多倍長が食い違うことはない。

`fuzz.py` は不一致を見つけると、**壊れ続ける限り行を削って**最小化してから報告する。生成は JIT の閾値を跨ぐよう整形してあり（呼び出し回数・back-edge 数）、型を後から入れ替える第 2 段の駆動部を持つ —— コンパイル済みコードが「見た型」に賭けたガードを外す場面がそこに来る。

## ベンチ

```
                      interp     --jit
SUM      s(5e6)       226.5ms     8.5ms   26.6x
COLLATZ  (1e5)        563.4ms    25.0ms   22.5x
FIB(32)  再帰         406.6ms    19.0ms   21.4x
LIST-SUM (8 x 2e5)     77.6ms     9.4ms    8.3x
```

いずれも出力はインタプリタと完全一致（全ワークロードで差分テスト済み）。list ループの倍率が低いのは、`Subscr` / `Len` がヘルパ呼び出しのまま（＝ safepoint で書き戻しが入る）ため。

## レイアウト

```
src/
  value.cppm      タグ付き値・Object・truthy
  bytecode.cppm   Op / Instr / CodeObject / 逆アセンブラ
  lexer.cppm      インデント対応トークナイザ
  ast.cppm        fat-node AST
  parser.cppm     再帰下降パーサ
  compiler.cppm   AST -> レジスタ bytecode（Program が所有）
  vm.cppm         レジスタ dispatch ループ + back-edge/on_call フック + GC
  regalloc.cppm   共有 linear-scan アロケータ
  disasm.cppm     生成コードのダンプ（MINPYTHON_JIT_DUMP=1）
  analysis.cppm   CodeObject の解析（到達性・liveness・feasible・must 解析）
  method.cppm     method JIT（codegen・OSR・inline・driver）
  tiered.cppm     非同期（バックグラウンド）method JIT
  minpython.cppm  primary module interface
  main.cpp        CLI（--jit / --tiered / --dis）
tests/            アサーション式テスト（interp と JIT の差分・GC・再帰境界）
bench/            interp vs JIT ベンチ
third_party/xbyak vendored（ヘッダオンリー）
```
