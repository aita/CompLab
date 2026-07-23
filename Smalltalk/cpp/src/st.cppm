// Primary module interface. A client only needs `import st;`.
export module st;

export import :bytecode;
export import :objects;
export import :heap;
export import :lexer;
export import :ast;
export import :parser;
export import :compiler;
export import :vm;
export import :kernel;
export import :system;

export namespace st {

constexpr const char* version = "0.1.0";

}  // namespace st
