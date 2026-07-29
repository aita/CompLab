import std;
import otter.check;
import otter.diagnostics;
import otter.interp;
import otter.program;

namespace {

void usage() {
    std::println(std::cerr, "usage: otter <program{}>", otter::sourceExtension);
    std::println(std::cerr, "");
    std::println(std::cerr, "Runs a program. Modules it imports are looked for beside it,");
    std::println(std::cerr, "except for the built-in io, str and math.");
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        usage();
        return 2;
    }

    std::filesystem::path path(argv[1]);
    if (!std::filesystem::exists(path)) {
        std::println(std::cerr, "otter: there is no file `{}`", path.string());
        return 2;
    }

    otter::Program program(path.parent_path());
    try {
        program.loadEntry(path);

        std::vector<otter::CompileError> errors = otter::checkProgram(program);
        if (!errors.empty()) {
            for (const otter::CompileError& error : errors) {
                std::println(std::cerr, "{}", error.what());
            }
            return 1;
        }

        return otter::runProgram(program);
    } catch (const otter::CompileError& error) {
        std::println(std::cerr, "{}", error.what());
        return 1;
    } catch (const otter::RuntimeError& error) {
        std::println(std::cerr, "otter: {}", error.what());
        return 1;
    }
}
