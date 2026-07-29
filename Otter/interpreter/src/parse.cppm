module;

#include <antlr4-runtime.h>

#include "OtterLexer.h"
#include "OtterParser.h"

export module otter.parse;

import std;
import otter.ast;
import otter.diagnostics;
import otter.types;

namespace otter::detail {

namespace grammar = ::otter::grammar;

// Turns ANTLR's complaints into ours, and stops at the first one: a parse tree
// patched up by error recovery is not worth lowering.
class ThrowingErrorListener : public antlr4::BaseErrorListener {
public:
    explicit ThrowingErrorListener(std::string file) : file_(std::move(file)) {}

    void syntaxError(antlr4::Recognizer*, antlr4::Token*, std::size_t line,
                     std::size_t column, const std::string& message,
                     std::exception_ptr) override {
        throw CompileError(Span{file_, Position{static_cast<int>(line),
                                                static_cast<int>(column) + 1}},
                           message);
    }

private:
    std::string file_;
};

void appendUtf8(std::string& out, char32_t code) {
    if (code < 0x80) {
        out += static_cast<char>(code);
    } else if (code < 0x800) {
        out += static_cast<char>(0xC0 | (code >> 6));
        out += static_cast<char>(0x80 | (code & 0x3F));
    } else if (code < 0x10000) {
        out += static_cast<char>(0xE0 | (code >> 12));
        out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (code & 0x3F));
    } else {
        out += static_cast<char>(0xF0 | (code >> 18));
        out += static_cast<char>(0x80 | ((code >> 12) & 0x3F));
        out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (code & 0x3F));
    }
}

// Reads one code point starting at `index`, leaving `index` on the next one.
char32_t decodeUtf8(std::string_view text, std::size_t& index) {
    auto first = static_cast<unsigned char>(text[index++]);
    if (first < 0x80) {
        return first;
    }
    int extra = (first >> 5) == 0b110 ? 1 : (first >> 4) == 0b1110 ? 2 : 3;
    char32_t code = first & (0x3F >> extra);
    for (int step = 0; step < extra && index < text.size(); ++step) {
        code = (code << 6) | (static_cast<unsigned char>(text[index++]) & 0x3F);
    }
    return code;
}

// The body of a quoted literal, with escapes resolved. `body` excludes the
// quotes.
std::string unescape(std::string_view body, const Span& span) {
    std::string out;
    for (std::size_t index = 0; index < body.size();) {
        char character = body[index];
        if (character != '\\') {
            out += character;
            ++index;
            continue;
        }
        ++index;
        if (index >= body.size()) {
            throw CompileError(span, "the literal ends in a backslash");
        }
        char escape = body[index++];
        switch (escape) {
            case 'a': out += '\a'; break;
            case 'b': out += '\b'; break;
            case 'f': out += '\f'; break;
            case 'n': out += '\n'; break;
            case 'r': out += '\r'; break;
            case 't': out += '\t'; break;
            case 'v': out += '\v'; break;
            case '0': out += '\0'; break;
            case '\\': out += '\\'; break;
            case '\'': out += '\''; break;
            case '"': out += '"'; break;
            case '?': out += '?'; break;
            case 'x': {
                if (index + 2 > body.size()) {
                    throw CompileError(span, "\\x needs two hexadecimal digits");
                }
                auto value = std::stoul(std::string(body.substr(index, 2)), nullptr, 16);
                out += static_cast<char>(value);
                index += 2;
                break;
            }
            case 'u': {
                if (index >= body.size() || body[index] != '{') {
                    throw CompileError(span, "\\u needs a braced code point, as in \\u{1F9A6}");
                }
                std::size_t close = body.find('}', index);
                if (close == std::string_view::npos) {
                    throw CompileError(span, "\\u is missing its closing brace");
                }
                auto value = std::stoul(std::string(body.substr(index + 1, close - index - 1)),
                                        nullptr, 16);
                appendUtf8(out, static_cast<char32_t>(value));
                index = close + 1;
                break;
            }
            default:
                throw CompileError(span, std::format("unknown escape \\{}", escape));
        }
    }
    return out;
}

std::int64_t parseInteger(std::string_view text, const Span& span) {
    std::string digits;
    for (char character : text) {
        if (character != '_') {
            digits += character;
        }
    }

    int base = 10;
    std::string_view body = digits;
    if (body.starts_with("0x") || body.starts_with("0X")) {
        base = 16;
        body.remove_prefix(2);
    } else if (body.starts_with("0b") || body.starts_with("0B")) {
        base = 2;
        body.remove_prefix(2);
    }

    std::uint64_t value = 0;
    auto [stop, error] =
        std::from_chars(body.data(), body.data() + body.size(), value, base);
    if (error != std::errc{} || stop != body.data() + body.size()) {
        throw CompileError(span, std::format("`{}` is not a whole number", text));
    }
    if (value > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
        throw CompileError(span, std::format("`{}` does not fit in an int", text));
    }
    return static_cast<std::int64_t>(value);
}

double parseFloating(std::string_view text, const Span& span) {
    std::string digits;
    for (char character : text) {
        if (character != '_') {
            digits += character;
        }
    }
    try {
        return std::stod(digits);
    } catch (const std::exception&) {
        throw CompileError(span, std::format("`{}` is not a number", text));
    }
}

// Walks the parse tree and builds the AST. Everything here is shape: names are
// carried across as written, and the checker decides what they mean.
class Lowering {
public:
    explicit Lowering(std::string file) : file_(std::move(file)) {}

    std::unique_ptr<ModuleAst> program(grammar::OtterParser::ProgramContext* context) {
        auto module = std::make_unique<ModuleAst>();
        module->file = file_;
        module->span = spanOf(context);
        module->name = context->moduleDeclaration()->Identifier()->getText();

        for (auto* entry : context->importDeclaration()) {
            module->imports.push_back(
                Import{entry->Identifier()->getText(), spanOf(entry), nullptr});
        }

        for (auto* entry : context->topLevelDeclaration()) {
            if (auto* declaration = entry->structDeclaration()) {
                module->structs.push_back(structDeclaration(declaration));
            } else if (auto* declaration = entry->typeAliasDeclaration()) {
                auto alias = typeAliasDeclaration(declaration);
                alias->owner = module.get();
                module->aliases.push_back(std::move(alias));
            } else if (auto* declaration = entry->functionDeclaration()) {
                auto function = functionDeclaration(declaration);
                function->owner = module.get();
                module->functions.push_back(std::move(function));
            } else {
                auto global = globalDeclaration(entry->globalVariableDeclaration());
                global->owner = module.get();
                module->globals.push_back(std::move(global));
            }
        }
        return module;
    }

private:
    Span spanOf(antlr4::ParserRuleContext* context) const {
        antlr4::Token* token = context->getStart();
        return Span{file_, Position{static_cast<int>(token->getLine()),
                                    static_cast<int>(token->getCharPositionInLine()) + 1}};
    }

    Span spanOf(antlr4::tree::TerminalNode* node) const {
        antlr4::Token* token = node->getSymbol();
        return Span{file_, Position{static_cast<int>(token->getLine()),
                                    static_cast<int>(token->getCharPositionInLine()) + 1}};
    }

    // -- declarations -------------------------------------------------------

    std::unique_ptr<StructDecl> structDeclaration(
        grammar::OtterParser::StructDeclarationContext* context) {
        auto declaration = std::make_unique<StructDecl>();
        declaration->name = context->Identifier()->getText();
        declaration->exported = context->Export() != nullptr;
        declaration->span = spanOf(context);
        for (auto* field : context->structField()) {
            declaration->fieldNames.push_back(field->Identifier()->getText());
            declaration->fieldTypes.push_back(typeExpression(field->type()));
            declaration->fieldSpans.push_back(spanOf(field));
        }
        return declaration;
    }

    std::unique_ptr<TypeAliasDecl> typeAliasDeclaration(
        grammar::OtterParser::TypeAliasDeclarationContext* context) {
        auto declaration = std::make_unique<TypeAliasDecl>();
        declaration->name = context->Identifier()->getText();
        declaration->exported = context->Export() != nullptr;
        declaration->span = spanOf(context);
        declaration->target = typeExpression(context->type());
        return declaration;
    }

    std::unique_ptr<FunctionDecl> functionDeclaration(
        grammar::OtterParser::FunctionDeclarationContext* context) {
        auto declaration = std::make_unique<FunctionDecl>();
        declaration->exported = context->Export() != nullptr;

        auto definition = std::make_unique<FunctionDefinition>();
        definition->name = context->Identifier()->getText();
        definition->span = spanOf(context);
        definition->parameters = parameters(context->parameterList());
        definition->declaredResult = typeExpression(context->type());
        if (auto* body = context->functionBody()->block()) {
            definition->body = block(body);
        }

        declaration->definition = std::move(definition);
        return declaration;
    }

    std::unique_ptr<GlobalDecl> globalDeclaration(
        grammar::OtterParser::GlobalVariableDeclarationContext* context) {
        auto declaration = std::make_unique<GlobalDecl>();
        declaration->name = context->Identifier()->getText();
        declaration->exported = context->Export() != nullptr;
        declaration->span = spanOf(context);
        declaration->declaredType = typeExpression(context->type());
        declaration->initializer = expression(context->expression());
        return declaration;
    }

    std::vector<Parameter> parameters(grammar::OtterParser::ParameterListContext* context) {
        std::vector<Parameter> result;
        for (auto* entry : context->parameter()) {
            Parameter parameter;
            parameter.name = entry->Identifier()->getText();
            parameter.declaredType = typeExpression(entry->type());
            parameter.span = spanOf(entry);
            result.push_back(std::move(parameter));
        }
        return result;
    }

    // -- types --------------------------------------------------------------

    TypeExprPtr typeExpression(grammar::OtterParser::TypeContext* context) {
        auto node = std::make_unique<TypeExpr>();
        node->span = spanOf(context);

        if (auto* named = dynamic_cast<grammar::OtterParser::NamedTypeContext*>(context)) {
            node->kind = TypeExprKind::Named;
            for (auto* part : named->qualifiedName()->Identifier()) {
                node->path.push_back(part->getText());
            }
            for (auto* argument : named->type()) {
                node->arguments.push_back(typeExpression(argument));
            }
            return node;
        }

        if (auto* pointer = dynamic_cast<grammar::OtterParser::PointerTypeContext*>(context)) {
            node->kind = TypeExprKind::Pointer;
            node->target = typeExpression(pointer->type());
            return node;
        }

        auto* function = dynamic_cast<grammar::OtterParser::FunctionTypeContext*>(context);
        node->kind = TypeExprKind::Function;
        // The grammar lists the parameters and then the result, so the last
        // type child is the result and the rest are parameters.
        std::vector<grammar::OtterParser::TypeContext*> parts = function->type();
        for (std::size_t index = 0; index + 1 < parts.size(); ++index) {
            node->parameters.push_back(typeExpression(parts[index]));
        }
        node->target = typeExpression(parts.back());
        return node;
    }

    // -- statements ---------------------------------------------------------

    std::unique_ptr<Block> block(grammar::OtterParser::BlockContext* context) {
        auto node = std::make_unique<Block>(spanOf(context));
        for (auto* entry : context->statement()) {
            node->statements.push_back(statement(entry));
        }
        return node;
    }

    StmtPtr statement(grammar::OtterParser::StatementContext* context) {
        if (auto* entry = context->variableDeclaration()) {
            auto node = std::make_unique<VarStmt>(spanOf(entry), entry->Identifier()->getText());
            node->declaredType = typeExpression(entry->type());
            node->initializer = expression(entry->expression());
            return node;
        }
        if (auto* entry = context->nestedFunctionDeclaration()) {
            auto node = std::make_unique<NestedFunctionStmt>(spanOf(entry));
            auto definition = std::make_unique<FunctionDefinition>();
            definition->name = entry->Identifier()->getText();
            definition->span = spanOf(entry);
            definition->parameters = parameters(entry->parameterList());
            definition->declaredResult = typeExpression(entry->type());
            definition->body = block(entry->block());
            node->definition = std::move(definition);
            return node;
        }
        if (auto* entry = context->returnStatement()) {
            auto node = std::make_unique<ReturnStmt>(spanOf(entry));
            if (auto* value = entry->expression()) {
                node->value = expression(value);
            }
            return node;
        }
        if (auto* entry = context->ifStatement()) {
            return ifStatement(entry);
        }
        if (auto* entry = context->whileStatement()) {
            auto node = std::make_unique<WhileStmt>(spanOf(entry));
            node->condition = expression(entry->expression());
            node->body = block(entry->block());
            return node;
        }
        if (auto* entry = context->forStatement()) {
            return forStatement(entry);
        }
        if (auto* entry = context->breakStatement()) {
            return std::make_unique<BreakStmt>(spanOf(entry));
        }
        if (auto* entry = context->continueStatement()) {
            return std::make_unique<ContinueStmt>(spanOf(entry));
        }
        if (auto* entry = context->expressionStatement()) {
            auto node = std::make_unique<ExprStmt>(spanOf(entry));
            node->value = expression(entry->expression());
            return node;
        }
        return block(context->block());
    }

    StmtPtr forStatement(grammar::OtterParser::ForStatementContext* context) {
        auto node = std::make_unique<ForStmt>(spanOf(context));

        if (auto* initializer = context->forInitializer()) {
            if (initializer->Var() != nullptr) {
                auto declaration = std::make_unique<VarStmt>(
                    spanOf(initializer), initializer->Identifier()->getText());
                declaration->declaredType = typeExpression(initializer->type());
                declaration->initializer = expression(initializer->expression());
                node->initializer = std::move(declaration);
            } else {
                auto statement = std::make_unique<ExprStmt>(spanOf(initializer));
                statement->value = expression(initializer->expression());
                node->initializer = std::move(statement);
            }
        }

        if (context->condition != nullptr) {
            node->condition = expression(context->condition);
        }
        if (context->step != nullptr) {
            node->step = expression(context->step);
        }
        node->body = block(context->block());
        return node;
    }

    StmtPtr ifStatement(grammar::OtterParser::IfStatementContext* context) {
        auto node = std::make_unique<IfStmt>(spanOf(context));
        node->condition = expression(context->expression());
        node->consequent = block(context->block());
        if (auto* alternative = context->elseBody()) {
            if (auto* chained = alternative->ifStatement()) {
                node->alternative = ifStatement(chained);
            } else {
                node->alternative = block(alternative->block());
            }
        }
        return node;
    }

    // -- expressions --------------------------------------------------------

    ExprPtr expression(grammar::OtterParser::ExpressionContext* context) {
        using Parser = grammar::OtterParser;
        Span span = spanOf(context);

        if (auto* node = dynamic_cast<Parser::IntegerExpressionContext*>(context)) {
            return std::make_unique<IntegerExpr>(span, parseInteger(node->getText(), span));
        }
        if (auto* node = dynamic_cast<Parser::FloatingExpressionContext*>(context)) {
            return std::make_unique<FloatingExpr>(span, parseFloating(node->getText(), span));
        }
        if (auto* node = dynamic_cast<Parser::StringExpressionContext*>(context)) {
            std::string text = node->getText();
            return std::make_unique<StringExpr>(
                span, unescape(std::string_view(text).substr(1, text.size() - 2), span));
        }
        if (auto* node = dynamic_cast<Parser::CharExpressionContext*>(context)) {
            return std::make_unique<CharExpr>(span, charLiteral(node->getText(), span));
        }
        if (dynamic_cast<Parser::TrueExpressionContext*>(context) != nullptr) {
            return std::make_unique<BoolExpr>(span, true);
        }
        if (dynamic_cast<Parser::FalseExpressionContext*>(context) != nullptr) {
            return std::make_unique<BoolExpr>(span, false);
        }
        if (dynamic_cast<Parser::NullExpressionContext*>(context) != nullptr) {
            return std::make_unique<NullExpr>(span);
        }
        if (auto* node = dynamic_cast<Parser::NameExpressionContext*>(context)) {
            return std::make_unique<NameExpr>(span, node->getText());
        }
        if (auto* node = dynamic_cast<Parser::GroupExpressionContext*>(context)) {
            return expression(node->expression());
        }
        if (auto* node = dynamic_cast<Parser::ArrayExpressionContext*>(context)) {
            return arrayLiteral(node->arrayLiteral());
        }
        if (auto* node = dynamic_cast<Parser::StructExpressionContext*>(context)) {
            return structLiteral(node->structLiteral());
        }
        if (auto* node = dynamic_cast<Parser::FunctionExpressionContext*>(context)) {
            auto result = std::make_unique<FunctionExpr>(span);
            result->definition = anonymousFunction(node->anonymousFunction());
            return result;
        }
        if (auto* node = dynamic_cast<Parser::ConditionalExpressionContext*>(context)) {
            return ifExpression(node->ifExpression());
        }
        if (auto* node = dynamic_cast<Parser::CallExpressionContext*>(context)) {
            auto result = std::make_unique<CallExpr>(span);
            std::vector<Parser::ExpressionContext*> parts = node->expression();
            result->callee = expression(parts.front());
            for (std::size_t index = 1; index < parts.size(); ++index) {
                result->arguments.push_back(expression(parts[index]));
            }
            return result;
        }
        if (auto* node = dynamic_cast<Parser::IndexExpressionContext*>(context)) {
            auto result = std::make_unique<IndexExpr>(span);
            result->subject = expression(node->expression(0));
            result->index = expression(node->expression(1));
            return result;
        }
        if (auto* node = dynamic_cast<Parser::FieldExpressionContext*>(context)) {
            auto result = std::make_unique<FieldExpr>(span, node->Identifier()->getText());
            result->subject = expression(node->expression());
            return result;
        }
        if (auto* node = dynamic_cast<Parser::UnaryExpressionContext*>(context)) {
            auto result = std::make_unique<UnaryExpr>(span, unaryOp(node->op->getText()));
            result->operand = expression(node->expression());
            return result;
        }
        if (auto* node = dynamic_cast<Parser::CastExpressionContext*>(context)) {
            auto result = std::make_unique<CastExpr>(span);
            result->operand = expression(node->expression());
            result->target = typeExpression(node->type());
            return result;
        }
        if (auto* node = dynamic_cast<Parser::AssignmentExpressionContext*>(context)) {
            auto result = std::make_unique<AssignExpr>(span);
            result->target = expression(node->expression(0));
            result->value = expression(node->expression(1));
            return result;
        }
        if (auto* node = dynamic_cast<Parser::LogicalAndExpressionContext*>(context)) {
            return binary(span, BinaryOp::And, node->expression(0), node->expression(1));
        }
        if (auto* node = dynamic_cast<Parser::LogicalOrExpressionContext*>(context)) {
            return binary(span, BinaryOp::Or, node->expression(0), node->expression(1));
        }
        if (auto* node = dynamic_cast<Parser::MultiplicativeExpressionContext*>(context)) {
            return binary(span, binaryOp(node->op->getText()), node->expression(0),
                          node->expression(1));
        }
        if (auto* node = dynamic_cast<Parser::AdditiveExpressionContext*>(context)) {
            return binary(span, binaryOp(node->op->getText()), node->expression(0),
                          node->expression(1));
        }
        if (auto* node = dynamic_cast<Parser::RelationalExpressionContext*>(context)) {
            return binary(span, binaryOp(node->op->getText()), node->expression(0),
                          node->expression(1));
        }
        auto* node = dynamic_cast<Parser::EqualityExpressionContext*>(context);
        return binary(span, binaryOp(node->op->getText()), node->expression(0),
                      node->expression(1));
    }

    ExprPtr binary(Span span, BinaryOp op, grammar::OtterParser::ExpressionContext* left,
                   grammar::OtterParser::ExpressionContext* right) {
        auto node = std::make_unique<BinaryExpr>(std::move(span), op);
        node->left = expression(left);
        node->right = expression(right);
        return node;
    }

    static UnaryOp unaryOp(const std::string& text) {
        if (text == "+") return UnaryOp::Plus;
        if (text == "-") return UnaryOp::Minus;
        if (text == "!") return UnaryOp::Not;
        if (text == "~") return UnaryOp::Complement;
        if (text == "*") return UnaryOp::Dereference;
        return UnaryOp::AddressOf;
    }

    static BinaryOp binaryOp(const std::string& text) {
        if (text == "*") return BinaryOp::Multiply;
        if (text == "/") return BinaryOp::Divide;
        if (text == "%") return BinaryOp::Remainder;
        if (text == "+") return BinaryOp::Add;
        if (text == "-") return BinaryOp::Subtract;
        if (text == "<") return BinaryOp::Less;
        if (text == "<=") return BinaryOp::LessEqual;
        if (text == ">") return BinaryOp::Greater;
        if (text == ">=") return BinaryOp::GreaterEqual;
        if (text == "==") return BinaryOp::Equal;
        return BinaryOp::NotEqual;
    }

    char32_t charLiteral(const std::string& text, const Span& span) {
        std::string body = unescape(std::string_view(text).substr(1, text.size() - 2), span);
        if (body.empty()) {
            throw CompileError(span, "a char literal needs a character");
        }
        std::size_t index = 0;
        char32_t code = decodeUtf8(body, index);
        if (index != body.size()) {
            throw CompileError(span, "a char literal holds one character, not several");
        }
        return code;
    }

    std::unique_ptr<ValueBlock> valueBlock(grammar::OtterParser::ValueBlockContext* context) {
        auto node = std::make_unique<ValueBlock>();
        node->span = spanOf(context);
        for (auto* entry : context->statement()) {
            node->statements.push_back(statement(entry));
        }
        node->value = expression(context->expression());
        return node;
    }

    ExprPtr ifExpression(grammar::OtterParser::IfExpressionContext* context) {
        auto node = std::make_unique<IfExpr>(spanOf(context));
        node->condition = expression(context->expression());
        node->consequent = valueBlock(context->valueBlock(0));

        if (auto* chained = context->ifExpression()) {
            // `else if` is an alternative whose only content is the next one.
            auto wrapper = std::make_unique<ValueBlock>();
            wrapper->span = spanOf(chained);
            wrapper->value = ifExpression(chained);
            node->alternative = std::move(wrapper);
        } else {
            node->alternative = valueBlock(context->valueBlock(1));
        }
        return node;
    }

    ExprPtr arrayLiteral(grammar::OtterParser::ArrayLiteralContext* context) {
        auto node = std::make_unique<ArrayExpr>(spanOf(context));
        std::vector<grammar::OtterParser::ExpressionContext*> parts = context->expression();

        // `[value; count]` and `[a, b, c]` differ only by the separator, which
        // the grammar does not name, so look for it among the children.
        bool repeated = false;
        for (auto* child : context->children) {
            if (auto* terminal = dynamic_cast<antlr4::tree::TerminalNode*>(child)) {
                if (terminal->getText() == ";") {
                    repeated = true;
                }
            }
        }

        if (repeated) {
            node->repeated = true;
            node->elements.push_back(expression(parts[0]));
            node->count = expression(parts[1]);
            return node;
        }
        for (auto* part : parts) {
            node->elements.push_back(expression(part));
        }
        return node;
    }

    ExprPtr structLiteral(grammar::OtterParser::StructLiteralContext* context) {
        auto node = std::make_unique<StructLiteralExpr>(spanOf(context));
        for (auto* part : context->qualifiedName()->Identifier()) {
            node->path.push_back(part->getText());
        }
        for (auto* entry : context->structInitializer()) {
            FieldInit init;
            init.name = entry->Identifier()->getText();
            init.value = expression(entry->expression());
            init.span = spanOf(entry);
            node->initializers.push_back(std::move(init));
        }
        return node;
    }

    std::unique_ptr<FunctionDefinition> anonymousFunction(
        grammar::OtterParser::AnonymousFunctionContext* context) {
        auto definition = std::make_unique<FunctionDefinition>();
        definition->span = spanOf(context);
        definition->parameters = parameters(context->parameterList());
        definition->declaredResult = typeExpression(context->type());
        definition->body = block(context->block());
        return definition;
    }

    std::string file_;
};

}  // namespace otter::detail

export namespace otter {

// Parses one file into a module. Throws CompileError on the first syntax
// problem; the caller supplies the text so that built-in modules can be parsed
// from memory.
std::unique_ptr<ModuleAst> parseModule(const std::string& file, const std::string& text) {
    antlr4::ANTLRInputStream input(text);
    detail::ThrowingErrorListener listener(file);

    grammar::OtterLexer lexer(&input);
    lexer.removeErrorListeners();
    lexer.addErrorListener(&listener);

    antlr4::CommonTokenStream tokens(&lexer);
    grammar::OtterParser parser(&tokens);
    parser.removeErrorListeners();
    parser.addErrorListener(&listener);

    grammar::OtterParser::ProgramContext* tree = parser.program();
    detail::Lowering lowering(file);
    return lowering.program(tree);
}

}  // namespace otter
