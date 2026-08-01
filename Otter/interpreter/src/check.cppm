export module otter.check;

import std;
import otter.ast;
import otter.builtins;
import otter.diagnostics;
import otter.program;
import otter.types;

namespace otter::detail {

// Does this statement leave the function on every path through it?
bool alwaysReturns(const Stmt* statement);

// Does a `break` in this statement belong to the loop we are asking about?
// Nested loops swallow their own breaks, so the walk stops at them.
bool breaksOutOfLoop(const Stmt* statement) {
    switch (statement->kind) {
        case StmtKind::Break:
            return true;
        case StmtKind::Block: {
            const auto* block = static_cast<const Block*>(statement);
            for (const StmtPtr& entry : block->statements) {
                if (breaksOutOfLoop(entry.get())) {
                    return true;
                }
            }
            return false;
        }
        case StmtKind::If: {
            const auto* branch = static_cast<const IfStmt*>(statement);
            if (breaksOutOfLoop(branch->consequent.get())) {
                return true;
            }
            return branch->alternative != nullptr &&
                   breaksOutOfLoop(branch->alternative.get());
        }
        default:
            return false;
    }
}

bool isAlwaysTrue(const Expr* condition) {
    return condition->kind == ExprKind::Bool && static_cast<const BoolExpr*>(condition)->value;
}

bool alwaysReturns(const Stmt* statement) {
    switch (statement->kind) {
        case StmtKind::Return:
            return true;
        case StmtKind::Block: {
            const auto* block = static_cast<const Block*>(statement);
            for (const StmtPtr& entry : block->statements) {
                if (alwaysReturns(entry.get())) {
                    return true;
                }
            }
            return false;
        }
        case StmtKind::If: {
            const auto* branch = static_cast<const IfStmt*>(statement);
            return branch->alternative != nullptr &&
                   alwaysReturns(branch->consequent.get()) &&
                   alwaysReturns(branch->alternative.get());
        }
        case StmtKind::While: {
            // A loop that never ends on its own leaves only by returning.
            const auto* loop = static_cast<const WhileStmt*>(statement);
            return isAlwaysTrue(loop->condition.get()) && !breaksOutOfLoop(loop->body.get());
        }
        case StmtKind::For: {
            const auto* loop = static_cast<const ForStmt*>(statement);
            bool endless = loop->condition == nullptr || isAlwaysTrue(loop->condition.get());
            return endless && !breaksOutOfLoop(loop->body.get());
        }
        default:
            return false;
    }
}

// A value block runs statements and then yields an expression, so there is
// nowhere for a jump out of it to go. Loops and functions written inside one
// are their own affair.
void rejectJumps(const Stmt& statement, bool insideLoop) {
    switch (statement.kind) {
        case StmtKind::Return:
            throw CompileError(statement.span,
                               "this block stands for a value, so it cannot return from the "
                               "function around it");
        case StmtKind::Break:
        case StmtKind::Continue:
            if (!insideLoop) {
                throw CompileError(statement.span,
                                   "this block stands for a value, so there is no loop here to "
                                   "leave");
            }
            return;
        case StmtKind::Block: {
            const auto* block = static_cast<const Block*>(&statement);
            for (const StmtPtr& entry : block->statements) {
                rejectJumps(*entry, insideLoop);
            }
            return;
        }
        case StmtKind::If: {
            const auto* branch = static_cast<const IfStmt*>(&statement);
            rejectJumps(*branch->consequent, insideLoop);
            if (branch->alternative != nullptr) {
                rejectJumps(*branch->alternative, insideLoop);
            }
            return;
        }
        case StmtKind::While:
            rejectJumps(*static_cast<const WhileStmt*>(&statement)->body, true);
            return;
        case StmtKind::For:
            rejectJumps(*static_cast<const ForStmt*>(&statement)->body, true);
            return;
        default:
            return;
    }
}

// Walks every declaration, resolves the names it mentions, and gives every
// expression a type.
class Checker {
public:
    explicit Checker(Program& program) : program_(program), types_(program.types()) {}

    std::vector<CompileError> run() {
        try {
            declareStructs();
            resolveStructFields();
            rejectStructCycles();
            declareSignatures();
        } catch (const CompileError& error) {
            // Nothing later can be trusted once the shape of the program is
            // wrong, so this is where the checker gives up.
            errors_.push_back(error);
            return errors_;
        }

        checkBodies();
        checkEntryPoint();
        return errors_;
    }

private:
    // -- phase 1: every struct gets a type, before any field is looked at ----

    void declareStructs() {
        for (ModuleAst* module : program_.order()) {
            std::set<std::string> seen;
            for (const auto& declaration : module->structs) {
                if (!seen.insert(declaration->name).second) {
                    throw CompileError(declaration->span,
                                       std::format("module `{}` declares struct `{}` twice",
                                                   module->name, declaration->name));
                }
                auto [type, info] = types_.declareStruct(module->name, declaration->name);
                declaration->type = type;
                declaration->structure = info;
            }
            for (const auto& declaration : module->aliases) {
                if (!seen.insert(declaration->name).second) {
                    throw CompileError(declaration->span,
                                       std::format("module `{}` already declares a type named "
                                                   "`{}`",
                                                   module->name, declaration->name));
                }
            }
        }
    }

    // Aliases are resolved when something asks for one, so that they may be
    // written in any order and may name each other.
    const Type* resolveAlias(TypeAliasDecl* declaration) {
        if (declaration->resolved != nullptr) {
            return declaration->resolved;
        }
        if (declaration->resolving) {
            throw CompileError(declaration->span,
                               std::format("type `{}` is defined in terms of itself",
                                           declaration->name));
        }

        declaration->resolving = true;
        ModuleAst* saved = std::exchange(module_, declaration->owner);
        declaration->resolved = resolveType(declaration->target.get());
        module_ = saved;
        declaration->resolving = false;
        return declaration->resolved;
    }

    // -- phase 2: field types, which may point back at their own struct ------

    void resolveStructFields() {
        for (ModuleAst* module : program_.order()) {
            module_ = module;
            for (const auto& declaration : module->structs) {
                std::set<std::string> seen;
                for (std::size_t index = 0; index < declaration->fieldNames.size(); ++index) {
                    const std::string& name = declaration->fieldNames[index];
                    if (!seen.insert(name).second) {
                        throw CompileError(
                            declaration->fieldSpans[index],
                            std::format("struct `{}` declares field `{}` twice",
                                        declaration->name, name));
                    }
                    const Type* type = resolveType(declaration->fieldTypes[index].get());
                    if (type->kind == TypeKind::Void) {
                        throw CompileError(declaration->fieldSpans[index],
                                           "a field cannot be void");
                    }
                    declaration->structure->fields.push_back(Field{name, type});
                }
                declaration->structure->complete = true;
            }
        }
        module_ = nullptr;
    }

    // A struct that holds itself by value would have no size. Holding itself
    // through a pointer is the whole point of a linked structure, so only the
    // direct case is rejected.
    void rejectStructCycles() {
        for (ModuleAst* module : program_.order()) {
            for (const auto& declaration : module->structs) {
                std::set<const StructInfo*> visiting;
                if (containsItself(declaration->structure, declaration->structure, visiting)) {
                    throw CompileError(
                        declaration->span,
                        std::format("struct `{}` contains itself by value, which has no size; "
                                    "hold it through a pointer instead",
                                    declaration->name));
                }
            }
        }
    }

    bool containsItself(const StructInfo* target, const StructInfo* current,
                        std::set<const StructInfo*>& visiting) {
        if (!visiting.insert(current).second) {
            return false;
        }
        for (const Field& field : current->fields) {
            if (field.type->kind != TypeKind::Struct) {
                continue;
            }
            if (field.type->structure == target ||
                containsItself(target, field.type->structure, visiting)) {
                return true;
            }
        }
        return false;
    }

    // -- phase 3: signatures, so that functions may call each other freely ---

    void declareSignatures() {
        for (ModuleAst* module : program_.order()) {
            module_ = module;
            std::set<std::string> seen;

            for (const auto& declaration : module->globals) {
                if (!seen.insert(declaration->name).second) {
                    throw CompileError(declaration->span,
                                       std::format("module `{}` declares `{}` twice",
                                                   module->name, declaration->name));
                }
                declaration->type = resolveType(declaration->declaredType.get());
                if (declaration->type->kind == TypeKind::Void) {
                    throw CompileError(declaration->span, "a variable cannot be void");
                }
            }

            for (const auto& declaration : module->functions) {
                FunctionDefinition& definition = *declaration->definition;
                if (!seen.insert(definition.name).second) {
                    throw CompileError(definition.span,
                                       std::format("module `{}` declares `{}` twice",
                                                   module->name, definition.name));
                }
                resolveSignature(definition);
                // A function without a body is one the host supplies, so the
                // name has to be one the host knows.
                if (definition.body == nullptr && findNative(definition.hostName) == nullptr) {
                    throw CompileError(
                        definition.span,
                        std::format("`{}` has no body, so it has to be a function this "
                                    "implementation provides, and there is none by that name",
                                    definition.name));
                }
            }
        }
        module_ = nullptr;
    }

    void resolveSignature(FunctionDefinition& definition) {
        // A nested function has its signature registered before its block is
        // walked, so that its siblings may call it; this is where the second
        // request lands.
        if (definition.type != nullptr) {
            return;
        }

        std::vector<const Type*> parameters;
        std::set<std::string> seen;
        for (Parameter& parameter : definition.parameters) {
            if (!seen.insert(parameter.name).second) {
                throw CompileError(parameter.span,
                                   std::format("parameter `{}` is declared twice",
                                               parameter.name));
            }
            parameter.type = resolveType(parameter.declaredType.get());
            if (parameter.type->kind == TypeKind::Void) {
                throw CompileError(parameter.span, "a parameter cannot be void");
            }
            parameters.push_back(parameter.type);
        }
        definition.resultType = resolveType(definition.declaredResult.get());
        definition.type = types_.functionOf(parameters, definition.resultType);
    }

    // -- phase 4: bodies ----------------------------------------------------

    void checkBodies() {
        for (ModuleAst* module : program_.order()) {
            module_ = module;

            for (const auto& declaration : module->globals) {
                guard(declaration->span, [&] {
                    const Type* actual = check(declaration->initializer.get(), declaration->type);
                    expect(actual, declaration->type, declaration->initializer->span,
                           "this initial value");
                });
            }

            for (const auto& declaration : module->functions) {
                guard(declaration->definition->span,
                      [&] { checkFunction(*declaration->definition); });
            }
        }
        module_ = nullptr;
    }

    void checkFunction(FunctionDefinition& definition) {
        if (definition.body == nullptr) {
            return;
        }

        scopes_.emplace_back();
        for (const Parameter& parameter : definition.parameters) {
            scopes_.back()[parameter.name] = parameter.type;
        }

        results_.push_back(definition.resultType);
        int savedLoopDepth = std::exchange(loopDepth_, 0);

        checkBlock(*definition.body, false);

        loopDepth_ = savedLoopDepth;
        results_.pop_back();
        scopes_.pop_back();

        if (definition.resultType->kind != TypeKind::Void &&
            !alwaysReturns(definition.body.get())) {
            throw CompileError(
                definition.span,
                std::format("`{}` returns {}, but control can reach the end of its body "
                            "without a return",
                            definition.name.empty() ? "this function" : definition.name,
                            describe(definition.resultType)));
        }
    }

    void checkEntryPoint() {
        ModuleAst* entry = program_.entry();
        const FunctionDecl* main = entry->findFunction("main");
        if (main == nullptr) {
            errors_.emplace_back(entry->span,
                                 std::format("module `{}` is the entry point, so it needs a "
                                             "`fun main() -> int`",
                                             entry->name));
            return;
        }
        const FunctionDefinition& definition = *main->definition;
        if (!definition.parameters.empty()) {
            errors_.emplace_back(definition.span, "`main` takes no arguments");
        }
        if (definition.resultType != types_.intType() &&
            definition.resultType->kind != TypeKind::Void) {
            errors_.emplace_back(definition.span, "`main` returns int or void");
        }
    }

    template <typename Body>
    void guard(const Span& span, Body&& body) {
        try {
            body();
        } catch (const CompileError& error) {
            errors_.push_back(error);
        } catch (const std::exception& error) {
            errors_.emplace_back(span, error.what());
        }
    }

    // -- types --------------------------------------------------------------

    const Type* builtinType(const std::string& name) const {
        if (name == "void") return types_.voidType();
        if (name == "bool") return types_.boolType();
        if (name == "int") return types_.intType();
        if (name == "byte") return types_.byteType();
        if (name == "char") return types_.charType();
        if (name == "string") return types_.stringType();
        if (name == "float32") return types_.float32Type();
        if (name == "float64") return types_.float64Type();
        return nullptr;
    }

    const Type* resolveType(TypeExpr* node) {
        if (node->resolved != nullptr) {
            return node->resolved;
        }
        node->resolved = resolveTypeUncached(node);
        return node->resolved;
    }

    const Type* resolveTypeUncached(TypeExpr* node) {
        switch (node->kind) {
            case TypeExprKind::Pointer:
                return types_.pointerTo(resolveType(node->target.get()));

            case TypeExprKind::Function: {
                std::vector<const Type*> parameters;
                for (const TypeExprPtr& parameter : node->parameters) {
                    parameters.push_back(resolveType(parameter.get()));
                }
                return types_.functionOf(parameters, resolveType(node->target.get()));
            }

            case TypeExprKind::Named:
                break;
        }

        if (node->path.size() == 1) {
            const std::string& name = node->path[0];
            if (const StructDecl* declaration = module_->findStruct(name)) {
                requireNoArguments(node, name);
                return declaration->type;
            }
            if (TypeAliasDecl* declaration = module_->findAlias(name)) {
                requireNoArguments(node, name);
                return resolveAlias(declaration);
            }
            if (name == "array") {
                if (node->arguments.size() != 1) {
                    throw CompileError(node->span,
                                       "`array` names the type of its elements, as in array<int>");
                }
                const Type* element = resolveType(node->arguments[0].get());
                if (element->kind == TypeKind::Void) {
                    throw CompileError(node->span, "an array cannot hold void");
                }
                return types_.arrayOf(element);
            }
            if (const Type* builtin = builtinType(name)) {
                requireNoArguments(node, name);
                return builtin;
            }
            throw CompileError(node->span, std::format("there is no type named `{}`", name));
        }

        if (node->path.size() == 2) {
            const std::string& moduleName = node->path[0];
            const std::string& typeName = node->path[1];
            const ModuleAst* target = importedModule(moduleName, node->span);

            if (const StructDecl* declaration = target->findStruct(typeName)) {
                if (!declaration->exported) {
                    throw CompileError(
                        node->span, std::format("`{}.{}` is not exported", moduleName, typeName));
                }
                requireNoArguments(node, typeName);
                return declaration->type;
            }
            if (TypeAliasDecl* declaration = target->findAlias(typeName)) {
                if (!declaration->exported) {
                    throw CompileError(
                        node->span, std::format("`{}.{}` is not exported", moduleName, typeName));
                }
                requireNoArguments(node, typeName);
                return resolveAlias(declaration);
            }
            throw CompileError(node->span, std::format("module `{}` has no type `{}`", moduleName,
                                                       typeName));
        }

        throw CompileError(node->span, "a type name is either `Name` or `module.Name`");
    }

    void requireNoArguments(const TypeExpr* node, const std::string& name) const {
        if (!node->arguments.empty()) {
            throw CompileError(node->span,
                               std::format("`{}` does not take type arguments", name));
        }
    }

    const ModuleAst* importedModule(const std::string& name, const Span& span) const {
        const Import* entry = module_->findImport(name);
        if (entry == nullptr) {
            throw CompileError(span, std::format("module `{}` is not imported here", name));
        }
        return entry->target;
    }

    // -- statements ---------------------------------------------------------

    void checkBlock(Block& block, bool ownScope = true) {
        if (ownScope) {
            scopes_.emplace_back();
        }
        declareNestedFunctions(block.statements);
        for (const StmtPtr& statement : block.statements) {
            checkStatement(*statement);
        }
        if (ownScope) {
            scopes_.pop_back();
        }
    }

    // Every function declared in a block is in scope throughout it, so a pair
    // of them may call each other and either may be used before it is written.
    void declareNestedFunctions(const std::vector<StmtPtr>& statements) {
        for (const StmtPtr& statement : statements) {
            if (statement->kind != StmtKind::NestedFunction) {
                continue;
            }
            FunctionDefinition& definition =
                *static_cast<NestedFunctionStmt&>(*statement).definition;
            resolveSignature(definition);
            if (scopes_.back().contains(definition.name)) {
                throw CompileError(definition.span,
                                   std::format("`{}` is already declared in this block",
                                               definition.name));
            }
            scopes_.back()[definition.name] = definition.type;
        }
    }

    void checkStatement(Stmt& statement) {
        switch (statement.kind) {
            case StmtKind::VariableDeclaration: {
                auto& declaration = static_cast<VarStmt&>(statement);
                declaration.type = resolveType(declaration.declaredType.get());
                if (declaration.type->kind == TypeKind::Void) {
                    throw CompileError(declaration.span, "a variable cannot be void");
                }
                const Type* actual = check(declaration.initializer.get(), declaration.type);
                expect(actual, declaration.type, declaration.initializer->span,
                       "this initial value");
                if (scopes_.back().contains(declaration.name)) {
                    throw CompileError(declaration.span,
                                       std::format("`{}` is already declared in this block",
                                                   declaration.name));
                }
                scopes_.back()[declaration.name] = declaration.type;
                return;
            }

            case StmtKind::Return: {
                auto& node = static_cast<ReturnStmt&>(statement);
                const Type* wanted = results_.back();
                if (node.value == nullptr) {
                    if (wanted->kind != TypeKind::Void) {
                        throw CompileError(node.span,
                                           std::format("this function returns {}, so `return` "
                                                       "needs a value",
                                                       describe(wanted)));
                    }
                    return;
                }
                if (wanted->kind == TypeKind::Void) {
                    throw CompileError(node.span,
                                       "this function returns void, so `return` takes no value");
                }
                const Type* actual = check(node.value.get(), wanted);
                expect(actual, wanted, node.value->span, "this returned value");
                return;
            }

            case StmtKind::If: {
                auto& node = static_cast<IfStmt&>(statement);
                requireBool(node.condition.get(), "an if condition");
                checkStatement(*node.consequent);
                if (node.alternative != nullptr) {
                    checkStatement(*node.alternative);
                }
                return;
            }

            case StmtKind::NestedFunction:
                // The signature was registered when the block was entered.
                checkFunction(*static_cast<NestedFunctionStmt&>(statement).definition);
                return;

            case StmtKind::While: {
                auto& node = static_cast<WhileStmt&>(statement);
                requireBool(node.condition.get(), "a while condition");
                ++loopDepth_;
                checkStatement(*node.body);
                --loopDepth_;
                return;
            }

            case StmtKind::For: {
                // The loop's own scope holds whatever the initialiser declares,
                // so it is gone once the loop is.
                auto& node = static_cast<ForStmt&>(statement);
                scopes_.emplace_back();
                if (node.initializer != nullptr) {
                    checkStatement(*node.initializer);
                }
                if (node.condition != nullptr) {
                    requireBool(node.condition.get(), "a for condition");
                }
                if (node.step != nullptr) {
                    check(node.step.get(), nullptr);
                }
                ++loopDepth_;
                checkStatement(*node.body);
                --loopDepth_;
                scopes_.pop_back();
                return;
            }

            case StmtKind::Break:
                if (loopDepth_ == 0) {
                    throw CompileError(statement.span, "`break` is only meaningful inside a loop");
                }
                return;

            case StmtKind::Continue:
                if (loopDepth_ == 0) {
                    throw CompileError(statement.span,
                                       "`continue` is only meaningful inside a loop");
                }
                return;

            case StmtKind::Expression:
                check(static_cast<ExprStmt&>(statement).value.get(), nullptr);
                return;

            case StmtKind::Block:
                checkBlock(static_cast<Block&>(statement));
                return;
        }
    }

    void requireBool(Expr* condition, std::string_view what) {
        const Type* actual = check(condition, types_.boolType());
        if (actual != types_.boolType()) {
            throw CompileError(condition->span,
                               std::format("{} is a bool, but this is {}", what,
                                           describe(actual)));
        }
    }

    void expect(const Type* actual, const Type* wanted, const Span& span,
                std::string_view what) const {
        if (!assignable(actual, wanted)) {
            throw CompileError(span, std::format("{} is {}, but {} was expected", what,
                                                 describe(actual), describe(wanted)));
        }
    }

    // -- expressions --------------------------------------------------------

    const Type* check(Expr* expr, const Type* expected) {
        expr->type = checkUncached(expr, expected);
        return expr->type;
    }

    const Type* checkUncached(Expr* expr, const Type* expected) {
        switch (expr->kind) {
            case ExprKind::Integer:
                return checkInteger(static_cast<IntegerExpr&>(*expr), expected);
            case ExprKind::Floating:
                if (expected != nullptr && isFloating(expected)) {
                    return expected;
                }
                return types_.float64Type();
            case ExprKind::String:
                return types_.stringType();
            case ExprKind::Char:
                return types_.charType();
            case ExprKind::Bool:
                return types_.boolType();
            case ExprKind::Null:
                if (expected != nullptr && expected->kind == TypeKind::Pointer) {
                    return expected;
                }
                return types_.nullType();
            case ExprKind::Name:
                return checkName(static_cast<NameExpr&>(*expr));
            case ExprKind::Array:
                return checkArray(static_cast<ArrayExpr&>(*expr), expected);
            case ExprKind::StructLiteral:
                return checkStructLiteral(static_cast<StructLiteralExpr&>(*expr));
            case ExprKind::Function:
                return checkFunctionExpr(static_cast<FunctionExpr&>(*expr));
            case ExprKind::Call:
                return checkCall(static_cast<CallExpr&>(*expr));
            case ExprKind::Index:
                return checkIndex(static_cast<IndexExpr&>(*expr));
            case ExprKind::Field:
                return checkFieldAccess(static_cast<FieldExpr&>(*expr));
            case ExprKind::Unary:
                return checkUnary(static_cast<UnaryExpr&>(*expr), expected);
            case ExprKind::Cast:
                return checkCast(static_cast<CastExpr&>(*expr));
            case ExprKind::Binary:
                return checkBinary(static_cast<BinaryExpr&>(*expr), expected);
            case ExprKind::Assign:
                return checkAssign(static_cast<AssignExpr&>(*expr));
            case ExprKind::Conditional:
                return checkConditional(static_cast<IfExpr&>(*expr), expected);
        }
        throw CompileError(expr->span, "unhandled expression");
    }

    const Type* checkInteger(IntegerExpr& expr, const Type* expected) {
        const Type* type = expected != nullptr && isInteger(expected) ? expected
                                                                     : types_.intType();
        IntegerRange range = rangeOf(type);
        if (expr.value < range.low || expr.value > range.high) {
            throw CompileError(expr.span, std::format("{} does not fit in {}", expr.value,
                                                      describe(type)));
        }
        return type;
    }

    const Type* checkName(NameExpr& expr) {
        for (auto scope = scopes_.rbegin(); scope != scopes_.rend(); ++scope) {
            auto entry = scope->find(expr.name);
            if (entry != scope->end()) {
                expr.resolution = NameKind::Local;
                return entry->second;
            }
        }
        if (const GlobalDecl* global = module_->findGlobal(expr.name)) {
            expr.resolution = NameKind::Global;
            expr.global = global;
            return global->type;
        }
        if (const FunctionDecl* function = module_->findFunction(expr.name)) {
            expr.resolution = NameKind::Function;
            expr.function = function;
            return function->definition->type;
        }
        if (const Import* entry = module_->findImport(expr.name)) {
            expr.resolution = NameKind::Module;
            expr.module = entry->target;
            throw CompileError(expr.span,
                               std::format("`{}` is a module, so it needs a member, as in `{}.x`",
                                           expr.name, expr.name));
        }
        throw CompileError(expr.span, std::format("there is nothing named `{}` here", expr.name));
    }

    const Type* checkArray(ArrayExpr& expr, const Type* expected) {
        const Type* element =
            expected != nullptr && expected->kind == TypeKind::Array ? expected->element : nullptr;

        if (expr.repeated) {
            const Type* actual = check(expr.elements[0].get(), element);
            const Type* countType = check(expr.count.get(), types_.intType());
            if (countType != types_.intType()) {
                throw CompileError(expr.count->span,
                                   std::format("an array length is an int, but this is {}",
                                               describe(countType)));
            }
            return types_.arrayOf(element != nullptr ? element : actual);
        }

        if (expr.elements.empty()) {
            if (element == nullptr) {
                throw CompileError(expr.span,
                                   "an empty array literal has no element type to go on; give "
                                   "the variable a type, as in `var a: array<int> = [];`");
            }
            return types_.arrayOf(element);
        }

        const Type* first = check(expr.elements[0].get(), element);
        const Type* wanted = element != nullptr ? element : first;
        expect(first, wanted, expr.elements[0]->span, "this element");
        for (std::size_t index = 1; index < expr.elements.size(); ++index) {
            const Type* actual = check(expr.elements[index].get(), wanted);
            expect(actual, wanted, expr.elements[index]->span, "this element");
        }
        return types_.arrayOf(wanted);
    }

    const Type* checkStructLiteral(StructLiteralExpr& expr) {
        const StructDecl* declaration = nullptr;
        if (expr.path.size() == 1) {
            declaration = module_->findStruct(expr.path[0]);
            if (declaration == nullptr) {
                throw CompileError(expr.span,
                                   std::format("there is no struct named `{}`", expr.path[0]));
            }
        } else if (expr.path.size() == 2) {
            const ModuleAst* target = importedModule(expr.path[0], expr.span);
            declaration = target->findStruct(expr.path[1]);
            if (declaration == nullptr) {
                throw CompileError(expr.span, std::format("module `{}` has no struct `{}`",
                                                          expr.path[0], expr.path[1]));
            }
            if (!declaration->exported) {
                throw CompileError(expr.span, std::format("`{}.{}` is not exported", expr.path[0],
                                                          expr.path[1]));
            }
        } else {
            throw CompileError(expr.span, "a struct name is either `Name` or `module.Name`");
        }

        StructInfo* info = declaration->structure;
        expr.structure = info;

        std::vector<bool> given(info->fields.size(), false);
        for (FieldInit& initializer : expr.initializers) {
            int index = info->indexOf(initializer.name);
            if (index < 0) {
                throw CompileError(initializer.span,
                                   std::format("struct `{}` has no field `{}`", info->name,
                                               initializer.name));
            }
            if (given[static_cast<std::size_t>(index)]) {
                throw CompileError(initializer.span,
                                   std::format("field `{}` is given twice", initializer.name));
            }
            given[static_cast<std::size_t>(index)] = true;
            initializer.index = index;

            const Type* wanted = info->fields[static_cast<std::size_t>(index)].type;
            const Type* actual = check(initializer.value.get(), wanted);
            expect(actual, wanted, initializer.value->span,
                   std::format("field `{}`", initializer.name));
        }

        for (std::size_t index = 0; index < given.size(); ++index) {
            if (!given[index]) {
                throw CompileError(expr.span,
                                   std::format("field `{}` of struct `{}` is missing",
                                               info->fields[index].name, info->name));
            }
        }
        return declaration->type;
    }

    const Type* checkFunctionExpr(FunctionExpr& expr) {
        FunctionDefinition& definition = *expr.definition;
        resolveSignature(definition);
        checkFunction(definition);
        return definition.type;
    }

    const Type* checkCall(CallExpr& expr) {
        const Type* callee = check(expr.callee.get(), nullptr);
        if (callee->kind != TypeKind::Function) {
            throw CompileError(expr.callee->span,
                               std::format("this is {}, which is not something you can call",
                                           describe(callee)));
        }
        if (expr.arguments.size() != callee->parameters.size()) {
            throw CompileError(expr.span,
                               std::format("this function takes {} argument(s), but was given {}",
                                           callee->parameters.size(), expr.arguments.size()));
        }
        for (std::size_t index = 0; index < expr.arguments.size(); ++index) {
            const Type* wanted = callee->parameters[index];
            const Type* actual = check(expr.arguments[index].get(), wanted);
            expect(actual, wanted, expr.arguments[index]->span,
                   std::format("argument {}", index + 1));
        }
        return callee->result;
    }

    const Type* checkIndex(IndexExpr& expr) {
        const Type* subject = check(expr.subject.get(), nullptr);
        const Type* index = check(expr.index.get(), types_.intType());
        if (index != types_.intType()) {
            throw CompileError(expr.index->span,
                               std::format("an index is an int, but this is {}", describe(index)));
        }
        if (subject->kind == TypeKind::Array) {
            return subject->element;
        }
        if (subject->kind == TypeKind::String) {
            return types_.byteType();
        }
        throw CompileError(expr.subject->span,
                           std::format("{} cannot be indexed", describe(subject)));
    }

    const Type* checkFieldAccess(FieldExpr& expr) {
        // `a.b` where `a` names an imported module is a member reference, not a
        // field, so that possibility is settled before the subject is typed.
        if (expr.subject->kind == ExprKind::Name) {
            auto& name = static_cast<NameExpr&>(*expr.subject);
            if (!isBound(name.name)) {
                if (const Import* entry = module_->findImport(name.name)) {
                    name.resolution = NameKind::Module;
                    name.module = entry->target;
                    name.type = types_.voidType();
                    return checkModuleMember(expr, entry->target, name.name);
                }
            }
        }

        const Type* subject = check(expr.subject.get(), nullptr);

        // Reaching a field through a pointer to a struct saves writing (*p).f
        // everywhere a linked structure is walked.
        const Type* holder = subject;
        if (holder->kind == TypeKind::Pointer && holder->element->kind == TypeKind::Struct) {
            holder = holder->element;
            expr.throughPointer = true;
        }

        if (holder->kind == TypeKind::Struct) {
            StructInfo* info = holder->structure;
            int index = info->indexOf(expr.name);
            if (index < 0) {
                throw CompileError(expr.span, std::format("struct `{}` has no field `{}`",
                                                          info->name, expr.name));
            }
            expr.resolution = FieldKind::StructField;
            expr.index = index;
            return info->fields[static_cast<std::size_t>(index)].type;
        }

        if (subject->kind == TypeKind::Array || subject->kind == TypeKind::String) {
            if (expr.name != "length") {
                throw CompileError(expr.span,
                                   std::format("{} has no member `{}`; it has `length`",
                                               describe(subject), expr.name));
            }
            expr.resolution = FieldKind::Length;
            return types_.intType();
        }

        throw CompileError(expr.span,
                           std::format("{} has no member `{}`", describe(subject), expr.name));
    }

    bool isBound(const std::string& name) const {
        for (const auto& scope : scopes_) {
            if (scope.contains(name)) {
                return true;
            }
        }
        return module_->findGlobal(name) != nullptr || module_->findFunction(name) != nullptr;
    }

    const Type* checkModuleMember(FieldExpr& expr, const ModuleAst* target,
                                  const std::string& moduleName) {
        if (const FunctionDecl* function = target->findFunction(expr.name)) {
            if (!function->exported) {
                throw CompileError(expr.span, std::format("`{}.{}` is not exported", moduleName,
                                                          expr.name));
            }
            expr.resolution = FieldKind::ModuleFunction;
            expr.function = function;
            return function->definition->type;
        }
        if (const GlobalDecl* global = target->findGlobal(expr.name)) {
            if (!global->exported) {
                throw CompileError(expr.span, std::format("`{}.{}` is not exported", moduleName,
                                                          expr.name));
            }
            expr.resolution = FieldKind::ModuleGlobal;
            expr.global = global;
            return global->type;
        }
        if (target->findStruct(expr.name) != nullptr) {
            throw CompileError(expr.span,
                               std::format("`{}.{}` is a type, not a value; to build one write "
                                           "`new {}.{} {{ ... }}`",
                                           moduleName, expr.name, moduleName, expr.name));
        }
        throw CompileError(expr.span,
                           std::format("module `{}` has no member `{}`", moduleName, expr.name));
    }

    const Type* checkUnary(UnaryExpr& expr, const Type* expected) {
        switch (expr.op) {
            case UnaryOp::Plus:
            case UnaryOp::Minus: {
                const Type* operand = check(expr.operand.get(), expected);
                if (!isNumeric(operand)) {
                    throw CompileError(expr.span,
                                       std::format("`{}` wants a number, but this is {}",
                                                   expr.op == UnaryOp::Plus ? "+" : "-",
                                                   describe(operand)));
                }
                return operand;
            }

            case UnaryOp::Not: {
                const Type* operand = check(expr.operand.get(), types_.boolType());
                if (operand != types_.boolType()) {
                    throw CompileError(expr.span, std::format("`!` wants a bool, but this is {}",
                                                              describe(operand)));
                }
                return operand;
            }

            case UnaryOp::Complement: {
                const Type* operand = check(expr.operand.get(), expected);
                if (!isInteger(operand)) {
                    throw CompileError(expr.span,
                                       std::format("`~` wants a whole number, but this is {}",
                                                   describe(operand)));
                }
                return operand;
            }

            case UnaryOp::Dereference: {
                const Type* operand = check(expr.operand.get(), nullptr);
                if (operand->kind != TypeKind::Pointer) {
                    throw CompileError(expr.span,
                                       std::format("`*` wants a pointer, but this is {}",
                                                   describe(operand)));
                }
                return operand->element;
            }

            case UnaryOp::AddressOf: {
                const Type* inner =
                    expected != nullptr && expected->kind == TypeKind::Pointer ? expected->element
                                                                              : nullptr;
                const Type* operand = check(expr.operand.get(), inner);
                if (operand->kind == TypeKind::Void) {
                    throw CompileError(expr.span, "there is no address of a void value");
                }
                return types_.pointerTo(operand);
            }
        }
        throw CompileError(expr.span, "unhandled unary operator");
    }

    const Type* checkCast(CastExpr& expr) {
        const Type* target = resolveType(expr.target.get());
        const Type* operand = check(expr.operand.get(), nullptr);

        if (isNumeric(operand) && isNumeric(target)) {
            return target;
        }
        if (operand->kind == TypeKind::Pointer && target->kind == TypeKind::Pointer) {
            return target;
        }
        if (operand->kind == TypeKind::NullPointer && target->kind == TypeKind::Pointer) {
            return target;
        }
        if (operand == target) {
            return target;
        }
        throw CompileError(expr.span, std::format("there is no conversion from {} to {}",
                                                  describe(operand), describe(target)));
    }

    const Type* checkBinary(BinaryExpr& expr, const Type* expected) {
        if (expr.op == BinaryOp::And || expr.op == BinaryOp::Or) {
            requireBool(expr.left.get(), "an operand of `&&` or `||`");
            requireBool(expr.right.get(), "an operand of `&&` or `||`");
            expr.operandType = types_.boolType();
            return types_.boolType();
        }

        // A bare number takes its type from the other side, so that `1 + x`
        // reads the same as `x + 1`.
        const Type* left = nullptr;
        const Type* right = nullptr;
        if (isBareNumber(*expr.left) && !isBareNumber(*expr.right)) {
            right = check(expr.right.get(), expected);
            left = check(expr.left.get(), right);
        } else {
            left = check(expr.left.get(), expected);
            right = check(expr.right.get(), left);
        }

        if (!assignable(left, right) && !assignable(right, left)) {
            throw CompileError(expr.span,
                               std::format("these operands are {} and {}; there are no implicit "
                                           "conversions, so write one with `as`",
                                           describe(left), describe(right)));
        }
        const Type* operand = left->kind == TypeKind::NullPointer ? right : left;
        expr.operandType = operand;

        switch (expr.op) {
            case BinaryOp::Add:
                if (operand->kind == TypeKind::String) {
                    return operand;
                }
                [[fallthrough]];
            case BinaryOp::Subtract:
            case BinaryOp::Multiply:
            case BinaryOp::Divide:
                if (!isNumeric(operand)) {
                    throw CompileError(expr.span,
                                       std::format("`{}` wants numbers, but these are {}",
                                                   describeOp(expr.op), describe(operand)));
                }
                return operand;

            case BinaryOp::Remainder:
                if (!isInteger(operand)) {
                    throw CompileError(expr.span,
                                       std::format("`%` wants whole numbers, but these are {}",
                                                   describe(operand)));
                }
                return operand;

            case BinaryOp::Less:
            case BinaryOp::LessEqual:
            case BinaryOp::Greater:
            case BinaryOp::GreaterEqual:
                if (!isNumeric(operand) && operand->kind != TypeKind::String) {
                    throw CompileError(expr.span,
                                       std::format("`{}` compares numbers or strings, but these "
                                                   "are {}",
                                                   describeOp(expr.op), describe(operand)));
                }
                return types_.boolType();

            case BinaryOp::Equal:
            case BinaryOp::NotEqual:
                if (operand->kind == TypeKind::Function) {
                    throw CompileError(expr.span, "functions cannot be compared");
                }
                return types_.boolType();

            default:
                break;
        }
        throw CompileError(expr.span, "unhandled binary operator");
    }

    static bool isBareNumber(const Expr& expr) {
        return expr.kind == ExprKind::Integer || expr.kind == ExprKind::Floating;
    }

    static std::string_view describeOp(BinaryOp op) {
        switch (op) {
            case BinaryOp::Add: return "+";
            case BinaryOp::Subtract: return "-";
            case BinaryOp::Multiply: return "*";
            case BinaryOp::Divide: return "/";
            case BinaryOp::Remainder: return "%";
            case BinaryOp::Less: return "<";
            case BinaryOp::LessEqual: return "<=";
            case BinaryOp::Greater: return ">";
            case BinaryOp::GreaterEqual: return ">=";
            case BinaryOp::Equal: return "==";
            case BinaryOp::NotEqual: return "!=";
            case BinaryOp::And: return "&&";
            case BinaryOp::Or: return "||";
        }
        return "?";
    }

    const Type* checkConditional(IfExpr& expr, const Type* expected) {
        requireBool(expr.condition.get(), "an if condition");

        const Type* consequent = checkValueBlock(*expr.consequent, expected);
        const Type* alternative =
            checkValueBlock(*expr.alternative, expected != nullptr ? expected : consequent);

        if (!assignable(consequent, alternative) && !assignable(alternative, consequent)) {
            throw CompileError(expr.span,
                               std::format("one arm of this if gives {} and the other gives {}, "
                                           "so it has no single type",
                                           describe(consequent), describe(alternative)));
        }
        if (consequent->kind == TypeKind::Void) {
            throw CompileError(expr.span,
                               "an if used for its value has to give one, but these arms give "
                               "void");
        }
        return consequent->kind == TypeKind::NullPointer ? alternative : consequent;
    }

    const Type* checkValueBlock(ValueBlock& block, const Type* expected) {
        scopes_.emplace_back();
        declareNestedFunctions(block.statements);
        for (const StmtPtr& statement : block.statements) {
            rejectJumps(*statement, false);
            checkStatement(*statement);
        }
        const Type* type = check(block.value.get(), expected);
        scopes_.pop_back();
        return type;
    }

    const Type* checkAssign(AssignExpr& expr) {
        const Type* target = check(expr.target.get(), nullptr);
        requireAssignable(*expr.target);
        const Type* value = check(expr.value.get(), target);
        expect(value, target, expr.value->span, "this value");
        return target;
    }

    // The forms that name storage rather than a result.
    void requireAssignable(const Expr& target) const {
        switch (target.kind) {
            case ExprKind::Name: {
                const auto& name = static_cast<const NameExpr&>(target);
                if (name.resolution == NameKind::Local || name.resolution == NameKind::Global) {
                    return;
                }
                throw CompileError(target.span,
                                   std::format("`{}` is not a variable", name.name));
            }
            case ExprKind::Field: {
                const auto& field = static_cast<const FieldExpr&>(target);
                if (field.resolution == FieldKind::StructField ||
                    field.resolution == FieldKind::ModuleGlobal) {
                    return;
                }
                throw CompileError(target.span,
                                   std::format("`{}` is not a variable", field.name));
            }
            case ExprKind::Index: {
                const auto& index = static_cast<const IndexExpr&>(target);
                if (index.subject->type->kind == TypeKind::String) {
                    throw CompileError(target.span, "strings cannot be changed in place");
                }
                return;
            }
            case ExprKind::Unary:
                if (static_cast<const UnaryExpr&>(target).op == UnaryOp::Dereference) {
                    return;
                }
                break;
            default:
                break;
        }
        throw CompileError(target.span, "this is not something that can be assigned to");
    }

    Program& program_;
    TypeArena& types_;
    ModuleAst* module_ = nullptr;

    std::vector<std::unordered_map<std::string, const Type*>> scopes_;
    std::vector<const Type*> results_;
    int loopDepth_ = 0;
    std::vector<CompileError> errors_;
};

}  // namespace otter::detail

export namespace otter {

// Checks every module of a loaded program. The returned list is empty when the
// program is well formed.
std::vector<CompileError> checkProgram(Program& program) {
    detail::Checker checker(program);
    return checker.run();
}

}  // namespace otter
