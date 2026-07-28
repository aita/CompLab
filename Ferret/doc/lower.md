# 1. グラフから IR へ — `lower.ml`

グラフには入口も順序もありません。あるのはノードとエッジだけです。IR には順序が
あります。この章はその間を埋める1パスの話です。

## 2通りの歩き方

**データエッジ**は後ろ向きに歩いて式の木を組み立て、**実行エッジ**は制御フロー
グラフを作ってから構造を復元します。

後ろ向きの歩きは、Counter が保持している値で止まります。そこはローカルだからです。

```ocaml
| "counter" ->
    (* Reading what a counter holds stops the backward walk: the value is a
       local, so the step may name the counter itself without that being a
       cycle. *)
    (Local (state_slot ctx n), assumed ctx (slot_key n))
```

**これが、絵の中の閉路が再帰の中の閉路にならない理由です。** 条件や「次の値」の式が
スロットを名指ししても、そこで木は終わります。本当の循環 — 加算ノードの出力が自分の
入力に戻っている類 — は別に検出してエラーにします。

```
  add: this node's value depends on itself
```

## 制御フローグラフを組み直す

実行エッジは循環します。wasm には goto がなく `block` / `loop` / `br` の入れ子しか
無いので、**描かれたグラフから入れ子を復元する**必要があります。`cfg.ml` がその
下ごしらえをします。

1. 実行ノードを頂点、実行エッジを辺としてグラフを作る
2. 逆後行順（reverse postorder）を取る
3. 支配木を求める — Cooper・Harvey・Kennedy の反復版。この規模なら2〜3周で収束します
4. 深さ優先の戻り辺を見つける。戻り先が始点を支配していなければ**簡約不能**なので断る

そのうえで、標準的な形で書き出します。

- **ループの先頭**（戻り辺が入るノード）は `loop` になり、そこへ戻る枝は `br` になる
- **合流点**（前向きの入り辺が2本以上あるノード）は、そこへ飛ぶ枝を全部囲む `block`
  の直後に置かれる。`br` でその block を抜けると、ちょうど合流点の手前に落ちる
- それ以外のノードは、**支配しているノードのその場に**書き出される

各ノードはちょうど1度だけ書かれます。

`examples/sum.json` — Condition に戻り線が1本あるだけのグラフ — はこうなります。

```
$ ferretc --emit ir examples/sum.json
(func main (result f64)
  (local total int)
  (local i int)
  (set total 0)
  (set i 1)
  (loop $1
    (if (<= i 100)
      (then
        (set total (+ total i))
        (set i (+ i 1))
        (br $1))
      (else
        (return (float total))))))
```

Counter の開始値が入口にまとめて出ていること、戻り線が `br $1` になっていることに
注目してください。

合流のほうは `block` になります。

```
(func main (result f64)
  (block $1
    (if (< i 10)
      (then
        (log 1))
      (else
        (log 2))))
  (log 3)
  (return 0))
```

両方の枝の末尾にあった `br $1` は消えています。**いま居るブロックの終わりへ飛ぶ
のは何もしないのと同じ**なので、後始末の1パスで落としています。これが無いと、
ただの if/else が if/else に見えません。

### なぜ S 式なのか

IR は木で、元のグラフも木です。だからダンプも木の形をしています。**式の形が
入れ子そのもの**なので、優先順位の表を覚えていなくても読めます。

wat とは別物です。`wat.ml` が書くのはスタックマシンで、1行1命令、`local.get` が
2行先の `i64.add` の引数になります。こちらは呼び出しの中に引数が入ったままです。

```
(set total (+ total i))          IR
```
```wat
local.get $total                 wat
local.get $i
i64.add
local.set $total
```

### 深さは数えない

`br` は相対の深さで書きます。ここを手で数えると必ず間違えます — **`if` も1段
数える**からです。だから IR ではラベルを持ち、深さは出力側がラベルの積み重なりから
求めます。

```ocaml
type label = int

type stmt =
  | Block of label * block  (* branching to it leaves the block *)
  | Loop of label * block   (* branching to it goes round again *)
  | Br of label
```

さきほどの sum が出す wat は `br 1` です。`loop` の1つ内側に `if` があるので、
`loop` へ戻るには1段ではなく2段目を指します。

## 1枚のノードが3つの頂点になる

`For Loop` は、描かれているのは1枚ですが、制御フローの上では3か所です。**入られる
ところ**（開始値を入れる）、**戻ってくるところ**（判定する）、**本体が落ちてくる
ところ**（1つ進める）。

そこで制御フローグラフの頂点を「ノード id」ではなく「ノード id と、どの扉から
入ったか」にしました。

```ocaml
(* A for loop is three places rather than one: the setup it is entered at, the
   test it comes back to, and the step the body falls into.  So a vertex of
   the control-flow graph is a node and the door it was entered by. *)
let vertex_for ctx ~dst ~port =
  let n = Graph.find ctx.g dst in
  if n.kind = "forloop" && port = "in" then dst ^ "#init" else dst
```

`l#init` の次は `l`、`l#step` の次も `l` です。あとは支配木もループ検出も、この
3頂点を普通の頂点として扱うだけで、Counter と Condition を並べて描いたときと同じ
形が出ます。

**開始値が入口ではなくここに出るのが、入れ子のループが数え直す理由です。**

### つながっていない端子も頂点にする

本体の終わりを step へ戻すには、「行き先の無いところ」を見つける必要があります。
ところが後続を「実行エッジの行き先の一覧」にすると、`true` が空なのか `false` が
空なのかが**リストの長さからは分かりません**。

そこで、配線されていない端子も頂点にしました。

```ocaml
(* A way out that was left unwired is a vertex of its own rather than a
   missing successor, so that a node with two exits keeps two of them however
   little is drawn: which pin is dangling is the whole question, and a list
   with a hole in it cannot say. *)
let gap ~node ~port = node ^ "#gap:" ^ port
```

ループ本体から辿り着いた gap は step に書き換えられ、書き換えられずに残った gap は
「both ways out of this node have to go somewhere」になります。本体の中の
Condition の片側を描き忘れたときは前者、ループの外で描き忘れたときは後者です。

本体を辿る歩きは、**別の For Loop の本体には入りません。** そこはその For Loop の
持ち物で、内側の `done` だけが外側に属します。

## 1つの値を1度だけ計算する

グラフには中間の値に名前をつける方法がありません。だから1つの出力を複数の入力に
配るのが、この言語の書き方そのものです。ところが**使うたびに式を展開すると、1段
ごとにコードが倍になります。**

`算術` ノードを22段つなぎ、それぞれの出力を次のノードの A と B の両方に入れた
グラフで測りました。

| | 展開したまま | 共有あり |
|---|---|---|
| 生成 wasm | 12,582,980 バイト | **254 バイト** |
| 所要時間 | 5.6 秒 | **6 ミリ秒** |

ブラウザ側はコンパイルを同期に走らせるので、これはそのままタブのフリーズでした。

### 何が安全にしているか

出力が2箇所以上に配られているノードは、一度だけ計算してローカルに入れ、以降は読む
だけにします。

```
$ ferretc --emit ir compiler/test/sharing.json
(func main (result f64)
  (local b0_value int)
  (local b1_value int)
  (set b0_value (+ 2 2))
  (set b1_value (+ b0_value b0_value))
  (return (float (+ b1_value b1_value))))
```

巻き上げが等価であることを保証しているのは**グループ**です。グループとは、生成される
コードの中で式がまとめて評価される1箇所のこと — 1つの文、ループの条件、ループの
「次の値」全体 — で、共有はグループの内側だけに閉じます。

```ocaml
(* A group is one place in the emitted code where a set of expressions is
   evaluated together: a statement, a loop's condition, a loop's whole set of
   next values.  Sharing is scoped to a group, and the assignments it hoists
   run at the head of it -- which is only sound because a group never writes a
   local that its own expressions read. *)
```

**グループは自分の式が読むローカルを書きません。** だから巻き上げた代入をグループの
先頭に置いてよいことになります。グループをまたいだ共有はしないので、ループの更新を
挟んで読まれた値はちゃんと2回読まれます。

ループの条件から巻き上げた代入は、`loop` の中・`if` の手前に出ます。毎周回そこを
通るので、条件が読む値はそのつど作り直されます。

## エラーは集めてから返す

最初の1つで止めず、全部集めて返します。それぞれが原因のノード id を持つので、
エディタは該当ノードを赤枠にしてメッセージをその下に出せます。編集のたびに全体を
コンパイルしているので、ビルドというよりリンタの体感になります。

```
$ dune test          # compiler/test/errors.ml が固定している文言から
  e: the value input is not connected
  w: the cond input wants a true or false but is given a whole number
  add: this node's value depends on itself
  f: * needs something before it
```

同じ文言が2度出ないよう、重複は落としています（名前を2回宣言すると同じ質問が2回
飛んでくるため）。

次は[2章 数に型をつける](types.md)。
