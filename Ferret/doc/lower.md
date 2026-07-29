# 1. グラフから IR へ — `lower.ml`

グラフには順序がありません。あるのはノードとエッジだけです。IR には順序があります。
この章はその間を埋める1パスの話です。

## 出口から後ろ向きに歩く

歩き始めるのは**出口**です。`Out`・`Log`・`Say`、それに新しい値を与えられている
`Feedback`。そこから「この値は何でできているか」を辿ると、必要なノードだけが必要な
順に並びます。

```ocaml
(* The nodes a cook is for.  Everything else in the graph is only there
   because one of these asks for it: nothing is evaluated that nothing wants,
   which is the whole of the evaluation order. *)
let sink_kinds = [ "out"; "log"; "say" ]
```

**前向きに歩くものは何もありません。** どこにもつながっていないノードはコードに
なりませんし、「先に置いたから先に走る」ということもありません。

後ろ向きの歩きは `Feedback` で止まります。そこはグローバルだからです。

```ocaml
| "feedback" ->
    (* Reading a feedback stops the backward walk: what comes out is what
       the last cook left, so the value it is fed may name the feedback
       itself without that being a cycle.  This is the only way a graph can
       depend on itself. *)
    (Global (state_slot ctx n), holds ctx n)
```

**これが、絵の中の閉路が式の中の閉路にならない理由です。** Feedback に与える式が
その Feedback 自身を名指ししても、そこで木は終わります。Feedback を通らない本当の
循環 — 加算ノードの出力が自分の入力に戻っている類 — は別に検出してエラーにします。

```
  add: this node's value depends on itself
```

歩いている途中のノードを覚えておいて、もう一度踏んだら閉路、というだけです。

```ocaml
if Hashtbl.mem ctx.active n.id then (
  complain ctx ~node:n.id "this node's value depends on itself";
  (Int 0, VInt))
```

## cook 1回の形

出てくる関数はいつも同じ骨格です。

```
pre      共有された値の巻き上げ（下記）
sunk     出口 — Log・Say と、Out の値をローカルに取る1行
work     各 Feedback の新しい値を、それぞれのローカルに
commit   ローカルからグローバルへ、まとめて
return   Out のローカル、または 0
```

`work` と `commit` が分かれているのが**「すべての Feedback が同時に取り込む」**です。

```
$ ferretc --emit ir examples/bounce.json
(global x int)
(global rising bool 1)
(func main (result f64)
  (local next_value int)
  (local result float)
  (local x_next int)
  (local rising_next bool)
  (set next_value (+ x (select rising 1 -1)))
  (log (float next_value))
  (set result (float next_value))
  (set x_next next_value)                                      ← work
  (set rising_next (select (or (>= next_value 10) (<= next_value 0)) (not rising) rising))
  (set x x_next)                                               ← commit
  (set rising rising_next)
  (return result))
```

`rising_next` の式が `rising` を読んでいるのに注意してください。commit がすべての
work の後にあるので、これは**この cook の頭の値**です。work と commit を混ぜると、
Feedback を書く順番が意味を持ってしまいます。

`Out` の値も同じ理由でローカルを1つ使います。値そのものは出口の並びの中のその場で
計算されますが、返すのは commit のあと — つまり関数の最後です。

## 制御フローが無いということ

実行の順序を描く言語なら、ここが章の半分を占めます — 描かれたグラフは循環するのに
wasm には `block` / `loop` / `br` の入れ子しか無いので、支配木を求め、戻り辺を
見つけ、入れ子を復元し、簡約不能なものを断ることになります。**リルーパ**です。

この IR に分岐命令はありません。

```ocaml
type stmt =
  | Assign of int * expr  (* a local *)
  | Store of int * expr   (* a global: what the graph holds *)
  | Drop of expr
  | Log of expr
  | Say of int            (* the index of a string literal *)
  | Ret of expr

type block = stmt list
```

条件分岐に当たるものは `Select` — 両方を計算して選ぶ式 — ひとつだけで、これは
**グラフの中に副作用のある場所が無い**から成り立ちます。読んだところで何も起きない
ので、要らないほうを計算しても構いません。

### なぜ S 式なのか

IR は木で、元のグラフも木です。だからダンプも木の形をしています。**式の形が
入れ子そのもの**なので、優先順位の表を覚えていなくても読めます。

wat とは別物です。`wat.ml` が書くのはスタックマシンで、1行1命令、`local.get` が
2行先の `i64.add` の引数になります。こちらは呼び出しの中に引数が入ったままです。

```
(set count_next (+ count step))   IR
```
```wat
global.get $count                 wat
global.get $step
f64.add
local.set $count_next
```

## 1つの値を1度だけ計算する

グラフには中間の値に名前をつける方法がありません。だから1つの出力を複数の入力に
配るのが、この言語の書き方そのものです。ところが**使うたびに式を展開すると、1段
ごとにコードが倍になります。**

`算術` ノードを22段つなぎ、それぞれの出力を次のノードの A と B の両方に入れた
グラフで測りました。

| | 展開したまま | 共有あり |
|---|---|---|
| 生成 wasm | 12,583,046 バイト | **285 バイト** |
| 所要時間 | 6.8 秒 | **38 ミリ秒** |

ブラウザ側はコンパイルを同期に走らせるので、これはそのままタブのフリーズでした。

### 何が安全にしているか

出力が2箇所以上に配られているノードは、一度だけ計算してローカルに入れ、以降は読む
だけにします。

```
$ ferretc --emit ir compiler/test/sharing.json
(func main (result f64)
  (local b0_value int)
  (local result float)
  (set b0_value (+ 2 2))
  (set result (float (+ b0_value b0_value)))
  (return result))
```

巻き上げが等価であることを保証しているのは**グループ**です。グループとは、生成される
コードの中で式がまとめて評価される1箇所のことで、共有はグループの内側だけに閉じます。

```ocaml
(* A group is one place in the emitted code where a set of expressions is
   evaluated together: one sink, or the whole set of new values the feedbacks
   take.  Sharing is scoped to a group, and the assignments it hoists
   run at the head of it -- which is only sound because a group never writes a
   local that its own expressions read. *)
```

**cook 全体がちょうど1つのグループです。** グラフの中に代入が無く、Feedback への
書き戻しは全部いちばん最後にまとまっているので、「自分の式が読むローカルを書かない」
がそのまま成り立ちます。だから巻き上げた代入を関数の先頭に置いてよいことになります。

### ホストに訊くノードは、辺の数によらず必ず1度

`Random` と `Time` は、**出て行く辺が1本でもローカルに取ります。**

```ocaml
(* A node that asks the host something is its answer: one draw, one reading
   of the clock, and every reader sees that one.  It is worked out into a
   local however few edges leave it, because the edge count is not the whole
   story -- a formula that names it twice leaves one edge and reads it
   twice. *)
let impure = List.mem from.Graph.kind [ "random"; "time" ] in
```

辺の数を数えるだけでは足りません。`Expression` に `x * x` と書いて `x` に乱数を
1本挿すと、辺は1本なのに読みは2回です。数えているのが**辺**で、意味を決めているのが
**読み**なので、ここだけは辺を無視します。

## 型は不動点

`Feedback` の型は一度見ただけでは決まりません — その新しい値の式が、その Feedback
自身を読むからです。だから lowering 全体が不動点になっています。全部を i64 と仮定
して始め、狭すぎたことが分かったらもう一度走る。仮定は緩む方向にしか動かないので、
Feedback の数 + 2 回で必ず止まります。詳しくは[2章](types.md)で。

## エラーは集めてから返す

最初の1つで止めず、全部集めて返します。それぞれが原因のノード id を持つので、
エディタは該当ノードを赤枠にしてメッセージをその下に出せます。編集のたびに全体を
コンパイルしているので、ビルドというよりリンタの体感になります。

```
$ dune test          # compiler/test/errors.ml が固定している文言から
  o: the value input is not connected
  p: the cond input wants a true or false but is given a whole number
  add: this node's value depends on itself
  n: a const node does not make text
  f: * needs something before it
  s: there is no start node in this language
```

最後のひとつは、このカタログに無い種類のノードが入っていたときです。「読み飛ばす」
のではなく名指しで断ります — 何も読まないノードは黙って消えてしまい、別のものを
計算した結果だけが残るからです。

同じ文言が2度出ないよう、重複は落としています。

次は[2章 数に型をつける](types.md)。
