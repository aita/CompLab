// Bytecode partition — the instruction set (pure data, no dependencies).
module;
#include <cstdint>
#include <string>

export module st:bytecode;

export namespace st {

enum class Op {
    PushLiteral,   // arg = literal index
    PushSelf,
    PushNil,
    PushTrue,
    PushFalse,
    PushContext,   // thisContext
    PushLocal,     // arg = slot
    StoreLocal,    // arg = slot (peeks TOS)
    PushOuter,     // arg = depth, arg2 = slot
    StoreOuter,    // arg = depth, arg2 = slot
    PushVar,       // name = ivar/global name
    StoreVar,      // name = ivar/global name (peeks TOS)
    Pop,
    Dup,
    Send,          // name = selector, arg = argc
    SendSuper,     // name = selector, arg = argc
    PushBlock,     // arg = literal index (a CompiledBlock)
    MakeArray,     // arg = count
    Jump,          // arg = target
    JumpTrue,      // arg = target (pops)
    JumpFalse,     // arg = target (pops)
    Return,        // ^expr; non-local from within a block
    BlockReturn,   // normal end of a block
};

struct Instr {
    Op op;
    int arg = 0;
    int arg2 = 0;
    std::string name;  // selector for Send*, variable name for *Var
};

}  // namespace st
