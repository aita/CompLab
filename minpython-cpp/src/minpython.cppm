// Primary module interface. A client only needs `import minpython;`.
export module minpython;

export import :value;
export import :bytecode;
export import :lexer;
export import :ast;
export import :parser;
export import :compiler;
export import :vm;
export import :regalloc;
export import :disasm;
export import :analysis;
export import :method;
export import :tiered;

export namespace minpython {
constexpr const char* version = "0.1.0";
}
