// Store partition — what exists while the module runs.
//
// The spec draws a line that is easy to lose and worth keeping: a *module* is
// text, a *store* is state, and an *instance* is the mapping between them. A
// module says "table 0"; the instance says "table 0 is store table 3"; the store
// holds the elements. Two instances of one module share no memory, and two
// modules that import each other's tables share one entry in the store.
//
// So every index in an instruction is resolved twice — once by the module's
// index space, once by the instance's address space — and a `funcref` is an
// address in the store rather than an index in a module. That is the only way a
// function reference can survive being passed between instances.
export module weasel:store;

import std;
import :common;
import :types;
import :validate;

export namespace weasel {

struct Instance;
struct Store;

// A linear memory: bytes, and a ceiling in pages.
struct MemInst {
  std::vector<u8> bytes;
  u32 max_pages = kMaxPages;
  bool has_max = false;

  u32 pages() const { return static_cast<u32>(bytes.size() / kPageSize); }

  // Returns the old size in pages, or -1 if the memory refuses to grow. The
  // refusal is a value, not a trap: `memory.grow` is the one instruction whose
  // failure the program is expected to handle.
  i32 grow(u32 delta) {
    const u32 old = pages();
    const u64 want = u64{old} + delta;
    const u32 ceiling = has_max ? max_pages : kMaxPages;
    if (want > ceiling) return -1;
    bytes.resize(static_cast<std::size_t>(want) * kPageSize, 0);
    return static_cast<i32>(old);
  }
};

struct TableInst {
  std::vector<Value> elems;  // null is all-zero, so a fresh table is all nulls
  ValType type = ValType::FuncRef;
  u32 max = 0xffffffffu;
  bool has_max = false;

  i32 grow(u32 delta, Value fill) {
    const u32 old = static_cast<u32>(elems.size());
    const u64 want = u64{old} + delta;
    const u64 ceiling = has_max ? max : 0xffffffffull;
    if (want > ceiling) return -1;
    elems.resize(static_cast<std::size_t>(want), fill);
    return static_cast<i32>(old);
  }
};

struct GlobalInst {
  Value value;
  GlobalType type;
};

struct Caller;
using HostFn = std::function<void(Caller&, std::span<const Value>, std::span<Value>)>;

// One entry covers both kinds of function, because `call_indirect` and `funcref`
// must not be able to tell them apart.
struct FuncInst {
  FuncType type;
  Instance* instance = nullptr;  // null for a host function
  const Code* code = nullptr;
  u32 module_index = 0;          // for names in traces
  HostFn host;
  std::string host_name;

  bool is_host() const { return instance == nullptr; }
};

struct Instance {
  const Module* module = nullptr;
  const std::vector<Code>* codes = nullptr;
  std::string name;

  // Module index space -> store address, one vector per space.
  std::vector<u32> funcs;
  std::vector<u32> tables;
  std::vector<u32> mems;
  std::vector<u32> globals;

  // Segment contents that `memory.init` and `table.init` still need. Dropping a
  // segment empties its entry; it does not remove it, because the indices are
  // baked into the code.
  std::vector<std::vector<u8>> datas;
  std::vector<std::vector<Value>> elems;
  std::vector<bool> data_dropped;
  std::vector<bool> elem_dropped;
};

struct Store {
  std::vector<FuncInst> funcs;
  std::vector<TableInst> tables;
  std::vector<MemInst> mems;
  std::vector<GlobalInst> globals;
  std::vector<std::unique_ptr<Instance>> instances;

  u32 add_func(FuncInst f) {
    funcs.push_back(std::move(f));
    return static_cast<u32>(funcs.size() - 1);
  }
  u32 add_table(TableInst t) {
    tables.push_back(std::move(t));
    return static_cast<u32>(tables.size() - 1);
  }
  u32 add_mem(MemInst m) {
    mems.push_back(std::move(m));
    return static_cast<u32>(mems.size() - 1);
  }
  u32 add_global(GlobalInst g) {
    globals.push_back(g);
    return static_cast<u32>(globals.size() - 1);
  }

  // A host function, given a signature and something to run.
  u32 add_host(std::string name, FuncType type, HostFn fn) {
    FuncInst f;
    f.type = std::move(type);
    f.host = std::move(fn);
    f.host_name = std::move(name);
    return add_func(std::move(f));
  }
};

// What a host function is handed: where it was called from, and a place to put a
// trap if it cannot do what was asked.
struct Caller {
  Store* store = nullptr;
  Instance* instance = nullptr;
  Trap trap = Trap::None;
  std::string message;
  i32 exit_code = 0;

  MemInst* memory() const {
    if (!instance || instance->mems.empty()) return nullptr;
    return &store->mems[instance->mems[0]];
  }
  void fail(Trap t, std::string msg = {}) {
    if (trap == Trap::None) {
      trap = t;
      message = std::move(msg);
    }
  }
};

// The four things a module can import, as one value: what a name resolves to.
struct Extern {
  ExternKind kind = ExternKind::Func;
  u32 addr = 0;
};

// A registry of names the modules being instantiated may import from. Both host
// modules (`wasi_snapshot_preview1`) and already-instantiated wasm modules end up
// here, which is what lets one module import another's exports.
struct Linker {
  std::map<std::string, std::map<std::string, Extern>> namespaces;

  void define(std::string ns, std::string name, Extern e) {
    namespaces[std::move(ns)][std::move(name)] = e;
  }
  const Extern* find(const std::string& ns, const std::string& name) const {
    auto i = namespaces.find(ns);
    if (i == namespaces.end()) return nullptr;
    auto j = i->second.find(name);
    if (j == i->second.end()) return nullptr;
    return &j->second;
  }
  // Publish every export of an instance under a namespace.
  void publish(const std::string& ns, const Instance& inst) {
    for (const Export& ex : inst.module->exports) {
      Extern e;
      e.kind = ex.kind;
      switch (ex.kind) {
        case ExternKind::Func: e.addr = inst.funcs[ex.index]; break;
        case ExternKind::Table: e.addr = inst.tables[ex.index]; break;
        case ExternKind::Memory: e.addr = inst.mems[ex.index]; break;
        case ExternKind::Global: e.addr = inst.globals[ex.index]; break;
      }
      define(ns, ex.name, e);
    }
  }
};

inline const Export* find_export(const Instance& inst, std::string_view name) {
  for (const Export& ex : inst.module->exports)
    if (ex.name == name) return &ex;
  return nullptr;
}

}  // namespace weasel
