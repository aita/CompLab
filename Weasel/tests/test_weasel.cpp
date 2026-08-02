// The test runner.
//
// Every `.wat` under `tests/wat/` is read twice: once by Weasel's own text
// parser, and once by `wat2wasm` and then Weasel's binary decoder. Both must
// produce a module that prints identically. That is the check that keeps the two
// front ends honest — a mistake in either shows up as a diff rather than as a
// wrong answer months later.
//
// The same files carry their own expectations, in comments the parser already
// ignores:
//
//   ;;= invoke fac 10 => 3628800
//   ;;= trap   div 1 0 => integer divide by zero
//   ;;= stdout hello, world
//
// so a case is one file and reads as one thing.

import std;
import weasel;

using namespace weasel;

namespace {

int failures = 0;
int checks = 0;

void fail(std::string_view where, std::string_view what) {
  ++failures;
  std::println(std::cerr, "FAIL {}: {}", where, what);
}

void expect(bool cond, std::string_view where, std::string_view what) {
  ++checks;
  if (!cond) fail(where, what);
}

void expect_eq(const std::string& a, const std::string& b, std::string_view where,
               std::string_view what) {
  ++checks;
  if (a == b) return;
  ++failures;
  std::println(std::cerr, "FAIL {}: {}\n  expected: {}\n  actual:   {}", where, what, b, a);
}

// ---------------------------------------------------------------------------

std::string read_text(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

bool have_wat2wasm() {
  static const bool yes = std::system("wat2wasm --version > /dev/null 2>&1") == 0;
  return yes;
}

// The comparable spelling of a value: integers in decimal, floats as bits,
// because two different NaNs are two different results.
std::string canon(ValType t, Value v) {
  switch (t) {
    case ValType::I32: return std::format("{}", static_cast<i32>(v.i32()));
    case ValType::I64: return std::format("{}", static_cast<i64>(v.i64()));
    case ValType::F32: return std::format("{:#010x}", static_cast<u32>(v.bits));
    case ValType::F64: return std::format("{:#018x}", v.bits);
    default: return v.is_null() ? "null" : std::format("ref{}", v.ref_addr());
  }
}

bool parse_value(ValType t, std::string s, Value& out) {
  const auto number = [&](auto& v) {
    return std::from_chars(s.data(), s.data() + s.size(), v).ec == std::errc{};
  };
  switch (t) {
    case ValType::I32: {
      i64 v = 0;
      if (s.starts_with("0x")) {
        u64 u = 0;
        if (std::from_chars(s.data() + 2, s.data() + s.size(), u, 16).ec != std::errc{})
          return false;
        out = Value::of_i32(static_cast<u32>(u));
        return true;
      }
      if (!number(v)) return false;
      out = Value::of_i32(static_cast<u32>(v));
      return true;
    }
    case ValType::I64: {
      i64 v = 0;
      if (s.starts_with("0x")) {
        u64 u = 0;
        if (std::from_chars(s.data() + 2, s.data() + s.size(), u, 16).ec != std::errc{})
          return false;
        out = Value::of_i64(u);
        return true;
      }
      if (!number(v)) return false;
      out = Value::of_i64(static_cast<u64>(v));
      return true;
    }
    case ValType::F32: case ValType::F64: {
      const bool neg = s.starts_with('-');
      std::string body = neg ? s.substr(1) : s;
      f64 v = 0;
      if (body == "inf") v = std::numeric_limits<f64>::infinity();
      else if (body == "nan") v = std::numeric_limits<f64>::quiet_NaN();
      else if (std::from_chars(body.data(), body.data() + body.size(), v).ec != std::errc{})
        return false;
      if (neg) v = -v;
      out = (t == ValType::F32) ? Value::of_f32(static_cast<f32>(v)) : Value::of_f64(v);
      return true;
    }
    default:
      if (s != "null") return false;
      out = Value::null_ref();
      return true;
  }
}

std::vector<std::string> words(std::string_view line) {
  std::vector<std::string> out;
  std::size_t i = 0;
  while (i < line.size()) {
    while (i < line.size() && line[i] == ' ') ++i;
    const std::size_t start = i;
    while (i < line.size() && line[i] != ' ') ++i;
    if (i > start) out.emplace_back(line.substr(start, i - start));
  }
  return out;
}

struct Directive {
  std::string kind;              // invoke, trap, stdout
  std::string name;
  std::vector<std::string> args;
  std::vector<std::string> expect;
};

std::vector<Directive> directives(std::string_view src) {
  std::vector<Directive> out;
  std::size_t pos = 0;
  while (pos < src.size()) {
    const std::size_t eol = src.find('\n', pos);
    std::string_view line = src.substr(pos, (eol == std::string_view::npos) ? eol : eol - pos);
    pos = (eol == std::string_view::npos) ? src.size() : eol + 1;
    const std::size_t at = line.find(";;=");
    if (at == std::string_view::npos) continue;
    line.remove_prefix(at + 3);
    if (line.starts_with(" stdout ")) {
      Directive dd;
      dd.kind = "stdout";
      dd.expect.emplace_back(line.substr(8));
      out.push_back(std::move(dd));
      continue;
    }
    const std::size_t arrow = line.find("=>");
    std::vector<std::string> lhs = words(line.substr(0, arrow));
    if (lhs.size() < 2) continue;
    Directive dd;
    dd.kind = lhs[0];
    dd.name = lhs[1];
    dd.args.assign(lhs.begin() + 2, lhs.end());
    if (arrow != std::string_view::npos) {
      if (dd.kind == "trap") {
        std::string_view rest = line.substr(arrow + 2);
        while (rest.starts_with(' ')) rest.remove_prefix(1);
        dd.expect.emplace_back(rest);
      } else {
        dd.expect = words(line.substr(arrow + 2));
      }
    }
    out.push_back(std::move(dd));
  }
  return out;
}

// ---------------------------------------------------------------------------

// stdout is redirected into a string while a module runs, so a WASI test can say
// what it expects to have printed.
struct Capture {
  std::ostringstream buffer;
  std::streambuf* saved = nullptr;
  Capture() { saved = std::cout.rdbuf(buffer.rdbuf()); }
  ~Capture() { std::cout.rdbuf(saved); }
};

void run_file(const std::filesystem::path& path) {
  const std::string where = path.filename().string();
  const std::string src = read_text(path.string());

  Diag td;
  LoadedModule from_text;
  const std::vector<u8> bytes(src.begin(), src.end());
  if (!load(bytes, from_text, td)) {
    fail(where, std::format("text front end: {}", td.message));
    return;
  }
  const std::string text_dump = dump_module(from_text.module);

  // The same source through wabt, then through the binary decoder.
  if (have_wat2wasm()) {
    const auto tmp = std::filesystem::temp_directory_path() /
                     std::format("weasel-{}.wasm", path.stem().string());
    const std::string cmd =
        std::format("wat2wasm '{}' -o '{}' 2>/dev/null", path.string(), tmp.string());
    if (std::system(cmd.c_str()) == 0) {
      auto wasm = read_file(tmp.string());
      std::filesystem::remove(tmp);
      if (!wasm) {
        fail(where, "wat2wasm produced nothing");
      } else {
        Diag bd;
        LoadedModule from_binary;
        if (!load(*wasm, from_binary, bd))
          fail(where, std::format("binary front end: {}", bd.message));
        else
          expect_eq(dump_module(from_binary.module), text_dump, where,
                    "the two front ends disagree");
      }
    } else {
      fail(where, "wat2wasm rejected a file Weasel accepted");
    }
  }

  const auto ds = directives(src);
  if (ds.empty()) return;

  Store store;
  Linker linker;
  WasiConfig cfg;
  cfg.args.push_back(where);
  add_wasi(store, linker, cfg);

  Capture cap;
  Diag id;
  Instance* inst = instantiate(store, linker, from_text, where, id);
  if (!inst) {
    fail(where, std::format("instantiation: {}", id.message));
    return;
  }

  for (const Directive& dd : ds) {
    if (dd.kind == "stdout") {
      std::cout.flush();
      expect_eq(cap.buffer.str(), dd.expect[0] + "\n", where, "stdout");
      continue;
    }
    const Export* ex = find_export(*inst, dd.name);
    if (!ex || ex->kind != ExternKind::Func) {
      fail(where, std::format("no exported function `{}`", dd.name));
      continue;
    }
    const u32 addr = inst->funcs[ex->index];
    const FuncType& ft = store.funcs[addr].type;
    if (ft.params.size() != dd.args.size()) {
      fail(where, std::format("`{}` takes {} arguments, {} given", dd.name,
                              ft.params.size(), dd.args.size()));
      continue;
    }
    std::vector<Value> args(ft.params.size());
    bool bad = false;
    for (std::size_t i = 0; i < args.size(); ++i)
      if (!parse_value(ft.params[i], dd.args[i], args[i])) {
        fail(where, std::format("cannot read `{}` as {}", dd.args[i],
                                valtype_name(ft.params[i])));
        bad = true;
      }
    if (bad) continue;

    Machine machine(store);
    machine.fuel = 100'000'000;
    std::vector<Value> results;
    const bool ok = machine.invoke(addr, args, results);

    if (dd.kind == "trap") {
      ++checks;
      if (ok) {
        fail(where, std::format("`{}` was expected to trap and did not", dd.name));
      } else if (!dd.expect.empty() &&
                 machine.trap_text().find(dd.expect[0]) == std::string::npos) {
        --checks;
        expect_eq(machine.trap_text(), dd.expect[0], where,
                  std::format("`{}` trapped with the wrong message", dd.name));
      }
      continue;
    }
    if (!ok) {
      fail(where, std::format("`{}` trapped: {}", dd.name, machine.trap_text()));
      continue;
    }
    if (results.size() != dd.expect.size()) {
      fail(where, std::format("`{}` returned {} values, {} expected", dd.name,
                              results.size(), dd.expect.size()));
      continue;
    }
    for (std::size_t i = 0; i < results.size(); ++i) {
      Value want{};
      if (!parse_value(ft.results[i], dd.expect[i], want)) {
        fail(where, std::format("cannot read `{}` as {}", dd.expect[i],
                                valtype_name(ft.results[i])));
        continue;
      }
      expect_eq(canon(ft.results[i], results[i]), canon(ft.results[i], want), where,
                std::format("{}({})", dd.name,
                            [&] {
                              std::string s;
                              for (const auto& a : dd.args) {
                                if (!s.empty()) s += ", ";
                                s += a;
                              }
                              return s;
                            }()));
    }
  }
}

// ---------------------------------------------------------------------------

// A handful of things no `.wat` can reach: the LEB128 reader's edges, and the
// modules a well-formed file cannot express.
void unit_tests() {
  {
    const std::vector<u8> b{0xe5, 0x8e, 0x26};
    Diag d;
    Reader r{b, 0, &d};
    expect(r.uleb(32) == 624485, "leb", "unsigned LEB128");
  }
  {
    const std::vector<u8> b{0xc0, 0xbb, 0x78};
    Diag d;
    Reader r{b, 0, &d};
    expect(r.sleb(32) == -123456, "leb", "signed LEB128");
  }
  {
    // Five bytes is the most a u32 may take, and the top byte may not carry
    // bits the value cannot hold.
    const std::vector<u8> b{0xff, 0xff, 0xff, 0xff, 0x7f};
    Diag d;
    Reader r{b, 0, &d};
    r.uleb(32);
    expect(d.failed, "leb", "an over-wide u32 must be rejected");
  }
  {
    Diag d;
    LoadedModule lm;
    const std::string src = "(module (func (result i32) i64.const 1))";
    const std::vector<u8> bytes(src.begin(), src.end());
    expect(!load(bytes, lm, d), "validate", "a wrong result type must be rejected");
  }
  {
    Diag d;
    LoadedModule lm;
    const std::string src = "(module (func (result i32) unreachable))";
    const std::vector<u8> bytes(src.begin(), src.end());
    expect(load(bytes, lm, d), "validate",
           std::format("unreachable satisfies any result type ({})", d.message));
  }
  {
    Diag d;
    LoadedModule lm;
    const std::string src = "(module (func br 1))";
    const std::vector<u8> bytes(src.begin(), src.end());
    expect(!load(bytes, lm, d), "validate", "a branch past the function must be rejected");
  }
  {
    Diag d;
    LoadedModule lm;
    const std::string src = "(module (global i32 (i32.const 1)) (func (result i32) global.get 0))";
    const std::vector<u8> bytes(src.begin(), src.end());
    expect(load(bytes, lm, d), "validate", std::format("globals ({})", d.message));
  }
  {
    // `block` and `end` leave nothing behind: a function whose body is one
    // `nop` inside a block plans to a single `return`.
    Diag d;
    LoadedModule lm;
    const std::string src = "(module (func block nop end))";
    const std::vector<u8> bytes(src.begin(), src.end());
    if (load(bytes, lm, d))
      expect(lm.codes[0].instrs.size() == 1 && lm.codes[0].instrs[0].op == Op::Return,
             "plan", "structured control flow must not survive planning");
    else
      fail("plan", d.message);
  }
}

}  // namespace

int main() {
  unit_tests();

  const std::filesystem::path dir = std::filesystem::path(WEASEL_TEST_DIR) / "wat";
  std::vector<std::filesystem::path> files;
  if (std::filesystem::exists(dir))
    for (const auto& e : std::filesystem::directory_iterator(dir))
      if (e.path().extension() == ".wat") files.push_back(e.path());
  std::ranges::sort(files);
  for (const auto& f : files) run_file(f);

  if (!have_wat2wasm())
    std::println(std::cerr,
                 "note: wat2wasm was not found, so the two front ends were not compared");
  std::println("{} checks, {} failures", checks, failures);
  return failures == 0 ? 0 : 1;
}
