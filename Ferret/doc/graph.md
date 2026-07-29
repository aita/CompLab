# 0. グラフがプログラムであるということ

ノードをつないだ図が、どういう規則でプログラムとして読まれるのか。この章はその
規則の話で、以降の章はすべて「その規則をどうやってコードに落とすか」の話です。

## エッジは1種類しかない

エッジは**値がどこから来るか**だけを言います。実行の順序を言うエッジはありません。
グラフは有向非巡回グラフで、辿るのは常に逆向き — 出口から「これは何でできている
か」を聞いていくと、必要なノードだけが必要な順に並びます。

**評価順は描くものではなく、依存から落ちてくるものです。** どのノードが先かは、
どのノードがどのノードの値を要るかで決まります。それ以外の順序は存在しません。

## Cook — 1回ぶんの計算

グラフを一度ぶん回しきることを **cook** と呼びます。モジュールがエクスポート
する `main` が、ちょうど cook 1回です。

```
$ ferretc examples/count.json -o count.wasm
$ node
> const { instance } = await WebAssembly.instantiate(readFileSync("count.wasm"), env)
> instance.exports.main()   // 0
> instance.exports.main()   // 1
> instance.exports.main()   // 2
```

**グラフの中にループはありません。** プログラムが先へ進むのは、ホストが `main` を
もう1回呼ぶからです。TouchDesigner のフレーム、シェーダの1ピクセル、オーディオの
1ブロックと同じ形で、繰り返しは外側にあります。

エディタの Run パネルの ▶ Play が、その外側です。100 ms ごとに `main` を呼びます。
↻ Cook は1回だけ呼びます。

## Feedback — cook と cook の間

cook の中でグラフは非巡回でなければなりませんが、それでは前回の結果を使えません。
`Feedback` がその1点です。

**読むと前回の cook が置いていった値が出ます。** 与えた値はこの cook の**最後に**
取り込まれます。だから Feedback の出力から辿って戻ってきても循環ではありません
— 読む先は前の cook だからです。

```
$ ferretc --emit ir examples/count.json
(global step float 1)
(global count float)
(func main (result f64)
  (local result float)
  (local count_next float)
  (log count)
  (set result count)
  (set count_next (+ count step))
  (set count count_next)
  (return result))
```

`count_next` に一度置いてから `count` に書いているのが、その「最後に」です。
**すべての Feedback が同時に取り込みます。** 2つの Feedback が互いを読んでいても、
どちらも相手が**前回**持っていた値を見ます。順番を気にする必要がありません。

`examples/bounce.json` がその形です。位置 `x` と向き `rising` が互いを読みます。

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
  (set x_next next_value)
  (set rising_next (select (or (>= next_value 10) (<= next_value 0)) (not rising) rising))
  (set x x_next)
  (set rising rising_next)
  (return result))
```

`x_next` と `rising_next` を全部決めてから、まとめて書き戻しています。

保持する値は数か真偽かをノード側で選びます。線を挿す前にポートの型が決まっている
必要があるので、配線から推測させるわけにはいきません。開始値もノードが持っていて、
それがそのままグローバルの初期値になります — 初期化を走らせる入口が無いからです。

## 出口 — cook が何のためにあるか

cook で計算されるのは、**出口が要求したものだけ**です。どこにもつながっていない
ノードはコードになりません。出口は3つあります。

| ノード | 何であるか |
|---|---|
| Out | cook の戻り値。無くてもよいが、2つは置けない |
| Log | `env.log` を数ひとつで呼ぶ |
| Say | `env.say(ptr, len)` を呼ぶ。渡せるのはリテラルだけ |

Feedback も「要求する側」です。出口が1つも無くても、Feedback に線が入っていれば
その値は毎 cook 計算されます。

## ノード一覧

| ノード | 何であるか |
|---|---|
| Out / Log / Say | 出口 |
| Feedback | 前の cook が置いた値。cook をまたぐ唯一のもの |
| Input | 走らせる前に Run パネルが訊いてくる数。既定値はモジュールにも入る |
| Constant / Yes or No / Text | 数・真偽・文字列のリテラル |
| Time | ホストの時計。cook ごとに1回訊く |
| Random | `[min, max)` の乱数。cook ごと・ノードごとに1回引く |
| Choose | 条件で2つのうちどちらかを選ぶ。数どうしでも真偽どうしでも |
| Arithmetic / Math function / Comparison / Logic | 式のノード |
| Expression | 計算を1行のテキストで書く。自由に残った名前がそのまま入力ポートになる |

演算子は、族の名前の下に1つずつ並びます — `Arithmetic` の下に `Multiply`、
`Comparison` の下に `At most`。**選ぶのは演算であって、あとから設定するノード
ではありません。** 実体は族ごとに1種類のノードで、カードは載っている演算子の名前を
名乗ります。インスペクタのドロップダウンは、線を引き直さずに変えるためのものです。

数値の入力ポートに何もつながっていなければ、そのポートが数値の入力欄になります。
1回しか使わない定数にノードを1つ立てる必要はありません。`Constant` ノードは、同じ
数を何箇所にも配るときのためにあります。

## ノードは1 cook に1度だけ計算される

出力を3箇所に配ったノードは、3回ではなく**1回**計算されます。その値はローカルに
入り、読む側はそれを読みます。

```
$ ferretc --emit ir compiler/test/sharing.json
(func main (result f64)
  (local b0_value int)
  (local result float)
  (set b0_value (+ 2 2))
  (set result (float (+ b0_value b0_value)))
  (return result))
```

これは最適化ではなく**意味**です。`Random` を2箇所から読めば、2回引くのではなく
**1回引いた同じ数**が両方に届きます。`Time` も同じで、1回の cook の中で時刻を2度
読んでも同じ瞬間です。

```
$ ferretc --emit ir compiler/test/time.json
(func main (result f64)
  (local t_value float)
  (local result float)
  (set t_value (now))
  (log (- t_value t_value))       ← いつでも 0
  (set result t_value)
  (return result))
```

**「ノードが値である」**という言い方がいちばん近くて、エッジはそれを配る線です。
1本の線の先で式が名前を2回使っても同じで、`examples/pi.json` の `x * x + y * y`
は乱数を1回しか引きません。

## Expression — 1行で書く

`x * x + y * y < 1` を描くとノード4枚と線6本になります。`Expression` ノードは、
これを1行で書くためのものです。

**評価するのではなく構文解析します。** 出てくるのは、配線して作ったときと同じ木
です。そして**自由に残った名前がこのノードの入力ポートになります。**

```
$ ferretc --emit ir compiler/test/formula.json
(func main (result f64)
  (local result float)
  (log (/ (min (float (+ (* 5 5) 1)) 100) 2))
  (set result (float (select (and (> 5 3) (< 5 10)) 1 0)))
  (return result))
```

打ち込んだテキストは `min(n * n + 1, 100) / 2` で、`n` はポート、`min` は呼び出し
です。「呼び出しの頭でない名前」が自由な名前だという規則ひとつで両者は分かれます
（上の出力で `n` が 5 になっているのは、そのポートに定数を挿してあるからです）。
優先順位は `|| < && < 比較 < + - < * / %` で、
`min max abs sqrt floor ceil round random` が呼べます。

エスケープハッチではありません。ポートの生え方が同じなので、他のノードと同じよう
に配線され、同じ型検査を受け、同じように共有されます。

## 名前ではなくエッジ

「変数に代入」「変数を読む」というノードを置く手もあります。取らなかったのは、
**名前の一致を目で追うのが面倒だから**です。`total` と書いたノードと `total` と
書いた別のノードが同じものを指しているかどうかは、文字列を見比べるしかありません。
エッジは見れば分かるのに。

状態を持つノードは `Feedback` だけで、その値は**そのノードの出力ポートからエッジで**
受け取ります。名前は表示のためだけのもので、どこにも一致を求めません。**状態の
同一性はノードそのもの**です。同じ名前の Feedback を2つ置けば、それは2つの別々の
状態です。

## 状態はグローバルにある

Feedback と Input はモジュールのグローバルで、`state_<名前>` としてエクスポート
されます。ホストはそれを読んで**いまグラフが何を持っているか**を全部見られます
— プログラムがそれを報告する必要はありません。Run パネルの State 表がそれです。

`Input` は走らせる前に書き込まれる、読み取り専用のグローバルです。**ノードを置いた
時点で**パネルに箱が出ます — まだどこにも配線していなくても、訊くこと自体がこの
ノードの用件だからです。既定値はグローバルの初期値としてモジュールにも入るので、
何も書き込まないホストでも描いたときの数で動きます。

## 文字列と真偽値

数でないものは2つあります。

**真偽値**は比較や `and` が作り、`Choose` と `Feedback` が受け取ります。そのまま
書くのが `Yes or No` です。`Choose` と `Feedback` は数と真偽のどちらを扱うかを
ノード側で選びます。

**文字列は意図的に薄い**です。`Text` がリテラルを持ち、`Say` がそれをホストに渡す。
それだけで、**繋げることも切ることもできません。** グラフの中に文字列を組み立てる
ための記憶領域が無いからです。リテラルはコンパイル時にモジュールのメモリへ順に
置かれ、`env.say(ptr, len)` はその一部を指します。メモリはエクスポートされるので、
ホストは渡された範囲を読み出せます。

```
$ ferretc --emit ir examples/blink.json
(global on bool)
(func main (result f64)
  (local on_next bool)
  (log (float (select on 1 0)))
  (say "blink")
  (set on_next (not on))
  (set on on_next)
  (return 0))
```

```wat
(memory (export "memory") 1)
(data (i32.const 0) "blink")
…
i32.const 0
i32.const 5
call $say
```

型の格子（[2章](types.md)）に文字列は入りません。式が文字列を作ることはないので、
`text` のポートは配線をたどってリテラルに解決されるだけです。

## 断るグラフ

cook の中でグラフは非巡回です。Feedback を通らない輪は値を持てないので、それを
閉じたノードのところで断ります。

```
  add: this node's value depends on itself
```

型が合わない場所も同じところで出ます。数を要求するポートに真偽を挿す、`Say` に
数を挿す、真偽を持つ Feedback に数を与える — どれもノードを名指しして断ります。

```
  sum: the a input wants a number but is given a true or false
  n: a const node does not make text
```

## 型は2つだけ

値はすべて数で、条件だけが真偽値です。混ぜようとすると型検査が止めます。

数の内部が i64 と f64 に分かれているのは[2章](types.md)の話で、グラフの上では見え
ません。

## ファイル形式

グラフは React Flow の保存形式そのままです。ノードの `type` がノードの種類で、
エッジの `sourceHandle` / `targetHandle` がポート名です。変換層はありません。

```json
{"id":"held","type":"feedback","position":{"x":380,"y":0},
 "data":{"name":"count","holds":"number","start":0}}
```

`values` が、ポートに直接打ち込まれた数です。エディタが保存するファイルは、そのまま
`ferretc` が受け取るファイルです。

次は[1章 グラフから IR へ](lower.md)。
