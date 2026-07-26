# copypatch

小さな動的型付け言語の **バイトコード VM ＋ copy-and-patch ベースライン JIT**。

Rust 側にアセンブラは無い。JIT が吐く機械語は **すべてビルド時に clang が生成したもの**で、
Rust は実行時にそれを並べて **ジャンプの変位（rel32）と 32bit 即値だけを書き換える**。

```
source ──nom──▶ AST ──▶ bytecode ──┬──▶ interpreter (Rust)
                                    └──▶ machine code (ステンシルを連結してパッチ)
                                              ▲
                    csrc/stencils.c ──clang──▶ │ build.rs が .text.st_* を切り出して
                                               │ stencils.bin として実行ファイルに埋め込む
```

## copy-and-patch の仕組み

### 1. C でステンシルを書く（`csrc/stencils.c`）

バイトコードのオペコード 1 個につき C 関数 1 個。次のオペへは **`musttail` で末尾呼び出し**する。

```c
STENCIL(add) {
    Value b = sp[-1], a = sp[-2];
    if (UNLIKELY(!BOTH_INT(a, b))) FAIL(ERR_TYPE);
    sp[-2] = a + b - 1;
    NEXT(sp - 1);            // __attribute__((musttail)) return HOLE_NEXT(...)
}
```

`HOLE_NEXT` / `HOLE_TARGET` / `HOLE_A` / `HOLE_B` / `HOLE_PC` は **実体のない extern シンボル**。
定義が無いので clang は再配置エントリを残すしかなく、それがそのまま「穴」になる。

### 2. clang でパッチ用バイナリを作る（`build.rs`）

```
clang -O2 -c -fno-pic -mcmodel=small -ffunction-sections -fno-jump-tables ...
```

- `-fno-pic -mcmodel=small` … `&HOLE_A` が `mov $imm32, %eax`（`R_X86_64_32`）になる。
  GOT 経由の間接ジャンプになってしまうので **`-fno-plt` は付けない**。
- `-ffunction-sections` … ステンシルごとに `.text.st_*` が分かれ、切り出しが一意になる。
- `-fno-jump-tables` … ジャンプテーブルが `.rodata` に落ちると再配置先が増えるので禁止。

`build.rs` は `object` クレートで ELF を読み、`st_*` シンボルのバイト列と、
再配置を `Hole { kind, offset, addend, pcrel }` に変換したものを取り出す。
`HOLE_*` 以外への再配置（libc 呼び出し、定数プール参照など）を見つけたら **その場でビルドを失敗させる**
—— 実行時パッチャが解決できない参照を混入させないため。

### 3. Rust ソースに直接埋め込む

`.bin` を `include_bytes!` するのではなく、`stencils.rs` に**バイトリテラルとして書き出す**。
さらにオブジェクトを逆アセンブルし直して、**1 命令 1 行、対応するアセンブリをコメントに付ける**。
機械語・アセンブリ・穴が同じ場所に並ぶので、生成ソースがそのまま読める。
現状 **23 ステンシル / 1230 バイト**。

```rust
// OUT_DIR/stencils.rs （build.rs が生成）
Stencil {
    name: "load_local",
    tail_jump: true,
    code: &[
        0xb8, 0x00, 0x00, 0x00, 0x00,  // +0   mov $0x0,%eax   <- ImmA
        0x89, 0xc0,                    // +5   mov %eax,%eax
        0x48, 0x8b, 0x04, 0xc6,        // +7   mov (%rsi,%rax,8),%rax
        0x48, 0x89, 0x07,              // +11  mov %rax,(%rdi)
        0x48, 0x83, 0xc7, 0x08,        // +14  add $0x8,%rdi
        0xe9, 0x00, 0x00, 0x00, 0x00,  // +18  jmp <Next>   (elided by the JIT)
    ],
    holes: &[
        Hole { kind: HoleKind::ImmA, offset: 1, addend: 0, pcrel: false },
        Hole { kind: HoleKind::Next, offset: 19, addend: -4, pcrel: true },
    ],
},
```

分岐命令のオペランドは `<Next>` / `<Target>` に差し替えてある。変位がまだ 0 なので
逆アセンブラは「次の命令へのジャンプ」と解決してしまい、その表示は嘘になるため。

逆アセンブラは `llvm-objdump` → `objdump` の順に探す。どちらも無ければ
コメントがバイトオフセットだけになり（`cargo:warning` で通知）、ビルドは通る。

### 4. 実行時はジャンプの書き換えだけ（`src/jit.rs`）

1. mmap した `PROT_READ|PROT_WRITE` の領域に、オペコード順にステンシルをベタ置き
2. 各穴を埋める
   - `Next` / `Target` … `jmp`・`jcc` の rel32 を `S + A - P` で計算して書く
   - `ImmA` / `ImmB` / `ImmPc` … 32bit 即値をそのまま書く
3. `mprotect` で `PROT_READ|PROT_EXEC` に落とす

関数本体は丸ごと `jmp` の連鎖になるので、**ディスパッチループもバイトコードフェッチも無い**。
末尾呼び出しなのでネイティブスタックも伸びない（伸びるのは実際の関数呼び出しのときだけ）。

```
$ copypatch prog.cp --jit 1 --dump-jit
jit fn add  125 bytes at 0x7f41fdc8d000
  +0        0  load           b8 00 00 00 00 89 c0 48 8b 04 c6 48 89 07 48 83 c7 08
  +18       1  load           b8 01 00 00 00 89 c0 48 8b 04 c6 48 89 07 48 83 c7 08
  +36       2  add            48 8b 47 f0 4c 8b 47 f8 ... e9 10 00 00 00 c7 42 08 01 ...
  +91       3  return         48 8b 47 f8 48 89 02 c3
```

### 末尾 jmp の削除

単純なステンシルは最後が `e9 00 00 00 00`（＝次のオペへの `jmp`）で終わる。
`Next` の飛び先は**必ず直後のステンシル**なので、この 5 バイトは常に無駄になる。
`build.rs` が「末尾 5 バイトが `E9` ＋ そこに `Next` の穴」を検出して `tail_jump` を立て、
JIT はその 5 バイトを**コピーしない**。23 個中 7 個が該当し、collatz で 1.5 倍速くなった。

`0xE9` 判定で十分なのは、`jcc rel32` なら同じ位置が `0F 8x` になるため。
仮にステンシル内部の分岐がこの末尾 `jmp` を指していたとしても、削除後はその分岐が
「直後のステンシル」に着地する ＝ `jmp` の飛び先と同じなので、意味は変わらない。

## 呼び出し規約

ステンシルは 4 引数を引き回すだけの `void` 関数で、System V の引数レジスタに固定される。

| | レジスタ | 中身 |
|---|---|---|
| `sp` | rdi | オペランドスタックのトップ |
| `locals` | rsi | ローカル変数スロット |
| `vm` | rdx | `Shared`（＝ Rust の `Vm` の先頭フィールド） |
| `consts` | rcx | 関数の定数プール |

ランタイムヘルパ（`rt_call` / `rt_print`）は **`Shared` 内の関数ポインタ経由**で呼ぶ。
名前で呼ぶと Rust 側シンボルへの再配置が必要になり、
生成コードと Rust の距離が ±2GB を超えたときに rel32 で届かなくなるため。

`Shared` は `#[repr(C)]` で、レイアウトは `csrc/stencils.c` の `struct Vm` と一致していなければならない。
オフセットは `src/vm.rs` のテストで固定している。

## 値表現

```
int n   ->  (n << 1) | 1       63bit、ラップアラウンド
false   ->  0b000
true    ->  0b010
fn #i   ->  (i << 3) | 0b100   関数テーブルのインデックス
```

- int 判定は `v & 1`
- `a + b - 1` でタグを外さずに加算（`2a+1` ＋ `2b+1` − 1 ＝ `2(a+b)+1`）
- タグ付けは 63bit の範囲で単調なので、比較もタグを外さずにそのまま
- `==` は **ビット比較だけ**でよい。3 つの型のビットパターンは互いに素なので、
  異種比較は自動的に `false` になり型チェックが要らない
- **bool 判定は「int でない」ではない。** 関数参照もビット 0 が 0 なので、
  bool はちょうど `0` と `2` であることを見る `v & ~2 == 0` で判定する
  （`not` と `jump_if_false` がこれを使う）

インタプリタ側（`src/vm.rs` の `binary`）はこのビット演算を 1 対 1 で写している。

## 言語

**トップレベルに文を書ける。** `fn` の外にある文はソース順に集められ、暗黙の `main` の本体になる。

```
// スクリプトとして書ける。関数は後ろで定義してもよい（前方参照可）
print gcd(1071, 462);       // 21

fn gcd(a, b) {
    while b != 0 {
        let t = b;
        b = a % b;
        a = t;
    }
    return a;
}

return gcd(270, 192);       // プログラムの戻り値
```

もちろん従来どおり `fn main()` を明示してもよい。

- 型は **int / bool / 関数**。動的型付けで、型エラーは実行時に出る
- 制御構造は `if` / `else` / `else if` / `while`
- 関数は `fn`。前方参照可、相互再帰可。引数は最大 16 個
- 演算子は `+ - * / %`、`< <= > >=`、`== !=`、`&& ||`、前置 `- !`
- `//` 行コメント
- `print` 文、`return` 文、`let` 束縛、代入

### 関数は値

関数名をそのまま書けば**関数参照**という値になる。変数に入れる、引数に渡す、返り値にする、
`==` で比較する、が全部できる。

```
fn add(a, b) { return a + b; }
fn mul(a, b) { return a * b; }

fn fold(op, from, to, acc) {          // op は普通の引数
    let i = from;
    while i <= to { acc = op(acc, i); i = i + 1; }
    return acc;
}

fn operator(kind) {                   // 関数を返す
    if kind == 0 { return add; }
    return mul;
}

print fold(add, 1, 10, 0);            // 55
print operator(1)(6, 7);              // 42     返り値をそのまま呼べる
print operator(0) == add;             // true   参照の同一性で比較
print add;                            // <fn add/2>
```

呼び出しは**後置演算子**なので、`f(1)(2)` や `(expr)(args)` も書ける。

クロージャは無い。関数リテラル（無名関数）も無く、参照できるのはトップレベルの `fn` だけ。

#### 直接呼び出しと間接呼び出し

- 呼び先が**関数名そのもの**で、同名のローカルに隠されていないときは `call`（呼び先を
  即値に焼き込む）にコンパイルされ、引数の個数もコンパイル時に検査される
- それ以外は `call_value`。呼び先はスタックに積まれ、**型と引数の個数は実行時に検査**される

つまり関数を値にできるようにしても、普通の名前呼び出しは今までどおり静的なままで、
JIT も呼び先インデックスを即値としてパッチできる。

### 意図的な仕様

- **トップレベル文と明示的な `fn main` は併用できない**（暗黙の `main` と衝突するのでコンパイルエラー）
- トップレベルの `let` は**暗黙の `main` のローカル変数**であって、グローバル変数ではない。
  他の関数からは見えない（この言語にグローバルは無い）
- トップレベルに `return` を書けば、それがプログラムの戻り値になる。無ければ `0`

- **整数は 63bit**。オーバーフローはラップする（`4611686018427387903 + 1` → `-4611686018427387904`）
- `-4611686018427387904` は書ける。単項マイナスの直後の数字列はリテラルの一部として扱う
- `if` / `while` の条件は **bool でなければならない**。`if 1 {}` は型エラー
- `&&` / `||` は Python 風。左辺は bool を要求するが、**右辺はそのまま値として返る**
  （`true && 1` は `1`）。条件位置で使えば `if` 側の型チェックに引っかかる
- `==` / `!=` は異種型で `false` / `true`（エラーにしない）。関数参照どうしは同一性比較
- **クロージャは無い**。関数値はトップレベル `fn` への参照でしかないので、
  ヒープも GC も要らない。`fact(fact, n)` のような自己適用は書ける
- `return` が無い関数、値なし `return` は `0` を返す
- 内側スコープの `let` はシャドウイングする。スロットは再利用しない

## ビルドと実行

必要なもの: Rust 1.82+、clang（`musttail` 対応 = clang 13+）、x86-64 Linux。

```sh
cargo build --release
./target/release/copypatch examples/tour.cp
```

`clang` の場所は環境変数 `CLANG` で差し替えられる。

```
usage: copypatch [options] <program.cp>

  --jit <n>          n 回目の呼び出しでコンパイル（既定 2、エントリポイントは常に即コンパイル）
  --no-jit           インタプリタのみ
  --entry <name>     エントリポイント（既定 main）
  --max-depth <n>    再帰の上限（既定 10000）
  --dump-bytecode    バイトコードを出して終了
  --dump-jit         実行後に生成した機械語を出す
  --dump-stencils    clang が作ったステンシル表を出して終了
  --stats            実行統計
  --quiet            戻り値を表示しない
```

## JIT の起動条件

関数は **N 回目の呼び出しでコンパイル**される（既定 N=2、`--jit` で変更）。

ただし**エントリポイントだけは最初に無条件でコンパイル**する。
エントリポイントはちょうど 1 回しか呼ばれないので呼び出しカウンタでは永久に hot にならないが、
スクリプト形式のプログラムでは処理の本体がまさにそこ（暗黙の `main`）にあるため。

```
let i = 0;
let s = 0;
while i < 3000000 { s = s + i; i = i + 1; }   # ← ここが全部
return s;
```

これは実際に効く（下表 `hot.cp`）。ただし**ヒューリスティックであって OSR ではない**。
`main` 以外の「1 回しか呼ばれないが中に重いループがある関数」は依然コンパイルされない。

## 計測

`--release`、x86-64、9 回の最小値。

| | インタプリタ | JIT (既定) |
|---|---|---|
| `examples/collatz.cp` | 455 ms | **111 ms** (4.1×) |
| `examples/fib.cp` | 14 ms | **6 ms** (2.3×) |
| 上のトップレベルのループ | 78 ms | **14 ms** (5.6×) |

`collatz` とトップレベルのループはループ主体なので素直に効く。`fib` は呼び出し主体で、
関数呼び出しが毎回 Rust の `rt_call` を経由する分だけ頭打ちになる。

## テスト

```sh
cargo test
```

`tests/tiers_agree.rs` は**差分テスト**になっている。各プログラムを

1. インタプリタのみ
2. 1 回目の呼び出しから JIT
3. 2 回目から JIT（＝同じ関数を両方の実行系が実行する）

の 3 通りで走らせ、**戻り値・`print` の出力・エラーメッセージがすべて一致すること**を要求する。
エラーメッセージを両者で共通の関数（`Vm::error_at`）から組み立てているのはこのため。
型情報を含めない代わりに、どちらの実行系でも同じ文言が出る。

## 既知の限界

- **x86-64 Linux 専用**。他ターゲットでは `build.rs` が明示的に失敗する
- JIT の起動条件が**呼び出し回数＋エントリポイント特例**しかない。エントリポイント以外で
  1 回しか呼ばれない関数は、中に重いループがあってもコンパイルされない。
  本来はループのバックエッジを数えて OSR（on-stack replacement）するべきところ
- JIT ↔ JIT の呼び出しも毎回 Rust の `rt_call` を経由する（直接呼び出しにはしていない）
- 最適化は一切しない。定数畳み込みもレジスタ割り当ても無い、文字どおりの**ベースライン** JIT
- 再帰の深さは `max_depth` で止める。両実行系とも言語レベルの呼び出し 1 回につき
  ネイティブフレームを 1 枚使うので、`main` は 64 MiB のスタックを持つスレッドで走らせている

## ファイル構成

```
csrc/stencils.c        オペコードごとのステンシル（clang がコンパイルする唯一の C）
build.rs               clang 起動 → ELF から機械語と再配置を抽出 → stencils.bin / stencils.rs
src/parser.rs          nom のパーサ（カスタムエラー型で位置付きメッセージ）
src/ast.rs             構文木
src/compiler.rs        AST → スタックバイトコード、暗黙の main の合成、スタック深さの解析
src/bytecode.rs        Op と Function
src/value.rs           タグ付き値（int / bool / 関数参照）
src/vm.rs              インタプリタ、Shared レイアウト、JIT からのコールバック
src/jit.rs             ステンシルの連結とパッチ、mmap/mprotect
src/main.rs            CLI
```
