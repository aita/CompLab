export module otter.diagnostics;

import std;

export namespace otter {

// Where something is in a source file. Columns are counted in bytes, which is
// what the parser hands us and what an editor jumping to a position wants.
struct Position {
    int line = 0;
    int column = 0;
};

struct Span {
    std::string file;
    Position start;
};

std::string describe(const Span& span) {
    if (span.file.empty()) {
        return "<unknown>";
    }
    if (span.start.line == 0) {
        return span.file;
    }
    return std::format("{}:{}:{}", span.file, span.start.line, span.start.column);
}

// A complaint about the program text: a syntax error, an unresolved name, a
// type mismatch. Everything the front end rejects arrives as one of these.
class CompileError : public std::runtime_error {
public:
    CompileError(Span span, std::string message)
        : std::runtime_error(std::format("{}: {}", describe(span), message)),
          span_(std::move(span)),
          message_(std::move(message)) {}

    const Span& span() const { return span_; }
    const std::string& message() const { return message_; }

private:
    Span span_;
    std::string message_;
};

// A fault while the program runs: a division by zero, an index out of range, a
// null dereference. The language checks these rather than letting them through.
class RuntimeError : public std::runtime_error {
public:
    RuntimeError(Span span, std::string message)
        : std::runtime_error(std::format("{}: {}", describe(span), message)),
          span_(std::move(span)),
          message_(std::move(message)) {}

    const Span& span() const { return span_; }
    const std::string& message() const { return message_; }

private:
    Span span_;
    std::string message_;
};

// Collects complaints so that one run can report every type error in a file
// rather than stopping at the first.
class ErrorLog {
public:
    void add(Span span, std::string message) {
        errors_.emplace_back(std::move(span), std::move(message));
    }

    template <typename... Args>
    void addf(Span span, std::format_string<Args...> format, Args&&... args) {
        add(std::move(span), std::format(format, std::forward<Args>(args)...));
    }

    bool empty() const { return errors_.empty(); }
    const std::vector<CompileError>& errors() const { return errors_; }

private:
    std::vector<CompileError> errors_;
};

}  // namespace otter
