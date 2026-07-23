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
    int arg2 = 0;      // Send: special-selector id (0 = none); *Outer: slot
    std::string name;  // selector for Send*, variable name for *Var

    // Monomorphic inline cache, filled by the VM at run time. Kept as void*
    // so this partition stays free of the object model; the VM casts them to
    // Class* / Method*. Validity is gated by ic_version vs the VM's method
    // version, so a class/method (re)definition invalidates every site at once.
    void* ic_class = nullptr;
    void* ic_method = nullptr;
    std::uint64_t ic_version = 0;

    // Interned selector (Symbol*) for Send/SendSuper — the method-dictionary
    // key, precomputed by the compiler. void* to keep this partition free of
    // the object model.
    void* sel = nullptr;
};

}  // namespace st
