# 10. LLVM の呼び方 — テキストを書いて渡す

この章はコード生成の話をひとつもしません。その前に決めなければならないこと —
**LLVM に何をどう渡すか** — だけの章です。

| | |
|---|---|
| LLVM IR | LLVM の中間表現。ビットコード・メモリ上の C++ の木・テキストの3つの姿を持つ |
| `.ll` | LLVM IR のテキストの姿。人が読める |
| LLVM-C API | LLVM が公開している C の ABI。木をメモリ上で組み立てる |
| ドライバ | `clang`。ソースでも `.ll` でも受け取って、最適化・命令選択・アセンブル・リンクを段取りする |
| verifier | LLVM の検査。支配・φ の数・`musttail` の形を見る |

## 1. 道は3つある

**ライブラリにリンクする。** `libLLVM.so` に対して `LLVMBuildAdd` を呼び、木をメモリ上に
作る。速く、検査がプロセス内にあり、そのかわり不透明ポインタの束と、シンボルになって
いない列挙の値を自分で持つことになります。

**公式のバインディングを使う。** LLVM のソースツリーには `llvm/bindings/ocaml` があり、
opam の `llvm` パッケージとして出ています。これが公式です。

**テキストを書いて、LLVM のコマンドラインに渡す。** `.ll` を組み立てて `clang` に食わせ、
そこから先は全部向こうにやってもらう。

この処理系は3つ目です。理由は順に見ます。

## 2. 公式のバインディングは使えない

好き嫌いの話ではなく、3つとも事実です。

**opam の `llvm` は 19 で止まっています。** 出ているのは `llvm.18-shared` と
`llvm.19-shared`／`19-static` までです。

**この機械の LLVM は 22 です。** そして Arch のリポジトリには llvm18・llvm20・llvm21・
llvm22 はあっても **19 がありません**。`llvm.19-shared` は `conf-llvm-shared = 19` を
要求するので、19 をソースから建てない限り入りません。

**開発パッケージが入っていません。** `libLLVM.so` はありますが、ヘッダも
`llvm-config` もない。公式バインディングは `llvm-config` を見て建つので、まず
`pacman -S llvm18` からになります。

つまり公式を使う道は「システムの LLVM 22 とは別に LLVM 18 を入れて、そちらに固定する」
であって、「LLVM を使う」ではありません。

## 3. ライブラリでもなく、テキスト

ヘッダなしで `libLLVM.so` に直接リンクすることもできます — LLVM-C は C の ABI なので、
使う関数の `extern` 宣言を自分で書けば `#include` は要りません。それでも建ちますし、
検査もプロセス内に残ります。

選ばなかったのは、**その道で自分の責任になるものが2つあるから**です。

**列挙の値。** `LLVMBuildICmp` の第2引数の `40` が `slt` であることは、リンカには
分かりません。`LLVMIntPredicate` が 32 から始まるのは、それが
`llvm::CmpInst::Predicate` の続き（0..15 が浮動小数の比較）だからで、その事実を
コンパイラの中に書き写して持つことになります。テキストなら `slt` と書きます。

**C API に無いもの。** `dso_local` がその例です。これは IR 上の印で、付いていないと
LLVM はシンボルが実行時に差し替えられるかもしれないと考え、静的リンクの実行ファイルでも
PLT と GOT を書きます。そして LLVM-C に `LLVMSetDSOLocal` はありません。
`LLVMSetVisibility` で `hidden` にすると `GlobalValue::maybeSetDsoLocal` が横から
立ててくれる、という経路を通すことになります。テキストなら `dso_local` と書きます。

```llvm
@skunk_true_blk = external dso_local global i64
declare dso_local i64 @skunk_alloc(i64, i64)
```

これがあるかないかで、

```
callq	skunk_lt@PLT
movq	skunk_true_blk@GOTPCREL(%rip), %rax
```

が

```
callq	skunk_lt
cmpq	$skunk_true_blk+8, %rax
```

になります。静的リンクなので `dso_local` は嘘ではありません — このプログラムの中に
あるものは、全部このプログラムの中にあります。

## 4. 依存は `clang` ひとつ

`.ll` を渡す先は `clang` です。LLVM のドライバで、入力が `.ll` でも受け取ります。

```sh
clang -O2 -fno-pic -fno-pie -mcmodel=small -Wno-override-module -c prog.ll -o prog.o
clang -nostdlib -static -o prog prog.o runtime.o
```

1行目が `opt` と `llc` の2段を1回でやっています。`-O2` がパスパイプライン、
`-fno-pic` が静的な再配置モデル、`-mcmodel=small` がコードモデル — 後ろ2つが
「グローバルの番地は即値、呼び出しは直接呼び出し」を決めます。`-c` はオブジェクトで
止まるという意味です。

`llc` と `opt` があるなら、同じことを2段で書けます。

```sh
opt -passes='default<O2>' prog.ll -o prog.bc
llc -filetype=obj -relocation-model=static -code-model=small prog.bc -o prog.o
```

この機械には入っていません（`llvm` パッケージが未導入で、`clang` だけがある）ので、
`emit.ml` は `clang` を呼びます。どちらでも出るものは同じです。

**検査は clang の中で走ります。** `.ll` を読むということは parser と verifier を通す
ということなので、支配も φ の数も `musttail` の形も、そこで見られています。壊れた
モジュールを書けば clang が行番号付きで文句を言い、`emit.ml` はそのとき **`.ll` を
消さずに残して場所を言います**。

```ocaml
let run ~keep cmd =
  if Sys.command cmd <> 0 then begin
    (match keep with
    | Some path -> Printf.eprintf "skunkllvm: the module that failed is in %s\n" path
    | None -> ());
    Loc.fail ~where:"error" Loc.unknown "clang failed"
  end
```

## 5. テキストで面倒なのは名前

テキストにすると消える面倒が2つあり、増える面倒が1つあります。増えるほうが**名前**です。

LLVM IR では、名前を付けなかった値は番号になります。そして番号は**LLVM が振ったのと
同じ順**でなければなりません — 引数が番号を消費し、名前のない基本ブロックも消費する。
規則に角がいくつもあり、1つずれると parser が「値 %17 がない」と言います。

だから `ir.ml` は**何にも番号を任せません**。

```
%_0 = inttoptr i64 %arg to ptr
%_1 = getelementptr i8, ptr %_0, i64 -8
```

一時変数は `%_0`、`%_1`。プログラムから来た名前は引用符で囲んでそのまま使います。

```
"join.k":
  %"v" = phi i64 [ %_4, %"arm" ], [ %_6, %"arm.0" ], [ %_8, %"default" ]
```

引用符の中は何でも書けるので、`t.60` も `pick$1` も `arm.2` も、front end が作った形の
まま出ます。衝突は**関数ごとに1つの表**が防ぎます。

```ocaml
let unique f base =
  let rec go candidate n =
    if Hashtbl.mem f.taken candidate then go (Printf.sprintf "%s.%d" base n) (n + 1)
    else begin
      Hashtbl.replace f.taken candidate ();
      candidate
    end
  in
  go base 0
```

表が**1つ**なのには理由があります。LLVM では**基本ブロックのラベルと局所値が同じ名前空間**
にいます。`arm` という名前のブロックと `arm` という名前の値は共存できません。だから
ラベルも同じ表を通ります。上の `arm.0` は2つ目の腕で、`.0` はこの表が付けたものです。

## 6. φ はあとから埋まる

消えない面倒がもう1つ、**φ の incoming は行を印字したあとに決まる**ことです。join point
への jump は継続の側にあり、継続は φ ができたあとに下ろされます
（[11章](11-lower.md)の1節）。テキストは一度書いたら書き換えられません。

だから `ir.ml` はブロックを**溜めます**。

```ocaml
type block = {
  label : string;
  mutable phis : phi list;
  body : Buffer.t;
  mutable term : string;
}
```

φ は「値と出どころの組」を足せるレコードで、命令はバッファに積まれ、終端命令は1つの
文字列です。関数が終わったときに、ラベル・φ・本体・終端の順で描画されます。

これは LLVM のビルダが持っている形と**同じ**で、同じ理由でそうなっています。テキストに
したから増えた仕事ではなく、SSA を前から順に書き下すことができない、というだけの話です。

## 7. 出るもの

`--emit-llvm -O0` は `ir.ml` が書いたものをそのまま印字します。LLVM は動きません。

`--emit-llvm`（最適化あり）は clang に `-S -emit-llvm` で読み書きさせるので、
`-O2` が何をしたかが2つを並べれば見えます。`-S` はアセンブリ、`-c` はオブジェクト、
既定は実行ファイルで、どれも同じ1回の `clang` の呼び出しの `mode` が違うだけです。

```ocaml
let object_file ~ll ~out ~level = stage ~ll ~out ~level ~mode:"-c"
let assembly ~ll ~out ~level = stage ~ll ~out ~level ~mode:"-S"
let optimised_ir ~ll ~out ~level = stage ~ll ~out ~level ~mode:"-S -emit-llvm"
```

## 8. していないこと

- **`target triple` も `target datalayout` も書いていません。** 書けば `.ll` は
  その機械のものになります。書かないので clang が補い、`-Wno-override-module` は
  そのことを黙らせるためです。テキストが機械に縛られないほうが、読み物としても
  他の LLVM に渡すときにも都合がよいと判断しました。
- **ビットコードを出していません。** `.ll` のテキストだけです。バイナリのほうが速く
  読めますが、この規模で測れる差ではなく、読めなくなる代償のほうが大きい。
- **JIT がありません。** 出るのはファイルです。
- **メタデータもデバッグ情報もありません。** 行番号は `Loc` が持っていて、それが実行時に
  出るのは match 失敗のときだけです。
- **`opt` と `llc` を探していません。** `emit.ml` は `clang` と書いてあります。2段に
  分けたいなら4節のコマンドをそのまま置き換えれば済みますが、この機械に入っていない
  ものを既定にはしませんでした。

---

[← 9. 言語リファレンス](09-language.md) ・ [11. Flat から LLVM IR へ →](11-lower.md)
