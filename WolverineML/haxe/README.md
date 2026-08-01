# WolverineML — Haxe

Tiger の言語を SML の書き方で書き、ARMv8 に落とす処理系の Haxe 版です。パスも、
中間表現も、ダンプの1バイトも `python/` と同じで、レジスタ割り当てだけ
グラフ彩色1本に絞ってあります。

```sh
haxe build.hxml                                   # bin/wolv.n
neko bin/wolv.n emit -s <stage> prog.wol
neko bin/wolv.n run prog.wol
haxe test.hxml && neko bin/test.n                 # テスト
```

`<stage>` は `tokens` `ast` `ir` `ssa` `opt` `dag` `mach` `flat` `ra` `asm` の10段です。

`run` と `build` には `aarch64-linux-gnu-gcc` と `qemu-aarch64` が要ります。
どちらも無い環境ではテストがその項目を **skip** と報告して先へ進みます。

## 対象は neko

`sys.io.Process` でクロス `gcc` と qemu を叩くので、`sys` が使える対象が必要です。
neko なら追加のツールチェーンなしにビルドできます。ランタイム (`runtime/runtime.c`)
は `-resource` でコンパイラ自身に埋め込まれ、リンク時に取り出されます。

## Haxe で書くとこうなる、という点

**命令は `enum`、書き換えは値を返す。** Haxe の enum は不変なので、他の5実装が
「命令を破壊的に書き換えて戻り値を捨てる」ところを、ここでは新しい命令を返して
配列に置き直します。

```haxe
block.instrs[at] = Ir.mapUses(block.instrs[at], rename);
```

見返りは**網羅検査**です。`defs` `uses` `mapUses` `withDef` `hasEffect` `showInstr`
はどれも命令1つにつき1メソッドではなく、問い1つにつき `switch` 1つで、命令を
足せば6箇所すべてがコンパイルエラーになります。

**構文木は Haxe 自身の形。** `haxe.macro.Expr` が
`{expr:ExprDef, pos:Position}` であるのと同じく、`Exp` は「どこに書かれたか・
型検査が何を知ったか」を持つクラスで、形は `enum ExpDef` が言います。クラス階層に
すると Haxe では `switch` できず `Std.isOfType` の連鎖になるので、木を歩くコードが
そうならない形を選びました。

**`Map` に順序が無い。** これが移植で一番効きました。φ の配置順はダンプの行順
そのものなので、集合を歩くところは全部並べ替える必要があります。専用の
`IntSet` を置いて、`ordered()` を通さないと歩けないようにしてあります
（OCaml の `Set.Make(Int)` が黙ってやっていることです）。

**文字列はバイト列。** neko の `String` はバイト列なので、言語のバイト文字列に
そのまま対応します。代わりに字句解析器が UTF-8 を自前で復号します。

**シフトの桁数がマスクされる。** `haxe.Int64` の `/` `%` は `sdiv` と完全に一致
（`-7/2 = -3`、`MIN/-1 = MIN`）しますが、`1 << 64` は `1` になるので、
定数畳み込みの `shl`/`shr` には64以上の明示ガードがあります。

**Unicode 表が無い。** 標準ライブラリに文字種のデータベースが無いので、
字句解析器は「ASCII 英字＋0x80 以上すべて」を letter として扱います。**6実装の
うちここだけが Python と厳密には一致しません。** ダンプ側は影響を受けません:
文字列リテラルはバイト列で、`\xNN` にするかどうかは 0x00–0xFF の範囲で
決まり、その範囲なら答えは C0・C1 制御文字、no-break space、soft hyphen の
4つに固定だからです。

**モジュールは名前空間を切らない。** `wolv.Ir.Bin` の実体は `wolv.Bin` です。
そのため構文木の側に `E`/`D` 接頭辞（`EBin`、`DVal`）を付け、`Lower` の設定を
`Lowering` と呼んでいます。

## 検証

- **ダンプ 400/400 が `python --regalloc graph` と一致**（10段 × 10プログラム × 4設定）
- **テスト121件全通過、skip 0**（qemu の end-to-end と乱択オラクル込み）
- 4393行（25ファイル）＋ テスト 382行

## ファイル

| | |
|---|---|
| `Diag.hx` | 位置と、全パスが投げる唯一の例外 |
| `Lexer.hx` `Parser.hx` | 1回通る字句、優先順位表1つの Pratt 構文解析 |
| `Ast.hx` `AstShow.hx` | 構文木と、その字下げダンプ |
| `Types.hx` `Typecheck.hx` | 単相の型と、エスケープ解析 |
| `Ir.hx` `Lower.hx` | 三番地コードの CFG へ |
| `Ssa.hx` `Opt.hx` `Liveness.hx` | 支配辺境、φ、最適化5パス、生存解析 |
| `Dag.hx` `Select.hx` `Mach.hx` | ブロックを DAG に読み、タイルで敷き詰める |
| `OutOfSsa.hx` `Copies.hx` | φ をコピーに、並列コピーを順番に |
| `IntSet.hx` `Registers.hx` `Hints.hx` `Spill.hx` `Graph.hx` `Allocator.hx` | グラフ彩色 |
| `Emit.hx` | AAPCS64、フレーム、予約1本 |
| `Driver.hx` `../Wolv.hx` | パイプラインとツールチェーン、コマンドライン |
