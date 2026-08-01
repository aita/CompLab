export module otter.program;

import std;
import otter.ast;
import otter.builtins;
import otter.diagnostics;
import otter.parse;
import otter.types;

export namespace otter {

// The file extension a module of a given name is expected to live in.
inline constexpr std::string_view sourceExtension = ".otter";

// Every module a run needs, loaded and linked to the modules it imports.
//
// Loading is depth first from the entry file, so `order()` lists a module only
// after everything it imports, which is the order the checker and the evaluator
// both want.
class Program {
public:
    explicit Program(std::filesystem::path directory) : directory_(std::move(directory)) {}

    TypeArena& types() { return types_; }

    ModuleAst* entry() const { return entry_; }

    // Modules with their dependencies before them.
    const std::vector<ModuleAst*>& order() const { return order_; }

    ModuleAst* find(const std::string& name) const {
        auto entry = modules_.find(name);
        return entry == modules_.end() ? nullptr : entry->second.get();
    }

    // Reads the entry file and everything it reaches.
    void loadEntry(const std::filesystem::path& path) {
        Span span{path.string(), Position{}};
        std::string text = readFile(path, span);
        auto module = parseModule(path.string(), text);

        std::string stem = path.stem().string();
        if (module->name != stem) {
            throw CompileError(module->span,
                               std::format("this file declares module `{}`, but a module lives "
                                           "in a file named after it, so `{}{}` was expected",
                                           module->name, module->name, sourceExtension));
        }
        entry_ = adopt(std::move(module));
        resolveImports(entry_);
    }

private:
    ModuleAst* adopt(std::unique_ptr<ModuleAst> module) {
        const std::string& name = module->name;
        auto [entry, inserted] = modules_.try_emplace(name, std::move(module));
        if (!inserted) {
            throw CompileError(entry->second->span,
                               std::format("module `{}` is already loaded", name));
        }
        return entry->second.get();
    }

    void resolveImports(ModuleAst* module) {
        loading_.insert(module->name);
        for (Import& entry : module->imports) {
            if (entry.name == module->name) {
                throw CompileError(entry.span,
                                   std::format("module `{}` imports itself", entry.name));
            }
            if (loading_.contains(entry.name)) {
                throw CompileError(
                    entry.span,
                    std::format("modules `{}` and `{}` import one another, and a module has to "
                                "be complete before another can use it",
                                module->name, entry.name));
            }
            entry.target = require(entry.name, entry.span);
        }
        loading_.erase(module->name);
        order_.push_back(module);
    }

    ModuleAst* require(const std::string& name, const Span& span) {
        if (ModuleAst* loaded = find(name)) {
            return loaded;
        }

        std::unique_ptr<ModuleAst> parsed;
        if (const BuiltinModule* builtin = findBuiltinModule(name)) {
            parsed = buildBuiltinModule(*builtin);
        } else {
            std::filesystem::path path = directory_ / (name + std::string(sourceExtension));
            if (!std::filesystem::exists(path)) {
                throw CompileError(span, std::format("no module `{}`: there is no file `{}`",
                                                     name, path.string()));
            }
            parsed = parseModule(path.string(), readFile(path, span));
            if (parsed->name != name) {
                throw CompileError(parsed->span,
                                   std::format("`{}` declares module `{}`, but it was imported "
                                               "as `{}`",
                                               path.string(), parsed->name, name));
            }
        }

        ModuleAst* module = adopt(std::move(parsed));
        resolveImports(module);
        return module;
    }

    // A type that is already known, dressed as something the source could have
    // said, so that the checker resolves it the way it resolves any other.
    static TypeExprPtr writtenType(const Type* type, const Span& span) {
        auto node = std::make_unique<TypeExpr>();
        node->kind = TypeExprKind::Named;
        node->span = span;
        node->path.push_back(describe(type));
        node->resolved = type;
        return node;
    }

    // A module the implementation provides. Its functions have no body and
    // stand for host functions, which is what a body-less function is anywhere
    // else, so nothing downstream has to know where the module came from.
    std::unique_ptr<ModuleAst> buildBuiltinModule(const BuiltinModule& description) {
        Span span{std::format("<{}>", description.name), Position{}};

        auto module = std::make_unique<ModuleAst>();
        module->name = description.name;
        module->file = span.file;
        module->span = span;

        for (const BuiltinFunction& entry : description.functions) {
            auto definition = std::make_unique<FunctionDefinition>();
            definition->name = entry.name;
            definition->hostName = entry.hostName;
            definition->span = span;
            definition->declaredResult =
                writtenType(types_.primitiveType(entry.result), span);
            for (std::size_t index = 0; index < entry.parameters.size(); ++index) {
                Parameter parameter;
                parameter.name = std::format("argument{}", index + 1);
                parameter.span = span;
                parameter.declaredType =
                    writtenType(types_.primitiveType(entry.parameters[index]), span);
                definition->parameters.push_back(std::move(parameter));
            }

            auto declaration = std::make_unique<FunctionDecl>();
            declaration->exported = true;
            declaration->definition = std::move(definition);
            declaration->owner = module.get();
            module->functions.push_back(std::move(declaration));
        }
        return module;
    }

    static std::string readFile(const std::filesystem::path& path, const Span& span) {
        std::ifstream stream(path, std::ios::binary);
        if (!stream) {
            throw CompileError(span, std::format("cannot read `{}`", path.string()));
        }
        std::ostringstream buffer;
        buffer << stream.rdbuf();
        return buffer.str();
    }

    std::filesystem::path directory_;
    TypeArena types_;
    std::map<std::string, std::unique_ptr<ModuleAst>> modules_;
    std::vector<ModuleAst*> order_;
    std::set<std::string> loading_;
    ModuleAst* entry_ = nullptr;
};

}  // namespace otter
