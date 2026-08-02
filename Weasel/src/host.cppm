// Host partition — the `env` module the sibling Ferret compiles against.
//
// Ferret draws a graph and emits `\0asm` bytes for it; the bytes import five
// functions from `env`, which in the browser are supplied by the page. Supplying
// them here is what lets a Ferret graph run from a terminal, and it is the
// smallest possible demonstration of the point :wasi makes at greater length —
// that there is nothing special about a "system" interface. It is five host
// functions with agreed names.
export module weasel:host;

import std;
import :common;
import :types;
import :store;

export namespace weasel {

// Register `env`. `sink` collects everything the module logs or says, so an
// embedder that is not a terminal can have it too.
struct EnvLog {
  std::vector<f64> logged;
  std::vector<std::string> said;
  std::vector<std::pair<u32, f64>> watched;
  bool echo = true;  // also print to stdout as it happens
};

void add_env(Store& store, Linker& linker, EnvLog& log) {
  const auto def = [&](std::string name, FuncType t, HostFn fn) {
    const u32 addr = store.add_host(name, std::move(t), std::move(fn));
    linker.define("env", std::move(name), Extern{ExternKind::Func, addr});
  };
  constexpr ValType I = ValType::I32;
  constexpr ValType F = ValType::F64;

  def("log", FuncType{{F}, {}},
      [&log](Caller&, std::span<const Value> a, std::span<Value>) {
        log.logged.push_back(a[0].f64v());
        if (log.echo) std::println("{}", a[0].f64v());
      });

  def("random", FuncType{{}, {F}},
      [](Caller&, std::span<const Value>, std::span<Value> r) {
        static std::mt19937_64 rng{0x5eed};  // fixed, so a run repeats
        static std::uniform_real_distribution<f64> dist(0.0, 1.0);
        r[0] = Value::of_f64(dist(rng));
      });

  def("now", FuncType{{}, {F}},
      [](Caller&, std::span<const Value>, std::span<Value> r) {
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch());
        r[0] = Value::of_f64(static_cast<f64>(ms.count()));
      });

  // A graph says text by handing over a slice of its own memory — the same
  // arrangement WASI uses for everything, in one line.
  def("say", FuncType{{I, I}, {}},
      [&log](Caller& c, std::span<const Value> a, std::span<Value>) {
        MemInst* mem = c.memory();
        const u64 ptr = a[0].i32();
        const u64 len = a[1].i32();
        if (!mem || ptr + len > mem->bytes.size()) {
          c.fail(Trap::OutOfBoundsMemory, "say() outside linear memory");
          return;
        }
        std::string s(reinterpret_cast<const char*>(mem->bytes.data() + ptr), len);
        if (log.echo) std::println("{}", s);
        log.said.push_back(std::move(s));
      });

  def("watch", FuncType{{I, F}, {F}},
      [&log](Caller&, std::span<const Value> a, std::span<Value> r) {
        log.watched.emplace_back(a[0].i32(), a[1].f64v());
        r[0] = a[1];  // a watch is transparent: it returns what it was given
      });
}

}  // namespace weasel
