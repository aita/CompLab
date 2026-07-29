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

リリースビルドで 197 KB です。

## ノードの定義はコンパイラ側にある

パレットに並ぶのは**グループだけ**です。カタログが30項目を越えて一覧には長すぎるので、
グループにポインタを乗せる（かクリックする）と、その中身が横に開きます。選ぶとその
ノードが置かれ、メニューは閉じます。ドラッグでキャンバスに落とすこともできます。

メニューはパレットの外に出るので `position: fixed` で、行の矩形から座標を取ります
（パレットは `overflow-y: auto` なので、中に絶対配置すると切られてしまう）。行から
メニューへポインタを動かすと途中に隙間があるので、閉じるのは140ミリ秒待ってから
です — 移動中に消えないように。

ノードについて知るべきことは、`compiler/lib/spec.ml` の1エントリに全部あります。
**エディタ側に写しはありません。**

```ocaml
{
  blank with
  kind = "feedback";
  title = "Feedback";
  glyph = "↺";
  color = "#15b79e";
  category = "Values";
  hint = "What the last cook left. …";
  outputs = [ num "out" "held" ];
  inputs = [ num "value" "next" ];
  data = [ ("name", `String "held"); ("holds", `String "number");
           ("start", `Int 0) ];
  fields =
    [ Text { key = "name"; label = "Name" };
      Select { key = "holds"; label = "Holds"; options = … };
      Number { key = "start"; label = "Starts at" } ];
}
```

**ポート id は飾りではありません。** `lower.ml` が `sourceHandle` /
`targetHandle` から読むのがこの文字列で、カードに描かれるのも同じ値です。同じ
ファイルの中にあるので、片方だけ直して食い違う、ということが起こりません。

入力ポートは1本きりで、新しい線を落とすと差し替わります。出力は何本でも出せます
— 1つのノードが1度しか計算されないというのが、そもそもそのための規則です。

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
  "categories": [ "Out", "Values", "Operators" ],
  "nodes": [
```

### 線がつながっていない入力は、その場で数を打つ

数値の入力ポートに何もつながっていなければ、そこは数の入力欄になります。カードの上に
小さく出るのに加えて、**インスペクタにも「Inputs」として並べます**。`Expression` の
入力はテキストが自由に残した名前で決まるので、探しに行く先はカードの端の小さな箱では
なくインスペクタだろう、という理由です。どのノードでも同じように出ます。

```tsx
// An input with nothing wired into it is a number to give, and the card's
// own box is small and easy to miss -- an Expression's inputs are named by
// whatever its text left free, so this is where you go looking for them.
const open = shown.inputs.filter(
  (p) => p.kind === "num" && !connected.has(portKey(node.id, p.id)),
);
```

書き込む先はカードの箱と同じ `data.values` なので、どちらで直しても同じところに入り
ます。線をつなぐと欄は消えます — 値の出どころは1つだけです。

### ポートが設定で変わるノード

`Logic` の入力は `not` のときだけ1本、`Feedback` と `Choose` のポートは持つものが数か
真偽かで変わります。そして `Expression` のポートは、**打ち込まれたテキスト次第**です。

だからカタログとは別に、1ノードぶんを答える口があります。

```
$ ferret.describe("expr", '{"text":"a > b && a < 10"}')
{"title":"Expression","glyph":"()","badge":null,
 "inputs":[{"id":"a",…},{"id":"b",…}],
 "outputs":[{"id":"out","label":"result","kind":"bool"}]}
```

エディタ側で近似することもできます — 「呼び出しの頭でない名前を拾う」正規表現と、
「括弧の外に比較があれば bool」という判定です。そうせずに**同じレキサとパーサに
答えさせています。** 出力が条件かどうかは木の頂点を見るだけなので、近似ではなく
本当の答えが返ります。

半端に打ちかけのテキストでもポートは出ます。名前はパースではなくトークン列から
読むので、`a * b + ` の途中でも `a` と `b` は残ります。

```ocaml
(* The same names, read off the tokens rather than off the parse.  The editor
   asks for these to know which ports to draw, and it asks on every keystroke:
   a formula that is halfway typed has no tree yet but does have ports. *)
let free_names (text : string) : string list = …
```

カードは描画のたびにこれを聞きますが、答えは記憶します。鍵は種類と設定なので、
**同じ設定なら同じ答え**で、設定が変わるのは編集したときだけです。ノードをドラッグ
しても1回も呼ばれません。

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
ブレークポイントで止めるにはスレッドごと止めるしかないからで、暴走した cook を
3秒で terminate できるのも同じ理由です（[4章](debug.md)）。

**モジュールはワーカーの中に立ったままです。** `main` を1回呼ぶのが1 cook で、
Feedback が持っているものは次の cook のためにそこに残ります。パネルの ▶ Play は
100 ms ごとに「もう1回 cook して」とワーカーに投げるだけです。

```ts
if ("cook" in e.data) {
  stepAll = e.data.step ?? false;
  cook();
  return;
}
```

ホストが渡すインポートは5本、エクスポートは `main` とグラフの状態を持つグローバル、
それに文字列があればメモリです。**引数はありません** — グラフは何も受け取らず、
必要なら `Input` のグローバルと `env.now` から貰います。

```ts
env: {
  log: (x) => …,
  random: () => Math.random(),
  watch: (watch, value) => { … return value; },
  now: () => Date.now(),
  say: (ptr, len) => …,   // モジュールのメモリの一部を読む
}
```

## エッジの描き方

Unreal Engine の Blueprint と同じく、**水平に出て水平に入るベジエ**です。直角
ルーティングも試しましたが、平行な経路が重なって1本に見えるうえ、カードの枠線に
乗った線が枠の一部に見えました。曲線のほうが追えます。

Blueprint が読みやすい理由の半分は曲線ではなく**縁取り**にあります。同じ経路を2度
描き、1本目をキャンバスの色で太く描くことで、交差したところに隙間ができます。手前の
線が途切れずに読めるのはこれのおかげです。

```tsx
<g className={"wire" + (faded ? " is-faded" : "")}>
  <path className="wire-casing" d={path} strokeWidth={6} />
  <BaseEdge id={id} path={path}
            style={{ stroke: color, strokeWidth: 2,
                     strokeDasharray: later ? "7 5" : undefined }} />
</g>
```

**`Feedback` に入る線だけ破線です。** グラフの中でその1本だけが、この cook から次の
cook へ渡る線だからです。逆向きに走っている線が絵の中にあるのは普通ですが、時間を
またぐのはこれだけで、そこは区別が付いたほうがいい。

戻る線は別の経路を取ります。ノードが横に並んでいると、戻り線は**ノードが乗っている
その線の上**を通ることになり、行を貫く1本の直線になります。そこで、右へ出て、自分の
高さまで上がって越え、左から入る、という経路にしています。両端は変わらず水平に出入り
するので、1本の筆致に見えます。

高さが違う戻り線は普通の曲線のままです。すでに曲線として読めているものを上へ
回すと、関係するノードから遠ざかるだけなので。

矢印は付けません。値の向きは、カードのどちら側から出ているかで既に分かるからです。

ノードを選ぶと、触れていないエッジが薄くなります。何度も枝分かれした先を目で追うには
これが一番効きます。

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
| Counting | 5 | 5 | Feedback ひとつ。cook を重ねると数が増える |
| Wave | 6 | 6 | 折り返す位相と、1つの値を2つの出口が読むこと |
| Bounce | 11 | 15 | 互いを読む2つの Feedback、真偽を選ぶ Choose |
| Blink | 6 | 5 | 真偽を持つ Feedback、Text と Say |
| Random walk | 4 | 4 | cook ごとに1回引く Random |
| Monte Carlo | 11 | 12 | 累算する2つの Feedback と、名前を2回使う Expression |
