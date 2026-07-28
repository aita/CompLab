# 8. gdb スタブ — `gdbstub.cppm`

gdb のリモートシリアルプロトコルを喋って、ゲストを外から覗けるようにする層です。gdb は
逆アセンブラも DWARF リーダも自分で持っているので、**スタブが渡すのはレジスタとメモリと
「なぜ止まったか」だけ**です。それだけで、ソースレベルのデバッグが成立します。

## 1. できること

```
$ rvemu -g 1234 ./dbg
rvemu: waiting for gdb on 127.0.0.1:1234
rvemu: (gdb) target remote :1234
```

```
$ gdb -q ./dbg
(gdb) target remote :1234
0x000000000001038c in _start ()
(gdb) break fib if n == 3
Breakpoint 1 at 0x10476: file dbg.c, line 2.
(gdb) continue

Breakpoint 1, fib (n=3) at dbg.c:2
2	int fib(int n){ return n<2?n:fib(n-1)+fib(n-2); }
(gdb) bt -4
#5  0x0000000000010492 in fib (n=8) at dbg.c:2
#6  0x0000000000010492 in fib (n=9) at dbg.c:2
#7  0x0000000000010492 in fib (n=10) at dbg.c:2
#8  0x00000000000104ca in main () at dbg.c:3
(gdb) print n
$1 = 3
(gdb) info registers pc sp ra
pc             0x10476	0x10476 <fib+16>
sp             0x7fffffffd800	0x7fffffffd800
ra             0x10492	0x10492 <fib+44>
(gdb) finish
Value returned is $2 = 2
(gdb) print $fa0
$3 = {float = 0, double = 0}
```

条件付きブレークポイントが効いているのが分かりやすい例です。gdb は `n == 3` になるまで
**止めては条件を見て再開する**ので、`Z0` の登録と、停止からの再開と、レジスタとメモリの
読み出しが全部回っていないと動きません。

ホストの `gdb` が `riscv:rv64` を扱えればそれで足ります。

```sh
$ gdb -batch -ex "set architecture riscv:rv64" -ex "show architecture"
The target architecture is set to "riscv:rv64".
```

## 2. パケット層

`$<本文>#<チェックサム2桁>` を送り、`+` か `-` が返る。それだけです。

```
--> qSupported:xmlRegisters=riscv
<-- $PacketSize=4000;qXfer:features:read+;swbreak+;vContSupported+;QStartNoAckMode+#70

--> ?
<-- $T05thread:1;#d7

--> p20
<-- $a803010000000000#3d

--> m10000,8
<-- $7f454c4602010103#8e

--> Z0,103a8,4
<-- $OK#9a
```

`p20` はレジスタ 0x20 = 32、つまり pc です。リトルエンディアンの16進で
`0x0000000000010_3a8` —— この ELF の入口です。`m10000,8` は `0x10000` から 8 バイトで、
`7f 45 4c 46` = `\x7fELF` が返っています。

受信側で1つだけ気をつけることがあります。**`}` は次の1バイトを `0x20` と XOR する
エスケープ**です。`read_packet` の中でほどくので、`X`（バイナリでのメモリ書き込み）を
扱う側はエスケープを知らずに済みます。

```cpp
if (c == '}') {
  sum += c;
  read_byte(c);
  sum += c;
  out.push_back(static_cast<char>(c ^ 0x20));
  continue;
}
```

`QStartNoAckMode` に対応しているので、gdb が望めば `+`/`-` のやりとりを省けます。TCP が
既に順序と再送を保証しているので、この上に載せる ack は二重です。

## 3. レジスタ番号は、こちらが決める

gdb に「どのレジスタが何番か」を推測させません。`qXfer:features:read:target.xml` で
**こちらから渡します**。

```
--> qXfer:features:read:target.xml:0,64
<-- $m<?xml version="1.0"?>
<!DOCTYPE target SYSTEM "gdb-target.dtd">
<target version="1.0">
  <architectu#f7
```

返事の先頭の `m` は「まだ続きがある」、`l` なら「これで最後」です。gdb は続きをオフセット
指定で取りに来ます。

中身はこの割り当てです。

| 番号 | |
|---|---|
| 0–31 | `zero` `ra` `sp` … `t6` |
| 32 | `pc` |
| 33–64 | `ft0` … `ft11` |
| 65–67 | `fflags` `frm` `fcsr` |

x と f は 8 バイト、浮動小数点の CSR は 4 バイトです。`g`（全部読む）はこの順にただ並べた
ものになります。

型を付けるところに意味があります。**`ra` と `pc` を `code_ptr`、`sp` と `s0` を `data_ptr`**
にしておくと、gdb がフレームを組み立てて `bt` をまともに出せます。

```cpp
const char* type = (i == 1) ? "code_ptr" : (i == 2 || i == 8) ? "data_ptr" : "int";
```

## 4. ブレークポイント — テキストを汚さない

ふつうのスタブは、ブレークポイントの番地に `ebreak` を書き込み、元の命令を憶えておいて、
外すときに戻します。**やっていません。**

代わりに `Z0` に対応すると宣言し、番地の集合を[実行ループ](exec.md)側で照合します。

```cpp
if (p[0] == 'Z') m_.breakpoints.insert(addr);
else             m_.breakpoints.erase(addr);
```

```cpp
// machine.cppm の resume()
if (!single && !first && breakpoints.contains(cpu.hart.pc)) return Event::Breakpoint;
```

ここでは実利があります。**圧縮命令は 2 バイトしかありません。** 4 バイトの `ebreak` を
埋める方式だと隣の命令を潰します。長さの合う `c.ebreak` を選ぶこともできますが、それは
「書き込む前に元の命令をデコードする」ことを意味していて、話が増えます。集合で持てば
その問題自体が消えます。

`first` の扱いに1つ罠があります。**停止した番地から再開するとき、その番地のブレークポイントで
もう一度止まってはいけません。** さもないと `continue` が何も進めずに戻ってきます。
最初の1命令だけ照合を飛ばします。

止まったことを伝えるとき、それが自分のブレークポイントなら `swbreak` を添えます。gdb が
「書き込んだはずのパッチ」を探しに行かないようにするためです。

```cpp
const bool ours = m_.breakpoints.contains(m_.cpu.hart.pc);
send_packet(ours ? "T05thread:1;swbreak:;" : "T05thread:1;");
```

止まった理由はシグナル番号に翻訳します。ブレークポイントが `T05`（SIGTRAP）、メモリ
フォールトが `T0b`（SIGSEGV）、不正命令が `T04`（SIGILL）、`^C` が `T02`（SIGINT）、
終了が `W<終了コード>`。

## 5. 実行中の ^C

`continue` の途中で gdb が割り込むとき、パケットではなく**裸の `0x03` が1バイト**流れて
きます。読み手が要ります。

スレッドは増やしていません。代わりに、実行ループが一定間隔でスタブを呼び戻します。

```cpp
// machine.cppm
std::function<void()> poll_hook;
static constexpr u64 kPollInterval = 1 << 16;
...
if (poll_hook && (executed % kPollInterval) == 0) poll_hook();
```

```cpp
// gdbstub.cppm
void poll_interrupt() {
  pollfd p{conn_, POLLIN, 0};
  if (::poll(&p, 1, 0) <= 0) return;         // 待たない
  const ssize_t n = ::recv(conn_, buf, sizeof buf, MSG_DONTWAIT);
  for (ssize_t i = 0; i < n; ++i) {
    if (buf[i] == 0x03) m_.interrupt = true;
    else inbuf_.push_back(buf[i]);           // パケットの先頭なら取っておく
  }
}
```

**6万5千命令に1回、待たない `poll` が1回**です。30M 命令/秒 で走っているので、1秒あたり
450 回ほど。1命令あたりの値段は分岐1つで、それも `poll_hook` が空なら（gdb を使っていない
なら）そこで終わります。

`0x03` 以外のバイトが来ていたら捨てずに `inbuf_` に積みます。次に `read_packet` が呼ばれた
とき、そこから読み始めます。

## 6. 切れたときと、外れたとき

| | |
|---|---|
| `D`（デタッチ） | ゲストを**最後まで走らせて**、その終了コードを返す |
| `k`（kill） | そこで終える |
| 接続が切れた | 走らせずに終える |

デタッチが「殺す」ではなく「走らせ切る」なのは、`gdb -ex detach` が普通の実行と同じ結果に
なってほしいからです。

## していないこと

**ウォッチポイント（`Z2`–`Z4`）は空の返事をします。** ハードウェア支援を実装するには、
[3章](exec.md)のすべてのロードとストアにフックが要ります。gdb は対応していないと分かると
**ソフトウェアウォッチポイントに落ちて**、1命令ずつ止めては値を比べます。動くには動き、
遅いだけです。

**スレッドは1つです。** `qfThreadInfo` は `m1` を返し、`H` はどんなスレッド指定にも `OK` と
答えます。

**`vRun` も `R` もありません。** プログラムの入れ替えと再起動はできません。`rvemu` を
もう一度起動するほうが早いからです。

**ソケットはループバックにだけ束ねます。** デバッグスタブは「任意のメモリを読み書きできる」
という機能そのものなので、実インタフェースに出す用事がありません。

```cpp
addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
```

## 参考文献

- [GDB Remote Serial Protocol][rsp]。パケットの一覧と、停止応答の書式。
- [GDB Target Descriptions][tdesc]。`org.gnu.gdb.riscv.cpu` と `.fpu` の feature 名。

[rsp]: https://sourceware.org/gdb/current/onlinedocs/gdb.html/Remote-Protocol.html
[tdesc]: https://sourceware.org/gdb/current/onlinedocs/gdb.html/Target-Descriptions.html

## 実装の地図

| | |
|---|---|
| `gdbstub.cppm` 50–58行 | レジスタ番号の割り当て |
| `gdbstub.cppm` 70–105行 | `wait_for_debugger` — ループバックに束ねて待つ |
| `gdbstub.cppm` 151–163行 | `send_packet` — チェックサムと ack |
| `gdbstub.cppm` 187–225行 | `read_packet` — `}` のエスケープをほどく |
| `gdbstub.cppm` 228–239行 | `poll_interrupt` — 実行中の `0x03` |
| `gdbstub.cppm` 277–340行 | `read_reg` / `write_reg` / `read_all_regs` |
| `gdbstub.cppm` 342–378行 | `target_xml` — レジスタ定義を組み立てる |
| `gdbstub.cppm` 391–426行 | `report` — `Event` をシグナル番号へ |
| `gdbstub.cppm` 428–548行 | `handle` — パケットの振り分け |
| `machine.cppm` 84–86行 | `poll_hook` と `kPollInterval` |

---

[← 7. アセンブラ](assembler.md) ／ [目次](index.md) ／ [付録A. 対応表 →](isa.md)
