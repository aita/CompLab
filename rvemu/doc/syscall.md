# 6. システムコール — `syscall.cppm`

`ecall` が何を意味するかを決める層です。ここから先はもう RISC-V の話ではなく、Linux の
話になります。

## 1. 呼び出し規約

番号が `a7`、引数が `a0`–`a5`、結果が `a0`。失敗は別のフラグではなく**負の errno** です。

```cpp
void handle() {
  const u64 num = h.x[17];
  const u64 a0 = h.x[10], a1 = h.x[11], ...;
  ++count;
  const i64 r = dispatch(num, a0, a1, a2, a3, a4, a5);
  if (!exited) h.x[10] = static_cast<u64>(r);
}
```

pc は `step()` が既に進めてあります（[3章 §5](exec.md#5-トラップの境界)）。だからここは
`a0` を書くだけで、戻り先を考えなくて済みます。

RV64 が使うのは asm-generic の番号表です。x86-64 のそれとは番号が違うので、表そのものは
書き下しています。

```cpp
enum Sys : u64 {
  SysWrite = 64, SysExit = 93, SysBrk = 214, SysMmap = 222, ...
};
```

## 2. なぜ、ほとんどが素通しでよいのか

RV64 と x86-64 は**どちらも asm-generic から同じものを受け継いでいます**。

- `open` のフラグ（`O_CREAT` = 0100、`O_CLOEXEC` = 02000000 …）
- errno の値
- `struct iovec` = `{ void* base; size_t len; }`
- `struct timespec` = `{ i64 sec; i64 nsec; }`
- `struct pollfd` = `{ int fd; short events; short revents; }`
- `struct termios` の 36 バイト

だから `read` も `write` も `openat` も、ゲストのポインタを実体に直してホストに渡すだけで
終わります。

```cpp
i64 do_write(int fd, u64 buf, u64 len, i64 offset) {
  std::vector<u8> tmp(len);
  if (len && !mem().read(buf, tmp.data(), len)) return kFault;
  const ssize_t r = (offset < 0) ? ::write(fd, tmp.data(), len)
                                 : ::pwrite(fd, tmp.data(), len, off_t(offset));
  return r < 0 ? err() : r;
}
```

ゲストのポインタが解決できなければ `-EFAULT` を返します。本物のカーネルと同じ答えです。

**ゲストのファイルディスクリプタは、ホストのファイルディスクリプタそのもの**にしました。
対応表を持ちません。`openat` が返した番号をそのままゲストに渡します。

得なのは、fd の追跡が無料になることだけではありません。**ゲストの標準出力が、本当に
エミュレータの標準出力になります。** 自分で書いたコンパイラの出力をパイプに流したいとき、
これが効きます。

`close(0..2)` だけは何もせずに成功を返します。エミュレータ自身の stdio を閉じられると、
そのあとの出力が消えるからです。

## 3. 素通しにできない3か所

### `struct stat`

RISC-V が使うのは asm-generic の 128 バイトの版で、これは x86-64 のものと違います。
フィールドを1つずつ組みます。

```cpp
put64(0, st.st_dev);      put64(8, st.st_ino);
put32(16, st.st_mode);    put32(20, u32(st.st_nlink));
put32(24, st.st_uid);     put32(28, st.st_gid);
put64(32, st.st_rdev);    put64(40, 0);          // __pad1
put64(48, u64(st.st_size));
put32(56, u32(st.st_blksize));  put32(60, 0);    // __pad2
put64(64, u64(st.st_blocks));
put64(72, ...); // atim, mtim, ctim が 16 バイトずつ
```

`statx` も同じ手で 256 バイトを組みます。今の glibc は `stat` より先に `statx` を試すので、
これが無いと 1 つ古い経路に落ちます（落ちても動きますが、余計なシステムコールが1回増えます）。

### `brk` と `mmap`

委譲する相手がいません。ゲストのアドレス空間はハッシュマップなので、[1章](memory.md)の
`Memory` に対して実装します。

`brk` は素直です。伸ばすときはページを貼り、縮めるときは捨てます。**縮めて返すのは、
malloc を多用したゲストが最高到達点をずっと抱えたままにならないため**です。

`mmap` は置き場所を決めるところが仕事です。`MAP_FIXED` ならそこ。ヒントがあって、その範囲が
まるごと空いていればそこ（**カーネルと同じ規則**）。どちらでもなければ、`0x7f00'0000'0000`
から下に向かって空いている場所を探します。

```cpp
base = mmap_next_ - len;
while (!mem().range_free(base, len)) base -= kPageSize;
mmap_next_ = base;
```

ファイルを写す `mmap` は**先読みします**。ページフォールトで遅延して埋める経路がそもそも
無いのと、これを使うゲスト（ロケールのデータくらい）が小さいからです。

### プロセスとシグナル

hart が1つで、`fork` も threads もありません。だから:

- `rt_sigaction` / `rt_sigprocmask` / `set_robust_list` / `rseq` — **成功を返して何もしません**
- `futex` — `FUTEX_WAIT` は `-EAGAIN`。1 hart で待ったらデッドロックにしかならないので、
  「値が変わっていた」という、呼ぶ側が必ず扱える競合のほうを返します
- `clone` / `clone3` / `execve` — `-ENOSYS`
- `kill` / `tgkill` — **自分宛なら `128 + signo` で終了**します

最後のものが `abort()` の経路です。シグナルハンドラが走らない以上、自分に向けたシグナルは
「プロセスの終わり」以外の意味を持ちません。

## 4. 知らない番号は、知らないと言う

```
$ rvemu -T ./hello
[syscall] unimplemented: 258
[syscall] 258(0x7fffffffdaa0, 0x1, 0x0) = -38
[syscall] 214(0x0, 0xb00, 0x7bd10) = 528384
[syscall] 96(0x810f0, 0x0, 0x0) = 1081521
[syscall] 99(0x81100, 0x18, 0x0) = 0
[syscall] 293(0x817c0, 0x20, 0x0) = 0
[syscall] 261(0x0, 0x3, 0x0) = 0
[syscall] 78(0xffffffffffffff9c, 0x53ef8, 0x7fffffffca20) = 13
[syscall] 278(0x80580, 0x8, 0x1) = 8
...
[syscall] 64(0x1, 0x82100, 0x9) = 9
hello 42
[syscall] 94(0x0, 0x0, 0x0) = 0
```

258 は RISC-V 固有の `riscv_hwprobe` です。実装していないので `-38`（`ENOSYS`）を返し、
glibc は**それを古いカーネルの合図として扱って**先に進みます。

これが方針です。**知らないシステムコールには `-ENOSYS` を返します。** ゼロや成功を返して
「それらしく」振る舞うと、呼んだ側は返ってきた内容を信じてしまいます。`ENOSYS` は Linux の
ユーザ空間がいちばんよく扱える答えで、たいていフォールバックの経路が用意されています。

残りは 214 が `brk`、96 が `set_tid_address`、99 が `set_robust_list`、293 が `statx`、
261 が `prlimit64`、78 が `readlinkat`（`/proc/self/exe`）、278 が `getrandom`、
64 が `write`、94 が `exit_group` です。

`/proc/self/exe` は、**中身が名前と違う唯一の道**です。`openat` と `readlinkat` の両方で、
実行しているファイルの実際のパスに差し替えます。

## 5. 合っていることの確かめ方

同じプログラムを `qemu-riscv64` と並べて走らせて、出力と終了コードを突き合わせます。

```c
struct stat st;  stat("/etc/hostname", &st);
struct pollfd p = { .fd = 0, .events = POLLIN };  poll(&p, 1, 0);
fd_set rs; FD_ZERO(&rs); FD_SET(0, &rs);  select(1, &rs, NULL, NULL, &tv);
isatty(1);
```

```
$ rvemu ./io < /dev/null          $ qemu-riscv64 ./io < /dev/null
stat size=7 mode=644              stat size=7 mode=644
poll=1 revents=1                  poll=1 revents=1
select=1 isset=1                  select=1 isset=1
isatty(1)=0                       isatty(1)=0
```

`isatty` は `ioctl(TCGETS)` です。端末に関する問い合わせだけを通しているのは、**そこを
間違えると出力そのものが変わる**からです。行バッファか完全バッファかの判断がここで
決まります。それ以外の `ioctl` は `-ENOTTY` を返します。

## していないこと

**シグナルハンドラは走りません。** `rt_sigaction` は登録を受け付けたふりをします。動かす
には[3章](exec.md)の実行ループにシグナルの配送点を作り、シグナルスタックとフレームと
`rt_sigreturn` を実装することになります。

**`ppoll` / `pselect6` はシグナルマスクを見ません。** ブロックする相手がいないので、
マスクを尊重しても観測できる違いが出ません。

**`riscv_hwprobe`（258）と `riscv_flush_icache`（259）はありません。** 前者は上のとおり
`ENOSYS` で足ります。後者はゲストがコードを生成したときに必要になりますが、このエミュレータ
は命令をキャッシュしないので、実装するとしても中身は空です。

**`mremap` は `-ENOMEM` を返します。** 呼ぶ側は `mmap` + コピーに落ちます。

## 参考文献

- [Linux `include/uapi/asm-generic/unistd.h`][unistd]。RV64 の番号表。
- [Linux `include/uapi/asm-generic/stat.h`][stat]。128 バイトの `struct stat`。

[unistd]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/uapi/asm-generic/unistd.h
[stat]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/uapi/asm-generic/stat.h

## 実装の地図

| | |
|---|---|
| `syscall.cppm` 56–117行 | `Sys` — 番号表 |
| `syscall.cppm` 120–132行 | mmap のフラグ、mmap 領域の天井、スタックの位置と大きさ |
| `syscall.cppm` 148–164行 | `handle` — `ecall` の入口 |
| `syscall.cppm` 173–375行 | `dispatch` — 大きな switch |
| `syscall.cppm` 378–410行 | `do_read` / `do_write` / `do_iov` |
| `syscall.cppm` 436–466行 | `do_ioctl` — 端末の問い合わせだけ |
| `syscall.cppm` 468–529行 | `write_stat` / `do_statx` — 手で組む構造体 |
| `syscall.cppm` 532–572行 | `do_ppoll` / `do_pselect6` |
| `syscall.cppm` 599–650行 | `do_brk` / `do_mmap` |

---

[← 5. プロセスの起動](process.md) ／ [目次](index.md) ／ [7. アセンブラ →](assembler.md)
