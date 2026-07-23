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

`str` / `list` / 関数のペイロード（`Object`）は VM 上のアリーナが所有し、VM 破棄まで生存する（短命なスクリプト向けの割り切り。GC は持たない）。

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

#### 未実装（Python 版にはあるもの）

サイドトレース、LICM、SSA ベースのレジスタ割り当て。ガードが記録経路から外れると（例: collatz の奇偶分岐）その回はインタプリタに戻る。

## ベンチ（参考値）

```
collatz(300000):
  interpreter ~1740 ms
  tracing JIT  ~730 ms  (~2.4x)
```

奇偶で分岐するため半数のイテレーションはガード離脱でインタプリタに戻る。分岐のない純粋な整数ループではもっと差が出る。

## レイアウト

```
src/
  value.cppm      タグ付き値・Object・truthy
  bytecode.cppm   Op / Instr / CodeObject / 逆アセンブラ
  lexer.cppm      インデント対応トークナイザ
  ast.cppm        fat-node AST
  parser.cppm     再帰下降パーサ
  compiler.cppm   AST -> レジスタ bytecode（Program が所有）
  vm.cppm         レジスタ dispatch ループ + back-edge フック
  jit.cppm        xbyak トレーシング JIT（記録・codegen・driver）
  minpython.cppm  primary module interface
  main.cpp        CLI
tests/            アサーション式テスト（interp + JIT 差分）
bench/            interp vs JIT ベンチ
third_party/xbyak vendored（ヘッダオンリー）
```
