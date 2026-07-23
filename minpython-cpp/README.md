# minpython-cpp

`jit-expt/minpython/`（Python 実装のレジスタ VM ＋トレーシング JIT）の **C++ 移植版**。
自己完結型のフロントエンド（字句解析・構文解析・コンパイル）と、[xbyak](https://github.com/herumi/xbyak) で x86-64 を吐く**トレーシング JIT** を持つ。

姉妹プロジェクト `Smalltalk/cpp` と同様に **C++23 モジュール**（`minpython` を partition に分割）で構成し、clang++ / CMake / ninja でビルドする。標準ライブラリは **`import std;`**（`#include` は xbyak のみ）。**例外は使わない**（`-fno-exceptions -fno-rtti`）—— エラーはラッチ `Diag` で伝播し、xbyak も `XBYAK_NO_EXCEPTION` モードで使う。

> `import std;` は CMake の実験的機能。`CMAKE_EXPERIMENTAL_CXX_IMPORT_STD` の UUID は CMake のバージョン依存なので、CMake を更新して怒られたら `CMakeLists.txt` の UUID を差し替える。clang++ ＋ libstdc++（GCC の `bits/std.cc`）で検証済み。

## ビルドと実行

```sh
cmake -G Ninja -B build -DCMAKE_BUILD_TYPE=Release
ninja -C build
ctest --test-dir build            # ユニットテスト

./build/minpython examples/fib.mpy         # インタプリタで実行
./build/minpython --jit examples/collatz.mpy   # JIT を有効化
./build/minpython --dis examples/fib.mpy       # 逆アセンブル
./build/mp_bench                               # interp vs JIT ベンチ
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

### トレーシング JIT（xbyak）

LuaJIT を簡略化した形:

1. **プロファイル** —— back-edge ごとにカウント。閾値を超えたら記録開始。
2. **記録** —— 1 イテレーションを、その時点の実レジスタ値で分岐方向を確定しながら単一直線の「ALU ステップ列＋制御ガード」に落とす。整数コアで扱えないもの（呼び出し・オブジェクト演算・`//` `%` `**`・非 int 定数）は**中断**してインタプリタに任せる。
3. **コード生成** —— 各ステップを、レジスタ配列上で直接演算する x86-64 に落とす（メモリオペランド方式）。

#### ネイティブ型ガード

Python 版は「リージョン入口で unbox（int64 化）」する設計上、型ガードは Python 側（`run_raw`）でしか行えなかった。C++ 版は値が**タグ付き struct の配列**としてメモリにあるので、**型ガードそのものを機械語で書ける**:

```asm
    cmp byte [regs + slot*16], Int    ; ← 入口の型ガード（ネイティブ）
    jne deopt
```

ライブイン（トレース内で書く前に読むレジスタ）が int でなくなっていれば、トレースは `-1` を返して**インタプリタへ deopt**する。値はレジスタ配列に常に反映されているのでスナップショットは不要 —— ガード離脱は「その時点の pc をインタプリタに返す」だけ。

例: `x = x + x` は int なら倍化、str なら連結。int で記録・native 実行されるが、同じ関数を str で呼ぶと入口の型ガードが機械語で外れて deopt し、インタプリタが連結を行う（結果は常にインタプリタと一致）。

#### str / list も JIT する（mixed トレース）

オブジェクト演算を含むループも JIT できる（Python 版にはない）。トレースに `len` / 添字が現れたら **mixed** 扱いにして、専用のコード生成を使う:

- **整数演算はネイティブ inline**、`Subscr` / `Len` は**ランタイムヘルパ呼び出し**（ヒープ確保や `std::string`/`vector` は機械語に inline できないため）
- **per-op ネイティブ型ガード** —— 入口で `xs` が List か（`cmp byte[..], List; jne deopt`）、各 `xs[i]` の**結果が記録時の型か**を機械語で検査。異なれば deopt してインタプリタが処理する（結果は常に一致）
- 値は**callee-saved レジスタに常駐**させる（共有 linear-scan で割り当て。ヘルパ呼び出しを跨いで生き残る）。配列ベースと `VM*` も callee-saved（`r12`/`rbx`）
- **GC 安全は「safepoint プロトコル」で担保**（stack map は使わない、下記）

#### GC safepoint プロトコル（register map を使わない理由）

GC が動きうるのは**ヘルパ呼び出しの瞬間だけ**。そこで:

1. 呼び出し**直前に、レジスタ常駐スロットを全部レジスタ配列へ書き戻す** —— 配列は GC ルートなので、これで全オブジェクトが確実に辿れる（かつヘルパも正しい値を読む）
2. 呼び出し**直後に、ヘルパが書いた宛先スロットだけ**レジスタへ再ロード
3. GC は**非移動**なので、レジスタに残っている他のポインタはそのまま有効 —— 他は再ロード不要

これにより **safepoint ごとの stack map / register map もネイティブフレームのアンワインドも不要**になる（HotSpot の OopMap 相当の機構を持たずに precise GC を保てる）。代償は safepoint での書き戻しコスト。

例: `while i < len(xs): t = t + xs[i]` が JIT され interp 比 **~2.6x**（レジスタ常駐化前は ~2.1x）。異種リスト `[1, True, 3]` では Bool 要素で per-op 型ガードが外れて deopt。型ガード失敗時は**ループ先頭ではなくガードした命令の次の pc へ復帰**する（先頭に戻すと同一イテレーションで既に書いたローカルを二重適用してしまう —— 実際にバグらせて回帰テストに固定済み）。str 添字（毎回 1 文字 Object を確保）のループで GC を強制発火させても、生存オブジェクト数まで interp と一致。

まだ非対応: str/list の連結（`+`）と `MakeList` はトレースを中断する。

#### レジスタ割り当て（共有 linear-scan）

ループ搬送値はメモリ往復せず**機械語レジスタに常駐**する。割り当ては Python 版と同じ **linear-scan**（`regalloc.cppm`、Poletto & Sarkar）で、tracing JIT と method JIT が**同じアロケータを共有**する（レジスタは抽象インデックスで扱い両 JIT 非依存）。tracing 側はループ搬送 slot を全区間ライブにして再利用衝突を防ぐ。タグは常にメモリ管理なので bool/int の区別はタダで正確。

### method JIT（関数コンパイラ）

tracing JIT はループ back-edge でしか発火しないので、`fib_rec` のようなループの無い再帰関数には効かない。method JIT がそこを埋める: 関数が**呼ばれた回数**が閾値を超えたら、両分岐を含めて本体全体を機械語化し、**直接自己再帰は native `call`** になる。int 特化・自己再帰のみ（`mdetail::feasible`）、値は callee-saved レジスタ（再帰 call を跨いで生存）に linear-scan で割り当て、あふれたらスタックにスピル。

#### オブジェクト対応の method コンパイラ

str/list を触る関数は別のコンパイラが担当する（タグ付きフレーム上で関数全体を機械語化）:

- **型が合わなければ「遅い経路」をネイティブのまま呼ぶ** —— int の速い経路をインラインで持ち、外れたら汎用ヘルパ（`op_binop`/`op_compare`/`op_unary`/truthiness）を呼んで**そのまま実行を継続**する。インタプリタに関数ごと落ちない。これにより文字列連結のような処理もネイティブ実行のまま進む。
- **冗長な型ガードを削除** —— CFG 前向き must 解析で「既に int と判明したスロット」を求め、再ガードを省く（インラインキャッシュ型フィードバックの安価な代用）。
- **自己再帰は native `call`** —— 呼び出し先の同一性をガードし、VM 値スタックからフレームをバンプ確保して自分の入口を直接呼ぶ。非自己呼び出しは VM 経由なので**相互再帰も動く**。
- 型ガードが外れて続行できない場合のみ pc を返し、**フレーム配列がそのまま状態**なのでインタプリタがその pc から続きを実行する（deopt 機構は不要）。

### 非同期（バックグラウンド）コンパイル

`TieredJIT` は method JIT を**ワーカースレッドでコンパイル**する: 関数がホットになったらジョブを投げて、**ブロックせずインタプリタを続行**。完成したらロック下で差し替え、次の呼び出しから native。差し替えられた旧コードは（実行中フレームのため）解放せず退避する。free-threaded Python 3.14 の狙いを C++ スレッドに移したもの。

#### baseline（copy-and-patch）を入れなかった理由

Python 版の baseline（stencil/copy-and-patch）は「Python でバイト列を吐くのが遅いので memcpy ベースの段が速い」ための tier。C++ は xbyak が µs でコンパイルするので、baseline は**コンパイル速度の利点が無く、コード品質が低いだけ**。実測でも call-bound の fib で baseline は method より遅かったので**外した**（tiered は method の単段バックグラウンド版に簡約）。

#### 未実装（Python 版にはあるもの）

トレーシングのサイドトレース・LICM・SSA IR、copy-and-patch baseline。tracing のガードが記録経路から外れると（例: collatz の奇偶分岐）その回はインタプリタに戻る。

## ベンチ（同一プログラム、Python 版と比較）

```
SUM s(3e6)  [trace jit]   C++ jit 12ms  / Py jit  65ms   → C++ 5.3x
COLLATZ(8e4)[trace jit]   C++ jit 140ms / Py jit 3917ms  → C++ 28x
FIB(30) rec [method jit]  C++ jit  7ms  / Py jit  67ms   → C++ 9.7x
```

いずれも全実装で出力一致。差は主にランタイムの重さ（Python は境界の boxing・deopt が重い）。tracing の純粋整数ループは interp 比 ~20x、method JIT の再帰も ~20x。

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
  jit.cppm        xbyak トレーシング JIT（記録・codegen・driver）
  method.cppm     method JIT（reachable/liveness/regalloc/self-recursion）
  tiered.cppm     非同期（バックグラウンド）method JIT
  minpython.cppm  primary module interface
  main.cpp        CLI（--jit / --method / --tiered / --dis）
tests/            アサーション式テスト（interp + 各 JIT 差分・GC）
bench/            interp vs JIT ベンチ
third_party/xbyak vendored（ヘッダオンリー）
```
