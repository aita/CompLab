# 4. 浮動小数点 — `cpu.cppm`, `exec.cppm`

F と D を、soft-float ライブラリを持ち込まずに実装する話です。他の章が「仕様どおりに作る」
話なのに対して、この章だけは**ホストを借りたときにどこがずれるか**という別種の問題を
扱います。借りられないものが1つ残っていて、それは §7 に出てきます。

## 1. なぜホストの FPU を借りるのか

Berkeley SoftFloat を持ってくれば、答えは必ず合います。1万行のC が増えるのと引き換えです。

一方、x86-64 の binary32 / binary64 は **RISC-V が要求するのと同じ IEEE-754 の演算**です。
加減乗除も平方根も融合積和も、ビット単位で同じ答えを出します。だとすれば、必要なのは
「同じでない場所」の一覧だけです。

同じでないのは4か所あります。

| | ホスト | RISC-V |
|---|---|---|
| 演算結果の NaN | 入力のペイロードを quiet 化して伝播 | 常に正規形 |
| `fmin` / `fmax` | 片方が NaN のときの扱いが違う | NaN でないほうを返す |
| `fcvt` の範囲外 | C++ では未定義動作 | 飽和して NV を上げる |
| 丸めモード RMM | **存在しない** | 最近接、同点なら 0 から遠いほう |

はじめの3つは埋められます。4つ目は埋め切れません。

## 2. NaN boxing — 単精度は 64 ビットのレジスタに入る

f レジスタは 64 ビットです。そこに binary32 を入れるとき、RISC-V は**上位 32 ビットを
全部 1 にする**ことを要求します。そうなっていない値を単精度として読んだら、それは
「妥当な単精度ではない」ので正規形の NaN として扱います。

```cpp
inline float unbox_f32(u64 bits) {
  const u32 w = ((bits & kNanBoxMask) == kNanBoxMask) ? static_cast<u32>(bits)
                                                     : kCanonicalNanF32;
  return std::bit_cast<float>(w);
}
inline u64 box_f32(float v) { return kNanBoxMask | std::bit_cast<u32>(v); }
```

`fmv.w.x` で整数を入れたときも、`flw` でメモリから読んだときも、書き込む側が箱に入れます。
読む側が毎回検査するので、箱に入っていない値がレジスタに残ることはありません。

`fsgnj.s` の類はビット演算なので、`box_f32_bits` で 32 ビットのまま箱に入れ直します。
値として解釈しないほうが、`-0.0` の符号や NaN のペイロードを壊さずに済みます。

## 3. 正規形の NaN

x86 は `NaN + 1.0` で入力の NaN のペイロードを持ち帰ります。RISC-V は**演算の結果として
生じる NaN を必ず正規形にする**と決めています。単精度は `0x7fc00000`、倍精度は
`0x7ff8000000000000` です。

出口で1回通すだけで済みます。

```cpp
inline double canon(double v) {
  return std::isnan(v) ? std::bit_cast<double>(kCanonicalNanF64) : v;
}
...
case Op::FaddD: h.f[in.rd] = from_f64(canon(da + db)); return Stop::None;
```

効いていることは確かめられます。ペイロード `0x42` を持つ NaN に 1.0 を足して、下位バイトを
終了コードにするプログラムです。

```
$ rvemu ./nanprop; echo $?      # 0 なら正規形、66 ならペイロードが残っている
0
$ qemu-riscv64 ./nanprop; echo $?
0
```

`canon` を外すと、この値は 66 になります。

## 4. `fmin` / `fmax` と符号注入 — 整数で書く

RISC-V の `fmin` / `fmax` は、ホストの `minsd` / `maxsd` とも C++ の `std::min` とも違う
規則を持っています。

- 片方だけが NaN なら、**NaN でないほうを返す**
- 両方 NaN なら正規形の NaN
- シグナル型 NaN が入っていたら NV を上げる（結果は上の規則のまま）
- `-0.0 < +0.0` として順序づける

そのまま書きます。

```cpp
template <class F>
F fminmax(F x, F y, bool want_max) {
  if (is_snan(x) || is_snan(y)) hart.raise(FFlagNV);
  if (std::isnan(x) && std::isnan(y)) return canon(x);
  if (std::isnan(x)) return canon(y);
  if (std::isnan(y)) return canon(x);
  if (x == F{0} && y == F{0}) {
    const bool xneg = std::signbit(x);
    return (want_max ? (xneg ? y : x) : (xneg ? x : y));
  }
  return want_max ? std::max(x, y) : std::min(x, y);
}
```

```
$ rvemu ./minmax; echo $?       # fmin.d(NaN, -2.0)、0 なら -2.0 が返っている
0
$ qemu-riscv64 ./minmax; echo $?
0
```

`fsgnj` / `fsgnjn` / `fsgnjx` は値ではなくビットの操作として定義されているので、そもそも
浮動小数点演算にしません。フラグも立ちません。

```cpp
case Op::FsgnjD: h.f[in.rd] = (fa & ~(u64{1} << 63)) | (fb & (u64{1} << 63));
```

比較（`feq` / `flt` / `fle`）は NV の上げ方が違います。**`feq` は静かな比較**でシグナル型
NaN のときだけ NV を上げ、`flt` と `fle` はどんな NaN でも上げます。順序が付かないときの
結果はどれも 0 です。

## 5. `fcvt` — 飽和と、その前の範囲検査

C++ で範囲外の浮動小数点を整数にキャストすると未定義動作です。RISC-V は飽和すると決めて
いるので、**キャストの前に必ず範囲を見ます**。

```cpp
template <class I, class F>
I to_int(F v, u8 rm) {
  if (std::isnan(v)) { hart.raise(FFlagNV); return std::numeric_limits<I>::max(); }
  const F r = round_to_integral(v, rm);
  const F hi_bound = std::ldexp(F{1}, sgn ? (sizeof(I) * 8 - 1) : (sizeof(I) * 8));
  const F lo_bound = sgn ? -hi_bound : F{0};
  if (r >= hi_bound) { hart.raise(FFlagNV); return std::numeric_limits<I>::max(); }
  if (r < lo_bound)  { hart.raise(FFlagNV); return std::numeric_limits<I>::min(); }
  if (r != v) hart.raise(FFlagNX);
  return static_cast<I>(r);
}
```

境界は `2^31` `2^32` `2^63` `2^64` で、どれも binary32 でも binary64 でも**厳密に表現
できます**。だから `>=` と `<` の比較に誤差が入りません。

NaN のときの答えが符号の有無で変わることに注意が要ります。`fcvt.w.s` は `INT32_MAX`、
`fcvt.wu.s` は `2^32 - 1` です。どちらも 64 ビットレジスタには符号拡張して書くので、
後者は `0xffffffffffffffff` になります。

**NV が立ったときは NX を立てません。** 上のコードで範囲外の分岐が先に return しているのは
そのためです。

[テスト](../tests/test_rvemu.cpp)がこの3つを固定しています。

```
NaN     -> INT32_MAX, fflags = NV
1e18    -> fcvt.w.d は INT32_MAX + NV、fcvt.l.d は 1000000000000000000 でフラグなし
1.0/0.0 -> +inf, fflags = DZ
```

## 6. 丸めモードと fflags — ホストの制御語に乗せる

丸めモードと累積例外フラグは、ホストの FPU の制御語・状態語をそのまま使います。1命令の
あいだだけモードを差し替え、出るときにホストが上げた例外を `fcsr` に畳み込みます。

```cpp
class FpGuard {
  FpGuard(Hart& h, u8 rm) : hart_(h), saved_(std::fegetround()) {
    std::feclearexcept(FE_ALL_EXCEPT);
    std::fesetround(host_round(rm));
  }
  ~FpGuard() {
    const int raised = std::fetestexcept(FE_ALL_EXCEPT);
    u32 flags = 0;
    if (raised & FE_INEXACT)   flags |= FFlagNX;
    if (raised & FE_UNDERFLOW) flags |= FFlagUF;
    ...
    hart_.raise(flags);
    std::fesetround(saved_);
    std::feclearexcept(FE_ALL_EXCEPT);
  }
};
```

5つのフラグは1対1で対応します。アンダーフローの定義（「丸めたあとに小さすぎ、かつ不正確」）
まで x86 と RISC-V で一致しているので、読み替えは要りません。

命令の `rm` 欄が `dyn`（7）なら `fcsr` の `frm` を使い、8 以上の予約値なら
**演算する前に `Illegal`** にします。オペランドを見るより先です。

```cpp
const u8 rm = h.effective_rm(in.rm);
if (!need_rm()) return illegal(in);
FpGuard guard(h, rm);
```

ビルドには `-ffp-contract=off -fno-fast-math` を付けています。コンパイラが勝手に融合積和に
まとめたり、既定の丸め環境を仮定したりすると、この仕組みが黙って壊れるからです。

## 7. RMM — 借りられなかったもの

RMM（最近接、同点なら 0 から遠いほう）に対応する丸めモードが x86 にありません。
`FE_TONEAREST` は同点を偶数側に丸めます。

**変換命令は自前で丸めるので、RMM も厳密です。**

```cpp
template <class F>
F round_to_integral(F v, u8 rm) {
  switch (rm) {
    case RmRTZ: return std::trunc(v);
    case RmRDN: return std::floor(v);
    case RmRUP: return std::ceil(v);
    case RmRMM: return std::round(v);   // 定義からして同点は0から遠いほう
    default:    return std::nearbyint(v);
  }
}
```

**算術命令は RNE に落ちます。** ここだけは埋めていません。値段は測れます —— 同点になる
加算を1つ書いて、`qemu-riscv64` と突き合わせたものです。

```
$ cat rmm_arith.s
        li      t0, 4                   # frm = RMM
        csrw    frm, t0
        li      t1, 0x3ff0000000000000  # 1.0
        fmv.d.x ft0, t1
        li      t2, 0x3ca0000000000000  # 2^-53、ちょうど半 ulp
        fmv.d.x ft1, t2
        fadd.d  ft2, ft0, ft1           # 同点。RNE -> 1.0、RMM -> 1.0+ulp
        fmv.x.d a0, ft2
        andi    a0, a0, 0xff

$ rvemu ./rmm_arith;       echo $?    # 0 = RNE で丸めた
0
$ qemu-riscv64 ./rmm_arith; echo $?    # 1 = RMM で丸めた
1
```

変換のほうは一致します。

```
$ rvemu ./rmm_cvt;         echo $?    # fcvt.l.d 2.5, rmm
3
$ qemu-riscv64 ./rmm_cvt;  echo $?
3
```

埋めるには、同点になる場合を検出して自分で1 ulp 動かすか、soft-float を持ってくることに
なります。**RMM を明示的に指定する算術命令を吐くコンパイラを見たことがない**ので、
今は開けたままにして、ここに書いておくほうを選んでいます。

## していないこと

**例外を実際に発生させることはしません。** RISC-V のユーザモードでは浮動小数点例外は
トラップせず `fflags` に溜まるだけなので、これは仕様どおりです。

**Zfh（半精度）と Q（4倍精度）はありません。** `fp_op` が `fmt > 1` を `Illegal` にします。

## 参考文献

- [The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA][isa] §11–12。
  NaN boxing（§11.3）、正規形 NaN（§11.4）、`fmin`/`fmax`（§11.6）、変換の範囲
  （§11.7 の表）がこの章の元です。
- [IEEE 754-2019][ieee]。アンダーフローの検出時期（丸めのあと）の定義。

[isa]: https://riscv.org/technical/specifications/
[ieee]: https://standards.ieee.org/ieee/754/6210/

## 実装の地図

| | |
|---|---|
| `cpu.cppm` 55–82行 | `FFlag` / `RoundMode` / `Csr` |
| `cpu.cppm` 121–166行 | NaN boxing、`canon`、`is_snan`、`fclass_bits` |
| `cpu.cppm` 168–202行 | `FpGuard` — 丸めモードとフラグの出し入れ |
| `cpu.cppm` 208–217行 | `round_to_integral` — RMM が厳密なのはここ |
| `exec.cppm` 396–420行 | `to_int` — 範囲検査と飽和 |
| `exec.cppm` 422–441行 | `fminmax` / `fcompare` |
| `exec.cppm` 443–556行 | `fp` — F/D の switch。前半はフラグを立てない命令 |

---

[← 3. インタプリタ](exec.md) ／ [目次](index.md) ／ [5. プロセスの起動 →](process.md)
