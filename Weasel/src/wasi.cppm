// Wasi partition — a small `wasi_snapshot_preview1`.
//
// Every function here is an ordinary host function: a signature, and a C++
// lambda that reads and writes the calling instance's memory. That is the whole
// of the interface. What makes WASI feel like a system call layer is only that
// the names are fixed and the argument encoding is by pointer into linear
// memory — the runtime has no idea any of this is "a system".
//
// The two things worth noticing:
//
//   * **Nothing is passed by reference.** A wasm value is 32 or 64 bits, so
//     every structure crosses as an address into the caller's memory, and the
//     host writes results back the same way. `fd_write` takes an array of
//     (pointer, length) pairs and writes the byte count to a third pointer.
//   * **`proc_exit` cannot return.** It is spelled as a trap, and the embedder
//     tells that trap apart from a failure by its code.
export module weasel:wasi;

import std;
import :common;
import :types;
import :store;

export namespace weasel {

struct WasiConfig {
  std::vector<std::string> args;
  std::vector<std::string> env;
};

}  // namespace weasel

namespace weasel {

// The errno values this subset can produce.
constexpr u32 kESuccess = 0;
constexpr u32 kEBadf = 8;
constexpr u32 kEInval = 28;
constexpr u32 kENotCapable = 76;
constexpr u32 kESpipe = 70;

FuncType sig(std::vector<ValType> params, std::vector<ValType> results) {
  return FuncType{std::move(params), std::move(results)};
}

constexpr ValType I = ValType::I32;
constexpr ValType L = ValType::I64;

struct Mem {
  MemInst* m = nullptr;
  Caller* c = nullptr;

  bool in_bounds(u64 addr, u64 n) {
    if (!m || addr + n > m->bytes.size()) {
      c->fail(Trap::OutOfBoundsMemory, "WASI argument is outside linear memory");
      return false;
    }
    return true;
  }
  bool get32(u32 addr, u32& out) {
    if (!in_bounds(addr, 4)) return false;
    std::memcpy(&out, m->bytes.data() + addr, 4);
    return true;
  }
  bool put32(u32 addr, u32 v) {
    if (!in_bounds(addr, 4)) return false;
    std::memcpy(m->bytes.data() + addr, &v, 4);
    return true;
  }
  bool put64(u32 addr, u64 v) {
    if (!in_bounds(addr, 8)) return false;
    std::memcpy(m->bytes.data() + addr, &v, 8);
    return true;
  }
  bool put_bytes(u32 addr, std::string_view s) {
    if (!in_bounds(addr, s.size())) return false;
    if (!s.empty()) std::memcpy(m->bytes.data() + addr, s.data(), s.size());
    return true;
  }
  std::string_view view(u32 addr, u32 n) {
    if (!in_bounds(addr, n)) return {};
    return std::string_view(reinterpret_cast<const char*>(m->bytes.data() + addr), n);
  }
};

// The `(pointer, length)` array WASI uses wherever POSIX would use `struct
// iovec`: eight bytes per entry, both fields little-endian u32.
bool for_each_iov(Mem& mem, u32 iovs, u32 count, auto&& fn) {
  for (u32 i = 0; i < count; ++i) {
    u32 ptr = 0, len = 0;
    if (!mem.get32(iovs + i * 8, ptr) || !mem.get32(iovs + i * 8 + 4, len)) return false;
    if (!fn(ptr, len)) return false;
  }
  return true;
}

}  // namespace weasel

export namespace weasel {

// Register the subset under `wasi_snapshot_preview1`. `cfg` must outlive the
// store, because the closures capture it by pointer.
void add_wasi(Store& store, Linker& linker, WasiConfig& cfg) {
  const auto def = [&](std::string name, FuncType t, HostFn fn) {
    const u32 addr = store.add_host(name, std::move(t), std::move(fn));
    linker.define("wasi_snapshot_preview1", std::move(name),
                  Extern{ExternKind::Func, addr});
  };

  def("proc_exit", sig({I}, {}),
      [](Caller& c, std::span<const Value> a, std::span<Value>) {
        c.exit_code = static_cast<i32>(a[0].i32());
        c.fail(Trap::Exit);
      });

  def("fd_write", sig({I, I, I, I}, {I}),
      [](Caller& c, std::span<const Value> a, std::span<Value> r) {
        Mem mem{c.memory(), &c};
        const u32 fd = a[0].i32();
        if (fd != 1 && fd != 2) {
          r[0] = Value::of_i32(kEBadf);
          return;
        }
        u32 total = 0;
        auto& out = (fd == 1) ? std::cout : std::cerr;
        if (!for_each_iov(mem, a[1].i32(), a[2].i32(), [&](u32 ptr, u32 len) {
              auto s = mem.view(ptr, len);
              if (c.trap != Trap::None) return false;
              out.write(s.data(), static_cast<std::streamsize>(s.size()));
              total += len;
              return true;
            }))
          return;
        out.flush();
        if (!mem.put32(a[3].i32(), total)) return;
        r[0] = Value::of_i32(kESuccess);
      });

  def("fd_read", sig({I, I, I, I}, {I}),
      [](Caller& c, std::span<const Value> a, std::span<Value> r) {
        Mem mem{c.memory(), &c};
        if (a[0].i32() != 0) {
          r[0] = Value::of_i32(kEBadf);
          return;
        }
        u32 total = 0;
        bool eof = false;
        if (!for_each_iov(mem, a[1].i32(), a[2].i32(), [&](u32 ptr, u32 len) {
              if (eof || len == 0) return true;
              std::string buf(len, '\0');
              std::cin.read(buf.data(), static_cast<std::streamsize>(len));
              const u32 got = static_cast<u32>(std::cin.gcount());
              if (got < len) eof = true;
              if (!mem.put_bytes(ptr, std::string_view(buf).substr(0, got))) return false;
              total += got;
              return true;
            }))
          return;
        if (!mem.put32(a[3].i32(), total)) return;
        r[0] = Value::of_i32(kESuccess);
      });

  def("fd_close", sig({I}, {I}),
      [](Caller&, std::span<const Value>, std::span<Value> r) {
        r[0] = Value::of_i32(kESuccess);
      });

  def("fd_seek", sig({I, L, I, I}, {I}),
      [](Caller&, std::span<const Value>, std::span<Value> r) {
        r[0] = Value::of_i32(kESpipe);  // the three standard streams do not seek
      });

  // A character device with no rights: enough for a libc to decide that stdout
  // is not a file and stop asking.
  def("fd_fdstat_get", sig({I, I}, {I}),
      [](Caller& c, std::span<const Value> a, std::span<Value> r) {
        Mem mem{c.memory(), &c};
        const u32 p = a[1].i32();
        if (!mem.put32(p, 2) || !mem.put32(p + 4, 0) || !mem.put64(p + 8, 0) ||
            !mem.put64(p + 16, 0))
          return;
        r[0] = Value::of_i32(kESuccess);
      });

  def("fd_prestat_get", sig({I, I}, {I}),
      [](Caller&, std::span<const Value>, std::span<Value> r) {
        r[0] = Value::of_i32(kEBadf);  // no preopened directories at all
      });
  def("fd_prestat_dir_name", sig({I, I, I}, {I}),
      [](Caller&, std::span<const Value>, std::span<Value> r) {
        r[0] = Value::of_i32(kEBadf);
      });
  def("path_open", sig({I, I, I, I, I, L, L, I, I}, {I}),
      [](Caller&, std::span<const Value>, std::span<Value> r) {
        r[0] = Value::of_i32(kENotCapable);
      });

  // `args_get` and `environ_get` share their shape exactly: a pointer array and
  // a flat buffer of NUL-terminated strings, sized by a matching `*_sizes_get`.
  const auto strings_sizes = [](std::vector<std::string>* v) {
    return [v](Caller& c, std::span<const Value> a, std::span<Value> r) {
      Mem mem{c.memory(), &c};
      u32 bytes = 0;
      for (const auto& s : *v) bytes += static_cast<u32>(s.size()) + 1;
      if (!mem.put32(a[0].i32(), static_cast<u32>(v->size())) ||
          !mem.put32(a[1].i32(), bytes))
        return;
      r[0] = Value::of_i32(kESuccess);
    };
  };
  const auto strings_get = [](std::vector<std::string>* v) {
    return [v](Caller& c, std::span<const Value> a, std::span<Value> r) {
      Mem mem{c.memory(), &c};
      u32 ptrs = a[0].i32();
      u32 buf = a[1].i32();
      for (const auto& s : *v) {
        if (!mem.put32(ptrs, buf)) return;
        ptrs += 4;
        if (!mem.put_bytes(buf, s)) return;
        if (!mem.put_bytes(buf + static_cast<u32>(s.size()), std::string_view("\0", 1)))
          return;
        buf += static_cast<u32>(s.size()) + 1;
      }
      r[0] = Value::of_i32(kESuccess);
    };
  };
  def("args_sizes_get", sig({I, I}, {I}), strings_sizes(&cfg.args));
  def("args_get", sig({I, I}, {I}), strings_get(&cfg.args));
  def("environ_sizes_get", sig({I, I}, {I}), strings_sizes(&cfg.env));
  def("environ_get", sig({I, I}, {I}), strings_get(&cfg.env));

  def("clock_time_get", sig({I, L, I}, {I}),
      [](Caller& c, std::span<const Value> a, std::span<Value> r) {
        Mem mem{c.memory(), &c};
        const auto now = std::chrono::system_clock::now().time_since_epoch();
        const u64 ns = static_cast<u64>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(now).count());
        if (!mem.put64(a[2].i32(), ns)) return;
        r[0] = Value::of_i32(kESuccess);
      });

  def("random_get", sig({I, I}, {I}),
      [](Caller& c, std::span<const Value> a, std::span<Value> r) {
        Mem mem{c.memory(), &c};
        const u32 len = a[1].i32();
        if (!mem.in_bounds(a[0].i32(), len)) return;
        std::random_device rd;
        for (u32 i = 0; i < len; ++i)
          mem.m->bytes[a[0].i32() + i] = static_cast<u8>(rd() & 0xff);
        r[0] = Value::of_i32(kESuccess);
      });

  def("sched_yield", sig({}, {I}),
      [](Caller&, std::span<const Value>, std::span<Value> r) {
        r[0] = Value::of_i32(kESuccess);
      });
  def("poll_oneoff", sig({I, I, I, I}, {I}),
      [](Caller&, std::span<const Value>, std::span<Value> r) {
        r[0] = Value::of_i32(kEInval);
      });
}

}  // namespace weasel
