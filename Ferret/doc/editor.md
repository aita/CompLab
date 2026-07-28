# 5. エディタと橋渡し

キャンバスは React Flow、コンパイラは OCaml。この章は、その2つがどうつながっていて、
ノードを1種類足すのに何を書くのかの話です。

## 同じコンパイラを2通りにビルドする

`compiler/lib` は1つのライブラリで、そこから2つの実行形が出ます。

```
compiler/bin/ferretc.ml   → コマンドラインの ferretc
compiler/web/ferret_js.ml → js_of_ocaml で1本の .js に
```

ブラウザ側は `public/ferret.js` を素の `<script>` タグで読みます（Vite に巨大な
バンドルを解析させないため）。橋渡しは `globalThis.ferret.compile(json)` 1つだけです。

```ocaml
let () =
  let api = obj [| ("compile", inject (Js.wrap_callback compile)) |] in
  (* [Js.export] alone lands on module.exports under node; the editor loads
     the bundle with a plain script tag and wants it on the global. *)
  Js.export "ferret" api;
  Js.Unsafe.set Js.Unsafe.global (Js.string "ferret") api
```

返すのは、CLI が書き出すのと同じもの — wasm のバイト列、wat、IR、ブレークポイントの
表 — です。バイト列は素の数値配列で渡し、TypeScript 側で `Uint8Array` に
します。

```
$ npm run compiler   # dune build --profile release + public/ へコピー
```

リリースビルドで 190 KB です。

## ノードの定義はコンパイラ側にある

ノードについて知るべきことは、`compiler/lib/spec.ml` の1エントリに全部あります。
**エディタ側に写しはありません。**

```ocaml
{
  blank with
  kind = "counter";
  title = "Counter";
  glyph = "i";
  color = "#06aed4";
  category = "Flow";
  hint = "The only node that holds anything. …";
  exec_in = true;
  exec_out = next;
  inputs = [ num "from" "starts at"; num "by" "moves by" ];
  outputs = [ num "value" "value" ];
  data = [ ("name", `String "i"); ("mode", `String "by"); … ];
  fields =
    [ Text { key = "name"; label = "Name" };
      Select { key = "mode"; label = "Each pass it"; options = … } ];
}
```

**ポート id は飾りではありません。** `lower.ml` が `sourceHandle` /
`targetHandle` から読むのがこの文字列で、カードに描かれるのも同じ値です。同じ
ファイルの中にあるので、片方だけ直して食い違う、ということが起こりません。

実行の**入力**ポートだけは、何本でも受け取ります。ループを閉じるのがそれだから
です。値の入力と実行の出力は1本きりで、新しい線を落とすと差し替わります。

ノードを1種類足すのに要るのは、ここに1エントリと、隣の `lower.ml` に1ケース。
エディタには何も足しません。

橋渡しは2本です。

```ocaml
let specs () = Js.string (Yojson.Safe.to_string (Ferret.Spec.to_json ()))

let describe kind data = … (* その設定のときのタイトル・記号・ポート *)
```

コマンドラインからも同じものが出ます。カタログはテストで固定してあります。

```
$ ferretc --emit spec | head -3
{
  "categories": [ "Flow", "Operators", "Values" ],
  "nodes": [
```

### ポートが設定で変わるノード

`Start` の出力は宣言された入力の数だけあり、`Logic` の入力は `not` のときだけ1本です。そして
`Expression` のポートは、**打ち込まれたテキスト次第**です。

だからカタログとは別に、1ノードぶんを答える口があります。

```
$ ferret.describe("expr", '{"text":"a > b && a < 10"}')
{"title":"Expression","glyph":"()","badge":null,
 "inputs":[{"id":"a",…},{"id":"b",…}],
 "outputs":[{"id":"out","label":"result","kind":"bool"}]}
```

以前はここにエディタ側の判定がありました。「呼び出しの頭でない名前を拾う」正規表現と、
「括弧の外に比較があれば bool」という近似です。いまは**同じレキサとパーサが答えます。**
出力が条件かどうかは木の頂点を見るだけなので、近似ではなくなりました。

半端に打ちかけのテキストでもポートは出ます。名前はパースではなくトークン列から
読むので、`a * b + ` の途中でも `a` と `b` は残ります。

```ocaml
(* The same names, read off the tokens rather than off the parse.  The editor
   asks for these to know which ports to draw, and it asks on every keystroke:
   a formula that is halfway typed has no tree yet but does have ports. *)
let free_names (text : string) : string list = …
```

カードは描画のたびにこれを聞きますが、答えは記憶します。鍵は種類と設定なので、
**同じ設定なら同じ答え**で、設定が変わるのは編集したときだけです。実測では、
6ノードの triangle を開いて5回、ノードをドラッグして0回、8文字打って8回でした。

### 1エントリが n 個の項目になる

`Arithmetic` ノードを置いてから `×` に設定する、という手順は1つ多い。パレットに
並ぶべきなのは演算のほうです。そこでエントリに「この1ノードが代表している演算子」を
持たせました。

```ocaml
variants = Some ("op", arith);
```

パレットは族の名前を見出しにして、その下に演算子を並べます。押すと `data.op` が
決まった状態でノードが生まれるので、**カードは最初から `Multiply` を名乗ります。**

ノードの種類が増えたわけではありません。`binop` は1種類のままで、`lower.ml` にも
エディタにも分岐は増えていません。増えたのは**パレットの項目**だけです。同じ表から
インスペクタのドロップダウンも作られているので、並びと名前がずれることもありません。

## 編集のたびにコンパイルする

```ts
// Compiling on every edit is what makes the errors feel like a linter; the
// whole pipeline is well under a millisecond for graphs this size.
const compiled: CompileResult = useMemo(() => compile(graph), [graph]);
```

エラーはノード id を持っているので、Map に畳んで context 経由でカードに配ります。
該当ノードが赤枠になり、メッセージがカードの下に出ます。

## 走らせる

生成したモジュールは Web Worker で instantiate します。UI スレッドではありません。
戻り線1本で止まらないループが書けてしまうので、3秒で terminate できる場所に置く
必要があります。ブレークポイントで止める仕組みも同じワーカーの上です
（[4章](debug.md)）。

ホストが渡すインポートは5本です。**引数はありません** — グラフは何も受け取らず、
必要なら Start から時刻を、`Wait for Event` からイベントを貰います。

```ts
env: {
  log: (x) => …,
  random: () => Math.random(),
  watch: (watch, value) => { … return value; },
  now: () => Date.now(),
  wait: () => { … Atomics.wait(flags, AT_EVENT, RUNNING); return payload[0]; },
}
```

`wait` の中でワーカーは止まります。ページは共有バッファに数を書いて `notify` する
だけです。**待っているのはハングではない**ので、3秒の時計もそのあいだ止めます。

## エッジの描き方

Unreal Engine の Blueprint と同じく、**水平に出て水平に入るベジエ**です。直角
ルーティングも試しましたが、平行な経路が重なって1本に見えるうえ、カードの枠線に
乗った線が枠の一部に見えました。曲線のほうが追えます。

Blueprint が読みやすい理由の半分は曲線ではなく**縁取り**にあります。同じ経路を2度
描き、1本目をキャンバスの色で太く描くことで、交差したところに隙間ができます。手前の
線が途切れずに読めるのはこれのおかげです。

```tsx
<g className={"wire" + (faded ? " is-faded" : "")}>
  <path className="wire-casing" d={path} strokeWidth={exec ? 8 : 6} />
  <BaseEdge id={id} path={path} markerEnd={markerEnd}
            style={{ stroke: color, strokeWidth: exec ? 2.5 : 2 }} />
</g>
```

戻る線は別の経路を取ります。ノードが横に並んでいると、戻り線は**ノードが乗っている
その線の上**を通ることになり、行を貫く1本の直線になります。ループがいちばん
見えてはいけない形です。そこで、右へ出て、自分の高さまで上がって越え、左から入る、
という経路にしています。両端は変わらず水平に出入りするので、1本の筆致に見えます。

高さが違う戻り線は普通の曲線のままです。すでに曲線として読めているものを上へ
回すと、関係するノードから遠ざかるだけなので。

矢印は実行エッジにだけ付けます。値の向きは、カードのどちら側から出ているかで既に
分かるからです（これも Blueprint と同じ）。

ノードを選ぶと、触れていないエッジが薄くなります。ループの帰り線を目で追うには
これが一番効きます。

実行ポートはカード上端の帯にまとめてあります。実行の筋がカードの上辺を通る1本の
レーンになり、値の配線と高さで分離されます。

## ファイル

File メニューの New / Open / Save は、`{ name, nodes, edges }` を読み書きします。
**これは `ferretc` がそのまま受け取る形式**なので、エディタで描いたものを変換なしで
コマンドラインからコンパイルできます。

```
$ ferretc my-flow.json -o my-flow.wasm
```

編集中のものは localStorage に入ります。読み戻すときは、知らないノード型が入って
いないかを確かめてから使います。古いノードセットで保存されたグラフを、理解できない
グラフとして復元しないためです。

```ts
function readable(doc: unknown): doc is Doc {
  const d = doc as Doc;
  return (
    !!d &&
    Array.isArray(d.nodes) &&
    Array.isArray(d.edges) &&
    d.nodes.every((n) => !!n.type && n.type in SPEC_BY_TYPE)
  );
}
```

## サンプル

`examples/*.json` は、エディタと CLI が**同じファイル**を読みます。エディタ側は Vite の
JSON import でそのまま取り込むので、コピーもコード生成もありません。

| | ノード | エッジ | 何を見せるか |
|---|---|---|---|
| Sum of 1 to n | 6 | 9 | Condition の戻り線と、積み上げる Counter |
| Collatz steps | 13 | 19 | State、Choose、`%`、ログ |
| π by throwing darts | 16 | 21 | Random と、1回の抽選を2回読むこと |
| Multiplication triangle | 6 | 8 | For Loop の入れ子と、`r * c` の Expression |
| Row sums | 7 | 11 | State の reset と in、2本の通り道 |
| Echo events | 7 | 10 | Wait for Event を Condition の輪に入れたイベントループ |
