# 0. グラフがプログラムであるということ

ノードをつないだ図が、どういう規則でプログラムとして読まれるのか。この章はその
規則の話で、以降の章はすべて「その規則をどうやってコードに落とすか」の話です。

## 2種類のエッジ

エッジには2種類あり、描き分けられ、別々に検査されます。

**実行エッジ**（四角い端子）は、次に何が起きるかを言います。実行は唯一の `Start`
ノードから始まり、これを辿ります。**データエッジ**（丸い端子）は、値がどこから来る
かを言います。こちらは必要になったときに逆向きに引かれます。

この2つは型が違うので、つなぎ間違えることができません。エディタは接続時に弾き、
コンパイラも `sourceHandle` / `targetHandle` を見て弾きます。

| ノード | 何であるか |
|---|---|
| Start | 入口。渡してくるのは**実行が始まった時刻**ひとつだけ |
| End | 値を返して終わる |
| Condition | 実行を true / false のどちらかへ送る。ループはこれに戻り線を張って作る |
| Counter | 数える。通り抜けるたびに `by` を足す |
| State | 覚える。通り抜けると与えられた値を保存し、`reset` を通ると初期値に戻る |
| Wait for Event | ホストからイベントが来るまで止まり、届いた数を渡す |
| For Loop | ある数からある数まで数え、そのたびに本体を走らせる。Counter と Condition を1枚にしたもの |
| Choose | 値の分岐。条件で2つの値のどちらかを選ぶ |
| Log | インポートした `env.log` を値付きで呼ぶ |
| Expression | 計算を1行のテキストで書く。自由に残った名前がそのまま入力ポートになる |
| Constant, Random, Arithmetic, Math function, Comparison, Logic | 式のノード |

演算子は、族の名前の下に1つずつ並びます — `Arithmetic` の下に `Multiply`、
`Comparison` の下に `At most`。**選ぶのは演算であって、あとから設定するノード
ではありません。** 実体は族ごとに1種類のノードで、カードは載っている演算子の名前を
名乗ります。インスペクタのドロップダウンは、線を引き直さずに変えるためのものです。

数値の入力ポートに何もつながっていなければ、そのポートが数値の入力欄になります。
1回しか使わない定数にノードを1つ立てる必要はありません。`Constant` ノードは、同じ
数を何箇所にも配るときのためにあります。

## Expression — 1行で書く

`x * x + y * y < 1` を描くとノード4枚と線6本になります。`Expression` ノードは、
これを1行で書くためのものです。

**評価するのではなく構文解析します。** 出てくるのは、配線して作ったときと同じ木
です。そして**自由に残った名前がこのノードの入力ポートになります。**

```
$ ferretc --emit ir compiler/test/formula.json
(func main (result f64)
  (log (/ (min (float (+ (* 5 5) 1)) 100) 2))
  (return (float (select (and (> 5 3) (< 5 10)) 1 0))))
```

打ち込んだテキストは `min(n * n + 1, 100) / 2` で、`n` はポート、`min` は呼び出し
です。「呼び出しの頭でない名前」が自由な名前だという規則ひとつで両者は分かれます
（上の出力で `n` が 5 になっているのは、そのポートに定数を挿してあるからです）。優先順位は `|| < && < 比較 < + - < * / %` で、
`min max abs sqrt floor ceil round random` が呼べます。

エスケープハッチではありません。ポートの生え方が同じなので、他のノードと同じよう
に配線され、同じ型検査を受け、同じように共有されます。

## For Loop — 数え上げを1枚に

Condition と Counter でループは作れますが、「1から n まで」を描くたびに Counter と
Comparison と Condition を並べることになります。`For Loop` はその配置を1枚にした
ものです。Condition の `true` / `false` に当たるところが `body` / `done` です。

**本体に戻り線は要りません。** 本体から辿って行き先が無くなったところは、ループの
step へ戻ります。Blueprint のマクロが自分で閉じるのと同じです。

Counter との違いがひとつあります。Counter の開始値は**関数の入口で**設定されます
が、For Loop は**入られたところで**設定されます。だから For Loop の中の For Loop
は、外側が1周するたびに数え直します。

```
$ ferretc --emit ir examples/triangle.json
(func main (result f64)
  (local r int)
  (local c int)
  (set r 1)
  (loop $1
    (if (<= r 4)
      (then
        (set c 1)
        (loop $2
          (if (<= c r)
            (then
              (log (float (* r c)))
              (set c (+ c 1))
              (br $2))
            (else
              (set r (+ r 1))
              (br $1)))))
      (else
        (return 0)))))
```

## 名前で書き換えるのをやめた

最初は「変数に代入」「変数を読む」というノードがありました。それをやめたのは、
**名前の一致を目で追うのが面倒だから**です。`total` と書いたノードと `total` と
書いた別のノードが同じものを指しているかどうかは、文字列を見比べるしかありません
でした。エッジは見れば分かるのに。

いまは状態を持つノードは `Counter` と `State` の2つで、その値は**そのノードの
出力ポートからエッジで**受け取ります。名前は表示のためだけのもので、どこにも
一致を求めません。**状態の同一性はノードそのもの**です。同じ名前の State を2つ
置けば、それは2つの別々の状態です。

## Counter — 通り抜けると数える

`Counter` は開始値をひとつ持ち、実行がそこを通るたびに `by` を足します。`by` は
定数である必要はありません。`total` の `by` に `i` を挿せば累算になります。

開始値は**関数の入口で1度だけ**設定されます。あとでどのループの中に置かれることに
なっても同じです。

## State — 通り抜けると覚える

`State` は与えられた値を保存します。足しません。コラッツの `cur` のように「次は
この値」と言いたいときのノードです。

```
$ ferretc --emit ir examples/collatz.json
(func main (result f64)
  (local cur float)
  (local steps int)
  (set cur 27)
  (set steps 0)
  (loop $1
    (if (!= cur 1)
      (then
        (log cur)
        (set cur (select (== (% cur 2) 0) (/ cur 2) (+ (* 3 cur) 1)))
        (set steps (+ steps 1))
        (br $1))
      (else
        (return (float steps))))))
```

**通り道が2本あります。**

| | |
|---|---|
| in → next | `value` を保存する |
| reset → after reset | 開始値に戻す |

2本目があるのは、Counter が抱えている制限を State では外したいからです。Counter の
開始値は関数の入口で1度きりなので、**ループの中に置いても数え直しません。** State は
`reset` を通せばそこで戻ります。行き先が別々なのは、戻す場所と保存する場所が普通は
別だからです — 戻すのはループの手前、保存するのは本体の中です。

```
$ ferretc --emit ir examples/rowsums.json
(func main (result f64)
  (local run int)
  (local r int)
  (local c int)
  (set run 0)
  (set r 1)
  (loop $1
    (if (<= r 5)
      (then
        (set run 0)
        (set c 1)
        (loop $2
          (if (<= c r)
            (then
              (set run (+ run c))
              (set c (+ c 1))
              (br $2))
            (else
              (log (float run))
              (set r (+ r 1))
              (br $1)))))
      (else
        (return 0)))))
```

三角形の各行の和 `1, 3, 6, 10, 15` が出ます。Counter だけでは書けない形です。

## Wait for Event — 唯一、時間のかかるノード

ここまでのノードはどれも算術で、実行は一直線に終わりまで走ります。`Wait for Event`
だけが違います。**通り抜けようとすると、ホストが何か送ってくるまでそこで止まります。**
返ってくるのは数がひとつ。イベントとは数のことです。

これを Condition の輪の中に置けば、それがイベントループです。

```
$ ferretc --emit ir examples/echo.json
(func main (result f64)
  (local seen int)
  (local e float)
  (set seen 0)
  (loop $1
    (set e (wait))
    (if (!= e 0)
      (then
        (log e)
        (set seen (+ seen 1))
        (br $1))
      (else
        (return (float seen))))))
```

**ループはランタイムの中ではなくグラフの中にあります。** 「イベントが来たらこの
ハンドラを呼ぶ」ではなく、「イベントを待って、見て、また待つ」と描いてあります。
どこで待っているか、待った値が次にどこへ行くかが、線で見えます。

止め方は[4章](debug.md)のブレークポイントとまったく同じ仕組みです — wasm の呼び出しは
同期なので、**止めるにはスレッドを止めるしかありません。**

## Condition — 分けるだけ

`Condition` は真偽値をひとつ受け取り、実行を `true` と `false` のどちらかへ送り
ます。それだけです。

**ループは描いて作ります。** 本体の終わりから Condition へ実行エッジを戻すと、
それがループです。分岐の合流も同じで、2本の実行エッジが同じノードに入れば、そこが
合流点です。

```
Start ──> Condition ──true──> Counter(total) ──> Counter(i) ──┐
             ▲                                                │
             └────────────────────────────────────────────────┘
             └──false──> End
```

だから実行エッジは木ではなく、**本物のグラフ**です。値のほうは相変わらず木で、
Counter の出力で止まります。

## その代償

以前は実行エッジが木だったので、wasm が要求する `block` / `loop` / `br` の入れ子は
IR の時点で既にありました。いまは無いので、バックエンドが組み直します — 支配木、
ループの検出、合流点の判定（[1章](lower.md)）。

そのぶん、書けないグラフも出てきます。**ループの途中に2通りの入り方があるもの**は、
wasm のブロックではコードを複製せずに書けません。推測せずに断ります。

```
  a: this loop has two ways in, which cannot be written with wasm's blocks;
     route both through one condition (the wire from c2 closes it)
```

分岐の両方の行き先も要ります（ループ本体の中でぶら下がっている端子は step へ
戻るので、この文句が出るのは戻り先の無いところだけです）。

```
  w: both ways out of this node have to go somewhere
```

## 型は2つだけ

値はすべて数で、条件だけが真偽値です。混ぜようとすると型検査が止めます。Condition の
`test` ポートは数を受け取りませんし、`End` の `result` は比較の結果を受け取りません。

数の内部が i64 と f64 に分かれているのは[2章](types.md)の話で、グラフの上では見え
ません。

## ファイル形式

グラフは React Flow の保存形式そのままです。ノードの `type` がノードの種類で、
エッジの `sourceHandle` / `targetHandle` がポート名です。変換層はありません。

```json
{"id":"i","type":"counter","position":{"x":1160,"y":0},
 "data":{"name":"i","values":{"from":1,"by":1}}}
```

`values` が、ポートに直接打ち込まれた数です。エディタが保存するファイルは、そのまま
`ferretc` が受け取るファイルです。

次は[1章 グラフから IR へ](lower.md)。
