# 7. 木を歩く — `interp.cppm` ／ `interp.ml`

評価器は素直な再帰の走査です。面白いところは3つあります。**制御フローが例外ではなく
戻り値であること。閉包が「ブロックに入るとき」に作られること。ポインタの取り扱いが
[6章](06-values.md)の `place` に分かれていること。**

## 1. 文は「どう終わったか」を返す

```cpp
// 文がどう終わったか。投げるのではなく返すことで、ループの中の `return` の代価が
// 比較1回で済む。
enum class Flow { Normal, Break, Continue, Return };
```

OCaml 側は値を一緒に運びます。

```ocaml
type flow = Normal | Break | Continue | Return of value
```

C++ 側は `Value returnValue_` というメンバに置きます。**この差が[8章](08-gc.md)に
効きます**（収集器から見えるように、根の走査に `returnValue_` を含める必要がある）。

ブロックは最初の非 `Normal` で抜けます。

```cpp
Flow executeAll(Block& block, Environment& scope) {
    makeNestedFunctions(block.statements, scope);
    for (const StmtPtr& entry : block.statements) {
        Flow flow = execute(*entry, scope);
        if (flow != Flow::Normal) { return flow; }
    }
    return Flow::Normal;
}
```

ループは `Break` を食べ、`Return` を通します。`Continue` は明示的に扱われません。

```cpp
while (evaluate(*node.condition, scope).as<bool>()) {
    Flow flow = execute(*node.body, scope);
    if (flow == Flow::Break) { break; }
    if (flow == Flow::Return) { return flow; }
}
```

**`Continue` はここに落ちてきて、何もされずに次の反復に進みます。** `for` では
それが効きます。

```cpp
if (flow == Flow::Break) { break; }
if (flow == Flow::Return) { return flow; }
// `continue` もここに来るので、歩進は必ず走る。
if (node.step != nullptr) { evaluate(*node.step, *held.get()); }
```

**`continue` が歩進を飛ばさない**のは、この2行の並びだけで実現されています。だから
`for` は必ず前に進みます。

```
$ cat flow.otter
fun sum_to(limit: int) -> int {
    var total: int = 0;
    for (var i: int = 0; i < limit; i = i + 1) {
        if (i % 2 == 0) { continue; }      // 歩進は飛ばされない
        if (i > 7) { return total; }       // ループの中からでも返る
        total = total + i;
    }
    return 0 - 1;
}

$ ./interpreter/build/otter flow.otter
loop    16
```

16 は 1+3+5+7。`i` が 9 のとき `return` して抜けています。

## 2. スコープは木、探索は外向き

ブロックに入ると環境が1つできて、親を指します。

```cpp
case StmtKind::Block: {
    auto* inner = heap_.allocate<Environment>();
    RootObject<Environment> held(heap_, inner);
    held->parent = &scope;
    return executeAll(block, *held.get());
}
```

`for` も自分の環境を持ちます。初期化子が宣言したものはループのものだからです。

呼び出しのときだけ、親が**呼び出し元ではなく閉包が持っているもの**になります。

```cpp
auto* frame = heap_.allocate<Environment>();
RootObject<Environment> heldFrame(heap_, frame);
heldFrame->parent = heldCallee.get().as<Closure*>()->environment;
```

**これが静的スコープの全文です。** 呼び出し元のスコープはどこにも現れません。

名前の探索は外へ向かいます。

```cpp
Cell* find(const std::string& name) {
    for (Environment* scope = this; scope != nullptr; scope = scope->parent) {
        auto entry = scope->slots.find(name);
        if (entry != scope->slots.end()) { return entry->second; }
    }
    return nullptr;
}
```

## 3. 閉包はブロックに入るときに作られる

```cpp
// ブロックの中で宣言された関数は、ブロックに入るときに、そのブロックが走っている
// スコープの上で閉包になる。2つが互いを呼べるように。
void makeNestedFunctions(const std::vector<StmtPtr>& statements, Environment& scope) {
    for (const StmtPtr& entry : statements) {
        if (entry->kind != StmtKind::NestedFunction) { continue; }
        auto& node = static_cast<NestedFunctionStmt&>(*entry);
        auto* closure = heap_.allocate<Closure>();
        RootObject<Closure> held(heap_, closure);
        held->definition = node.definition.get();
        held->environment = &scope;
        define(scope, node.definition->name, Value(held.get()));
    }
}
```

そして宣言の文そのものは何もしません。

```cpp
case StmtKind::NestedFunction:
    // 閉包はブロックに入るときに作られているので、宣言より上に書かれた呼び出しでも
    // 見つかる。
    return Flow::Normal;
```

**閉包が指す環境は、宣言を含むブロックのスコープそのものです。** 自分もその中に
定義されているので、自分自身も、隣の関数も見えます。

```
    fun even(n: int) -> bool { if (n == 0) { return true; } return odd(n - 1); }
    fun odd(n: int) -> bool { if (n == 0) { return false; } return even(n - 1); }
    io.println("mutual  " + str.from_bool(even(10)) + " " + str.from_bool(odd(10)));
...
mutual  true false
```

[4章](04-check.md)の `declareNestedFunctions` と対になっています。**検査でも実行でも
「ブロックに入るときに登録する」ので、上で呼んでも型が見つかり、値も見つかります。**

無名関数はその場で作られます。

```cpp
case ExprKind::Function: {
    auto& node = static_cast<FunctionExpr&>(expr);
    auto* closure = heap_.allocate<Closure>();
    closure->definition = node.definition.get();
    closure->environment = &scope;
    return Value(closure);
}
```

閉包が捉えるのは**変数そのもの**です。スコープを指しているだけなので、変数のセルは
共有されます。

```
    var count: int = 0;
    var bump: fun() -> void = fun() -> void { count = count + 1; return; };
    bump(); bump(); bump();
...
closure 3
```

トップレベルの関数だけは親を持ちません。

```cpp
// トップレベルの名前つき関数は何も捉えないので、宣言1つにつき閉包1つで足りる。
Value functionValue(const FunctionDecl* declaration) {
    auto entry = functions_.find(declaration);
    if (entry == functions_.end()) {
        auto* closure = heap_.allocate<Closure>();
        closure->definition = declaration->definition.get();
        entry = functions_.emplace(declaration, closure).first;
    }
    return Value(entry->second);
}
```

だから `io.println` を10回書いても閉包は1つで、`==` で比べれば同じもの——ですが、
関数の比較は検査器が拒みます（[6章](06-values.md)）。

## 4. 呼び出し

```cpp
Value call(const Value& callee, std::vector<Value>& arguments, const Span& span) {
    Root heldCallee(heap_, callee);
    Closure* closure = heldCallee.get().as<Closure*>();
    const FunctionDefinition& definition = *closure->definition;

    if (definition.body == nullptr) { return callNative(definition, arguments, span); }

    if (++depth_ > callDepthLimit) { --depth_; throw RuntimeError(span, ...); }
    ...
    for (std::size_t index = 0; index < definition.parameters.size(); ++index) {
        define(*heldFrame.get(), definition.parameters[index].name,
               copyOf(heap_, arguments[index]));
    }

    Value returned;
    Flow flow = execute(*definition.body, *heldFrame.get());
    if (flow == Flow::Return) { returned = returnValue_; returnValue_ = Value(); }
    --depth_;
    return returned;
}
```

**本体があるかどうかの1つの分岐が、ホスト関数と普通の関数を分ける全部です**
（[9章](09-host.md)）。

引数は `copyOf` を通ります。struct は写され、配列は分かち合われます。

深さの上限はスタック溢れの代わりです。

```cpp
// 走りっぱなしの再帰を、C++ のスタックが尽きる前に捕まえるだけの深さ。
inline constexpr int callDepthLimit = 2000;
```

```
$ cat deep.otter                  down(1998) と down(1999)
$ ./interpreter/build/otter deep.otter
1998
otter: deep.otter:10:16: more than 2000 nested calls; this looks like a recursion that
never ends
$ ./ocaml/_build/default/bin/otter.exe deep.otter
1998
otter: deep.otter:10:16: more than 2000 nested calls; this looks like a recursion that
never ends
```

**同じ数で止まります。** 2000 は両方の `interp` に定数として書かれていて、実際の
スタックの余裕とは関係ありません。だから OCaml 側（ヒープ上のスタックを持ち、
はるかに深く潜れる）も同じところで止まります。

## 5. 値ブロックは分岐を持たない

```cpp
// 値ブロックからは飛び出せないので、文は最後まで走り、ブロックの式が答えになる。
Value evaluateConditional(IfExpr& expr, Environment& scope) {
    bool taken = evaluate(*expr.condition, scope).as<bool>();
    ValueBlock& arm = taken ? *expr.consequent : *expr.alternative;
    ...
    makeNestedFunctions(arm.statements, *held.get());
    for (const StmtPtr& entry : arm.statements) { execute(*entry, *held.get()); }
    return evaluate(*arm.value, *held.get());
}
```

`execute` の戻り値を捨てているのは、[4章](04-check.md)の `rejectJumps` が
`Normal` 以外を返す文を禁じているからです。**検査器の仕事が、評価器のコードを
3行短くしています。**

## 6. `&&` と `||` は評価器の中で短絡する

```cpp
if (expr.op == BinaryOp::And) {
    return Value(evaluate(*expr.left, scope).as<bool>() &&
                 evaluate(*expr.right, scope).as<bool>());
}
```

C++ の `&&` に任せているので、左が偽なら右の `evaluate` は呼ばれません。

```
    trace = "";
    io.println("and     " + str.from_bool(note("f") && note("t")) + " [" + trace + "]");
...
and     false [f]
or      true [t]
```

`trace` に `f` しか積まれていないので、右辺は評価されていません。

## 7. 整数は巻き戻る、そして型ごとに幅が違う

```cpp
Value integerOperation(BinaryExpr& expr, std::int64_t left, std::int64_t right) {
    auto wrapping = [](std::int64_t a, std::int64_t b, auto op) {
        return static_cast<std::int64_t>(
            op(static_cast<std::uint64_t>(a), static_cast<std::uint64_t>(b)));
    };
    switch (expr.op) {
        case BinaryOp::Add:
            return integerValue(wrapping(left, right, std::plus<std::uint64_t>{}), expr.type);
```

**符号なしで計算して符号ありに戻す**のは、C++ の符号付き整数の桁あふれが未定義だから
です。`integerValue` が結果の型で幅を切ります。

```cpp
static Value integerValue(std::int64_t value, const Type* type) {
    switch (type->kind) {
        case TypeKind::Byte: return Value(static_cast<std::uint8_t>(value));
        case TypeKind::Char: return Value(static_cast<char32_t>(value));
        default: return Value(value);
    }
}
```

```
    var big: int = 9223372036854775807;
    io.println("wrap    " + str.from_int(big + 1));
...
wrap    -9223372036854775808
```

割り算と剰余だけは0を弾きます。

```cpp
case BinaryOp::Divide:
    if (right == 0) { throw RuntimeError(expr.span, "division by zero"); }
```

`expr.type` と `expr.operandType` を使い分けているのがここです。比較の `type` は
`bool` なので、**何の型として比べるか**は `operandType` から来ます。

```cpp
const Type* operand = expr.operandType;
if (operand->kind == TypeKind::String) { return stringOperation(...); }
if (isFloating(operand)) { ... }
return integerOperation(expr, wholeNumberOf(left.get(), operand),
                        wholeNumberOf(right.get(), operand));
```

## 8. 実行時に起きうる誤りは5つ

```
$ ./interpreter/build/otter index_out_of_range.otter
otter: index_out_of_range.otter:5:12: index 3 lies outside a run of 3 element(s)
$ ./interpreter/build/otter null_pointer.otter
otter: null_pointer.otter:10:12: this pointer is null
$ ./interpreter/build/otter divide_by_zero.otter
otter: divide_by_zero.otter:5:12: division by zero
```

これに「負の長さの配列」と「2000段の呼び出し」が加わって5つです。言語仕様の
[Faults](language.md#faults) と同じ5つで、**それ以外はプログラムが始まる前に
決着しています**。

`otter: ` という接頭辞が付くのは実行時エラーだけです。`main.cpp` の catch が
2つに分かれていて、片方だけが付けます。

## していないこと

**変数を添字で引いていません。** 環境は名前つきの表で、探索は文字列比較です。
検査器はスコープの深さと位置を計算できる位置にいる（[4章](04-check.md)の
`scopes_` がそれ）ので、`NameExpr` に (深さ, 添字) を書き込めば表引きが消えます。
そうしないのは、この処理系が速さを目的にしていないからです。

**捕捉した変数を集めていません。** `FunctionDefinition::captures` という欄はあります
が、埋める道がありません。閉包はスコープの鎖をそのまま持ち、必要なときに歩きます。
捕捉を明示的に集めれば、閉包が保つスコープを小さくできます（[8章](08-gc.md)で
効きます）。

**末尾呼び出しの最適化がありません。** 深さの上限が2000なので、そもそも深く潜れません。

**`Continue` を関数の外へ漏らさない仕組みが検査器側にしかありません。** 評価器は
ループの外で `Continue` を受け取れば、それを `executeAll` が上へ返します。届く先が
ないので `call` が `Return` でないとして無視します。到達しない道です。

## 参考文献

- R. Nystrom, [*Crafting Interpreters*][ci] の "Functions" と "Closures"。
  閉包が環境の鎖を持つ形と、宣言をブロックの頭で登録する扱い。
- G. Steele, [*Debunking the "Expensive Procedure Call" Myth*][steele], 1977。
  制御フローを例外ではなく戻り値で運ぶ選択の対極にある議論。ここでは末尾呼び出しを
  していないので、この論の恩恵は受けていません。
- ISO/IEC 14882 の符号付き整数の桁あふれが未定義であること。7節の `wrapping` は
  それを避けるための書き方です。

[ci]: https://craftinginterpreters.com/functions.html
[steele]: https://dspace.mit.edu/handle/1721.1/5753

## 実装の地図

| C++ | |
|---|---|
| `interp.cppm` 15行 | `Flow` |
| `interp.cppm` 23行 | `callDepthLimit` |
| `interp.cppm` 44行 | `run` |
| `interp.cppm` 86行 | `call` — 本体の有無で分かれる |
| `interp.cppm` 139行 | `execute` |
| `interp.cppm` 198–210行 | `for` — `continue` が歩進を飛ばさない2行 |
| `interp.cppm` 236行 | `executeAll` |
| `interp.cppm` 250行 | `makeNestedFunctions` |
| `interp.cppm` 380行 | `evaluate` |
| `interp.cppm` 437行 | `evaluateConditional` — 分岐がない |
| `interp.cppm` 478行 | `functionValue` — 宣言1つにつき閉包1つ |
| `interp.cppm` 452行 | `integerValue` — 結果の型で幅を切る |
| `interp.cppm` 693行 | `evaluateBinary` — `operandType` で分ける |
| `interp.cppm` 767行 | `integerOperation` — 符号なしで巻き戻す |

| OCaml | |
|---|---|
| `interp.ml` 14行 | `flow` — `Return` が値を運ぶ |
| `interp.ml` 71行 | `call` |
| `interp.ml` 110行 | `run_block` |
| `interp.ml` 129行 | `make_nested_functions` |
| `interp.ml` 138行 | `execute` |
| `interp.ml` 163–190行 | `S_for` |
| `interp.ml` 269行 | `evaluate` |
| `interp.ml` 315行 | `evaluate_value_block` |
| `interp.ml` 333行 | `function_value` |
| `interp.ml` 487行 | `integer_operation` |

---

[← 6. 値](06-values.md) ／ [目次](index.md) ／ [8. 収集器と根 →](08-gc.md)
