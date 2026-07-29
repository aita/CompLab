# 0006. サーバは js\_of\_ocaml バンドルを Bun で走らせる

状態: 採用（検証済み）

## 背景

[0002](0002-machines.md) のサーバ側マシンを何の上で走らせるか。制約として
**Windows で楽に動く**ことが求められた。開発は Linux で行い、成果物を Windows で
走らせる。

## 決定

**既存の js\_of\_ocaml バンドル（`editor/public/ferret.js`）を Bun で走らせる。**

```js
import "./ferret.js"                      // js_of_ocaml のバンドル
const out = ferret.compile(graphJson)     // → out.wasm はバイト配列
const { instance } = await WebAssembly.instantiate(
  new Uint8Array(out.wasm), { env: { log, random, watch, now, say } })
```

## 理由

**Windows 上で誰がグラフをコンパイルするのかが決め手になった。**

Go + wazero は .wasm を**走らせる**ことしかできない。`.json` のグラフを .wasm に
するには `ferretc.exe` を Windows に置く必要があり、それは OCaml の Windows
ビルド問題を呼び戻す。**js_of_ocaml なら、サーバがコンパイラを丸ごと持ち歩ける。**
Windows に置くのは .js と Bun だけで、OCaml のツールチェインは Linux の手元に
あれば足りる。

副次的に、サーバがブラウザと**同じバイト列**を走らせる。IR 評価器を書かないので、
「動いているのはコンパイラが吐いたものそのもの」がサーバ側でも保たれる。

さらに、ゲートウェイが `.json` を受け取ってその場でコンパイルし直せるので、
デプロイ済みグラフのホットリロードが追加の仕掛けなしで手に入る。

## 検証

Bun 1.2.20 で実測（2026-07-29）。

- `editor/public/ferret.js` は Bun で import でき、`globalThis.ferret` に
  `compile` / `specs` / `describe` が載る。`ferret_js.ml` が `Js.export` に加えて
  global にも明示的に置いているのがそのまま効く
- `ferret.compile()` を `examples/bounce.json` に適用して **223 バイト**。
  README の表の Bounce と一致
- インスタンスを立てたまま13回 cook して
  `1 2 3 4 5 6 7 8 9 10 9 8 7` — `compiler/test/run_wasm.mjs` が pin している
  数字と同一。`state_*` グローバルも読める
- `bun build --compile --target=bun-windows-x64` が Linux から
  **PE32+ x86-64 の実行ファイル**を生成する。コンパイラごと詰まった単一ファイル
- 起動 **約60ms**（バンドル読み込み + コンパイル + インスタンス化 + 13 cook 込み）

## 結果

- **.exe は 118MB。** Bun ランタイム丸ごとの重さで、Go なら 10〜15MB。この選択の
  唯一の実コストである
- Windows 側にインストールさせるものが無い。ランタイムも VC++ 再頒布可能
  パッケージも Node も不要
- **Bun の弱点は N-API のネイティブアドオンで、`serialport` がまさにそれ。**
  サーバが物理的にデバイスと繋がるマシンだと詰まりうる。デバイスを MQTT に載せ
  （Pico W / Pico 2 W）、開発中の実機接続はブラウザの Web Serial に任せる限り、
  サーバはシリアルに触らない。この前提が崩れたときだけ Go + wazero か
  （FFI 内蔵の）Deno に戻る

## 未解決

**生成した .exe が Windows で実際に起動するかは未検証。** 検証環境に wine が
無く、PE ヘッダが正しいことまでしか確認していない。実機か CI で1回通すこと。

## 採らなかった案

**OCaml ネイティブ。** 言語が1つに揃い、`spec.ml` やチャンネル表を写しではなく
直接共有できるという利点は本物だったが、**それはビルドが楽である場合の利点**で
あった。Linux から Windows へのクロスコンパイルが実質できず（`GOOS=windows`
相当が無い）、現実には Windows の CI ランナーを立てて opam 2.2 のネイティブ
Windows 対応でビルドすることになる。

**Go + wazero。** Windows 向けの単一 .exe は綺麗に出るが、上記の通りコンパイラを
持てない。シリアル接続のゲートウェイが必要になった場合の fallback として残す。

**Node。** ランタイムのインストールが要り、この判断軸のどこにも勝っていない。

**Deno。** 同じアイディアが成立し、Windows 対応は Bun より長く FFI も組み込み
なので安全側ではある。Bun を採ったのは起動の速さと npm 互換の厚さ。
