# 7. アセンブラ — `assembler.cppm`

`rvemu prog.s` が外部ツールチェーンなしで動くようにする部分です。ソースの3割がここに
あります。

受け付けるのは、手書きとコンパイラ出力の RISC-V アセンブリが実際に使う GNU as の方言 ——
RV64GC のニーモニック、擬似命令、ふつうのディレクティブ、`%hi`/`%lo`/`%pcrel_hi`/`%pcrel_lo`、
数字のローカルラベルです。

## 1. リラクゼーションをしない、という決定

これが他のすべてを決めています。**どの命令の大きさも、シンボルの値ではなく構文から
決まります。**

| | 大きさ |
|---|---|
| ふつうの命令 | 4 |
| `call` / `tail` / `la` / `lla` | 常に 8（`auipc` + 1命令） |
| `li` | 手元にあるリテラルから展開した長さ |
| `lw rd, symbol` | 8（`auipc` + ロード） |

GNU as なら、届く距離のときに `call` を `jal` 1本に縮めます。それをやると「縮んだせいで
別の場所が届くようになって、また縮む」という不動点計算になります。**縮めないと決めれば、
シンボルの値が1つも分からないうちにレイアウトを確定できます。**

代償は1つだけ、入力に条件が付きます。

```
$ rvemu prog.s
rvemu: prog.s:4: li needs an absolute value; use `la` to load an address
```

`li a0, some_label` はラベルに値が付いた時点で展開の長さが変わるので、**黙って壊れる代わりに
エラーにします**。アドレスを積むのは `la` の仕事で、そもそも書きたかったのはそちらのはずです。
`.equ` の定数は値がレイアウトに依存しないので通ります。

```asm
msg:    .string "hello from rvemu\n"
        .equ    msglen, . - msg - 1
        li      a2, msglen              # 通る
```

## 2. 3回歩く

2回ではなく3回です。

| | すること | エラー |
|---|---|---|
| 1回目 | セクションの大きさを測る | 出さない |
| — | セクションのベースを決める | |
| 2回目 | 全ラベルの最終アドレスを確定する | 出さない |
| 3回目 | 本番の出力 | **ここだけ** |

2回で足りない理由は、**前方参照**です。1回目はベースが 0 のまま歩くので、そこで付いた
ラベルの値は本物ではありません。ベースを決めたあとにもう一度歩いて初めて、まだ定義に
辿り着いていないラベルも含めて全部が正しい値になります。3回目は完全なシンボル表を持って
出力します。

大きさが3回とも同じであることが前提で、それを保証しているのが §1 です。

```cpp
if (!walk(false, d)) return false;   // 測る
assign_bases();
if (!walk(false, d)) return false;   // ラベルを確定する
if (!walk(true, d)) return false;    // 出力する
```

「まだ知らないシンボル」は 1・2 回目では 0 として扱い、エラーにしません。3回目でも見つから
なければ、そこで初めて未定義シンボルです。

```cpp
out = 0;
return !emitting_;   // 出力パスでだけ「知らない」を失敗にする
```

セクションは最初に現れた順に、`0x10000` から**各々ページ境界**に置きます。境界を揃えるのは
権限をセクション単位にするためと、`.align` の意味が「オフセットの整列」と「アドレスの整列」で
食い違わないようにするためです。

## 3. 字句 — 文に切る

行ではなく**文**に切ります。`;` は区切り、`#` と `//` は行コメント、`/* */` はブロック
コメント、`:` の手前はラベル。1行に複数のラベルと1つの文が載ります。

```cpp
if (c == ':') {
  std::string name = cur; trim(name);
  pending.push_back(name);   // 次の文に付くラベル
  cur.clear();
```

オペランドは**括弧と引用符の外側にあるカンマ**で分けます。`sw a0, 8(sp)` の中のカンマでも、
`.string "a,b"` の中のカンマでも切れません。

数字のローカルラベル（`1:` に対する `1f` / `1b`）は、最初に全文を走査して「どの文番号で
何番目に定義されたか」を集め、参照のたびに現在の文番号と突き合わせます。`1b` は**現在の文
以下で最も近いもの**なので、同じ行に付いたラベルも `b` の射程に入ります。

## 4. 式

再帰下降です。C と同じ優先順位で `+ - * / % << >> & | ^ ~ ()`、10/16/8/2 進数、文字リテラル、
`.`（現在位置）。

`%` に曖昧さがあります。**先頭に来たら再配置の指定、途中に来たら剰余**です。`parse()` が
先頭だけ特別扱いし、`%hi` `%lo` `%pcrel_hi` `%pcrel_lo` のどれでもなければ位置を戻して
式として読み直します。

```cpp
if (!name.empty()) { d_.fail_at(line_, ...); return {}; }
i_ = save;    // ただの '%' は剰余演算子。expr() に渡す
```

`&&` と `||` は演算子として扱いません。`&` `|` の1文字だけを見るとき、2文字続いていないか
確かめます。アセンブリに論理演算子は要らず、間違って半分だけ食べるほうが害だからです。

## 5. 再配置

`%hi` と `%pcrel_hi` は **20 ビットの欄の値**を返し、`%lo` と `%pcrel_lo` は**符号拡張した
12 ビット**を返します。上位に `0x800` を足しているのは、あとで来る `%lo` が符号拡張される
ぶんを先に相殺するためです。

```cpp
case as::Reloc::Hi:
  out = i64((u64(o.value) + 0x800) >> 12) & 0xfffff;
  return true;
case as::Reloc::Lo:
  out = sext(u64(o.value), 12);
  return true;
```

`%pcrel_lo(L)` は少し変わっていて、**引数が対になる `auipc` のラベル**です。オフセットは
その `auipc` の位置から測ります。出力中に `auipc` の番地とその行き先を憶えておき、
`%pcrel_lo` が引きます。

```cpp
pcrel_targets_[pc] = u64(o.value);          // %pcrel_hi のとき
...
auto it = pcrel_targets_.find(auipc_at);    // %pcrel_lo のとき
out = sext(u64(i64(it->second) - i64(auipc_at)), 12);
```

## 6. `li` の展開

12 ビットに入るなら 1 命令。32 ビットに収まるなら `lui` + `addiw`。それ以外は、**低い 12
ビットを剥がして残りに対して再帰**し、ゼロの並びをシフト量に畳みます。

```cpp
const i64 lo12 = sext(u64(value), 12);
i64 hi = (value - lo12) >> 12;
unsigned shift = 12;
while ((hi & 1) == 0) { hi >>= 1; ++shift; }   // 末尾のゼロをシフトに畳む
emit_li(rd, hi);
put_u32(enc_i(0x13, rd, 1, rd, i32(shift)));   // slli
if (lo12) put_u32(enc_i(0x13, rd, 0, rd, i32(lo12)));
```

実際に出るもの:

```
$ rvemu -d -a li.s
     0x10000:	li a0,5
     0x10004:	lui a1,0x12              # 0x12345
     0x10008:	addiw a1,a1,837
     0x1000c:	lui a2,0x80000           # 0x7fffffff
     0x10010:	addiw a2,a2,-1
     0x10014:	lui a3,0x92              # 0x123456789abcdef
     0x10018:	addiw a3,a3,-1493
     0x1001c:	slli a3,a3,12
     0x10020:	addi a3,a3,965
     0x10024:	slli a3,a3,13
     0x10028:	addi a3,a3,-1347
     0x1002c:	slli a3,a3,12
     0x10030:	addi a3,a3,-529
     0x10034:	li a4,-1
     0x10038:	li a5,1                  # 0x100000000
     0x1003c:	slli a5,a5,32
```

`lui` の次が `addi` ではなく **`addiw`** なのが要点です。32 ビットに収まる値では、
`lui` の結果に `addi` を足すと上位へ桁上がりが漏れることがあります。`addiw` なら 32 ビットの
計算として閉じたあと符号拡張されます。

末尾のゼロを畳む効果は最後の例に出ています。`0x100000000` は `li 1` + `slli 32` の 2 命令で
済みます。

`li` は展開の長さが値だけで決まるので、3回とも同じバイト数になります。これが §1 の制約の
理由です。

## 7. 擬似命令

大半は「本物の命令に書き換えて、通常の経路に戻す」だけです。

```cpp
auto as_real = [&](std::string op, std::vector<std::string> operands) {
  as::Stmt s = st;
  s.op = std::move(op);
  s.operands = std::move(operands);
  s.labels.clear();
  return instruction(s, d);
};

if (m == "mv")   return as_real("addi",  {ops[0], ops[1], "0"});
if (m == "not")  return as_real("xori",  {ops[0], ops[1], "-1"});
if (m == "ret")  return as_real("jalr",  {"zero", "ra", "0"});
if (m == "bgt")  return as_real("blt",   {ops[1], ops[0], ops[2]});   // 順を入れ替える
```

自分でバイトを出すのは4つだけです —— `li`（§6）、`la`/`lla`、`call`/`tail`（どれも
`auipc` + 1命令）、`unimp`（`0x00000000`、つまり `Illegal`）。

浮動小数点の移動は符号注入です。`fmv.s fd, fs` は `fsgnj.s fd, fs, fs`、`fneg.s` は
`fsgnjn.s`、`fabs.s` は `fsgnjx.s`。

## 8. GNU as と突き合わせる

このアセンブラが正しいかどうかは、意見ではなく差分で決められます。
[`tests/isa.s`](../tests/isa.s) は全ニーモニックと全擬似命令を1行ずつ並べたファイルで、
164 行が 172 命令に展開されます。これを2通りにアセンブルして、rvemu 自身に逆アセンブル
させて比べます。

```sh
$ tests/compare-with-gnu-as.sh
ok: 174 lines identical to GNU as
```

```
riscv64-linux-gnu-as → ld → ELF ─┐
                                  ├─→ rvemu -d → diff
tests/isa.s → rvemu の内蔵 ──────┘
```

両側とも rvemu の逆アセンブラを通すので、**差が出たらそれはバイトの差**です。この突き合わせで
実際に3件出ました。

1. `lui` の即値を「値」で印字していた（GNU は 20 ビットの欄の値を印字する）
2. `fcvt.d.s` / `fcvt.d.w` / `fcvt.d.wu` の既定の丸めモードが `dyn` になっていた。
   丸めが起こり得ない拡大変換なので、GNU as は `rne` を入れる
3. ELF のマッピングシンボル（`$xrv64i2p1_...`）が `_start` に勝っていた

コンパイラの出力も通ります。同じリポジトリの [MartenML](../../MartenML) が吐いた
アセンブリは、外部シンボル（C のランタイム）を差し替えれば 234 命令が最後まで通ります。

## していないこと

**リラクゼーション。** §1 のとおりです。

**オブジェクトファイルを出しません。** 出るのは「メモリに貼られたイメージ」だけで、`.o` も
リンクもありません。外部シンボルは未定義シンボルとしてエラーになります。

**`.macro` / `.rept` / `.if` はありません。** マクロプロセッサはアセンブラとは別の言語で、
手書きのアセンブリで困っていません。

**セクション属性（`"ax"` など）を見ません。** 権限はセクション名から決めます —— `.text` が
読み取り実行、`.rodata` が読み取り、それ以外は読み書き。

## 参考文献

- [GNU as, RISC-V Dependent Features][gnuas]。方言の定義。
- [RISC-V Assembly Programmer's Manual][asmman]。擬似命令と再配置の表。

[gnuas]: https://sourceware.org/binutils/docs/as/RISC_002dV_002dDependent.html
[asmman]: https://github.com/riscv-non-isa/riscv-asm-manual

## 実装の地図

| | |
|---|---|
| `assembler.cppm` 44–49行 | `Stmt` — ラベルと、ニーモニックと、切り分けたオペランド |
| `assembler.cppm` 65–96行 | `split_operands` — 括弧と引用符の外のカンマ |
| `assembler.cppm` 98–187行 | `tokenize` — コメント、`;`、ラベル |
| `assembler.cppm` 197–437行 | `Eval` — 式の再帰下降。`%` の曖昧さは 204–239行 |
| `assembler.cppm` 515–556行 | `Fmt` と `Enc` — 命令形式の分類 |
| `assembler.cppm` 557–730行 | `table()` — ニーモニックの表 |
| `assembler.cppm` 736–760行 | `assemble` — 3回歩く |
| `assembler.cppm` 817–825行 | `assign_bases` — セクションの配置 |
| `assembler.cppm` 934–976行 | `relocate` — `%hi` / `%lo` / `%pcrel_*` |
| `assembler.cppm` 990–1014行 | `walk` — 1回ぶんの走査 |
| `assembler.cppm` 1016–1145行 | `directive` — ディレクティブ |
| `assembler.cppm` 1152–1177行 | `emit_li` — 再帰する展開 |
| `assembler.cppm` 1209–1507行 | `encode` — 形式ごとの符号化 |
| `assembler.cppm` 1509–1685行 | `pseudo` — 擬似命令 |

---

[← 6. システムコール](syscall.md) ／ [目次](index.md) ／ [8. gdb スタブ →](gdb.md)
