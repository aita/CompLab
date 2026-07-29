# 0010. 組み込みは OCaml、拡張はパッケージで配るマニフェスト

状態: 採用

## 背景

Bun サーバ側の拡張（[0008](0008-external-apis.md) の HTTP など）と、デバイス側の
I/O（[0005](0005-firmware.md) の `io.gpio_write` など）を、`spec.ml` を
書き換えずに足せるようにしたい。spec は JS/TS で書け、VS Code の拡張のように
パッケージで入れられるとよい。サーバ側のものは処理の中身もそこに書きたい。

`spec.ml` の存在理由は「ポート id を宣言するコードと、`sourceHandle` からそれを
読み出すコードが同じ場所にある」ことである（README）。拡張機構はこの性質を
壊してはならない。

## 決定

**拡張ノードは新しい IR の形を追加できない。既存の形に束縛されるだけである。**

これが機構全体を成り立たせている不変条件である。拡張ノードは例外なく**境界の
ノード**で、次の3つの `shape` しか取らない。

| shape | 落ち先 | 例 |
|---|---|---|
| `read` | 値を生む import 呼び出し | `gpio_read`、`adc_read` |
| `write` | sink としての import 呼び出し | `gpio_write`、`pwm_write`、`Publish` |
| `channel` | ホストが書くグローバルの読み出し | `Subscribe`、`Fetch` |

[0008](0008-external-apis.md) の外部 API も [0005](0005-firmware.md) の
デバイス I/O も、すべてこの2つに収まる。拡張が任意のコードを吐けてしまうと、
型検査も [0005](0005-firmware.md) の WCET も
[0004](0004-backends.md) の差分テストも同時に壊れる。

**交換形式は既にある。** `Spec.to_json ()` が吐き、`ferretc --emit spec` が印字し、
`compiler/test/spec.json.expected` が pin し、エディタが `ferret.specs()` で
消費しているカタログ JSON がそれである。**拡張機構とは、この JSON にエントリを
足すことである。** エディタ側の改修は要らない。

**TS は記述の言語、JSON は交換の形式とする。** 拡張は TS モジュールとして
マニフェストを export し、ビルド段階で JSON に落ちる。コンパイラが読むのは JSON
だけなので、**`ferretc`（ネイティブ）に JS エンジンが要らない**。

**設定に依存するポートは宣言的な規則で書く。** 組み込みは任意の計算ができる
（Expression ノードは打ち込まれた式を実際に構文解析してポートを決める）が、拡張は
次の2つで足りる。

- **repeat** — 設定中のリストの要素ごとに1本。[0008](0008-external-apis.md) の
  `Fetch` は JMESPath の一覧から出力ポートが生えるので、これに当たる
- **variant** — 列挙型の設定値ごとに別のポート集合。組み込みの Logic ノードが
  `not` のとき片側だけ取るのと同じ形

**実装を持てるかどうかは、そのマシンのホストが何かで決まる。** マニフェストが
import の名前と引数を宣言するところまでは共通だが、**ホストが TS であるマシン
（Bun・browser）ではパッケージが実装ごと持てる**。ファームウェアではそうは
いかない。この非対称が配り方を決める（後述）。

**拡張は npm のパッケージとして配る。** VS Code の拡張と同じで、エディタを作り
直さずに入れたり外したりできる。

## 理由

組み込みを OCaml に残すのは、Expression ノードのように**ポートを決めるのに本物の
構文解析が要る**ものがあり、それらが型体系の中核であり、拡張機構なしで
`ferretc` が動く必要があるからである。

拡張を宣言的にするのは、コンパイラに JS エンジンを持ち込まないためである。
コンパイラは js_of_ocaml でブラウザと Bun の上では JS として動くが
（[0006](0006-server-bun.md)）、`ferretc` はネイティブバイナリで `dune test` が
それを使う。マニフェストを JSON に落としておけば3つとも同じものを読む。

## マニフェストの形

```ts
import { defineExtension, port, setting, num, bool, repeat, fromTarget }
  from "@ferret/extension"

export default defineExtension({
  name: "pico-io",

  // このノードを置けるマシン。[0002] の target 名。
  // ここに無い target のマシンに置いたらコンパイルエラーになり、
  // パレットにも出ない。
  machines: ["pico", "pico-sdk", "browser"],

  // ホストが供給しなければならない関数。バックエンドが wasm なら import、
  // C なら extern 宣言になる（[0005] が「import テーブルは全バックエンドで
  // 同一」と定めている）。型は Ferret の型で書く——i32 や f64 とは書かない。
  // 数値幅は target が決めるので、バックエンドが選ぶ。
  imports: {
    "io.gpio_read":  { args: ["num"],        result: "bool" },
    "io.gpio_write": { args: ["num", "bool"] },
    "io.adc_read":   { args: ["num"],        result: "num", cost: 96 },
    "io.pwm_write":  { args: ["num", "num"] },
  },

  nodes: {
    pin_read: {
      title: "Read Pin",
      glyph: "▲",
      color: "#0e9f6e",
      category: "Device",
      hint: "what a pin is reading, asked once per cook",

      // インスペクタが出す設定。選択肢はマシンのボード記述から来る
      fields: [
        { key: "pin", label: "Pin", kind: "select", options: fromTarget("pins") },
      ],
      data: { pin: "GP15" },          // 既定の設定

      outputs: [bool("value", "is on")],

      // 値を生む import 呼び出し。args はホスト関数の引数を順に並べたもので、
      // 設定から来るもの（コンパイル時の定数）と入力ポートから来るもの
      // （データフローの値）を混ぜられる。
      lower: { shape: "read", call: "io.gpio_read", args: [setting("pin")] },
    },

    pin_write: {
      title: "Write Pin",
      glyph: "▼",
      color: "#0e9f6e",
      category: "Device",
      hint: "drive a pin every cook",

      fields: [
        { key: "pin", label: "Pin", kind: "select", options: fromTarget("pins") },
      ],
      data: { pin: "GP25" },
      inputs: [bool("value", "on")],

      lower: {
        shape: "write",                             // sink
        call: "io.gpio_write",
        args: [setting("pin"), port("value")],
      },
    },
  },
})

// ホストが TS であるマシンでだけ呼ばれる。このパッケージにとってそれは
// browser だけなので、**これは実機の代わりに動くシミュレータである**。
export const host = {
  "io.gpio_read":  (pin: number) => pins[pin] ?? 0,
  "io.gpio_write": (pin: number, on: number) => { pins[pin] = on },
}
```

実機では同じインタフェースをファームウェアが用意する。名前は機械的に対応する。

```c
int32_t io_gpio_read(int32_t pin);
void    io_gpio_write(int32_t pin, int32_t on);
```

サーバ向けのパッケージは事情が違う。ホストが Bun なので、**宣言と実装が同じ
パッケージに入り、それがそのまま本番で動く**。

```ts
export default defineExtension({
  name: "http",
  machines: ["bun", "browser"],
  imports: { "http.poll": { args: ["num"], result: "num" } },
  nodes: {
    fetch: {
      title: "Fetch",
      fields: [
        { key: "url",   label: "URL",       kind: "text" },
        { key: "every", label: "Every (s)", kind: "number" },
        { key: "paths", label: "Values",    kind: "list" },
      ],
      outputs: repeat("paths", { id: "@name", label: "@name", kind: "@type" }),
      lower: { shape: "channel", transport: "http.poll" },
    },
  },
})

// 実装。ポーリングの周期は cook レートから独立している（[0007]）ので、
// 値を取りに行くのはここであって、グラフの側ではない。
export const host = {
  transports: {
    "http.poll": (node, emit) =>
      setInterval(async () => {
        const doc = await fetch(node.url).then(r => r.json())
        for (const p of node.paths) emit(p.name, jmespath(doc, p.path))
      }, node.every * 1000),
  },
}
```

**ピンは設定であってポートではない。** インスペクタで選んだ値がコンパイル時に
import 呼び出しの引数に焼き込まれる。`args` が設定と入力ポートを順に混ぜられる
ことが、この機構の要である。

### `shape` について2つ

`read` は **1 cook に1回に畳まれる**。ホストに訊いたものはその答えそのものなので、
読み手が何本あっても、式が同じ名前を2回書いても、1回しか訊かない。README が
Random と Time について定めている規則と同じである。

`channel` は初期値を持ち、`age` と `epoch` の補助出力が自動で付く
（[0002](0002-machines.md)）。マニフェストで書く必要はない。

### 設定で変わるポート

```ts
// repeat — 設定中のリストの要素ごとに1本。@name は行の name 欄を指す。
// [0007] の Fetch がこれで、JMESPath の一覧から出力ポートが生える。
outputs: repeat("paths", { id: "@name", label: "@name", kind: "@type" }),

// variant — 列挙型の設定値ごとに別のポート集合。
inputs: variant("op", {
  not: [bool("a", "value")],
  and: [bool("a", "a"), bool("b", "b")],
}),
```

**どちらもデータであって関数ではない。** JSON に落ちるので、コンパイラは JS を
評価せずにポートを決められる。組み込みの Expression ノードのように本物の構文解析が
要るものは `spec.ml` に残る。

### 拡張が言えないこと

- **sink の順序。** 複数の `write` がどの順で呼ばれるかは lowering の順であって、
  マニフェストからは指定できない。順序に意味がある機器は、1つのノードで
  まとめて書くようにする
- **費用。** `cost` は WCET のための任意の申告である（[0005](0005-firmware.md)）。
  書かなければ「N 命令 + ホスト呼び出し M 回」と分けて報告されるだけで、
  嘘を書けば WCET が嘘になる

## パッケージ

```
package.json    名前と版
ferret.json     マニフェスト（TS から生成された JSON）
host/           マシンのホストが TS のときに読まれる実装
```

パッケージが提供できるものは4つ。

| | 例 |
|---|---|
| ノード | `Read Pin`、`Fetch` |
| ボード記述 | Pico のピン一覧。`fromTarget("pins")` がこれを読む |
| トランスポート | MQTT、HTTP ポーリング（[0002](0002-machines.md)） |
| マシンの target | 新しいボードへの対応（[0004](0004-backends.md)） |

### サーバ向けとデバイス向けは別のパッケージにする

**この2つは対称ではない。**

| | サーバ / browser | デバイス |
|---|---|---|
| ホスト | Bun・ブラウザ = **TS が動く** | ファームウェア |
| パッケージが持てるもの | 宣言 **と実装** | **宣言だけ** |
| 入れるのに要ること | インストールするだけ | **ファームウェアの焼き直し** |

デバイス向けのパッケージは「このファームウェアはこの import を持っている」という
宣言でしかない。実体は焼いた時点で決まっている（[0005](0005-firmware.md)）。
このADRが下で書く「グラフはホットスワップでき、能力はできない」がこれである。

**だから混ぜない。** 1つのパッケージに両方入れると、インストールで済むものと
焼き直しが要るものが同居して、入れた人に何が起きるか分からなくなる。

なおデバイス向けパッケージの `host/` は無駄にならない。**ホストが TS であるマシン
＝ browser でだけ呼ばれるので、それは実機の代わりに動くシミュレータになる。**
[0005](0005-firmware.md) の実装順序が最初に置いたブラウザ上のシミュレーションが、
これで手に入る。

### 読み込みと依存

マニフェストは JSON なので、**コンパイラは実行時に受け取れる。**
`Compile.of_json` が拡張カタログを引数に取り、`ferret.specs()` は組み込みと
インストール済みパッケージを合わせて返す。エディタは今までどおりカタログを描く
だけで、改修は要らない。

**グラフは要求するパッケージと版を記録する。** 入っていないパッケージのノードを
参照するグラフはコンパイルできない。[0009](0009-wire-formats.md) のマニフェストの
ハッシュにも含める——マシンごとに入っているパッケージが違えば、それは検出される
べき食い違いである。

### 信頼

**サーバ向けパッケージの TS は、ゲートウェイのプロセスの中で、ネットワークに手が
届く状態で動く。** npm の依存に置くのと同じ信頼を置くことになる。

サンドボックスは置かない。置くなら実装を wasm にする話になるが、それは
[0007](0007-runtime-library.md) が扱う純粋な計算の話であって、I/O をする
トランスポートには適用できない。**何を入れるかを選ぶのは人間の責任である。**

## 拡張が担うものではないもの

**純粋な計算の再利用は拡張ではなくサブグラフである。** PID もデバウンスも
ヒステリシスも、境界のノードではなく既存のノードの組み合わせなので、
[0011](0011-subgraphs.md) で解くべきものである。拡張は**外の世界に触るところ**だけを
担う。

## 結果

- **型検査は OCaml に残る。** マニフェストはポートの型を宣言し、`lower.ml` が
  組み込みと同じように検査する。拡張が自分で型検査をすることはない
- **どのマシンに置けるかはマニフェストの項目になる。**
  [0008](0008-external-apis.md) が「HTTP ノードはターゲットが許可したマシンでのみ
  合法」と決めたのは、この項目として実現される。パレットもこれを読む
- **デバイスの拡張はファームウェアの焼き直しを要する。** ファームウェアの import
  テーブルは焼いた時点で固定されるので、[0005](0005-firmware.md) の
  「グラフは通信で差し替える」は保たれるが、**使える I/O ノードの集合は差し替え
  られない**。グラフはホットスワップでき、能力はできない
- **WCET が2つに割れる。** [0005](0005-firmware.md) の静的な最悪実行時間は
  グラフ自身の命令数について言えるが、拡張の import 呼び出しの費用は分からない。
  「N 命令 + ホスト呼び出し M 回」と分けて報告する。グラフの側は依然として静的で
  ある
- **グラフはどの拡張を要るか記録する必要がある。** 入っていない拡張のノードを
  参照するグラフはコンパイルできない
- エディタは既にカタログから描いているので、改修は要らない

## 採らなかった案

**拡張の `describe` を JS の関数として持ち、コンパイラから呼ぶ。** ポートを決める
のに任意の計算が使えるようになるが、コンパイラが JS エンジンを抱えることになり、
`ferretc` が拡張を扱えなくなる。repeat と variant で実際の必要は満たせる。

**組み込みも同じマニフェスト形式にして OCaml から追い出す。** 機構が1つになるのは
魅力だが、Expression ノードの後ろに式の構文解析器を置く必要があり、宣言的な形式で
それは表せない。カタログ**の JSON 形式**は既に1つなので、生産者が2つあるだけで
形式が2つあるわけではない。

**デバイス拡張の実装も JS/TS で書けるようにする。** Pico のホストは
ファームウェアであって JS エンジンではない（Node-RED MCU Edition は XS という
JS エンジンを載せる道を採っているが、[0005](0005-firmware.md) は wasm を
解釈する道を選んだ）。spec は TS で書けても、I/O の実装はその場の言語になる。
**純粋な計算だけは例外で、Rust のランタイムライブラリとしてモジュールにリンクされる**
（[0007](0007-runtime-library.md)）。
