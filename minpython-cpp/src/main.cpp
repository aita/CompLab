// MinPython CLI: run a .mpy file on the register VM, optionally with the JIT.
//
//   minpython program.mpy          run on the interpreter
//   minpython --jit program.mpy    attach the tracing JIT
//   minpython --dis program.mpy    print the disassembly and exit
import std;

import minpython;

using namespace minpython;

int main(int argc, char** argv) {
  bool jit = false, method = false, tiered = false, dis = false;
  std::string path;
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--jit") jit = true;
    else if (arg == "--method") method = true;
    else if (arg == "--tiered") tiered = true;
    else if (arg == "--dis") dis = true;
    else path = arg;
  }
  if (path.empty()) {
    std::cerr << "usage: minpython [--jit] [--method|--tiered] [--dis] "
                 "program.mpy\n";
    return 2;
  }
  std::ifstream in(path);
  if (!in) {
    std::cerr << "cannot open " << path << "\n";
    return 2;
  }
  std::stringstream ss;
  ss << in.rdbuf();

  std::string err;
  auto prog = compile_module(ss.str(), err);
  if (!prog) {
    std::cerr << "MinPythonError: " << err << "\n";
    return 1;
  }
  if (dis) {
    std::cout << disassemble(*prog->module) << "\n";
    return 0;
  }
  VM vm;
  std::unique_ptr<TracingJIT> tj;
  std::unique_ptr<MethodJIT> mj;
  std::unique_ptr<TieredJIT> ti;
  if (jit) tj = std::make_unique<TracingJIT>(vm);
  if (tiered) ti = std::make_unique<TieredJIT>(vm);
  else if (method) mj = std::make_unique<MethodJIT>(vm);
  vm.run_code(prog->module);
  if (vm.diag.failed) {
    std::cerr << "MinPythonError: " << vm.diag.message << "\n";
    return 1;
  }
  if (tj)
    std::cerr << "[trace jit] compiled=" << tj->n_compiled
              << " mixed=" << tj->n_mixed << " runs=" << tj->n_trace_runs
              << " aborted=" << tj->n_aborted
              << " type_deopt=" << tj->n_type_deopt << "\n";
  if (mj)
    std::cerr << "[method jit] compiled=" << mj->n_compiled
              << " mixed=" << mj->n_mixed
              << " native_calls=" << mj->n_calls_native
              << " aborted=" << mj->n_aborted << "\n";
  if (ti)
    std::cerr << "[async method jit] compiled=" << ti->n_compiled
              << " native_calls=" << ti->n_calls_native << "\n";
  if (vm.n_gc)
    std::cerr << "[gc] collections=" << vm.n_gc
              << " live_objects=" << vm.live_objects() << "\n";
  return 0;
}
