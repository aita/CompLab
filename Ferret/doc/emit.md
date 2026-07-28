# 3. バイト列を手で書く — `wasm.ml` / `emit.ml` / `wat.ml`

アセンブラも wabt も使いません。IR から `\0asm` で始まるバイト列を直接組み立てます。
この処理系の眼目はここで、他はそのための下ごしらえと言ってもいい部分です。

## 出来上がるもの

`examples/sum.json` は 160 バイトになります。中身の内訳:

```
  magic + version       8 バイト
  section 1 (type)     21 バイト
  section 2 (import)   59 バイト
  section 3 (function)  4 バイト
  section 7 (export)   10 バイト
  section 10 (code)    58 バイト
  total               160 バイト
```

インポートが5本（`env.log` / `env.random` / `env.watch` / `env.now` /
`env.wait`）あるので、**import セクションがコードより大きい**。メモリもテーブルも
グローバルもありません。エクスポートは `main` ひとつで、**引数は取りません。**

## バイナリライタ

`wasm.ml` はフォーマットのうち、必要な分だけを書けるようにした 201 行です。
リロケーションはありません。**各パートの長さは、そのパートを書き終えた時点で確定
する**ので、Buffer に書いてから長さを前置するだけで済みます。

```ocaml
let section (out : buf) id (contents : buf) =
  u8 out id;
  uleb out (Buffer.length contents);
  Buffer.add_buffer out contents
```

LEB128 は素直に:

```ocaml
let rec uleb (b : buf) n =
  let x = n land 0x7f and rest = n lsr 7 in
  if rest = 0 then u8 b x
  else (
    u8 b (x lor 0x80);
    uleb b rest)
```

符号付きは終了条件が違います。最上位に残った符号ビットを見る形です。

```ocaml
let rec sleb (b : buf) n =
  let x = n land 0x7f and rest = n asr 7 in
  if (rest = 0 && x land 0x40 = 0) || (rest = -1 && x land 0x40 <> 0) then u8 b x
  else (
    u8 b (x lor 0x80);
    sleb b rest)
```

f64 は LEB ではなく、`Int64.bits_of_float` の8バイトをそのまま並べます。**これが
`f64.const` が9バイトで `i64.const` が2バイトになる理由**です（[2章](types.md)）。

## 制御フローはそのまま入れ子になる

wasm には goto がなく、`block` / `loop` / `br` が入れ子になります。[0章](graph.md)で
見たとおり実行エッジは1本の鎖なので、IR の時点ですでに入れ子になっており、組み直す
仕事がありません。ループはこう出ます。

```
block
  loop
    …前置ブロック…
    …条件…
    i32.eqz
    br_if 1      ← 条件が偽なら block を抜ける
    …本体…
    br 0         ← loop の先頭へ
  end
end
```

`br` の深さは相対で、`1` が外側の `block`、`0` が `loop` 自身です。

## 命令選択

型は木から読めるので（[2章](types.md)）、選択は左辺の型を見るだけです。

```ocaml
let binop_code t = function
  | Add -> if t = VInt then Wasm.i64_add else Wasm.f64_add
  …
  | Div -> Wasm.f64_div
  | Mod -> Wasm.i64_rem_s (* the float case is expanded before this *)
```

wasm に無い演算は展開します。

| 書きたいもの | 出るもの | スクラッチ |
|---|---|---|
| `x % y`（f64） | `x - trunc(x / y) * y` | 2本 |
| `x % y`（i64） | `i64.rem_s` | 0本 |
| `-x`（i64） | `0 - x` | 0本 |
| `abs x`（i64） | `select(-x, x, x < 0)` | 1本 |
| `random(lo, hi)` | `lo + random() * (hi - lo)` | `lo` が原子でなければ1本 |

スクラッチローカルは、式が要求する型と順序をあらかじめ数えておき、生成時に同じ順で
取ります。

```ocaml
(* The scratch an expression needs, in the order it will be taken *)
let rec scratch_of_expr ty = function
  | Bin (Mod, l, r) ->
      (if ty l = VFloat then [ VFloat; VFloat ] else [])
      @ scratch_of_expr ty l @ scratch_of_expr ty r
```

数える順と取る順が同じなので、宣言したローカルと使うローカルがずれません。

## ローカルの並び

パラメータ、変数、スクラッチの順です。フォーマットは同じ型の連続を1エントリで
書くことを求めるので、run-length に畳みます。

```ocaml
let runs types =
  List.rev
    (List.fold_left
       (fun acc t ->
         let v = wasm_type t in
         match acc with
         | (n, u) :: tl when u = v -> (n + 1, u) :: tl
         | _ -> (1, v) :: acc)
       [] types)
```

## テキストも同じ順で出す

`wat.ml` は `emit.ml` と**同じ命令列を同じ順でテキストにします**。折り畳んだ S 式では
なく、1行1命令です。バイナリと読み比べられるようにするためで、エディタの Code タブは
これを出しています。

```wat
(module
  (import "env" "log" (func $log (param f64)))
  (import "env" "random" (func $random (result f64)))
  (import "env" "watch" (func $watch (param i32) (param f64) (result f64)))
  (import "env" "now" (func $now (result f64)))
  (import "env" "wait" (func $wait (result f64)))
  (func $main (export "main") (result f64)
    (local $total i64)
    (local $i i64)
    i64.const 0
    local.set $total
    i64.const 1
    local.set $i
    loop  ;; $1
      local.get $i
      i64.const 100
      i64.le_s
      if
        local.get $total
        local.get $i
        i64.add
        local.set $total
        local.get $i
        i64.const 1
        i64.add
        local.set $i
        br 1  ;; $1
      else
        local.get $total
        f64.convert_i64_s
        return
      end
    end
    f64.const 0.0
  )
)
```

2つの出力器を別々に持つ以上、ずれる余地はあります。そこを縛っているのが
`compiler/test/` の wat スナップショットと、生成したモジュールを node で実際に走らせる
テストの両方です。

## 関数が1つしかないこと

このモジュールには関数が1つしかありません。だから再帰も呼び出しもなく、function
セクションは2バイトです。値はすべて数なので、配列も文字列もメモリも要りません。

最適化器もありません。emit は IR を素直に1回歩くだけなので、`x + 0` はそのまま
バイト列に残ります。[1章](lower.md)の共有だけが例外で、あれは最適化というより
**それが無いと使い物にならない**種類の処理です。

次は[4章 止まるデバッガ](debug.md)。
