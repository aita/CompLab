# 18. ABI リファレンス — 両側が合意していること

付録である。説明はせず、**取り決めだけ**を並べる。理由が知りたいところは章を指してある。

生成コードと実行時ライブラリは別々に書かれ、別々にコンパイルされ、リンク時に初めて
出会う（[14章](14-elf.md)の9節）。だから両者が字面まで一致していなければならない事実の
一覧が必要で、これがそれである。C で実行時に手を入れるとき、あるいは外から呼ぶときに
見る。

---

## 18.1 値の表現

```
整数    2n + 1                  タグ付き。最下位ビットが「ポインタでない」と言う
塊      8で揃ったポインタ。その −1 語目が記述子へのポインタ
```

塊の**値**は記述子の語の**次**を指す。確保したものを返すときは `header + 8` である。

タグ付き整数は**単調**なので、整数の順序比較は untag せずにそのままできる。等値も
同じ。負数は算術シフト（`sar`）で戻す。

真偽値は整数ではない。`bool` はふつうの直和型なので、比較の結果は
`skunk_true` か `skunk_false` という**静的な塊のアドレス**である
（[14章](14-elf.md)の4節）。

## 18.2 記述子

6語。生成コードが出し、実行時が読む。

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
| 6 | 空き領域 | `[大きさ（語数）]`。実行時の内部用（[15章](15-gc.md)の6節） |

**どの語が値か**は種別で決まる。収集器と `show` と `equal` が同じ表を見ている。

| 種別 | 値である語 |
|---|---|
| レコード・構成子 | 0 … nfields−1 |
| クロージャ | **1** … nfields−1（0はコードのアドレスで、値ではない） |
| 参照 | 0 |
| 配列 | **1** … n（0は長さで、値ではない） |
| 文字列 | なし |

塊の大きさは記述子から出る — ただし文字列と配列は**自分の長さを塊の中に持つ**ので、
そこだけ場合分けになる。すべての塊は**偶数語**に丸められている（[15章](15-gc.md)の6節）。

文字列の塊は長さの語を値が指し、`NUL` は長さに数えない。コピーせずにシステムコールへ
渡せるように置いてあるだけである。

## 18.3 呼び出し規約

```
rdi     クロージャ
rsi     引数（1つ。2つ以上は組で渡す）
rax     結果
```

呼び出しは、クロージャの0語目にあるアドレスへの間接呼び出しである。

```
mov <closure>, %rdi
mov <argument>, %rsi
mov (%rdi), %rcx
call *%rcx
```

`Capture i` は `[rdi + 8 + 8i]`。関数の入口で `rdi` と `rsi` は仮想レジスタに写され、
そこから先は割り付け器の裁量になる（[12章](12-select.md)）。

実行時ルーチンは**System V のまま**である（`rdi`・`rsi`・`rdx`、結果は `rax`）。
言語の引数1つとの差を埋めるのが基底環境のスタブで、組を開くのがその仕事の全部である
（[14章](14-elf.md)の6節）。

## 18.4 レジスタ

割り付けに使うのは13本。並びは System V の引数順で、呼び出しの被演算子が移動を
要らなくなることが多い。

| | |
|---|---|
| caller-saved | `rax` `rcx` `rdx` `rsi` `rdi` `r8` `r9` `r11` |
| callee-saved | `rbx` `r12` `r13` `r14` `r15` |
| 配らない | `r10`（末尾呼び出しの飛び先を待たせるスクラッチ）・`rsp`・`rbp` |

**呼び出しをまたいで生きている値は callee-saved かフレームスロットにしかない。**
呼び出しが caller-saved を全部定義するので、干渉グラフがそう押し出す
（[13章](13-regalloc.md)の3節）。これは収集器がルートを見つけられる理由でもある
（[15章](15-gc.md)の3節）。

## 18.5 フレーム

フレームポインタはない。実行時にスタックへ積むものが何もないので、`rsp` は本体の
あいだ動かない。

```
入口:  push <彩色が使った callee-saved を順に>
       sub  $8*nspill, %rsp
出口:  add  $8*nspill, %rsp
       pop  <逆順>
       ret
```

溢れの場所は `[rsp + 8i]`。末尾呼び出しはフレームを畳んでから飛ぶので、飛び先を
`r10` に読んでおく — `pop` はそれを触らない。

```
mov (%rdi), %r10
<epilogue>
jmp *%r10
```

## 18.6 記号の名前

| 形 | 何 |
|---|---|
| `code_<名前>` | 関数のコードブロック |
| `item_<n>` | 最上位の束縛 `n` 本目の本体 |
| `skunk_g_<名前>` | 大域変数1語 |
| `str_<n>` | 文字列リテラルの塊 |
| `desc_rec_<n>` `desc_con_<n>` `desc_clos_<n>` | 記述子 |
| `con_<n>` | 引数のない構成子の塊 |
| `clos_<n>` `rec_<n>` `labels_<n>` | 基底環境の静的データ |
| `basis_<名前>` | 基底環境のスタブ |
| `objsec_<n>` `objlocal_<n>_<名前>` | 読み込んだオブジェクトの節と局所記号 |

ソースの名前は、英数字と `_` 以外を `_XX`（16進）にして通す。だから `^` や `<=` にも
ラベルが付き、違う名前が衝突しない。

## 18.7 両側が名前で合意しているもの

**コンパイラが出し、実行時が要求する:**

| | |
|---|---|
| `skunk_program` | 最上位の束縛を順に走らせる。`skunk_boot` が呼ぶ |
| `skunk_data_start` `skunk_data_end` | データ領域の範囲。収集器が保守的に走査する |
| `skunk_true` `skunk_false` `skunk_nil` | 引数のない組み込み構成子の塊 |
| `skunk_true_name` `skunk_false_name` `skunk_nil_name` `skunk_cons_name` | その名前の文字列の塊。`show` が使う |
| `skunk_stack_top` | `_start` が `rsp` を書き込む1語 |

**実行時が出し、コンパイラが使う:**

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

`skunk_the_unit` は1語の大域変数で、`()` はどこでも同じ塊である。

比較と `not` が返すのは `skunk_true`/`skunk_false` のアドレスで、タグ付きの 0/1 では
ない（18.1）。

## 18.8 収集器に対して守ること

確保はいつでも収集を起こしうる。守るべきことは3つだけである。

- **生きている値をレジスタとスタックの外に隠さない。** 収集器はデータ領域とスタックと
  レジスタを見る。そのどこからも辿れない場所に唯一の参照を置いてはいけない。
- **塊の途中を指さない。** 内部ポインタはこの言語に存在せず、収集器は「塊の先頭か」で
  候補を検証する。途中を指すものは**ポインタとして認められない**。
- **半分できた塊は構わない。** 捕獲を書く前のクロージャを辿ることは起こるが、そこに
  入っている残骸も先頭マップで検証されるので、拒否されるか余分に1つ保持するかにしか
  ならない。非移動であることがこれを許している（[15章](15-gc.md)の4節）。

生の整数を callee-saved レジスタに置いたまま確保しても**安全である**。整数がポインタに
化けないのはタグのおかげで、ヒープの範囲に落ちた生の値は先頭マップが落とす。

## 18.9 ファイルの形

既定は libc なしの静的 ELF64。セグメント2つ、セクションヘッダなし、入口は `_start`
（[14章](14-elf.md)の3節）。`--dynamic` を付けると `PT_PHDR`・`PT_INTERP`・`PT_DYNAMIC`
が増え、`libc.so.6` を動的リンクする（同8節）。

`_start` は3命令である。`rsp` を `skunk_stack_top` に保存し、`skunk_boot` を呼ぶ。
libc がないので、コンストラクタも `argv` の解析もない。

---

## 参考文献

- System V ABI, AMD64 Processor Supplement — 18.3 と 18.4 が従っているもの。
- *The Definition of Standard ML (Revised)*, 1997 — 引数を1つ取り、2つ以上は組で渡す
  という形の出どころ。

## 実装の地図

| 何 | どこ |
|---|---|
| 値の表現と記述子 | `src/runtime/runtime.c` の冒頭と `struct desc` |
| レジスタの並びと役割 | `src/compiler/mach.ml` の `reg_name`、`caller_saved`、`callee_saved` |
| 呼び出しの組み立て | `src/compiler/select.ml` の `value` の `S.Call` の枝 |
| フレームと末尾呼び出し | `src/compiler/emit.ml` の `prologue`、`epilogue`、`func` |
| 記号の名前 | `src/compiler/statics.ml` の `mangle`、`code_label`、`global` ほか |
| 実行時ルーチンへの対応表 | `src/compiler/select.ml` の `prim_routine` |
| 基底環境のスタブ | `src/compiler/stubs.ml` |
| 組み込み構成子の塊 | `src/compiler/rt.ml` の `data` |

---

[← 17. ループと命令スケジューリング](17-loops.md) ・ [目次](index.md)
