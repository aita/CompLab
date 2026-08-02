# 0. 1つの `.wat` がトラップに着くまで

この章は道案内です。1つの小さなモジュールが、文字列から結果まで通り抜ける道筋を、
部品1つずつ1段落で追います。それぞれの段落が以降の1章に対応します。

題材はこれです。ユークリッドの互除法。

```wasm
(module
  (func $gcd (export "gcd") (param $a i32) (param $b i32) (result i32)
    (local $t i32)
    (block $done
      (loop $again
        (br_if $done (i32.eqz (local.get $b)))
        (local.set $t (i32.rem_u (local.get $a) (local.get $b)))
        (local.set $a (local.get $b))
        (local.set $b (local.get $t))
        (br $again)))
    (local.get $a)))
```

## 0.1 2つの入口

wasm には形式が2つあります。バイト列と、S式のテキストです。同じ言語の2つの綴りで、
`wat2wasm` はテキストをバイト列に変換します。

```
$ wat2wasm gcd.wat -o gcd.wasm && xxd gcd.wasm
00000000: 0061 736d 0100 0000 0107 0160 027f 7f01  .asm.......`....
00000010: 7f03 0201 0007 0701 0367 6364 0000 0a24  .........gcd...$
00000020: 0122 0101 7f02 4003 4020 0145 0d01 2000  ."....@.@ .E.. .
00000030: 2001 7021 0220 0121 0020 0221 010c 000b   .p!. .!. .!....
00000040: 0b20 000b                                . ..
```

68バイト。`\0asm` とバージョン `1` のあと、セクションが並びます。`01 07` は型セクションが
7バイト、`03 02` は関数セクションが2バイト、`07 07` は輸出セクションが7バイト、`0a 24` は
コードセクションが36バイト。そのコードセクションの中は `01`（本体1つ）、`22`（この本体は
34バイト）、`01 01 7f`（局所変数は「i32 が1つ」の組が1つ）と続き、そこから最後の `0b` まで
が命令です。`02 40` が `block`（結果なし）、`03 40` が `loop`、`0d 01` が `br_if 1`、
`0c 00` が `br 0`。

Weasel はこのどちらからも読みます。ファイルが `\0asm` で始まればバイナリ、そうでなければ
テキストと見なす — 拡張子は見ません（`weasel.cppm:24`）。

読んだ結果は同じ型 `Module` です。それが大事な点で、**どちらの入口から入っても構造は
1文字も違ってはいけない**。テストはそれを毎回確かめます。

```
$ weasel dump gcd.wasm
(module
  (type 0 (func (param i32 i32) (result i32)))
  (export "gcd" (func 0))
  (func 0 (type 0) (local i32)
    block
      loop
        local.get 1
        i32.eqz
        br_if 1
        local.get 0
        local.get 1
        i32.rem_u
        local.set 2
        local.get 1
        local.set 0
        local.get 2
        local.set 1
        br 0
      end
    end
    local.get 0
  end
  )
)
```

名前が消えています。`$a` は `local 0`、`$done` は `br_if 1` の `1` に、`$again` は
`br 0` の `0` になりました。**wasm に名前はありません**。あるのは添字です。テキスト形式の
`$名前` はパーサの中だけの話で（[2章](02-text.md)）、バイナリ形式には最初から番号しか
ありません（[1章](01-binary.md)）。

`br_if 1` の `1` は「1つ外側のラベルへ」という意味です。位置ではありません。ここが
次の段落の主題です。

## 0.2 型がつくと、位置が決まる

検証は、関数の本体を頭から1回走査して、オペランドスタックの型を追います。`local.get 1`
なら i32 を積む、`i32.rem_u` なら i32 を2つ降ろして1つ積む。それだけです。

ただしこの走査は、型のほかに**2つの数**を持ち歩いています。今のスタックの高さと、
囲んでいる各ラベルが「そこに戻ってきたときのスタックの高さ」です。仕様が型検査を
定義するために必要としたその2つが、そのまま実行時に分岐が必要とする2つです。

だから検証器はその場で計画を書き出します。

```
$ weasel plan gcd.wat
func[0] : (i32 i32) -> (i32)
  locals i32
  max operand stack 2
     0  local.get 1
     1  i32.eqz
     2  br_if -> 12 keep=0 height=0
     3  local.get 0
     4  local.get 1
     5  i32.rem_u
     6  local.set 2
     7  local.get 1
     8  local.set 0
     9  local.get 2
    10  local.set 1
    11  br -> 0 keep=0 height=0
    12  local.get 0
    13  return
```

`block` と `loop` と `end` が消えました。**この4つの命令は実行時には何も生みません**。
`br_if 1` は `br_if -> 12 keep=0 height=0` になりました。飛び先は12、運ぶ値は0個、
飛び先でのスタックの高さは0。`br 0` は `-> 0`、ループの先頭です。

`loop` への分岐は後ろ向きなので、ラベルを開いた瞬間に飛び先が分かります。`block` への
分岐は前向きなので、`end` に着いたときに埋めます。後埋めはこの処理系にただ1か所、
`Validator::resolve` にしかありません（[4章](04-plan.md)）。

`max operand stack 2` も同じ走査の副産物です。スタックの最大の高さが分かっているので、
実行前に領域を確保できます。

## 0.3 モジュールは、まだ何でもない

計画ができても、まだ動きません。「メモリ1ページ」と書いてあるのは説明であって、
ページではないからです。

インスタンス化がその境目です。輸入を名前で解決し、メモリ・表・大域変数を作り、
データ・要素セグメントを写し、`start` があれば呼ぶ。仕様はここで3つを分けます。

- **モジュール** — 読んだもの。不変。
- **ストア** — 走っている世界の状態。メモリの中身も表の中身もここにある。
- **インスタンス** — その間の対応表。「このモジュールの表0はストアの表3」。

だから `funcref` はモジュールの関数添字ではなく**ストアの番地**です。そうでなければ
関数参照をインスタンスの外に渡せません（[5章](05-instantiate.md)）。

この `gcd` は何も輸入せず、メモリも表も持たないので、インスタンス化はほとんど何も
しません。それでも `Store` と `Instance` はできます。

## 0.4 走らせる

機械のデータは `std::vector<Value>` 1本です。フレームは領域ではなく、その1本の中の
印です。

```
... 呼び出し側のオペランド | a b | t | この関数のオペランド ...
                          ^locals_base   ^stack_base
```

呼び出しは何も確保しません。引数はもうスタックに積まれているので、呼ばれた関数は
「その位置から先は自分の局所変数だ」と宣言し、自分で宣言した局所変数の分だけ0を積み、
その上を自分のオペランドスタックにします。

分岐は3つの数を写すだけです。上から `keep` 個の値を `stack_base + height` へ移し、
プログラムカウンタを `pc` にする。ラベルを探すことは一度もありません。**ラベルが無い**
からです。

```
$ weasel run gcd.wat --invoke gcd --arg 12 --arg 8 --trace
   0 local.get 1              |
   1 i32.eqz                  | 0x8
   2 br_if -> 12 keep=0 height=0 | 0x0
   3 local.get 0              |
   4 local.get 1              | 0xc
   5 i32.rem_u                | 0xc 0x8
   6 local.set 2              | 0x4
   7 local.get 1              |
   8 local.set 0              | 0x8
   9 local.get 2              |
  10 local.set 1              | 0x4
  11 br -> 0 keep=0 height=0  |
   0 local.get 1              |
   ...
```

`|` の右はその命令を**実行する前**のオペランドスタックです。3周して `b` が0になり、
`br_if` が12へ飛び、`local.get 0` が答えを積んで `return` します（[6章](06-exec.md)）。

`return` は特別扱いされていません。関数そのものが一番外側のラベルなので、
`return` は「一番外へ `br`」として計画されます。上の一覧の最後の `return` は、
その飛び先として置かれた1命令です。

## 0.5 止まるとき

wasm が止まる理由は決まっています。0除算、境界外アクセス、NaN の整数化、
`call_indirect` の型不一致、`unreachable`。これらは**トラップ**で、プログラムからは
捕まえられません。

```
$ weasel run gcd.wat --invoke gcd --arg 1 --arg 0
1
$ echo '(module (func (export "f") (result i32) (i32.div_s (i32.const 1) (i32.const 0))))' > d.wat
$ weasel run d.wat --invoke f
weasel: trap: integer divide by zero
```

エラーが2種類あることに注意してください。**検証が拒む**もの（型が合わない、添字が範囲外、
到達不能でないのにスタックが足りない）と、**走ってから止まる**もの（トラップ）です。
どちらでもない第三のものが1つだけあります — インスタンス化の失敗です。データセグメントが
メモリに収まらないとき、それはモジュールの誤りですが、検証では分かりません。オフセットが
輸入された大域変数から来ることがあるからです（[5章](05-instantiate.md)）。

Weasel はこの2種類を型で分けています。`Diag` は走る前の失敗、`Trap` は走ってからの失敗。
どちらも例外を投げません。この処理系は `-fno-exceptions` で建ちます（`common.cppm:28`, `common.cppm:52`）。

## 0.6 外の世界

`gcd` は閉じたプログラムですが、たいていの wasm はそうではありません。文字を出したければ、
ホストの関数を輸入するしかない。

```wasm
(import "wasi_snapshot_preview1" "fd_write"
  (func $fd_write (param i32 i32 i32 i32) (result i32)))
```

これで全部です。WASI に特別なところは何もなく、名前が決まっているホスト関数の集まり
でしかありません。引数はすべて32ビットか64ビットなので、構造体は**呼び出し側の線形メモリ
への番地**として渡ります。`fd_write` の第2引数は `(番地, 長さ)` の組の配列の番地で、
第4引数は「書けたバイト数を書き込む先」の番地です（[9章](09-host.md)）。

```
$ weasel run examples/sieve.wat | tr '\n' ' '
2 3 5 7 11 13 17 19 23 29 31 37 41 43 47 53 59 61 67 71 73 79 83 89 97 ...
```

---

## 参考文献

- **WebAssembly Core Specification**, W3C. 実装はここに書いてあることをそのまま
  やっています。とくに Appendix の「Validation Algorithm」は3章と4章の骨格です。
- Andreas Haas et al., *Bringing the Web up to Speed with WebAssembly*, PLDI 2017.
  なぜ構造化制御フローなのか、なぜ型検査が線形時間なのかが設計側から書かれています。
- **WebAssembly Specification Interpreter** (OCaml)。仕様の実行可能な形。迷ったら
  これが答えです。

## 実装の地図

| 場所 | 何があるか |
|---|---|
| `src/weasel.cppm:24` | `looks_binary` — 入口を選ぶ1行 |
| `src/weasel.cppm:31` | `load` — 読んで検証するまで |
| `src/main.cpp:116` | `check` / `dump` / `plan` / `run` の分岐 |
| `src/common.cppm:28` | `Diag` — 走る前の失敗 |
| `src/common.cppm:52` | `Trap` — 走ってからの失敗 |

---

[← 目次](index.md) · [1. バイナリ形式 →](01-binary.md)
