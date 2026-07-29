export module otter.interp;

import std;
import otter.ast;
import otter.builtins;
import otter.diagnostics;
import otter.program;
import otter.types;
import otter.value;

namespace otter::detail {

// How a statement finished. Returning this rather than throwing keeps the cost
// of `return` inside a loop down to a comparison.
enum class Flow {
    Normal,
    Break,
    Continue,
    Return,
};

// Deep enough to catch a runaway recursion before the C++ stack runs out.
inline constexpr int callDepthLimit = 2000;

// Walks the tree and runs it.
//
// The one rule that shapes this code: a value held only in a C++ local is
// invisible to the collector, so anything kept across a point where more
// memory can be asked for is held in a Root instead.
class Interpreter {
public:
    explicit Interpreter(Program& program) : program_(program) {
        heap_.setRootScanner([this](Marker& marker) {
            for (const auto& [declaration, cell] : globals_) {
                marker.visit(cell);
            }
            for (const auto& [declaration, closure] : functions_) {
                marker.visit(closure);
            }
            marker.visit(returnValue_);
        });
    }

    int run() {
        auto* scope = heap_.allocate<Environment>();
        RootObject<Environment> heldScope(heap_, scope);

        for (ModuleAst* module : program_.order()) {
            for (const auto& declaration : module->globals) {
                Root value(heap_, evaluate(*declaration->initializer, *heldScope.get()));
                *value = copyOf(heap_, value.get());
                globals_[declaration.get()] = makeCell(value.get());
            }
        }

        const FunctionDecl* main = program_.entry()->findFunction("main");
        Root callee(heap_, functionValue(main));
        std::vector<Value> noArguments;
        Root result(heap_, call(callee.get(), noArguments, main->definition->span));

        if (main->definition->resultType->kind == TypeKind::Int) {
            return static_cast<int>(result.get().as<std::int64_t>());
        }
        return 0;
    }

private:
    // -- cells and scopes ---------------------------------------------------

    Cell* makeCell(const Value& value) {
        Root held(heap_, value);
        auto* cell = heap_.allocate<Cell>();
        cell->value = held.get();
        return cell;
    }

    void define(Environment& scope, const std::string& name, const Value& value) {
        Cell* cell = makeCell(value);
        scope.slots[name] = cell;
    }

    // -- calling ------------------------------------------------------------

    // `arguments` has to be reachable from a root already; every caller here
    // holds it in a RootVector.
    Value call(const Value& callee, std::vector<Value>& arguments, const Span& span) {
        Root heldCallee(heap_, callee);
        Closure* closure = heldCallee.get().as<Closure*>();
        const FunctionDefinition& definition = *closure->definition;

        if (definition.body == nullptr) {
            return callNative(definition, arguments, span);
        }

        if (++depth_ > callDepthLimit) {
            --depth_;
            throw RuntimeError(span, std::format("more than {} nested calls; this looks like a "
                                                 "recursion that never ends",
                                                 callDepthLimit));
        }

        auto* frame = heap_.allocate<Environment>();
        RootObject<Environment> heldFrame(heap_, frame);
        heldFrame->parent = heldCallee.get().as<Closure*>()->environment;

        for (std::size_t index = 0; index < definition.parameters.size(); ++index) {
            define(*heldFrame.get(), definition.parameters[index].name,
                   copyOf(heap_, arguments[index]));
        }

        Value returned;
        Flow flow = execute(*definition.body, *heldFrame.get());
        if (flow == Flow::Return) {
            returned = returnValue_;
            returnValue_ = Value();
        }
        --depth_;
        return returned;
    }

    Value callNative(const FunctionDefinition& definition, std::vector<Value>& arguments,
                     const Span& span) {
        auto entry = natives_.find(&definition);
        if (entry == natives_.end()) {
            const NativeEntry* native = findNative(definition.name);
            if (native == nullptr) {
                throw RuntimeError(span,
                                   std::format("this implementation has no host function named "
                                               "`{}`",
                                               definition.name));
            }
            entry = natives_.emplace(&definition, native).first;
        }
        return entry->second->call(heap_, arguments, span);
    }

    // -- statements ---------------------------------------------------------

    Flow execute(Stmt& statement, Environment& scope) {
        switch (statement.kind) {
            case StmtKind::VariableDeclaration: {
                auto& declaration = static_cast<VarStmt&>(statement);
                Root value(heap_, evaluate(*declaration.initializer, scope));
                define(scope, declaration.name, copyOf(heap_, value.get()));
                return Flow::Normal;
            }

            case StmtKind::Return: {
                auto& node = static_cast<ReturnStmt&>(statement);
                if (node.value == nullptr) {
                    returnValue_ = Value();
                    return Flow::Return;
                }
                Root value(heap_, evaluate(*node.value, scope));
                returnValue_ = copyOf(heap_, value.get());
                return Flow::Return;
            }

            case StmtKind::If: {
                auto& node = static_cast<IfStmt&>(statement);
                if (evaluate(*node.condition, scope).as<bool>()) {
                    return execute(*node.consequent, scope);
                }
                if (node.alternative != nullptr) {
                    return execute(*node.alternative, scope);
                }
                return Flow::Normal;
            }

            case StmtKind::NestedFunction:
                // The closure was made when the block was entered, so that a
                // call written above the declaration still finds it.
                return Flow::Normal;

            case StmtKind::While: {
                auto& node = static_cast<WhileStmt&>(statement);
                while (evaluate(*node.condition, scope).as<bool>()) {
                    Flow flow = execute(*node.body, scope);
                    if (flow == Flow::Break) {
                        break;
                    }
                    if (flow == Flow::Return) {
                        return flow;
                    }
                }
                return Flow::Normal;
            }

            case StmtKind::For: {
                auto& node = static_cast<ForStmt&>(statement);
                auto* loop = heap_.allocate<Environment>();
                RootObject<Environment> held(heap_, loop);
                held->parent = &scope;

                if (node.initializer != nullptr) {
                    execute(*node.initializer, *held.get());
                }
                while (node.condition == nullptr ||
                       evaluate(*node.condition, *held.get()).as<bool>()) {
                    Flow flow = execute(*node.body, *held.get());
                    if (flow == Flow::Break) {
                        break;
                    }
                    if (flow == Flow::Return) {
                        return flow;
                    }
                    // `continue` lands here too, so the step always runs.
                    if (node.step != nullptr) {
                        evaluate(*node.step, *held.get());
                    }
                }
                return Flow::Normal;
            }

            case StmtKind::Break:
                return Flow::Break;

            case StmtKind::Continue:
                return Flow::Continue;

            case StmtKind::Expression:
                evaluate(*static_cast<ExprStmt&>(statement).value, scope);
                return Flow::Normal;

            case StmtKind::Block: {
                auto& block = static_cast<Block&>(statement);
                auto* inner = heap_.allocate<Environment>();
                RootObject<Environment> held(heap_, inner);
                held->parent = &scope;
                return executeAll(block, *held.get());
            }
        }
        return Flow::Normal;
    }

    Flow executeAll(Block& block, Environment& scope) {
        makeNestedFunctions(block.statements, scope);
        for (const StmtPtr& entry : block.statements) {
            Flow flow = execute(*entry, scope);
            if (flow != Flow::Normal) {
                return flow;
            }
        }
        return Flow::Normal;
    }

    // Every function declared in a block gets its closure as the block is
    // entered, over the scope the block itself is running in, so that a pair of
    // them can call each other.
    void makeNestedFunctions(const std::vector<StmtPtr>& statements, Environment& scope) {
        for (const StmtPtr& entry : statements) {
            if (entry->kind != StmtKind::NestedFunction) {
                continue;
            }
            auto& node = static_cast<NestedFunctionStmt&>(*entry);
            auto* closure = heap_.allocate<Closure>();
            RootObject<Closure> held(heap_, closure);
            held->definition = node.definition.get();
            held->environment = &scope;
            define(scope, node.definition->name, Value(held.get()));
        }
    }

    // -- places -------------------------------------------------------------

    // The slot an expression names, so that it can be written through or have
    // its address taken. Anything that is not storage gets a fresh cell, which
    // is what `&` on a temporary should do.
    Pointer place(Expr& expr, Environment& scope) {
        switch (expr.kind) {
            case ExprKind::Name: {
                auto& name = static_cast<NameExpr&>(expr);
                if (name.resolution == NameKind::Local) {
                    Cell* cell = scope.find(name.name);
                    return Pointer{cell, &cell->value};
                }
                if (name.resolution == NameKind::Global) {
                    Cell* cell = globals_.at(name.global);
                    return Pointer{cell, &cell->value};
                }
                break;
            }

            case ExprKind::Field: {
                auto& field = static_cast<FieldExpr&>(expr);
                if (field.resolution == FieldKind::ModuleGlobal) {
                    Cell* cell = globals_.at(field.global);
                    return Pointer{cell, &cell->value};
                }
                if (field.resolution == FieldKind::StructField) {
                    StructValue structure = structureOf(field, scope);
                    return Pointer{
                        structure.object,
                        &structure.object->fields[static_cast<std::size_t>(field.index)]};
                }
                break;
            }

            case ExprKind::Index: {
                auto& index = static_cast<IndexExpr&>(expr);
                if (index.subject->type->kind != TypeKind::Array) {
                    break;
                }
                Root subject(heap_, evaluate(*index.subject, scope));
                auto position = evaluate(*index.index, scope).as<std::int64_t>();
                ArrayObject* array = subject.get().as<ArrayObject*>();
                checkBounds(position, array->elements.size(), expr.span);
                return Pointer{array, &array->elements[static_cast<std::size_t>(position)]};
            }

            case ExprKind::Unary: {
                auto& unary = static_cast<UnaryExpr&>(expr);
                if (unary.op == UnaryOp::Dereference) {
                    Pointer pointer = evaluate(*unary.operand, scope).as<Pointer>();
                    if (pointer.slot == nullptr) {
                        throw RuntimeError(expr.span, "this pointer is null");
                    }
                    return pointer;
                }
                break;
            }

            default:
                break;
        }

        Root value(heap_, evaluate(expr, scope));
        Cell* cell = makeCell(value.get());
        return Pointer{cell, &cell->value};
    }

    // The struct a field access reads from, whether it was reached directly or
    // through a pointer.
    StructValue structureOf(FieldExpr& field, Environment& scope) {
        if (field.throughPointer) {
            Pointer pointer = evaluate(*field.subject, scope).as<Pointer>();
            if (pointer.slot == nullptr) {
                throw RuntimeError(field.span, "this pointer is null");
            }
            return pointer.slot->as<StructValue>();
        }
        if (isStorage(*field.subject)) {
            return place(*field.subject, scope).slot->as<StructValue>();
        }
        return evaluate(*field.subject, scope).as<StructValue>();
    }

    static bool isStorage(const Expr& expr) {
        switch (expr.kind) {
            case ExprKind::Name: {
                const auto& name = static_cast<const NameExpr&>(expr);
                return name.resolution == NameKind::Local ||
                       name.resolution == NameKind::Global;
            }
            case ExprKind::Field: {
                const auto& field = static_cast<const FieldExpr&>(expr);
                return field.resolution == FieldKind::StructField ||
                       field.resolution == FieldKind::ModuleGlobal;
            }
            case ExprKind::Index:
                // A string is not storage: its bytes cannot be written to.
                return static_cast<const IndexExpr&>(expr).subject->type->kind ==
                       TypeKind::Array;
            case ExprKind::Unary:
                return static_cast<const UnaryExpr&>(expr).op == UnaryOp::Dereference;
            default:
                return false;
        }
    }

    void checkBounds(std::int64_t position, std::size_t size, const Span& span) const {
        if (position < 0 || position >= static_cast<std::int64_t>(size)) {
            throw RuntimeError(span, std::format("index {} lies outside a run of {} element(s)",
                                                 position, size));
        }
    }

    // -- expressions --------------------------------------------------------

    Value evaluate(Expr& expr, Environment& scope) {
        switch (expr.kind) {
            case ExprKind::Integer:
                return integerValue(static_cast<IntegerExpr&>(expr).value, expr.type);
            case ExprKind::Floating:
                return expr.type->kind == TypeKind::Float32
                           ? Value(static_cast<float>(static_cast<FloatingExpr&>(expr).value))
                           : Value(static_cast<FloatingExpr&>(expr).value);
            case ExprKind::String:
                return Value(heap_.makeString(static_cast<StringExpr&>(expr).value));
            case ExprKind::Char:
                return Value(static_cast<CharExpr&>(expr).value);
            case ExprKind::Bool:
                return Value(static_cast<BoolExpr&>(expr).value);
            case ExprKind::Null:
                return Value(Pointer{});
            case ExprKind::Name:
                return evaluateName(static_cast<NameExpr&>(expr), scope);
            case ExprKind::Array:
                return evaluateArray(static_cast<ArrayExpr&>(expr), scope);
            case ExprKind::StructLiteral:
                return evaluateStructLiteral(static_cast<StructLiteralExpr&>(expr), scope);
            case ExprKind::Function: {
                auto& node = static_cast<FunctionExpr&>(expr);
                auto* closure = heap_.allocate<Closure>();
                closure->definition = node.definition.get();
                closure->environment = &scope;
                return Value(closure);
            }
            case ExprKind::Call:
                return evaluateCall(static_cast<CallExpr&>(expr), scope);
            case ExprKind::Index:
                return evaluateIndex(static_cast<IndexExpr&>(expr), scope);
            case ExprKind::Field:
                return evaluateField(static_cast<FieldExpr&>(expr), scope);
            case ExprKind::Unary:
                return evaluateUnary(static_cast<UnaryExpr&>(expr), scope);
            case ExprKind::Cast:
                return evaluateCast(static_cast<CastExpr&>(expr), scope);
            case ExprKind::Binary:
                return evaluateBinary(static_cast<BinaryExpr&>(expr), scope);
            case ExprKind::Conditional:
                return evaluateConditional(static_cast<IfExpr&>(expr), scope);
            case ExprKind::Assign: {
                auto& node = static_cast<AssignExpr&>(expr);
                Root target(heap_, Value(place(*node.target, scope)));
                Root value(heap_, evaluate(*node.value, scope));
                *value = copyOf(heap_, value.get());
                *target.get().as<Pointer>().slot = value.get();
                return value.get();
            }
        }
        return Value();
    }

    // Nothing in a value block can jump out of it, so the statements run to
    // the end and the block's expression is the answer.
    Value evaluateConditional(IfExpr& expr, Environment& scope) {
        bool taken = evaluate(*expr.condition, scope).as<bool>();
        ValueBlock& arm = taken ? *expr.consequent : *expr.alternative;

        auto* inner = heap_.allocate<Environment>();
        RootObject<Environment> held(heap_, inner);
        held->parent = &scope;

        makeNestedFunctions(arm.statements, *held.get());
        for (const StmtPtr& entry : arm.statements) {
            execute(*entry, *held.get());
        }
        return evaluate(*arm.value, *held.get());
    }

    static Value integerValue(std::int64_t value, const Type* type) {
        switch (type->kind) {
            case TypeKind::Byte:
                return Value(static_cast<std::uint8_t>(value));
            case TypeKind::Char:
                return Value(static_cast<char32_t>(value));
            default:
                return Value(value);
        }
    }

    Value evaluateName(NameExpr& expr, Environment& scope) {
        switch (expr.resolution) {
            case NameKind::Local:
                return scope.find(expr.name)->value;
            case NameKind::Global:
                return globals_.at(expr.global)->value;
            case NameKind::Function:
                return functionValue(expr.function);
            default:
                throw RuntimeError(expr.span, std::format("`{}` has no value", expr.name));
        }
    }

    // A named function at the top level captures nothing, so one closure per
    // declaration will do for the whole run.
    Value functionValue(const FunctionDecl* declaration) {
        auto entry = functions_.find(declaration);
        if (entry == functions_.end()) {
            auto* closure = heap_.allocate<Closure>();
            closure->definition = declaration->definition.get();
            entry = functions_.emplace(declaration, closure).first;
        }
        return Value(entry->second);
    }

    Value evaluateArray(ArrayExpr& expr, Environment& scope) {
        if (expr.repeated) {
            Root seed(heap_, evaluate(*expr.elements[0], scope));
            auto count = evaluate(*expr.count, scope).as<std::int64_t>();
            if (count < 0) {
                throw RuntimeError(expr.count->span,
                                   std::format("an array cannot have {} elements", count));
            }

            auto* array = heap_.allocate<ArrayObject>();
            RootObject<ArrayObject> held(heap_, array);
            held->element = expr.type->element;
            held->elements.reserve(static_cast<std::size_t>(count));
            for (std::int64_t index = 0; index < count; ++index) {
                held->elements.push_back(copyOf(heap_, seed.get()));
            }
            return Value(held.get());
        }

        auto* array = heap_.allocate<ArrayObject>();
        RootObject<ArrayObject> held(heap_, array);
        held->element = expr.type->element;
        held->elements.reserve(expr.elements.size());
        for (const ExprPtr& element : expr.elements) {
            Root value(heap_, evaluate(*element, scope));
            held->elements.push_back(copyOf(heap_, value.get()));
        }
        return Value(held.get());
    }

    Value evaluateStructLiteral(StructLiteralExpr& expr, Environment& scope) {
        auto* object = heap_.allocate<StructObject>();
        RootObject<StructObject> held(heap_, object);
        held->fields.resize(expr.structure->fields.size());

        for (FieldInit& initializer : expr.initializers) {
            Root value(heap_, evaluate(*initializer.value, scope));
            held->fields[static_cast<std::size_t>(initializer.index)] =
                copyOf(heap_, value.get());
        }
        return Value(StructValue{expr.structure, held.get()});
    }

    Value evaluateCall(CallExpr& expr, Environment& scope) {
        Root callee(heap_, evaluate(*expr.callee, scope));
        RootVector arguments(heap_);
        arguments->reserve(expr.arguments.size());
        for (const ExprPtr& argument : expr.arguments) {
            arguments->push_back(evaluate(*argument, scope));
        }
        return call(callee.get(), arguments.get(), expr.span);
    }

    Value evaluateIndex(IndexExpr& expr, Environment& scope) {
        Root subject(heap_, evaluate(*expr.subject, scope));
        auto position = evaluate(*expr.index, scope).as<std::int64_t>();

        if (expr.subject->type->kind == TypeKind::String) {
            const std::string& text = subject.get().as<StringObject*>()->text;
            checkBounds(position, text.size(), expr.span);
            return Value(static_cast<std::uint8_t>(text[static_cast<std::size_t>(position)]));
        }

        ArrayObject* array = subject.get().as<ArrayObject*>();
        checkBounds(position, array->elements.size(), expr.span);
        return array->elements[static_cast<std::size_t>(position)];
    }

    Value evaluateField(FieldExpr& expr, Environment& scope) {
        switch (expr.resolution) {
            case FieldKind::StructField: {
                StructValue structure = structureOf(expr, scope);
                return structure.object->fields[static_cast<std::size_t>(expr.index)];
            }
            case FieldKind::Length: {
                Value subject = evaluate(*expr.subject, scope);
                if (expr.subject->type->kind == TypeKind::String) {
                    return Value(
                        static_cast<std::int64_t>(subject.as<StringObject*>()->text.size()));
                }
                return Value(
                    static_cast<std::int64_t>(subject.as<ArrayObject*>()->elements.size()));
            }
            case FieldKind::ModuleFunction:
                return functionValue(expr.function);
            case FieldKind::ModuleGlobal:
                return globals_.at(expr.global)->value;
            default:
                throw RuntimeError(expr.span, std::format("`{}` has no value", expr.name));
        }
    }

    Value evaluateUnary(UnaryExpr& expr, Environment& scope) {
        if (expr.op == UnaryOp::AddressOf) {
            return Value(place(*expr.operand, scope));
        }
        if (expr.op == UnaryOp::Dereference) {
            Pointer pointer = evaluate(*expr.operand, scope).as<Pointer>();
            if (pointer.slot == nullptr) {
                throw RuntimeError(expr.span, "this pointer is null");
            }
            return *pointer.slot;
        }

        Value operand = evaluate(*expr.operand, scope);
        switch (expr.op) {
            case UnaryOp::Plus:
                return operand;
            case UnaryOp::Not:
                return Value(!operand.as<bool>());
            case UnaryOp::Minus:
                switch (expr.type->kind) {
                    case TypeKind::Int:
                        return Value(negate(operand.as<std::int64_t>()));
                    case TypeKind::Byte:
                        return Value(static_cast<std::uint8_t>(
                            0u - static_cast<unsigned>(operand.as<std::uint8_t>())));
                    case TypeKind::Char:
                        return Value(static_cast<char32_t>(
                            0u - static_cast<std::uint32_t>(operand.as<char32_t>())));
                    case TypeKind::Float32:
                        return Value(-operand.as<float>());
                    default:
                        return Value(-operand.as<double>());
                }
            case UnaryOp::Complement:
                switch (expr.type->kind) {
                    case TypeKind::Byte:
                        return Value(static_cast<std::uint8_t>(~operand.as<std::uint8_t>()));
                    case TypeKind::Char:
                        return Value(static_cast<char32_t>(~operand.as<char32_t>()));
                    default:
                        return Value(~operand.as<std::int64_t>());
                }
            default:
                break;
        }
        throw RuntimeError(expr.span, "unhandled unary operator");
    }

    static std::int64_t negate(std::int64_t value) {
        return static_cast<std::int64_t>(0ull - static_cast<std::uint64_t>(value));
    }

    Value evaluateCast(CastExpr& expr, Environment& scope) {
        Value operand = evaluate(*expr.operand, scope);
        const Type* from = expr.operand->type;
        const Type* to = expr.type;

        if (from == to || to->kind == TypeKind::Pointer) {
            return operand;
        }

        // Every numeric conversion goes through one of these two, which is
        // what makes `byte` truncate and `float32` round.
        if (isFloating(from)) {
            double value = from->kind == TypeKind::Float32
                               ? static_cast<double>(operand.as<float>())
                               : operand.as<double>();
            return fromDouble(value, to);
        }
        return fromInteger(wholeNumberOf(operand, from), to);
    }

    static std::int64_t wholeNumberOf(const Value& value, const Type* type) {
        switch (type->kind) {
            case TypeKind::Byte:
                return value.as<std::uint8_t>();
            case TypeKind::Char:
                return static_cast<std::int64_t>(value.as<char32_t>());
            default:
                return value.as<std::int64_t>();
        }
    }

    static Value fromInteger(std::int64_t value, const Type* to) {
        switch (to->kind) {
            case TypeKind::Byte:
                return Value(static_cast<std::uint8_t>(value));
            case TypeKind::Char:
                return Value(static_cast<char32_t>(value));
            case TypeKind::Float32:
                return Value(static_cast<float>(value));
            case TypeKind::Float64:
                return Value(static_cast<double>(value));
            default:
                return Value(value);
        }
    }

    static Value fromDouble(double value, const Type* to) {
        switch (to->kind) {
            case TypeKind::Byte:
                return Value(static_cast<std::uint8_t>(value));
            case TypeKind::Char:
                return Value(static_cast<char32_t>(value));
            case TypeKind::Float32:
                return Value(static_cast<float>(value));
            case TypeKind::Float64:
                return Value(value);
            default:
                return Value(static_cast<std::int64_t>(value));
        }
    }

    Value evaluateBinary(BinaryExpr& expr, Environment& scope) {
        if (expr.op == BinaryOp::And) {
            return Value(evaluate(*expr.left, scope).as<bool>() &&
                         evaluate(*expr.right, scope).as<bool>());
        }
        if (expr.op == BinaryOp::Or) {
            return Value(evaluate(*expr.left, scope).as<bool>() ||
                         evaluate(*expr.right, scope).as<bool>());
        }

        Root left(heap_, evaluate(*expr.left, scope));
        Root right(heap_, evaluate(*expr.right, scope));

        if (expr.op == BinaryOp::Equal) {
            return Value(equalValues(left.get(), right.get()));
        }
        if (expr.op == BinaryOp::NotEqual) {
            return Value(!equalValues(left.get(), right.get()));
        }

        const Type* operand = expr.operandType;
        if (operand->kind == TypeKind::String) {
            return stringOperation(expr, left.get().as<StringObject*>()->text,
                                   right.get().as<StringObject*>()->text);
        }
        if (isFloating(operand)) {
            if (operand->kind == TypeKind::Float32) {
                return floatingOperation<float>(expr, left.get().as<float>(),
                                                right.get().as<float>());
            }
            return floatingOperation<double>(expr, left.get().as<double>(),
                                             right.get().as<double>());
        }
        return integerOperation(expr, wholeNumberOf(left.get(), operand),
                                wholeNumberOf(right.get(), operand));
    }

    Value stringOperation(BinaryExpr& expr, const std::string& left, const std::string& right) {
        switch (expr.op) {
            case BinaryOp::Add:
                return Value(heap_.makeString(left + right));
            case BinaryOp::Less:
                return Value(left < right);
            case BinaryOp::LessEqual:
                return Value(left <= right);
            case BinaryOp::Greater:
                return Value(left > right);
            default:
                return Value(left >= right);
        }
    }

    template <typename Number>
    static Value floatingOperation(BinaryExpr& expr, Number left, Number right) {
        switch (expr.op) {
            case BinaryOp::Add:
                return Value(static_cast<Number>(left + right));
            case BinaryOp::Subtract:
                return Value(static_cast<Number>(left - right));
            case BinaryOp::Multiply:
                return Value(static_cast<Number>(left * right));
            case BinaryOp::Divide:
                return Value(static_cast<Number>(left / right));
            case BinaryOp::Less:
                return Value(left < right);
            case BinaryOp::LessEqual:
                return Value(left <= right);
            case BinaryOp::Greater:
                return Value(left > right);
            default:
                return Value(left >= right);
        }
    }

    Value integerOperation(BinaryExpr& expr, std::int64_t left, std::int64_t right) {
        auto wrapping = [](std::int64_t a, std::int64_t b, auto op) {
            return static_cast<std::int64_t>(
                op(static_cast<std::uint64_t>(a), static_cast<std::uint64_t>(b)));
        };

        switch (expr.op) {
            case BinaryOp::Add:
                return integerValue(wrapping(left, right, std::plus<std::uint64_t>{}),
                                    expr.type);
            case BinaryOp::Subtract:
                return integerValue(wrapping(left, right, std::minus<std::uint64_t>{}),
                                    expr.type);
            case BinaryOp::Multiply:
                return integerValue(wrapping(left, right, std::multiplies<std::uint64_t>{}),
                                    expr.type);
            case BinaryOp::Divide:
                if (right == 0) {
                    throw RuntimeError(expr.span, "division by zero");
                }
                return integerValue(left / right, expr.type);
            case BinaryOp::Remainder:
                if (right == 0) {
                    throw RuntimeError(expr.span, "remainder by zero");
                }
                return integerValue(left % right, expr.type);
            case BinaryOp::Less:
                return Value(left < right);
            case BinaryOp::LessEqual:
                return Value(left <= right);
            case BinaryOp::Greater:
                return Value(left > right);
            default:
                return Value(left >= right);
        }
    }

    Program& program_;
    Heap heap_;
    std::map<const GlobalDecl*, Cell*> globals_;
    std::map<const FunctionDecl*, Closure*> functions_;
    std::map<const FunctionDefinition*, const NativeEntry*> natives_;
    Value returnValue_;
    int depth_ = 0;
};

}  // namespace otter::detail

export namespace otter {

// Runs a checked program and returns what `main` returned.
int runProgram(Program& program) {
    detail::Interpreter interpreter(program);
    return interpreter.run();
}

}  // namespace otter
