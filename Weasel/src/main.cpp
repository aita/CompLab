// The command line. Four things to do with a module: look at what was read,
// look at what validation planned, check it, or run it.

import std;
import weasel;

using namespace weasel;

namespace {

void usage() {
  std::println(std::cerr, R"(usage: weasel <command> [options] <file.wat|file.wasm> [args...]

commands:
  run      instantiate and call a function (default: _start, else main)
  dump     print the module as it was read
  plan     print what validation planned, one flat listing per function
  check    decode and validate, print nothing on success

options for run:
  --invoke NAME    call this export instead of the default
  --arg V          one argument, repeated; read according to the signature
  --trace          print every instruction and the operand stack, to stderr
  --fuel N         stop after N instructions
  --               everything after this is passed to the module as argv)");
}

bool parse_arg(ValType t, const std::string& s, Value& out) {
  const char* b = s.data();
  const char* e = b + s.size();
  switch (t) {
    case ValType::I32: {
      i64 v = 0;
      if (std::from_chars(b, e, v).ec != std::errc{}) return false;
      out = Value::of_i32(static_cast<u32>(v));
      return true;
    }
    case ValType::I64: {
      i64 v = 0;
      if (std::from_chars(b, e, v).ec != std::errc{}) return false;
      out = Value::of_i64(static_cast<u64>(v));
      return true;
    }
    case ValType::F32: {
      f32 v = 0;
      if (std::from_chars(b, e, v).ec != std::errc{}) return false;
      out = Value::of_f32(v);
      return true;
    }
    case ValType::F64: {
      f64 v = 0;
      if (std::from_chars(b, e, v).ec != std::errc{}) return false;
      out = Value::of_f64(v);
      return true;
    }
    default:
      if (s == "null") {
        out = Value::null_ref();
        return true;
      }
      return false;
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    usage();
    return 2;
  }
  const std::string command = argv[1];
  std::string path;
  std::string invoke;
  std::vector<std::string> args;
  std::vector<std::string> module_argv;
  bool trace = false;
  u64 fuel = 0;

  for (int i = 2; i < argc; ++i) {
    const std::string a = argv[i];
    if (a == "--invoke" && i + 1 < argc) invoke = argv[++i];
    else if (a == "--arg" && i + 1 < argc) args.push_back(argv[++i]);
    else if (a == "--trace") trace = true;
    else if (a == "--fuel" && i + 1 < argc) fuel = std::strtoull(argv[++i], nullptr, 10);
    else if (a == "--") {
      for (int j = i + 1; j < argc; ++j) module_argv.push_back(argv[j]);
      break;
    } else if (a.starts_with("--")) {
      std::println(std::cerr, "weasel: unknown option {}", a);
      return 2;
    } else if (path.empty()) {
      path = a;
    } else {
      module_argv.push_back(a);
    }
  }
  if (path.empty()) {
    usage();
    return 2;
  }

  auto bytes = read_file(path);
  if (!bytes) {
    std::println(std::cerr, "weasel: cannot read {}", path);
    return 1;
  }

  Diag d;
  LoadedModule lm;
  if (!load(*bytes, lm, d)) {
    std::println(std::cerr, "weasel: {}: {}", path, d.message);
    return 1;
  }

  if (command == "check") return 0;
  if (command == "dump") {
    std::print("{}", dump_module(lm.module));
    return 0;
  }
  if (command == "plan") {
    std::print("{}", dump_plan(lm.module, lm.codes));
    return 0;
  }
  if (command != "run") {
    usage();
    return 2;
  }

  Store store;
  Linker linker;
  WasiConfig cfg;
  cfg.args.push_back(path);
  for (const auto& a : module_argv) cfg.args.push_back(a);
  add_wasi(store, linker, cfg);
  // `env` costs nothing to offer and is what the sibling Ferret compiles
  // against; a module that imports neither never notices either is there.
  EnvLog env_log;
  add_env(store, linker, env_log);

  Instance* inst = instantiate(store, linker, lm, path, d);
  if (!inst) {
    std::println(std::cerr, "weasel: {}: {}", path, d.message);
    return 1;
  }

  // With no `--invoke`, run whatever the module looks like it is: a WASI command
  // exports `_start`, a plain program usually exports `main`.
  if (invoke.empty()) {
    if (find_export(*inst, "_start")) invoke = "_start";
    else if (find_export(*inst, "main")) invoke = "main";
    else {
      std::println(std::cerr, "weasel: {} exports neither _start nor main; use --invoke",
                   path);
      return 1;
    }
  }
  const Export* ex = find_export(*inst, invoke);
  if (!ex || ex->kind != ExternKind::Func) {
    std::println(std::cerr, "weasel: {} exports no function named `{}`", path, invoke);
    return 1;
  }

  const u32 addr = inst->funcs[ex->index];
  const FuncType& ft = store.funcs[addr].type;
  if (args.size() != ft.params.size()) {
    std::println(std::cerr, "weasel: `{}` takes {} arguments, {} given", invoke,
                 ft.params.size(), args.size());
    return 1;
  }
  std::vector<Value> vals(ft.params.size());
  for (std::size_t i = 0; i < args.size(); ++i) {
    if (!parse_arg(ft.params[i], args[i], vals[i])) {
      std::println(std::cerr, "weasel: `{}` is not a {}", args[i],
                   valtype_name(ft.params[i]));
      return 1;
    }
  }

  Machine machine(store);
  machine.trace = trace;
  machine.fuel = fuel;
  std::vector<Value> results;
  if (!machine.invoke(addr, vals, results)) {
    if (machine.trap == Trap::Exit) return machine.exit_code;
    std::println(std::cerr, "weasel: trap: {}", machine.trap_text());
    return 1;
  }
  for (std::size_t i = 0; i < results.size(); ++i)
    std::println("{}", format_value(ft.results[i], results[i]));
  return 0;
}
