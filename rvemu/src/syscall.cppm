// Syscall partition — what `ecall` means in user mode.
//
// Linux/RV64 uses the asm-generic syscall table: the number is in a7, arguments
// in a0..a5, the result back in a0, and errors are the negated errno rather
// than a separate flag. That table is close enough to x86-64's that most calls
// here are a straight pass-through to the host -- the open flags, the errno
// values, `struct iovec` and `struct timespec` all agree bit for bit, because
// both architectures took them from asm-generic.
//
// The places that genuinely differ, and so get real code:
//
//   * `struct stat`. RISC-V uses the 128-byte asm-generic layout, which is not
//     x86-64's. `write_stat` builds it field by field.
//   * brk and mmap. There is no host mapping to delegate to -- the guest's
//     address space is a hash map -- so both are implemented against Memory.
//   * Anything about processes and signals. One hart, no fork, no threads: the
//     signal calls succeed and do nothing, and a self-directed kill terminates
//     the guest with the right status.
//
// Guest file descriptors *are* host file descriptors. It makes fd tracking free
// and means the guest's stdout is genuinely the emulator's stdout, which is what
// you want when the program under test is a compiler you just wrote.
module;

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <sys/random.h>
#include <sys/select.h>
#include <sys/sysmacros.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysinfo.h>
#include <sys/time.h>
#include <sys/times.h>
#include <sys/uio.h>
#include <sys/utsname.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

export module rvemu:syscall;

import std;
import :common;
import :memory;
import :cpu;
import :exec;
import :elf;

export namespace rvemu {

// The asm-generic numbers, which is what RV64 Linux uses.
enum Sys : u64 {
  SysGetcwd = 17,
  SysFcntl = 25,
  SysIoctl = 29,
  SysUnlinkat = 35,
  SysFaccessat = 48,
  SysChdir = 49,
  SysOpenat = 56,
  SysClose = 57,
  SysGetdents64 = 61,
  SysLseek = 62,
  SysRead = 63,
  SysWrite = 64,
  SysReadv = 65,
  SysWritev = 66,
  SysPread64 = 67,
  SysPwrite64 = 68,
  SysPselect6 = 72,
  SysPpoll = 73,
  SysReadlinkat = 78,
  SysNewfstatat = 79,
  SysFstat = 80,
  SysExit = 93,
  SysExitGroup = 94,
  SysSetTidAddress = 96,
  SysFutex = 98,
  SysSetRobustList = 99,
  SysClockGettime = 113,
  SysClockGetres = 114,
  SysClockNanosleep = 115,
  SysSchedGetaffinity = 123,
  SysSchedYield = 124,
  SysKill = 129,
  SysTgkill = 131,
  SysRtSigaction = 134,
  SysRtSigprocmask = 135,
  SysTimes = 153,
  SysUname = 160,
  SysGetrusage = 165,
  SysGettimeofday = 169,
  SysGetpid = 172,
  SysGetppid = 173,
  SysGetuid = 174,
  SysGeteuid = 175,
  SysGetgid = 176,
  SysGetegid = 177,
  SysGettid = 178,
  SysSysinfo = 179,
  SysBrk = 214,
  SysMunmap = 215,
  SysMremap = 216,
  SysClone = 220,
  SysExecve = 221,
  SysMmap = 222,
  SysMprotect = 226,
  SysMadvise = 233,
  SysRseq = 293,
  SysPrlimit64 = 261,
  SysGetrandom = 278,
  SysStatx = 291,
  SysClone3 = 435,
};

// mmap flags, as the guest sees them (asm-generic; identical to x86-64).
inline constexpr u64 kMapShared = 0x01, kMapPrivate = 0x02, kMapFixed = 0x10,
                     kMapAnonymous = 0x20;
inline constexpr u64 kProtRead = 1, kProtWrite = 2, kProtExec = 4;

// The mmap arena grows down from here, well above anything an ELF asks for and
// well below the stack.
inline constexpr u64 kMmapTop = 0x0000'7f00'0000'0000;

// The initial process stack: 8 MiB just under the top of the 47-bit user range,
// which is where Linux puts it and where a guest's own stack-overflow checks
// expect to find it.
inline constexpr u64 kStackTop = 0x0000'7fff'ffff'f000;
inline constexpr u64 kStackSize = 8ull << 20;

class Kernel {
 public:
  Kernel(Cpu& cpu, const Image& img) : cpu_(cpu), img_(img) {
    brk_start_ = brk_ = img.brk;
  }

  bool exited = false;
  int exit_code = 0;
  bool trace = false;  // --trace-syscalls
  u64 count = 0;       // how many ecalls have been served, for --stats

  void set_brk_start(u64 v) { brk_start_ = brk_ = v; }

  // Called when step() returns Stop::Ecall. The pc is already past the ecall.
  void handle() {
    Hart& h = cpu_.hart;
    const u64 num = h.x[17];
    const u64 a0 = h.x[10], a1 = h.x[11], a2 = h.x[12], a3 = h.x[13], a4 = h.x[14],
              a5 = h.x[15];
    ++count;
    const i64 r = dispatch(num, a0, a1, a2, a3, a4, a5);
    if (trace) {
      std::print(stderr, "[syscall] {}({:#x}, {:#x}, {:#x}) = {}\n", num, a0, a1, a2, r);
    }
    if (!exited) h.x[10] = static_cast<u64>(r);
  }

 private:
  Cpu& cpu_;
  const Image& img_;
  u64 brk_start_ = 0, brk_ = 0;
  u64 mmap_next_ = kMmapTop;

  Memory& mem() { return cpu_.mem; }

  static i64 err() { return -static_cast<i64>(errno); }
  // A guest pointer that does not resolve is EFAULT, the same as on real Linux.
  static constexpr i64 kFault = -EFAULT;

  i64 dispatch(u64 num, u64 a0, u64 a1, u64 a2, u64 a3, u64 a4, u64 a5) {
    switch (num) {
      // -- process lifetime -------------------------------------------------
      case SysExit:
      case SysExitGroup:
        exited = true;
        exit_code = static_cast<int>(a0 & 0xff);
        return 0;

      // abort() lands here. There are no signal handlers, so a signal aimed at
      // ourselves is simply the end of the process.
      case SysKill:
      case SysTgkill: {
        const u64 sig = (num == SysKill) ? a1 : a2;
        exited = true;
        exit_code = 128 + static_cast<int>(sig);
        return 0;
      }

      // -- file descriptors -------------------------------------------------
      case SysRead: return do_read(int(a0), a1, a2, -1);
      case SysPread64: return do_read(int(a0), a1, a2, i64(a3));
      case SysWrite: return do_write(int(a0), a1, a2, -1);
      case SysPwrite64: return do_write(int(a0), a1, a2, i64(a3));
      case SysReadv: return do_iov(int(a0), a1, a2, /*writing=*/false);
      case SysWritev: return do_iov(int(a0), a1, a2, /*writing=*/true);
      case SysClose:
        // Closing the emulator's own stdio would make later output vanish.
        if (a0 <= 2) return 0;
        return ::close(int(a0)) < 0 ? err() : 0;
      case SysLseek: {
        const off_t r = ::lseek(int(a0), off_t(a1), int(a2));
        return r < 0 ? err() : i64(r);
      }
      case SysFcntl: {
        const int r = ::fcntl(int(a0), int(a1), long(a2));
        return r < 0 ? err() : r;
      }
      case SysOpenat: return do_openat(int(a0), a1, u32(a2), u32(a3));
      case SysFaccessat: {
        std::string path;
        if (!mem().read_cstr(a1, path)) return kFault;
        const int r = ::faccessat(int(a0), path.c_str(), int(a2), 0);
        return r < 0 ? err() : 0;
      }
      case SysUnlinkat: {
        std::string path;
        if (!mem().read_cstr(a1, path)) return kFault;
        const int r = ::unlinkat(int(a0), path.c_str(), int(a2));
        return r < 0 ? err() : 0;
      }
      case SysChdir: {
        std::string path;
        if (!mem().read_cstr(a0, path)) return kFault;
        return ::chdir(path.c_str()) < 0 ? err() : 0;
      }
      case SysGetcwd: {
        std::vector<char> buf(a1 ? a1 : 1);
        if (!::getcwd(buf.data(), buf.size())) return err();
        const u64 n = std::strlen(buf.data()) + 1;
        if (!mem().write(a0, buf.data(), n)) return kFault;
        return i64(n);
      }
      case SysGetdents64: {
        std::vector<u8> buf(a2);
        const long r = ::syscall(SYS_getdents64, int(a0), buf.data(), a2);
        if (r < 0) return err();
        if (r && !mem().write(a1, buf.data(), u64(r))) return kFault;
        return r;
      }
      case SysIoctl: return do_ioctl(int(a0), a1, a2);

      // -- stat -------------------------------------------------------------
      case SysFstat: {
        struct stat st{};
        if (::fstat(int(a0), &st) < 0) return err();
        return write_stat(a1, st);
      }
      case SysNewfstatat: {
        std::string path;
        if (!mem().read_cstr(a1, path)) return kFault;
        struct stat st{};
        if (::fstatat(int(a0), path.c_str(), &st, int(a3)) < 0) return err();
        return write_stat(a2, st);
      }
      case SysReadlinkat: return do_readlinkat(int(a0), a1, a2, a3);
      case SysStatx: return do_statx(int(a0), a1, u32(a2), u32(a3), a4);

      // -- memory -----------------------------------------------------------
      case SysBrk: return do_brk(a0);
      case SysMmap: return do_mmap(a0, a1, u64(a2), u64(a3), int(a4), i64(a5));
      case SysMunmap:
        mem().unmap(a0, a1);
        return 0;
      case SysMprotect: {
        u8 p = 0;
        if (a2 & kProtRead) p |= PermR;
        if (a2 & kProtWrite) p |= PermW;
        if (a2 & kProtExec) p |= PermX;
        mem().protect(a0, a1, p);
        return 0;
      }
      case SysMadvise: return 0;  // advice, and we have none to take
      case SysMremap: return -ENOMEM;  // let the guest fall back to mmap+copy

      // -- time -------------------------------------------------------------
      case SysClockGettime: {
        struct timespec ts{};
        if (::clock_gettime(clockid_t(a0), &ts) < 0) return err();
        return write_timespec(a1, ts);
      }
      case SysClockGetres: {
        if (!a1) return 0;
        struct timespec ts{};
        if (::clock_getres(clockid_t(a0), &ts) < 0) return err();
        return write_timespec(a1, ts);
      }
      case SysGettimeofday: {
        struct timeval tv{};
        if (::gettimeofday(&tv, nullptr) < 0) return err();
        const i64 v[2] = {i64(tv.tv_sec), i64(tv.tv_usec)};
        if (a0 && !mem().write(a0, v, sizeof v)) return kFault;
        return 0;
      }
      case SysClockNanosleep: {
        i64 ts[2] = {0, 0};
        if (!mem().read(a2, ts, sizeof ts)) return kFault;
        struct timespec req{time_t(ts[0]), long(ts[1])};
        return ::clock_nanosleep(clockid_t(a0), int(a1), &req, nullptr);
      }
      case SysTimes: {
        struct tms t{};
        const clock_t r = ::times(&t);
        const i64 v[4] = {i64(t.tms_utime), i64(t.tms_stime), i64(t.tms_cutime),
                          i64(t.tms_cstime)};
        if (a0 && !mem().write(a0, v, sizeof v)) return kFault;
        return i64(r);
      }

      // -- identity and limits ----------------------------------------------
      case SysGetpid: return ::getpid();
      case SysGetppid: return ::getppid();
      case SysGettid: return ::getpid();
      case SysGetuid: return ::getuid();
      case SysGeteuid: return ::geteuid();
      case SysGetgid: return ::getgid();
      case SysGetegid: return ::getegid();
      case SysUname: return do_uname(a0);
      case SysSysinfo: return 0;
      case SysGetrusage: return 0;
      case SysPrlimit64: {
        // Report the stack limit honestly; everything else is unlimited.
        if (a2) return -EPERM;  // no setting of limits
        if (!a3) return 0;
        const u64 lim[2] = {kStackSize, kStackSize};
        if (!mem().write(a3, lim, sizeof lim)) return kFault;
        return 0;
      }
      case SysSchedGetaffinity: {
        // One hart, so one bit. glibc only wants a non-empty mask.
        if (a2 < 1) return -EINVAL;
        std::vector<u8> mask(a1, 0);
        if (mask.empty()) return -EINVAL;
        mask[0] = 1;
        if (!mem().write(a2, mask.data(), mask.size())) return kFault;
        return i64(mask.size());
      }
      case SysGetrandom: {
        std::vector<u8> buf(a1);
        const ssize_t r = ::getrandom(buf.data(), buf.size(), unsigned(a2));
        if (r < 0) return err();
        if (r && !mem().write(a0, buf.data(), u64(r))) return kFault;
        return r;
      }

      // -- threads and signals: accepted, and nothing happens ----------------
      case SysSetTidAddress: return ::getpid();
      case SysSetRobustList:
      case SysRtSigaction:
      case SysRtSigprocmask:
      case SysRseq:
      case SysSchedYield:
        return 0;
      case SysFutex:
        // FUTEX_WAIT on a single hart could only ever deadlock; report the
        // value-changed race instead, which every caller already handles.
        return ((a1 & 0x7f) == 0) ? -EAGAIN : 0;

      // -- refused ----------------------------------------------------------
      case SysClone:
      case SysClone3:
      case SysExecve:
        return -ENOSYS;

      case SysPpoll: return do_ppoll(a0, a1, a2);
      case SysPselect6: return do_pselect6(int(a0), a1, a2, a3, a4);

      default:
        if (trace) std::print(stderr, "[syscall] unimplemented: {}\n", num);
        return -ENOSYS;
    }
  }

  // -- helpers ---------------------------------------------------------------

  i64 do_read(int fd, u64 buf, u64 len, i64 offset) {
    std::vector<u8> tmp(len);
    const ssize_t r = (offset < 0) ? ::read(fd, tmp.data(), len)
                                   : ::pread(fd, tmp.data(), len, off_t(offset));
    if (r < 0) return err();
    if (r && !mem().write(buf, tmp.data(), u64(r))) return kFault;
    return r;
  }

  i64 do_write(int fd, u64 buf, u64 len, i64 offset) {
    std::vector<u8> tmp(len);
    if (len && !mem().read(buf, tmp.data(), len)) return kFault;
    const ssize_t r = (offset < 0) ? ::write(fd, tmp.data(), len)
                                   : ::pwrite(fd, tmp.data(), len, off_t(offset));
    return r < 0 ? err() : r;
  }

  // readv/writev. The guest iovec is {u64 base; u64 len}, which is the host
  // layout too, but the bases are guest addresses so each one is copied.
  i64 do_iov(int fd, u64 iov, u64 cnt, bool writing) {
    i64 total = 0;
    for (u64 i = 0; i < cnt; ++i) {
      u64 v[2] = {0, 0};
      if (!mem().read(iov + i * 16, v, sizeof v)) return kFault;
      if (v[1] == 0) continue;
      const i64 r = writing ? do_write(fd, v[0], v[1], -1) : do_read(fd, v[0], v[1], -1);
      if (r < 0) return total ? total : r;
      total += r;
      if (u64(r) < v[1]) break;  // short transfer ends the vector
    }
    return total;
  }

  i64 do_openat(int dirfd, u64 pathp, u32 flags, u32 mode) {
    std::string path;
    if (!mem().read_cstr(pathp, path)) return kFault;
    // The guest's own image is the one path that is not what it says it is.
    if (path == "/proc/self/exe") path = img_.path;
    const int fd = ::openat(dirfd, path.c_str(), int(flags), mode);
    return fd < 0 ? err() : fd;
  }

  i64 do_readlinkat(int dirfd, u64 pathp, u64 buf, u64 bufsz) {
    std::string path;
    if (!mem().read_cstr(pathp, path)) return kFault;
    if (path == "/proc/self/exe") {
      const std::string real = std::filesystem::absolute(img_.path).string();
      const u64 n = std::min<u64>(real.size(), bufsz);
      if (n && !mem().write(buf, real.data(), n)) return kFault;
      return i64(n);
    }
    std::vector<char> tmp(bufsz ? bufsz : 1);
    const ssize_t r = ::readlinkat(dirfd, path.c_str(), tmp.data(), bufsz);
    if (r < 0) return err();
    if (r && !mem().write(buf, tmp.data(), u64(r))) return kFault;
    return r;
  }

  i64 do_ioctl(int fd, u64 req, u64 argp) {
    // Only the terminal queries matter: they are how isatty() and line-buffering
    // decisions are made, and getting them wrong changes a program's output.
    switch (req) {
      case TCGETS: {
        struct termios t{};
        if (::tcgetattr(fd, &t) < 0) return err();
        // asm-generic termios and x86-64's are the same 36-byte layout.
        if (!mem().write(argp, &t, 36)) return kFault;
        return 0;
      }
      case TCSETS:
      case TCSETSW:
      case TCSETSF: {
        struct termios t{};
        if (!mem().read(argp, &t, 36)) return kFault;
        const int how = (req == TCSETS) ? TCSANOW : (req == TCSETSW) ? TCSADRAIN : TCSAFLUSH;
        return ::tcsetattr(fd, how, &t) < 0 ? err() : 0;
      }
      case TIOCGWINSZ: {
        struct winsize ws{};
        if (::ioctl(fd, TIOCGWINSZ, &ws) < 0) return err();
        if (!mem().write(argp, &ws, sizeof ws)) return kFault;
        return 0;
      }
      default:
        return -ENOTTY;
    }
  }

  // The RV64 `struct stat`: the 128-byte asm-generic layout, which is not the
  // host's, so it is built field by field.
  i64 write_stat(u64 dst, const struct stat& st) {
    std::array<u8, 128> b{};
    auto put64 = [&](u64 off, u64 v) { std::memcpy(b.data() + off, &v, 8); };
    auto put32 = [&](u64 off, u32 v) { std::memcpy(b.data() + off, &v, 4); };
    put64(0, st.st_dev);
    put64(8, st.st_ino);
    put32(16, st.st_mode);
    put32(20, u32(st.st_nlink));
    put32(24, st.st_uid);
    put32(28, st.st_gid);
    put64(32, st.st_rdev);
    put64(40, 0);  // __pad1
    put64(48, u64(st.st_size));
    put32(56, u32(st.st_blksize));
    put32(60, 0);  // __pad2
    put64(64, u64(st.st_blocks));
    put64(72, u64(st.st_atim.tv_sec));
    put64(80, u64(st.st_atim.tv_nsec));
    put64(88, u64(st.st_mtim.tv_sec));
    put64(96, u64(st.st_mtim.tv_nsec));
    put64(104, u64(st.st_ctim.tv_sec));
    put64(112, u64(st.st_ctim.tv_nsec));
    return mem().write(dst, b.data(), b.size()) ? 0 : kFault;
  }

  // statx is what a current glibc reaches for before falling back to fstat.
  // The 256-byte guest struct is filled from a plain fstatat.
  i64 do_statx(int dirfd, u64 pathp, u32 flags, u32 mask, u64 dst) {
    std::string path;
    if (!mem().read_cstr(pathp, path)) return kFault;
    struct stat st{};
    if (::fstatat(dirfd, path.c_str(), &st, int(flags)) < 0) return err();

    std::array<u8, 256> b{};
    auto put16 = [&](u64 off, u16 v) { std::memcpy(b.data() + off, &v, 2); };
    auto put32 = [&](u64 off, u32 v) { std::memcpy(b.data() + off, &v, 4); };
    auto put64 = [&](u64 off, u64 v) { std::memcpy(b.data() + off, &v, 8); };
    auto put_time = [&](u64 off, const struct timespec& ts) {
      put64(off, u64(ts.tv_sec));
      put32(off + 8, u32(ts.tv_nsec));
    };
    constexpr u32 kStatxBasicStats = 0x7ff;
    put32(0, mask & kStatxBasicStats);  // only the fields fstatat gave us
    put32(4, u32(st.st_blksize));
    put32(16, u32(st.st_nlink));
    put32(20, st.st_uid);
    put32(24, st.st_gid);
    put16(28, u16(st.st_mode));
    put64(32, st.st_ino);
    put64(40, u64(st.st_size));
    put64(48, u64(st.st_blocks));
    put_time(64, st.st_atim);
    put_time(80, st.st_mtim);  // no birth time from fstatat; mtime is the honest stand-in
    put_time(96, st.st_ctim);
    put_time(112, st.st_mtim);
    put32(128, major(st.st_rdev));
    put32(132, minor(st.st_rdev));
    put32(136, major(st.st_dev));
    put32(140, minor(st.st_dev));
    return mem().write(dst, b.data(), b.size()) ? 0 : kFault;
  }

  // The guest `struct pollfd` is {int fd; short events; short revents}, which is
  // the host layout too, so this is a copy in, a poll, and a copy back.
  i64 do_ppoll(u64 fds, u64 nfds, u64 timeout_ptr) {
    std::vector<pollfd> p(nfds);
    if (nfds && !mem().read(fds, p.data(), nfds * sizeof(pollfd))) return kFault;
    int timeout_ms = -1;
    if (timeout_ptr) {
      i64 ts[2] = {0, 0};
      if (!mem().read(timeout_ptr, ts, sizeof ts)) return kFault;
      timeout_ms = int(ts[0] * 1000 + ts[1] / 1000000);
    }
    const int r = ::poll(p.data(), nfds, timeout_ms);
    if (r < 0) return err();
    if (nfds && !mem().write(fds, p.data(), nfds * sizeof(pollfd))) return kFault;
    return r;
  }

  // select's fd_set is a bitmap of nfds bits. Copying it in and out is enough;
  // the guest's fds are the host's.
  i64 do_pselect6(int nfds, u64 rp, u64 wp, u64 ep, u64 timeout_ptr) {
    if (nfds < 0 || nfds > FD_SETSIZE) return -EINVAL;
    const std::size_t bytes = std::size_t((nfds + 7) / 8);
    fd_set sets[3];
    u64 ptrs[3] = {rp, wp, ep};
    for (int i = 0; i < 3; ++i) {
      FD_ZERO(&sets[i]);
      if (ptrs[i] && bytes && !mem().read(ptrs[i], &sets[i], bytes)) return kFault;
    }
    struct timespec ts{};
    if (timeout_ptr) {
      i64 v[2] = {0, 0};
      if (!mem().read(timeout_ptr, v, sizeof v)) return kFault;
      ts.tv_sec = time_t(v[0]);
      ts.tv_nsec = long(v[1]);
    }
    const int r = ::pselect(nfds, rp ? &sets[0] : nullptr, wp ? &sets[1] : nullptr,
                            ep ? &sets[2] : nullptr, timeout_ptr ? &ts : nullptr,
                            nullptr);
    if (r < 0) return err();
    for (int i = 0; i < 3; ++i) {
      if (ptrs[i] && bytes && !mem().write(ptrs[i], &sets[i], bytes)) return kFault;
    }
    return r;
  }

  i64 write_timespec(u64 dst, const struct timespec& ts) {
    const i64 v[2] = {i64(ts.tv_sec), i64(ts.tv_nsec)};
    return mem().write(dst, v, sizeof v) ? 0 : kFault;
  }

  i64 do_uname(u64 dst) {
    // Six NUL-padded 65-byte fields. The machine name is the one that has to
    // lie: the guest is RISC-V even though we are not.
    std::array<char, 65 * 6> buf{};
    auto set = [&](int i, std::string_view s) {
      std::memcpy(buf.data() + 65 * i, s.data(), std::min<std::size_t>(s.size(), 64));
    };
    set(0, "Linux");
    set(1, "rvemu");
    set(2, "6.1.0");
    set(3, "#1 SMP rvemu");
    set(4, "riscv64");
    set(5, "");
    return mem().write(dst, buf.data(), buf.size()) ? 0 : kFault;
  }

  // brk(0) reports the current break; brk(n) moves it and reports where it
  // ended up. Shrinking releases the pages, which keeps a malloc-heavy guest
  // from holding the whole high-water mark forever.
  i64 do_brk(u64 want) {
    if (want == 0 || want < brk_start_) return i64(brk_);
    const u64 old_end = align_up(brk_, kPageSize);
    const u64 new_end = align_up(want, kPageSize);
    if (new_end > old_end) mem().map(old_end, new_end - old_end, PermRW, true);
    else if (new_end < old_end) mem().unmap(new_end, old_end - new_end);
    brk_ = want;
    return i64(brk_);
  }

  i64 do_mmap(u64 addr, u64 len, u64 prot, u64 flags, int fd, i64 off) {
    if (len == 0) return -EINVAL;
    len = align_up(len, kPageSize);

    u8 perm = 0;
    if (prot & kProtRead) perm |= PermR;
    if (prot & kProtWrite) perm |= PermW;
    if (prot & kProtExec) perm |= PermX;
    // PROT_NONE guard pages are common; they still need to exist as mappings.
    if (perm == 0) perm = PermNone;

    u64 base = 0;
    if (flags & kMapFixed) {
      base = align_down(addr, kPageSize);
    } else {
      // A hint is honoured only if the whole range is free, exactly as the
      // kernel does; otherwise take the next slot down from the arena top.
      const u64 hint = align_down(addr, kPageSize);
      if (hint && mem().range_free(hint, len)) {
        base = hint;
      } else {
        base = mmap_next_ - len;
        while (!mem().range_free(base, len)) base -= kPageSize;
        mmap_next_ = base;
      }
    }
    mem().map(base, len, perm, /*zero=*/true);

    if (!(flags & kMapAnonymous)) {
      // File-backed: read it in eagerly. There is no page fault path to fill it
      // lazily, and the guests that use this (locale data, mostly) are small.
      std::vector<u8> tmp(len);
      const ssize_t r = ::pread(fd, tmp.data(), len, off_t(off));
      if (r < 0) {
        mem().unmap(base, len);
        return err();
      }
      if (r && !mem().poke(base, tmp.data(), u64(r))) return kFault;
    }
    return i64(base);
  }
};

}  // namespace rvemu
