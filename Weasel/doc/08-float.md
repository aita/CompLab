# 8. 浮動小数点 — ホストの標準ライブラリが使えないところ

wasm は浮動小数点を**ビット単位で**決めています。IEEE 754 に従う、というだけでなく、
NaN の扱いも、`min` と `max` の細部も、整数への変換が失敗する境界も、全部仕様に
書いてあります。

その結果、ホストの `<cmath>` をそのまま呼べる命令と、呼べない命令に分かれます。
この章はその境目の話です。

## 8.1 呼べるもの

四則演算と `sqrt` は、C++ の演算子と `std::sqrt` そのままです。IEEE 754 の
基本演算はどちらも同じものを指しているので、違いようがありません。

```cpp
WEASEL_FBIN(F32Add, f32, pop_f32, Value::of_f32, a + b)
WEASEL_FBIN(F64Div, f64, pop_f64, Value::of_f64, a / b)
WEASEL_FUN(F32Sqrt, f32, pop_f32, Value::of_f32, std::sqrt(a))
```
（`exec.cppm:786`）

`ceil` `floor` `trunc` も同じ。`nearest` だけ少し注意が要ります。

```cpp
WEASEL_FUN(F32Nearest, f32, pop_f32, Value::of_f32, std::nearbyint(a))
```

wasm の `nearest` は**偶数への丸め**（roundTiesToEven）です。C の `round` は
「0から遠いほうへ」なので使えません。`nearbyint` は現在の丸めモードに従い、
その既定が roundTiesToEven なので、これで合います。

Weasel は丸めモードを一度も変えません。ビルドも `-ffp-contract=off -fno-fast-math`
です（`CMakeLists.txt`）。融合積和も、結合則の入れ替えも、`0 * x == 0` の仮定も、
すべて仕様違反になるからです。

```
$ weasel run tests/wat/03-float.wat --invoke nearest --arg 0.5
0 (0x0000000000000000)
$ weasel run tests/wat/03-float.wat --invoke nearest --arg 1.5
2 (0x4000000000000000)
$ weasel run tests/wat/03-float.wat --invoke nearest --arg 2.5
2 (0x4000000000000000)
$ weasel run tests/wat/03-float.wat --invoke nearest --arg -0.5
-0 (0x8000000000000000)
```

1.5 も 2.5 も 2 になります。そして -0.5 は **-0** です。符号は保たれる。

## 8.2 呼べないもの1 — `min` と `max`

C の `fmin` は「片方が NaN なら他方を返す」。wasm の `f32.min` は
**片方が NaN なら NaN**。逆です。

さらに、`fmin(-0.0, 0.0)` は仕様上どちらを返してもよいことになっていますが、
wasm は **-0 を返せ**と決めています。

```cpp
template <typename F>
static F wasm_min(F a, F b) {
  if (std::isnan(a) || std::isnan(b)) return std::numeric_limits<F>::quiet_NaN();
  if (a == b) return std::signbit(a) ? a : b;  // -0 is less than +0
  return a < b ? a : b;
}
```
（`exec.cppm:117`）

`a == b` の枝が -0 と +0 のためだけにあります。IEEE の比較では `-0.0 == 0.0` が真
なので、`a < b` では区別がつきません。符号ビットを直接見るしかない。

```
$ weasel run tests/wat/03-float.wat --invoke min --arg -0.0 --arg 0.0
-0 (0x80000000)
$ weasel run tests/wat/03-float.wat --invoke max --arg -0.0 --arg 0.0
0 (0x00000000)
```

出力にビットパターンが並んでいるのは、**-0 と +0 は印字では区別しにくい**からです。
`format_value` は浮動小数点について値とビットの両方を出します（`dump.cppm:269`）。

## 8.3 呼べないもの2 — `abs` `neg` `copysign`

この3つは算術ではなく**ビット操作**です。指数も仮数も触らず、符号ビットだけを
いじる。だから NaN のペイロードも、シグナリング NaN であることも、変えてはいけない。

```cpp
case Op::F32Abs: push(Value::of_i32(pop_u32() & 0x7fffffffu)); break;
case Op::F32Neg: push(Value::of_i32(pop_u32() ^ 0x80000000u)); break;
case Op::F64Abs: push(Value::of_i64(pop_u64() & 0x7fffffffffffffffull)); break;
case Op::F64Neg: push(Value::of_i64(pop_u64() ^ 0x8000000000000000ull)); break;
```
（`exec.cppm:762`）

`std::fabs` を呼んでも実際には同じ結果になりますが、こう書いておけば
「これはビット操作である」ということがコードに残ります。値を通さないので、
コンパイラが何かを勘違いする余地もありません。

```
$ weasel run tests/wat/03-float.wat --invoke neg --arg 0.0
-0 (0x80000000)
```

## 8.4 呼べないもの3 — 整数への切り捨て

`i32.trunc_f64_s` は、範囲外や NaN で**トラップします**。C++ の
`static_cast<int32_t>(double)` は未定義動作です。だから範囲を先に見るしかない。

問題は、その範囲をどう書くかです。

```cpp
template <typename Int>
bool trunc_checked(f64 x, Int& out) {
  if (std::isnan(x)) { fail(Trap::InvalidConversion); return false; }
  const f64 t = std::trunc(x);
  bool ok;
  if constexpr (std::is_same_v<Int, i32>) ok = t >= -2147483648.0 && t <= 2147483647.0;
  else if constexpr (std::is_same_v<Int, u32>) ok = t >= 0.0 && t <= 4294967295.0;
  else if constexpr (std::is_same_v<Int, i64>) ok = t >= -9223372036854775808.0 && t < 9223372036854775808.0;
  else ok = t >= 0.0 && t < 18446744073709551616.0;
  if (!ok) { fail(Trap::IntegerOverflow); return false; }
  out = static_cast<Int>(t);
  return true;
}
```
（`exec.cppm:134`）

2つ、気をつけるところがあります。

**すべて `double` で比べている。** f32 の入力も `double` に広げてから同じ比較を
通します。f32 → double は情報を失わないので、これは安全で、比較を1組で済ませられます。

**32ビットと64ビットで不等号の向きが違う。** `2147483647.0` は double でちょうど
表せますが、`2^63 - 1` は表せません（一番近い double は `2^63`）。だから64ビットの
ほうは `< 2^63` と書きます。ここを `<= 9223372036854775807.0` と書くと、その定数が
`2^63` に丸められて、`2^63` そのものを通してしまいます。

```
$ weasel run tests/wat/03-float.wat --invoke trunc_s --arg 3.9
3
$ weasel run tests/wat/03-float.wat --invoke trunc_s --arg -3.9
-3
$ weasel run tests/wat/03-float.wat --invoke trunc_s --arg 2147483648.0
weasel: trap: integer overflow
$ weasel run tests/wat/03-float.wat --invoke trunc_s --arg nan
weasel: trap: invalid conversion to integer
```

（`--arg nan` は `std::from_chars` が読んでいます。）

## 8.5 飽和する版

「トラップするのが困る」という声に応えて追加されたのが `i32.trunc_sat_f64_s` の族
です。範囲外は端に、NaN は0に。

```cpp
template <typename Int>
static Int trunc_sat(f64 x) {
  if (std::isnan(x)) return 0;
  const f64 t = std::trunc(x);
  if constexpr (std::is_same_v<Int, i32>) {
    if (t <= -2147483648.0) return std::numeric_limits<i32>::min();
    if (t >= 2147483647.0) return std::numeric_limits<i32>::max();
  }
  ...
  return static_cast<Int>(t);
}
```
（`exec.cppm:157`）

```
$ weasel run tests/wat/03-float.wat --invoke trunc_sat_s --arg 2147483648.0
2147483647
$ weasel run tests/wat/03-float.wat --invoke trunc_sat_s --arg nan
0
```

これが C や Rust の `as` の意味論に合うので、コンパイラは実際にはこちらを使います。
トラップする版は、範囲を保証できるときだけの最適化になりました。

## 8.6 NaN のペイロード

仕様は NaN の**ペイロードを決めていません**。算術の結果が NaN になるとき、
その仮数部のビットは実装が選んでよい（"nondeterministic" と書かれています）。

Weasel は2つの態度を混ぜています。

- 算術（`+` `-` `*` `/` `sqrt` ...）は**ホストに任せる**。x86 でも ARM でも
  IEEE の伝播規則に従うので、ペイロードは入力から受け継がれます。
- `min` と `max` は**正規の quiet NaN を返す**。上の `wasm_min` のとおりです。
  ここでホストに任せるわけにはいかない以上、自分で1つ選ぶしかない。

テストは NaN のペイロードを比較しません。比較するのは「NaN であるかどうか」です。

```wasm
(func (export "is_nan") (param f64) (result i32) (f64.ne (local.get 0) (local.get 0)))
```
```
;;= invoke is_nan nan => 1
```

`x != x` が NaN の定義そのものです。

テキスト形式のほうは、ペイロードを名指しできます — `nan:0x400000`。これは
[2章](02-text.md)で見たとおり、値ではなくビットから組み立てられます。仕様の
テストスイートが NaN の伝播を書くための綴りです。

## 8.7 整数からの変換は素直

こちらは全部キャストで済みます。

```cpp
case Op::F32ConvertI64U: push(Value::of_f32(static_cast<f32>(pop_u64()))); break;
case Op::F64PromoteF32: push(Value::of_f64(static_cast<f64>(pop_f32()))); break;
case Op::F32DemoteF64: push(Value::of_f32(static_cast<f32>(pop_f64()))); break;
```

C++ の浮動小数点への変換は「現在の丸めモードで最も近い値へ」と決まっていて、
それが wasm の要求と同じだからです。

```
$ weasel run tests/wat/03-float.wat --invoke u64_to_f32 --arg -1
1.8446744e+19 (0x5f800000)
```

`--arg -1` は i64 として -1、つまり符号なしでは 18446744073709551615。それを f32 に
すると 2^64 = 1.8446744e19 に丸められます。f32 には仮数が24ビットしかないので、
この大きさでは2^40 刻みになる。

## 8.8 再解釈は何もしない

```cpp
case Op::I32ReinterpretF32: case Op::I64ReinterpretF64:
case Op::F32ReinterpretI32: case Op::F64ReinterpretI64:
  break;
```
（`exec.cppm:860`）

`Value` はもともとビットです（[5章](05-instantiate.md)）。だから再解釈の命令は、
機械の中では**何もしません**。言語には存在し、実装には存在しない命令です。

型がついているのは検証の中だけで、それが済んだあとには何も残らない。この4行が、
この処理系で「実行時に型が無い」ことのいちばん短い証拠です。

```
$ weasel run tests/wat/03-float.wat --invoke reinterpret --arg 1.0
1065353216
```

`1.0f` のビットパターンは `0x3f800000` = 1065353216。

## 8.9 V8 と突き合わせる

この章の主張はどれも「仕様がそう決めている」なので、Weasel がそう振る舞うことを
自分で確かめても意味が半分しかありません。同じ期待値を V8 にも通します。

```
$ node tests/compare-with-v8.mjs
73 checks on V8, 0 failures
```

`tests/wat/03-float.wat` の `;;=` の行が、Weasel と V8 の両方で成り立ちます。
片方だけで通るものがあれば、それはどちらかのバグです。

---

## していないこと

- **SIMD**。`f32x4.add` などの族。値が128ビットになるので、`Value` の定義から
  変わります（[10章](10-next.md)）。
- **NaN の正規化**。算術の NaN ペイロードはホスト任せなので、別の CPU では
  別のビットが出ることがあります。仕様が許しているとおりです。
- **例外フラグ**。IEEE の inexact / overflow などのフラグは、wasm からは見えません。
  読む方法も、設定する方法もないので、この処理系も何もしません。
- **丸めモードの変更**。同じ理由で、wasm からは触れません。

## 参考文献

- **WebAssembly Core Specification**, Section 4.3 "Numerics"。`fmin` と `fmax`、
  `trunc_s` の境界、NaN の非決定性がすべて式で書かれています。
- **IEEE 754-2019**。`minNum` / `maxNum` が2019年版で非推奨になった経緯を見ると、
  wasm がなぜ独自の `min` を定義したかが分かります。
- **The Nontrapping float-to-int conversions proposal**。`trunc_sat` の由来。

## 実装の地図

| 場所 | 何があるか |
|---|---|
| `src/exec.cppm:117` | `wasm_min` / `wasm_max` |
| `src/exec.cppm:134` | `trunc_checked` — double で判定する境界 |
| `src/exec.cppm:157` | `trunc_sat` |
| `src/exec.cppm:762` | `abs` / `neg` — ビット操作 |
| `src/exec.cppm:860` | 再解釈 — 何もしない4行 |
| `src/dump.cppm:269` | `format_value` — 値とビットを両方出す |
| `src/text.cppm:257` | `parse_float` — `nan:0x...` |
| `CMakeLists.txt` | `-ffp-contract=off -fno-fast-math` |

---

[← 7. 線形メモリ](07-memory.md) · [9. ホスト関数と WASI →](09-host.md)
