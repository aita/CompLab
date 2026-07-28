# 3. インタプリタ — `exec.cppm`, `cpu.cppm`

1命令を fetch して retire するまでです。浮動小数点だけは扱いが違うので[4章](float.md)に
分けてあります。

## 1. `Cpu` が知っていること

```cpp
class Cpu {
 public:
  Hart hart;      // x[32], f[32], pc, fcsr, instret, LR/SC の予約
  Memory mem;

  bool fetch(u64 pc, Inst& out);
  Stop step();
};
```

これで全部です。**システムコールも ELF もデバッガも知りません。** `ecall` に当たったら
止まって理由を返し、それが何を意味するかは上の `Machine` が決めます。この分け方の効き目は
§5 で書きます。

`Hart` の `x[0]` は書き込みを捨てます。読むほうを毎回分岐させないよう、書くほうで潰します。

```cpp
u64 getx(unsigned r) const { return r ? x[r] : 0; }
void setx(unsigned r, u64 v) { if (r) x[r] = v; }
```

## 2. 1命令

```cpp
Stop step() {
  Inst in;
  if (!fetch(hart.pc, in)) return fault(Access::Fetch);
  if (in.op == Op::Illegal) { bad_word = in.raw; return Stop::Illegal; }

  const u64 pc = hart.pc;
  u64 next = pc + in.len;
  const Stop s = run(in, pc, next);
  if (s == Stop::None || s == Stop::Ecall) {
    hart.pc = next;
    ++hart.instret;
  }
  return s;
}
```

`next` を参照で渡し、**分岐命令だけがそれを書き換えます**。分岐でない命令は `next` に
触らないので、pc を進める場所が1か所で済みます。

`fetch` は 16 ビットを読んで、圧縮でなければもう 16 ビット読みます。4 バイトの命令が
ページをまたぐことがあるので、繋げてから読むのではなく2回に分けます
（[1章 §4](memory.md#4-境界をまたぐアクセス)）。

## 3. 整数命令 — 仕様の角を丸めない

大きな `switch` です。面白いのは、**C++ で書くと違う答えになるところ**だけです。

**除算は絶対にトラップしません。** RISC-V は退化した場合をすべて値で定義しているので、
検査するのはゲストのコードの責任です。C++ の `/` にそのまま渡すと未定義動作になります。

```cpp
case Op::Div:
  if (b == 0) h.setx(in.rd, ~u64{0});
  else if (i64(a) == std::numeric_limits<i64>::min() && i64(b) == -1) h.setx(in.rd, a);
  else h.setx(in.rd, u64(i64(a) / i64(b)));
  return Stop::None;
```

| | 0 除算 | `INT64_MIN / -1` |
|---|---|---|
| `div` | 全ビット 1 | `INT64_MIN` |
| `rem` | 被除数 | 0 |
| `divu` | 全ビット 1 | — |
| `remu` | 被除数 | — |

**`*w` 系は 32 ビットで計算して符号拡張します。** 結果が上位32ビットまで正しく伸びて
いないと、あとで比較したときだけ壊れます。

```cpp
case Op::Addw:  h.setx(in.rd, sext32(u32(a) + u32(b)));  return Stop::None;
case Op::Sraw:  h.setx(in.rd, sext32(u32(i32(u32(a)) >> (b & 31)))); return Stop::None;
```

`srliw a6, t5, 4` に `t5 = -1` を入れると `0x0fffffff` になり、`srliw a6, t5, 0` なら
`0xffffffffffffffff` になります。後者は「32ビットの結果を符号拡張する」の帰結で、直感には
反しますが仕様どおりです。

**シフト量は下位ビットだけ見ます。** RV64 の `sll` は `rs2 & 63`、`sllw` は `rs2 & 31`。
C++ のシフトは幅以上だと未定義なので、マスクは省けません。

**乗算の上位は 128 ビットで取ります。** `mulh` / `mulhsu` / `mulhu` は `__int128` を
経由します。

## 4. A 拡張 — 1 hart の LR/SC

予約は1組だけ持ちます。

```cpp
bool resv_valid;
u64  resv_addr;
```

**hart が1つなので、予約を壊せるのは自分自身だけ**です。他の実行主体がいない以上、
`sc` が見るべきなのは「予約が生きていて、アドレスが一致するか」だけで足ります。

```cpp
if (!hart.resv_valid || hart.resv_addr != addr) {
  hart.resv_valid = false;
  hart.setx(in.rd, 1);        // 失敗。メモリには触らない
  return Stop::None;
}
```

`aq` / `rl` はデコードして `Inst` に入れますが、実行では見ません。順序づけるべき相手が
いないからです。AMO 9 種は `load → 関数 → store → 古い値を rd へ` の形にまとめてあり、
違うのはラムダだけです。

```cpp
case Op::AmominuD:
  return amo<i64>(in, a, [&](i64 o) { return i64(std::min(u64(o), b)); });
```

## 5. トラップの境界

`step()` が返す `Stop` は5種類です。

| | 意味 | pc |
|---|---|---|
| `None` | 普通に進んだ | 次の命令 |
| `Ecall` | 環境呼び出し | **その先へ進めてある** |
| `Ebreak` | ブレークポイント | その命令のまま |
| `Illegal` | デコードできない | その命令のまま |
| `Fault` | メモリ保護違反 | その命令のまま |

**フォールトで pc を進めないのは、デバッガが見せたいのがそこだから**です。ページを貼り
直して再実行するなら、そこから始めることになります。フォールト報告に出るアドレスが、
gdb が `bt` で見せる場所と一致します。

```
$ rvemu fault.s
rvemu: load fault at 0x40 (pc 0x10004 <_start+0x4>)
```

**`ecall` だけが例外**で、返す前に pc を進めます。そのおかげで
[システムコールのハンドラ](syscall.md)は `a0` を書くだけで済み、「戻り先はどこか」を
考えなくてよくなります。

境界をここに引いたことの効き目は、gdb で分かります。ゲストが `write()` の途中で止まって
いても、シングルステップは1命令だけ進みます。もし `Cpu` の中でシステムコールまで処理して
いたら、`ecall` の1ステップが「システムコール1回ぶん」の大きさになっていました。

## 6. CSR

読み書きできるのは6つだけです。

| | |
|---|---|
| `fflags` `frm` `fcsr` | 浮動小数点。glibc の `fenv` が触る（[4章](float.md)） |
| `cycle` `time` `instret` | カウンタ。読み出し専用 |

`cycle` は `instret` と同じ値を返します。サイクル精度のモデルがないので、**退役した命令数を
サイクル数の代わりに置いています**。ゲストから見て単調に増えることだけは保証されます。
`time` は起動時のナノ秒に `instret` を足したものです。

書けない CSR に書こうとしたら `Illegal` です。`csrrs` / `csrrc` は rs1 が `x0` なら書き込みを
やらないので、読み出し専用のカウンタは `csrr`（= `csrrs rd, csr, x0`）で読めます。

```cpp
const bool writes = (in.op == Op::Csrrw || in.op == Op::Csrrwi) || in.rs1 != 0;
```

## 7. 見え方

`-t` が1命令ずつ出します。右の欄はシンボルで、[5章](process.md)のシンボル表から引きます。

```
$ rvemu -t examples/fib.s
     0x1007c  li t2,10                 print_dec+0x14
     0x10080  beqz a0,0x100a0          print_dec+0x18
     0x10084  remu t3,a0,t2            print_dec+0x1c
     0x10088  addi t3,t3,48            print_dec+0x20
     0x1008c  addi t1,t1,-1            print_dec+0x24
     0x10090  sb t3,0(t1)              print_dec+0x28
     0x10094  divu a0,a0,t2            print_dec+0x2c
     0x10098  bnez a0,0x10084          print_dec+0x30
     0x10084  remu t3,a0,t2            print_dec+0x1c
```

`print_dec` が 10 で割りながら数字を後ろから書いているところです。ループが1周して
`0x10084` に戻っています。

## していないこと

**スーパーインストラクションもスレッデッドコードもありません。** `switch` 1つです。
30M 命令/秒 出ていて、いま困っている用途がありません。

**割り込みも例外ハンドラもありません。** ユーザモードのエミュレータなので、トラップは
すべて「エミュレータが止まる」で終わります。ゲスト側のシグナルハンドラは走りません
（[6章](syscall.md#していないこと)）。

## 参考文献

- [The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA][isa]。
  §7（M 拡張）の除算の表と、§8（A 拡張）の LR/SC の規定がこの章の元です。

[isa]: https://riscv.org/technical/specifications/

## 実装の地図

| | |
|---|---|
| `cpu.cppm` 88–116行 | `Hart` — レジスタ、pc、fcsr、LR/SC の予約 |
| `exec.cppm` 25–44行 | `Stop` — 止まった理由 |
| `exec.cppm` 61–72行 | `fetch` — パーセル2回 |
| `exec.cppm` 75–91行 | `step` — 1命令 |
| `exec.cppm` 101–285行 | `run` — 整数・M・A の switch |
| `exec.cppm` 286–336行 | `load_into` / `store_from` / `lr` / `sc` / `amo` |
| `exec.cppm` 339–384行 | `csr` / `csr_read` / `csr_write` |

---

[← 2. デコードとエンコード](decode.md) ／ [目次](index.md) ／ [4. 浮動小数点 →](float.md)
