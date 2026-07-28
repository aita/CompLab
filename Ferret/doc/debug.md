# 4. 止まるデバッガ

ノードを右クリックしてブレークポイントを置くと、そこで実行が止まり、値が見え、
Continue で先へ進みます。wasm にデバッガのフックはないので、全部こちら側で作ります。

## 値を素通しする呼び出し

コンパイラは3本目のインポートを埋め込みます。

```wat
(import "env" "watch" (func $watch (param i32) (param f64) (result f64)))
```

`watch(index, value) -> value` です。**値を渡して、そのまま返します。** だから計算
結果は1ビットも変わりません。変わるのは、その値がページから見えることだけです。

置き場所は[1章](lower.md)の共有規則から決まります。

```
$ ferretc --emit ir compiler/test/breakpoints.json
(func main (result f64)
  (local i int)
  (set i 0)
  (loop $1
    (if (watch 0 (< i 3))
      (then
        (set i (watch 1 (+ i 1)))
        (br $1))
      (else
        (return (float i))))))
```

複数箇所に配られるノードは1度しか計算されないので、**読み手ごとではなく評価ごとに
1ヒット**です。値を持たないノードは、通り抜けるときに求めるものを報告します —
Counter なら新しい値、Condition なら判定の結果です。

3まで数えるこのループを走らせたときのヒット列:

```
[0,1] [1,1] [0,1] [1,2] [0,1] [1,3] [0,0]
```

watch 0 は判定（真偽値なので 1 か 0）、watch 1 は数えた値です。最後の判定だけが 0
で、そこで抜けます。

コンパイラは、この番号が指す表（ノード id とラベル）も一緒に返します。フロントエンド
が「どこで止まったか」を名前で言えるようにするためです。

## 整数は往復させない

ホストが受け取るのも返すのも f64 です。i64 の値をそこに通すと 2⁵³ を超えたところで
壊れるので、整数のときはローカルに預けて、コピーだけを報告します。

```wat
local.set $t0        ← 本体はここで待つ
i32.const 0
local.get $t0
f64.convert_i64_s    ← 報告用のコピー
call $watch
drop
local.get $t0        ← 待たせておいた値をそのまま使う
```

条件（i32）は 0 と 1 しか取らないので f64 を往復しても正確に戻ります。そちらは変換
2つで済ませています。

## 止める

ここが厄介なところです。wasm の呼び出しは同期で、途中で中断する手段がありません。
**プログラムを止めるには、それが走っているスレッドを止めるしかありません。**

ワーカーがモジュールを走らせているので、止めるのはワーカーです。

```ts
if (resume) {
  ctx.postMessage({ type: "paused", watch, value, hit: hits.length });
  Atomics.store(resume, 0, RUNNING);
  Atomics.wait(resume, 0, RUNNING);
  if (Atomics.load(resume, 0) === STOP) throw new Stopped();
}
```

`postMessage` でページに知らせてから、`SharedArrayBuffer` 上で `Atomics.wait` に入り
ます。**`Wait for Event` ノードが使うのもこれと同じ仕組みです** — フラグが1本増えて
いるだけで、止め方は変わりません。ワーカーのイベントループは止まっていますが、`postMessage` はもう送られている
ので、ページ側はそれを受け取って UI を出せます。Continue はストアと通知です。

```ts
const wake = (how: number) => {
  Atomics.store(resume, 0, how);
  Atomics.notify(resume, 0);
  arm();
};
```

Stop は同じ経路で別の値を書き、ワーカーは wasm の呼び出しの中から例外を投げて抜けます。

### cross-origin isolation

`SharedArrayBuffer` は cross-origin isolated なページにしか渡されません。だから Vite に
COOP と COEP を吐かせています。

```ts
headers: {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp",
},
```

**ヘッダなしで配信された場合も動きます。** 止まらないだけで、全ヒットを記録して完走
し、パネルにその旨が出ます。素の `http.server` で配って確認してあります。

```
crossOriginIsolated -> false
without a shared buffer -> {"everPaused":false,"returned":"6","hits":8}
```

### 暴走ループの時計を止める

ワーカーには3秒のタイムアウトがあります。ブレークポイントで止まっている間はこの
時計も止めないと、考えている時間がハングと区別できません。

```ts
worker.onmessage = (e: MessageEvent) => {
  const m = e.data;
  if (m.type === "paused") {
    disarm();
    onPause(m as Paused);
    return;
  }
```

6秒放置してから Continue しても打ち切られないことを確認しています。イベント待ちも
同じ扱いで、6秒待たせてから送っても走り続けます。

## 実際の一往復

Counter に置けば動くたび、Condition に置けば判定のたびに止まります。Stop を押せば
`stopped` として終わり、そこまでのヒットは残ります。

## ステップ実行

1ノードずつ止めるのに、新しい仕組みは要りませんでした。**全ノードにブレークポイント
を置いたグラフをもう1本コンパイルするだけ**です。

```ts
const stepwise: CompileResult = useMemo(
  () =>
    compile({
      ...graph,
      nodes: graph.nodes.map((n) => ({
        ...n,
        data: { ...n.data, breakpoint: true },
      })),
    }),
  [graph],
);
```

Run は描かれたままのモジュールを走らせ、Step はこちらを走らせます。**片方がもう
片方の計測版ではありません。** どちらの場合も、ページが実行するのはコンパイラが
そのために吐いたバイト列です。

止まるたびに、その値を報告したノードへキャンバスを移します。

```ts
setCenter(n.position.x + w / 2, n.position.y + h / 2, {
  zoom: Math.max(getZoom(), 0.75),
  duration: 250,
});
```

ここで1つ引っかかりました。ノードを選択するとインスペクタに切り替わるようにして
あったので、**ステップするたびに Run パネルが消えて**いました。選択の変化ではなく
**クリック**でタブを切り替えるようにして直しています。プログラムが動かした選択と、
人が指した選択は別のものです。

```tsx
onNodeClick={(_, node) => {
  // Opening the inspector belongs to the click, not to the selection:
  // stepping selects nodes too, and it must not take the panel away from
  // the run that is paused.
  setSelected(node.id);
  setTab("node");
}}
```

次は[5章 エディタと橋渡し](editor.md)。
