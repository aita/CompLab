// MinPython CLI: run a .mpy file on the register VM, optionally with the JIT.
//
//   minpython program.mpy          run on the interpreter
//   minpython --jit program.mpy    attach the tracing JIT
//   minpython --dis program.mpy    print the disassembly and exit
import std;

import minpython;

using namespace minpython;

int main(int argc, char** argv) {
  bool jit = false, dis = false;
  std::string path;
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--jit") jit = true;
    else if (arg == "--dis") dis = true;
    else path = arg;
  }
  if (path.empty()) {
    std::cerr << "usage: minpython [--jit] [--dis] program.mpy\n";
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
  if (jit) tj = std::make_unique<TracingJIT>(vm);
  vm.run_code(prog->module);
  if (vm.diag.failed) {
    std::cerr << "MinPythonError: " << vm.diag.message << "\n";
    return 1;
  }
  if (tj)
    std::cerr << "[jit] compiled=" << tj->n_compiled
              << " runs=" << tj->n_trace_runs << " aborted=" << tj->n_aborted
              << " type_deopt=" << tj->n_type_deopt << "\n";
  return 0;
}
