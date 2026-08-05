# 12. ABI リファレンス — 両側が合意していること

付録である。説明はせず、**取り決めだけ**を並べる。理由が知りたいところは章を指してある。

生成コードと実行時ライブラリは別々に書かれ、別々にコンパイルされ、リンク時に初めて
出会う。だから両者が字面まで一致していなければならない事実の一覧が必要で、これがそれ
である。C で実行時に手を入れるとき、あるいは外から呼ぶときに見る。

---

## 12.1 値の表現

```
整数    2n + 1                  タグ付き。最下位ビットが「ポインタでない」と言う
塊      8で揃ったポインタ。その −1 語目が記述子へのポインタ
```

塊の**値**は記述子の語の**次**を指す。確保したものを返すときは `header + 8` である。
静的な塊では `ptrtoint (getelementptr i8, ptr @g, i64 8)` — LLVM はグローバルの途中に
シンボルを置けないが、定数 GEP が定数なので置く必要がない。

タグ付き整数は**単調**なので、整数の順序比較は untag せずにそのままできる。等値も
同じ。負数は算術シフトで戻す。

真偽値は整数ではない。`bool` はふつうの直和型なので、比較の結果は
`skunk_true_blk + 8` か `skunk_false_blk + 8` という**静的な塊のアドレス**である。
比較が作った `i1` をそのまま使う場合については[11章](11-lower.md)の5節。

## 12.2 記述子

6語。生成コードが出し、実行時が読む。LLVM 上では `[6 x i64]` のグローバルで、
**`constant` を付けない**（12.6）。

| 位置 | 何 |
|---|---|
| 0 | 種別 |
| 8 | フィールド数 |
| 16 | 構成子の名前（文字列の塊）、なければ 0 |
| 24 | ラベルの配列（フィールドごとに文字列の塊1つ）、組なら 0 |
| 32 | リストとして表示するか。0 ふつう / 1 nil / 2 cons |
| 40 | タグ。直和型の何番目の構成子か。`case` が比較するのはこれ |

種別:

| 値 | 種別 | 塊の中身 |
|---|---|---|
| 0 | レコード | フィールドが `nfields` 個 |
| 1 | 構成子 | 引数があれば1個 |
| 2 | 文字列 | `[長さ][バイト列][NUL]` |
| 3 | クロージャ | `[コードのアドレス][捕獲 0..n−1]` |
| 4 | 配列 | `[長さ][要素 0..n−1]` |
| 5 | 参照 | 1語 |
| 6 | 空き領域 | `[大きさ（語数）]`。実行時の内部用（[13章](13-gc.md)） |

**どの語が値か**は種別で決まる。収集器と `show` と `equal` が同じ表を見ている。

| 種別 | 値である語 |
|---|---|
| レコード・構成子 | 0 … nfields−1 |
| クロージャ | **1** … nfields−1（0はコードのアドレスで、値ではない） |
| 参照 | 0 |
| 配列 | **1** … n（0は長さで、値ではない） |
| 文字列 | なし |

塊の大きさは記述子から出る — ただし文字列と配列は**自分の長さを塊の中に持つ**ので、
そこだけ場合分けになる。すべての塊は**偶数語**に丸められている。

文字列の塊は長さの語を値が指し、`NUL` は長さに数えない。コピーせずにシステムコールへ
渡せるように置いてあるだけである。

## 12.3 呼び出し規約

コードブロックはどれも1つの LLVM 型を持つ。

```llvm
i64 (i64, i64)      ; (クロージャ, 引数) -> 値
```

呼び出しは、クロージャの0語目にあるアドレスへの間接呼び出しである。

```llvm
%code   = load i64, ptr %closure_word_0
%target = inttoptr i64 %code to ptr
%result = call i64 %target(i64 %closure, i64 %argument)
```

`Capture i` はクロージャの語 `i + 1`。引数は1つで、2つ以上は組で渡す。

**末尾呼び出しは `musttail`** で、その直後に `ret` が要る。合法なのは呼び出し元と
呼び出し先の型が一致しているからで、それがこの節の型が1つしかない理由でもある
（[11章](11-lower.md)の2節）。

最上位の束縛の本体も同じ型を持つ。誰も呼ばないのでクロージャと引数はタグ付きの 0
（`i64 1`）を渡すが、本体が末尾呼び出しを含みうるので型は揃っていなければならない。

実行時ルーチンは**C の呼び出し規約のまま**である。言語の引数1つとの差を埋めるのが
基底環境のスタブで、組を開くのがその仕事の全部である。レジスタの割り当ては LLVM の
System V 実装がやるので、この処理系はレジスタを1本も名指ししない。

## 12.4 セクションとシンボル

コンパイラが出すグローバルは**全部 `skunk_data` に入る**。リンカが C 識別子の名前を持つ
出力セクションの両端に `__start_skunk_data` と `__stop_skunk_data` を定義するので、
収集器が保守的に走査する範囲はそれで決まる（[13章](13-gc.md)）。全部 8 で揃えてある。

| 形 | 何 |
|---|---|
| `code_<名前>` | 関数のコードブロック |
| `basis_item_<n>` `main_item_<n>` | 最上位の束縛 `n` 本目の本体 |
| `skunk_g_<名前>` | 大域変数1語 |
| `str_<n>` | 文字列リテラルの塊 |
| `desc_rec_<n>` `desc_con_<n>` `desc_clos_<n>` | 記述子 |
| `con_<n>` | 引数のない構成子の塊 |
| `clos_<n>` `rec_<n>` `labels_<n>` | 基底環境の静的データ |
| `basis_<名前>` | 基底環境のスタブ |

ソースの名前は、英数字と `_` 以外を `_XX`（16進）にして通す。だから `^` や `<=` にも
シンボルが付き、違う名前が衝突しない。

コンパイラが出すものはすべて `internal`、実行時から借りるものはすべて `dso_local` で
ある。後者を書かないと、静的リンクの実行ファイルなのに PLT と GOT が現れる
（[10章](10-llvm.md)の3節）。

## 12.5 両側が名前で合意しているもの

**コンパイラが出し、実行時が要求する:**

| | |
|---|---|
| `skunk_program` | 最上位の束縛を順に走らせる。`skunk_boot` が呼ぶ |
| `skunk_data` セクション | 収集器が保守的に走査する範囲。両端の名前はリンカが付ける |

**実行時が出し、コンパイラが使う:**

| | |
|---|---|
| `skunk_the_unit` | 1語の大域変数。`()` はどこでも同じ塊 |
| `skunk_true_blk` `skunk_false_blk` `skunk_nil_blk` | 引数のない組み込み構成子の塊。値はその `+8` |

記述子 — `skunk_string_desc` `skunk_unit_desc` `skunk_array_desc` `skunk_ref_desc`
`skunk_pair_desc` `skunk_true_desc` `skunk_false_desc` `skunk_nil_desc`
`skunk_cons_desc`。**組み込み構成子の記述子は必ずこれを使う** — 2つの構成子が等しいのは
記述子が同じポインタのときだけなので、持ち主は1つでなければならない。

ルーチン（C の型で書く。`value` は `long`）:

```c
value skunk_alloc(struct desc *, long nwords);   /* 値を返す。header+8 */
value skunk_equal(value, value);   value skunk_noteq(value, value);
value skunk_not(value);
value skunk_lt(value, value);      value skunk_le(value, value);
value skunk_gt(value, value);      value skunk_ge(value, value);
value skunk_compare(value, value); /* Int.compare と String.compare は同じもの */
value skunk_div(value, value);     value skunk_mod(value, value);
value skunk_abs(value);            value skunk_min(value, value);
value skunk_max(value, value);
value skunk_concat(value, value);  value skunk_size(value);
value skunk_substring(value s, value start, value len);
value skunk_int_to_string(value);  value skunk_print(value);
value skunk_ref(value);            value skunk_deref(value);
value skunk_setref(value, value);
value skunk_array(value n, value init);        value skunk_array_length(value);
value skunk_array_sub(value, value);           value skunk_array_update(value, value, value);
value skunk_array_from_list(value);            value skunk_array_to_list(value);
value skunk_append(value, value);
void  skunk_report(const value *label, value); /* label は文字列の塊 */
void  skunk_report_label(const value *label);
void  skunk_match_fail(const value *where);    /* 戻らない */
void  skunk_flush(void);
```

比較と `not` が返すのは組み込み構成子の塊のアドレスで、タグ付きの 0/1 ではない（12.1）。

`div`・`mod`・6つの比較は、速い場合を生成コードが直接書き、遅い場合だけここへ来る
（[14章](14-opt.md)の3節）。意味は両方で同じでなければならない — `sdiv` と C の `/` は
どちらも0方向に切り捨てる。

## 12.6 LLVM に対して守ること

- **記述子に `constant` を付けない。** `-O2` の `constmerge` が中身の等しい定数
  グローバルを1つにまとめる。同じ形の記述子を持つ2つの構成子は、まとめられると等値に
  なってしまう。`tests/nullary.sk` がそれを聞く。
- **`getelementptr` に `inbounds` を付けない。** 記述子は語 −1 にあり、値が指している
  塊の外である。
- **確保をまたいで生きる値は、確保より前に計算する。** 引数として渡すか、呼び出しの後で
  使うかしていれば、LLVM は callee-saved かフレームに置くしかなく、収集器はその両方を
  見る（[11章](11-lower.md)の7節）。

## 12.7 収集器に対して守ること

確保はいつでも収集を起こしうる。守るべきことは3つだけである。

- **生きている値をレジスタとスタックの外に隠さない。** 収集器は `skunk_data` と
  スタックとレジスタを見る。そのどこからも辿れない場所に唯一の参照を置いてはいけない。
- **塊の途中を指してよい。** 内部ポインタは**認められる**。最適化器が作るので、そう
  しなければならなかった（[13章](13-gc.md)の3節）。ここは SkunkML の手書きバックエンドと
  違うところである。
- **半分できた塊は構わない。** 捕獲を書く前のクロージャを辿ることは起こるが、そこに
  入っている残骸も先頭マップで検証されるので、拒否されるか余分に1つ保持するかにしか
  ならない。非移動であることがこれを許している。

生の整数を callee-saved レジスタに置いたまま確保しても**安全である**。整数がポインタに
化けないのはタグのおかげで、ヒープの範囲に落ちた生の値は先頭マップが落とす。

## 12.8 ファイルの形

`skunkllvm` は `.ll` を書き、`clang -O2 -fno-pic -fno-pie -mcmodel=small -c` に渡して
`.o` にし、`clang -nostdlib -static` でリンクする。相手は実行時ライブラリの
オブジェクト1つで、それはコンパイラの中にバイト列として入っている。`-fno-pic` が
再配置モデル `Static`、`-mcmodel=small` がコードモデル `Small` にあたる。

`_start` は実行時ライブラリにある。C の関数ではないので naked で、やることは
スタックポインタを引数にして `skunk_boot` を呼ぶことだけである — その値が収集器の
走査の上端になる。libc がないので、コンストラクタも `argv` の解析もない。

```c
__attribute__((naked, noreturn)) void _start(void) {
  __asm__ volatile("movq %rsp, %rdi\n\tandq $-16, %rsp\n\tcallq skunk_boot");
}
```

`andq $-16` が要るのは、プロセスの入口には戻り番地が積まれていないぶん、C が期待する
16バイト整列が8だけずれているからである。

## 12.9 まだ決まっていないもの

**`real` の表現。** インタプリタには `real` があり、このバックエンドにはない。決めるべき
ことは3つある — 塊にするなら種別を1つ増やし、`show` が `types.ml` の `real_str` と
同じ桁を出す手順を freestanding な C で書き、`Real` と `Math` のスタブを足す。決まって
いないので、`skunkllvm` は推測せずに断る。

```
$ skunkllvm tests/reals.sk
?: unsupported: a real literal needs a representation the back end does not have yet
```

---

## 参考文献

- System V ABI, AMD64 Processor Supplement — 12.3 の実行時ルーチン側が従っているもの。
- LLVM Language Reference Manual, `musttail` と `getelementptr` の節。
- *The Definition of Standard ML (Revised)*, 1997 — 引数を1つ取り、2つ以上は組で渡す
  という形の出どころ。

## 実装の地図

| 何 | どこ |
|---|---|
| 値の表現と記述子 | `src/runtime/runtime.c` の冒頭と `struct desc` |
| LLVM IR のテキストを書く | `src/llvm/ir.ml` |
| 記述子・静的な塊・グローバル | `src/llvm/layout.ml` |
| 呼び出しと末尾呼び出しの組み立て | `src/llvm/lower.ml` の `call_closure` と `tail` |
| 速い場合を書いている場所 | `src/llvm/lower.ml` の `comparison` と `division` |
| 実行時ルーチンへの対応表 | `src/llvm/lower.ml` の `routine` |
| 基底環境のスタブ | `src/llvm/prelude.ml` |
| clang の呼び出しとリンク | `src/llvm/emit.ml` |

---

[← 11. Flat から LLVM IR へ](11-lower.md) ・ [13. 保守的 GC と最適化器 →](13-gc.md)
