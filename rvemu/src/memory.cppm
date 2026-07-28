// Memory partition — the guest's 64-bit address space.
//
// A user-mode RV64 process touches a handful of small, far-apart regions: the
// ELF image down near 0x10000, a heap just above it, an 8 MiB stack just under
// 2^47, and whatever mmap hands out in between. A flat allocation would be
// absurd, so pages live in a hash map and are created on demand.
//
// Every access goes through a small direct-mapped TLB of Page pointers, which is
// what keeps the interpreter's fetch/load/store off the hash map in the common
// case. The TLB is flushed wholesale whenever the mapping changes -- mappings
// change a few times per process, so there is nothing to be clever about.
//
// Permissions are checked on every guest access. The loader and the debugger use
// the `poke`/`peek` back doors instead, because both legitimately write to pages
// the guest may only read (program text, and gdb's breakpoint bytes).
export module rvemu:memory;

import std;
import :common;

export namespace rvemu {

inline constexpr u64 kPageBits = 12;
inline constexpr u64 kPageSize = u64{1} << kPageBits;
inline constexpr u64 kPageMask = kPageSize - 1;

enum Perm : u8 {
  PermNone = 0,
  PermR = 1,
  PermW = 2,
  PermX = 4,
  PermRW = PermR | PermW,
  PermRX = PermR | PermX,
  PermRWX = PermR | PermW | PermX,
};

// Which side of the machine took a fault, for the SIGSEGV report and for gdb's
// stop packet.
enum class Access : u8 { Fetch, Load, Store };

inline const char* access_name(Access a) {
  switch (a) {
    case Access::Fetch: return "fetch";
    case Access::Load: return "load";
    case Access::Store: return "store";
  }
  return "?";
}

class Memory {
 public:
  struct Page {
    u8 perm = PermNone;
    std::array<u8, kPageSize> data{};
  };

  Memory() { flush_tlb(); }

  // -- mapping ---------------------------------------------------------------

  // Create (or re-permission) every page overlapping [addr, addr+len). Pages
  // that did not exist are zero-filled; existing pages keep their contents
  // unless `zero` is set, which is what an anonymous mmap over old ground wants.
  void map(u64 addr, u64 len, u8 perm, bool zero = false) {
    if (len == 0) return;
    const u64 first = align_down(addr, kPageSize);
    const u64 last = align_up(addr + len, kPageSize);
    for (u64 p = first; p != last; p += kPageSize) {
      auto it = pages_.find(p);
      if (it == pages_.end()) {
        auto page = std::make_unique<Page>();
        page->perm = perm;
        pages_.emplace(p, std::move(page));
      } else {
        it->second->perm = perm;
        if (zero) it->second->data.fill(0);
      }
    }
    flush_tlb();
  }

  // Like map(), but existing pages gain `perm` instead of being reset to it.
  // Two PT_LOAD segments can share a page -- the tail of read-execute text and
  // the head of read-write data land together often enough -- and the page has
  // to satisfy both.
  void map_merge(u64 addr, u64 len, u8 perm) {
    if (len == 0) return;
    const u64 first = align_down(addr, kPageSize);
    const u64 last = align_up(addr + len, kPageSize);
    for (u64 p = first; p != last; p += kPageSize) {
      auto it = pages_.find(p);
      if (it == pages_.end()) {
        auto page = std::make_unique<Page>();
        page->perm = perm;
        pages_.emplace(p, std::move(page));
      } else {
        it->second->perm |= perm;
      }
    }
    flush_tlb();
  }

  void protect(u64 addr, u64 len, u8 perm) {
    if (len == 0) return;
    const u64 first = align_down(addr, kPageSize);
    const u64 last = align_up(addr + len, kPageSize);
    for (u64 p = first; p != last; p += kPageSize) {
      if (auto it = pages_.find(p); it != pages_.end()) it->second->perm = perm;
    }
    flush_tlb();
  }

  void unmap(u64 addr, u64 len) {
    if (len == 0) return;
    const u64 first = align_down(addr, kPageSize);
    const u64 last = align_up(addr + len, kPageSize);
    for (u64 p = first; p != last; p += kPageSize) pages_.erase(p);
    flush_tlb();
  }

  bool mapped(u64 addr) const { return pages_.contains(align_down(addr, kPageSize)); }

  // Is every page of [addr, addr+len) mapped? Used by mmap's placement search.
  bool range_free(u64 addr, u64 len) const {
    const u64 first = align_down(addr, kPageSize);
    const u64 last = align_up(addr + len, kPageSize);
    for (u64 p = first; p != last; p += kPageSize) {
      if (pages_.contains(p)) return false;
    }
    return true;
  }

  u64 page_count() const { return pages_.size(); }

  // -- faults ----------------------------------------------------------------

  // Set by any access that returns false. Only meaningful right after a failure.
  u64 fault_addr = 0;
  Access fault_access = Access::Load;

  // -- guest accesses (permission-checked) -----------------------------------

  bool read(u64 addr, void* dst, u64 n, Access how = Access::Load) {
    const u8 need = (how == Access::Fetch) ? PermX : PermR;
    return copy_out(addr, static_cast<u8*>(dst), n, need, how);
  }

  bool write(u64 addr, const void* src, u64 n) {
    return copy_in(addr, static_cast<const u8*>(src), n, PermW, Access::Store);
  }

  template <class T>
  bool load(u64 addr, T& out, Access how = Access::Load) {
    static_assert(std::is_trivially_copyable_v<T>);
    // Fast path: the whole object sits inside one page we already know about.
    if (Page* pg = lookup(addr, (how == Access::Fetch) ? PermX : PermR, how);
        pg && (addr & kPageMask) + sizeof(T) <= kPageSize) {
      std::memcpy(&out, pg->data.data() + (addr & kPageMask), sizeof(T));
      return true;
    }
    return copy_out(addr, reinterpret_cast<u8*>(&out), sizeof(T),
                    (how == Access::Fetch) ? PermX : PermR, how);
  }

  template <class T>
  bool store(u64 addr, T v) {
    static_assert(std::is_trivially_copyable_v<T>);
    if (Page* pg = lookup(addr, PermW, Access::Store);
        pg && (addr & kPageMask) + sizeof(T) <= kPageSize) {
      std::memcpy(pg->data.data() + (addr & kPageMask), &v, sizeof(T));
      return true;
    }
    return copy_in(addr, reinterpret_cast<const u8*>(&v), sizeof(T), PermW, Access::Store);
  }

  // -- back doors (no permission check) --------------------------------------
  //
  // The ELF loader fills text pages before marking them read-execute, and the
  // gdb stub writes ebreak into them afterwards. Both are the machine's own
  // doing rather than the guest's, so neither goes through the checks.

  bool peek(u64 addr, void* dst, u64 n) {
    return copy_out(addr, static_cast<u8*>(dst), n, PermNone, Access::Load);
  }

  bool poke(u64 addr, const void* src, u64 n) {
    return copy_in(addr, static_cast<const u8*>(src), n, PermNone, Access::Store);
  }

  // Read a NUL-terminated guest string, stopping at `limit` bytes. Used for
  // syscall paths and for the `qXfer` bits of the gdb stub.
  bool read_cstr(u64 addr, std::string& out, u64 limit = 4096) {
    out.clear();
    for (u64 i = 0; i < limit; ++i) {
      u8 c = 0;
      if (!load<u8>(addr + i, c)) return false;
      if (c == 0) return true;
      out.push_back(static_cast<char>(c));
    }
    return true;  // truncated, but the caller asked for a limit
  }

 private:
  // A 256-entry direct-mapped translation cache. A miss costs one hash lookup,
  // so this is a latency trim rather than a correctness structure.
  static constexpr u64 kTlbEntries = 256;
  struct TlbEntry {
    u64 page = ~u64{0};
    Page* ptr = nullptr;
  };

  std::unordered_map<u64, std::unique_ptr<Page>> pages_;
  std::array<TlbEntry, kTlbEntries> tlb_{};

  void flush_tlb() { tlb_.fill(TlbEntry{}); }

  // Find the page holding `addr` and check `need` against its permissions.
  // Returns nullptr and records the fault on failure. `need == PermNone` skips
  // the check, which is how peek/poke get in.
  Page* lookup(u64 addr, u8 need, Access how) {
    const u64 vpn = addr >> kPageBits;
    TlbEntry& e = tlb_[vpn & (kTlbEntries - 1)];
    Page* pg = nullptr;
    if (e.page == vpn) {
      pg = e.ptr;
    } else {
      auto it = pages_.find(vpn << kPageBits);
      if (it == pages_.end()) {
        fault_addr = addr;
        fault_access = how;
        return nullptr;
      }
      pg = it->second.get();
      e.page = vpn;
      e.ptr = pg;
    }
    if (need != PermNone && (pg->perm & need) != need) {
      fault_addr = addr;
      fault_access = how;
      return nullptr;
    }
    return pg;
  }

  // The general path: walks page by page so an access may straddle a boundary.
  // RISC-V user mode permits misaligned load/store, and Linux emulates the ones
  // hardware traps on, so the emulator simply allows them.
  bool copy_out(u64 addr, u8* dst, u64 n, u8 need, Access how) {
    while (n) {
      Page* pg = lookup(addr, need, how);
      if (!pg) return false;
      const u64 off = addr & kPageMask;
      const u64 chunk = std::min(n, kPageSize - off);
      std::memcpy(dst, pg->data.data() + off, chunk);
      addr += chunk;
      dst += chunk;
      n -= chunk;
    }
    return true;
  }

  bool copy_in(u64 addr, const u8* src, u64 n, u8 need, Access how) {
    while (n) {
      Page* pg = lookup(addr, need, how);
      if (!pg) return false;
      const u64 off = addr & kPageMask;
      const u64 chunk = std::min(n, kPageSize - off);
      std::memcpy(pg->data.data() + off, src, chunk);
      addr += chunk;
      src += chunk;
      n -= chunk;
    }
    return true;
  }
};

}  // namespace rvemu
