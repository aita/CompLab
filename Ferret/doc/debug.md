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
(global i int)
(func main (result f64)
  (local result float)
  (local i_next int)
  (set result (float i))
  (set i_next (watch 1 (watch 0 (+ i 1))))
  (set i i_next)
  (return result))
```

複数箇所に配られるノードは1度しか計算されないので、**読み手ごとではなく cook ごとに
1ヒット**です。`Feedback` が報告するのは**新しく取り込む値**で、配っている値では
ありません — 配っているほうは前の cook が既に報告しています。

このグラフを3 cook 走らせたときのヒット列:

```
[0,1] [1,1] [0,2] [1,2] [0,3] [1,3]
```

watch 0 が足し算、watch 1 がそれを受け取る Feedback です。同じ式に2つ乗っているので
同じ数を2回言います。

コンパイラは、この番号が指す表（ノード id とラベル）も一緒に返します。フロントエンド
が「どこで止まったか」を名前で言えるようにするためです。

## 止まったら中が見える

報告された値だけでは、デバッガとしては足りません。**そのとき何を持っているか**が
見えないと、どこがおかしいのか分かりません。

グラフの状態はグローバルにあり、`state_<名前>` としてエクスポートされています
（[0章](graph.md)）。だからワーカーは止まった瞬間にそれを全部読めます。プログラムが
報告してくるのを待つ必要はありません。

```ts
// What the graph is holding right now.  Its state is in exported globals, so
// a debugger can read all of it without the program having to report it.
function state() {
  const out = [];
  for (const [name, value] of Object.entries(ready?.exports ?? {})) {
    if (!name.startsWith("state_")) continue;
    const held = value.value;
    out.push({ name: name.slice(6),
               value: typeof held === "bigint" ? Number(held) : held });
  }
  return out;
}
```

i64 のグローバルは JS 側に BigInt で出てくるので、表示のために数へ落とします。

Bounce を Step で歩くと、こうなります。

```
Paused at step   cook 1    x 0   rising 1
Paused at next   cook 1    x 0   rising 1
Paused at show   cook 1    x 0   rising 1
…
Paused at dir    cook 1    x 0   rising 1
                          ↑ commit はまだなので、cook 1 の間ずっと前回の値
```

**cook の途中では状態が動かない**のが見えます。動くのは最後の commit だけで、そこを
抜けると `x 1  rising 1` になります。[0章](graph.md)の「すべての Feedback が同時に
取り込む」が、デバッガからはこう見えるわけです。

見出しには**何回目の cook か**も出ます。走らせっぱなしにできるモデルなので、
「いつの」値なのかが分からないと表を読めません。

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
if (flags) {
  ctx.postMessage({ type: "paused", watch, value, hit: hits.length,
                    cook: cooks + 1, state: state() });
  Atomics.store(flags, AT_BREAKPOINT, RUNNING);
  Atomics.wait(flags, AT_BREAKPOINT, RUNNING);
}
```

`postMessage` でページに知らせてから、`SharedArrayBuffer` 上で `Atomics.wait` に入り
ます。ワーカーのイベントループは止まっていますが、`postMessage` はもう送られている
ので、ページ側はそれを受け取って UI を出せます。Continue はストアと通知です。

```ts
const wake = (which: number, how: number) => {
  Atomics.store(flags, which, how);
  Atomics.notify(flags, which);
  arm();
};
```

Stop はワーカーごと終わらせます。モジュールとそれが持っているものはワーカーの中に
しかないので、巻き戻すものがありません。

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
し、パネルにその旨が出ます。素の `http.server` で `dist/` を配って確認しています。

```
crossOriginIsolated -> false
⏭ Step -> {"paused":false,"result":"cook 1 gave 0",
           "sections":["State","Breakpoints (5)","Log output (1)"]}
```

止まる先をワーカーがどう決めるかだけが変わります。共有バッファがあるときはページが
書いたフラグを cook の途中で読み直しますが、無いときは**投げられた時点の指示**に
従います。

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

6秒放置してから Continue しても打ち切られないことを確認しています。

## 走り続けるものを止める

▶ Play は 100 ms ごとに cook を投げます。ブレークポイントに当たった cook は返って
こないので、次の cook は投げられません — 押し出されるのではなく、そこで列が止まります。

```ts
ticker.current = setInterval(() => {
  // A cook still going, or held at a breakpoint, keeps its turn.
  if (!inFlight.current) void again();
}, FRAME_MS);
```

Continue を押すと止まっていた cook が終わり、次の tick でまた走り出します。**止めて
中を見て、また流す**というのが、走り続けるプログラムのデバッガの形です。

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

ただし**どこで止まるかはモジュールが決めません。ページが決めます。** 報告は全ノード
から上がってきて、ワーカーはそのつど共有バッファのフラグを見ます。

```ts
// Every node reports; whether the run stops here is the page's to say, and
// it can change its mind while the worker is held at one.  Stepping is that:
// stop at the next report, whatever it is.
watch: (watch, value) => {
  const stepping = flags ? Atomics.load(flags, MODE) === AT_EVERY : false;
  if (!stepping && !(stopAt?.[watch] ?? false)) return value;
  …
}
```

**止まっている最中にこのフラグを書き替えられる**のが肝で、これがそのまま3つの操作に
なります。

| | フラグ | 次に止まるところ |
|---|---|---|
| Cook / Play | marked | ブレークポイントを置いたノード |
| Step | every | その cook の最初のノード |
| Next | every | 次に報告してきたノード＝1ステップ |
| Continue | marked | 次のブレークポイント |

だから**ブレークポイントで止めてから、そこから1ノードずつ進める**という、デバッガの
普通の流れになります。

止まるのは**ノードの評価ごとに1回**、cook ごとにやり直しです。Bounce を Step で歩くと、
評価される順に11ノード分止まります。

```
step → next → show → out → x → top → bottom → turn → flip → keep → dir
```

出口が先で、Feedback の新しい値が後にまとまっているのが[1章](lower.md)の cook の
骨格そのものです。`show` と `out` が別々に止まるのに、両方が読んでいる `next` では
1回しか止まらないのは共有の規則から（[1章](lower.md)）、`flip` に止まるのは Choose が
両腕を評価するから（[0章](graph.md)）です。どちらも止め方の都合ではなく、言語が
そう決まっているからそう見えます。

ブレークポイントの無い Cook と Play だけは、報告の入らない**描かれたままの
モジュール**が走ります。止まる先が無いのに計測を積む理由はありません。

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
