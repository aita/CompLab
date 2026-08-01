export module otter.types;

import std;

export namespace otter {

enum class TypeKind {
    Void,
    Bool,
    Int,
    Byte,
    Char,
    Float32,
    Float64,
    String,
    Array,
    Pointer,
    Struct,
    Function,
    // The type of the `null` literal on its own. It converts to any pointer,
    // and never appears in a declaration.
    NullPointer,
};

struct Type;

struct Field {
    std::string name;
    const Type* type = nullptr;
};

// Structs are nominal: two declarations with identical fields are still
// different types, so the identity of this record is the identity of the type.
struct StructInfo {
    std::string moduleName;
    std::string name;
    std::vector<Field> fields;
    bool complete = false;

    std::string qualifiedName() const { return std::format("{}.{}", moduleName, name); }

    const Field* find(const std::string& fieldName) const {
        for (const Field& field : fields) {
            if (field.name == fieldName) {
                return &field;
            }
        }
        return nullptr;
    }

    int indexOf(const std::string& fieldName) const {
        for (std::size_t index = 0; index < fields.size(); ++index) {
            if (fields[index].name == fieldName) {
                return static_cast<int>(index);
            }
        }
        return -1;
    }
};

struct Type {
    TypeKind kind = TypeKind::Void;

    // Array and Pointer.
    const Type* element = nullptr;

    // Struct.
    StructInfo* structure = nullptr;

    // Function.
    std::vector<const Type*> parameters;
    const Type* result = nullptr;
};

bool isInteger(const Type* type) {
    switch (type->kind) {
        case TypeKind::Int:
        case TypeKind::Byte:
        case TypeKind::Char:
            return true;
        default:
            return false;
    }
}

bool isFloating(const Type* type) {
    return type->kind == TypeKind::Float32 || type->kind == TypeKind::Float64;
}

bool isNumeric(const Type* type) { return isInteger(type) || isFloating(type); }

// The range a whole-number literal must fall in to be written as this type.
struct IntegerRange {
    std::int64_t low;
    std::int64_t high;
};

IntegerRange rangeOf(const Type* type) {
    switch (type->kind) {
        case TypeKind::Byte:
            return {0, 255};
        case TypeKind::Char:
            return {0, 0x10FFFF};
        default:
            return {std::numeric_limits<std::int64_t>::min(),
                    std::numeric_limits<std::int64_t>::max()};
    }
}

std::string describe(const Type* type) {
    switch (type->kind) {
        case TypeKind::Void:
            return "void";
        case TypeKind::Bool:
            return "bool";
        case TypeKind::Int:
            return "int";
        case TypeKind::Byte:
            return "byte";
        case TypeKind::Char:
            return "char";
        case TypeKind::Float32:
            return "float32";
        case TypeKind::Float64:
            return "float64";
        case TypeKind::String:
            return "string";
        case TypeKind::NullPointer:
            return "null";
        case TypeKind::Array:
            return std::format("array<{}>", describe(type->element));
        case TypeKind::Pointer:
            return std::format("*{}", describe(type->element));
        case TypeKind::Struct:
            return type->structure->qualifiedName();
        case TypeKind::Function: {
            std::string text = "fun(";
            for (std::size_t index = 0; index < type->parameters.size(); ++index) {
                if (index > 0) {
                    text += ", ";
                }
                text += describe(type->parameters[index]);
            }
            return text + ") -> " + describe(type->result);
        }
    }
    return "?";
}

// Owns every type object and hands out one pointer per distinct type, so that
// type equality is pointer equality everywhere else.
class TypeArena {
public:
    TypeArena() {
        voidType_ = intern(TypeKind::Void);
        boolType_ = intern(TypeKind::Bool);
        intType_ = intern(TypeKind::Int);
        byteType_ = intern(TypeKind::Byte);
        charType_ = intern(TypeKind::Char);
        float32Type_ = intern(TypeKind::Float32);
        float64Type_ = intern(TypeKind::Float64);
        stringType_ = intern(TypeKind::String);
        nullType_ = intern(TypeKind::NullPointer);
    }

    const Type* voidType() const { return voidType_; }
    const Type* boolType() const { return boolType_; }
    const Type* intType() const { return intType_; }
    const Type* byteType() const { return byteType_; }
    const Type* charType() const { return charType_; }
    const Type* float32Type() const { return float32Type_; }
    const Type* float64Type() const { return float64Type_; }
    const Type* stringType() const { return stringType_; }
    const Type* nullType() const { return nullType_; }

    // The type a kind that takes no argument stands for.
    const Type* primitiveType(TypeKind kind) const {
        switch (kind) {
            case TypeKind::Bool: return boolType_;
            case TypeKind::Int: return intType_;
            case TypeKind::Byte: return byteType_;
            case TypeKind::Char: return charType_;
            case TypeKind::Float32: return float32Type_;
            case TypeKind::Float64: return float64Type_;
            case TypeKind::String: return stringType_;
            default: return voidType_;
        }
    }

    const Type* arrayOf(const Type* element) {
        auto [entry, inserted] = arrays_.try_emplace(element, nullptr);
        if (inserted) {
            Type* type = allocate();
            type->kind = TypeKind::Array;
            type->element = element;
            entry->second = type;
        }
        return entry->second;
    }

    const Type* pointerTo(const Type* element) {
        auto [entry, inserted] = pointers_.try_emplace(element, nullptr);
        if (inserted) {
            Type* type = allocate();
            type->kind = TypeKind::Pointer;
            type->element = element;
            entry->second = type;
        }
        return entry->second;
    }

    const Type* functionOf(std::vector<const Type*> parameters, const Type* result) {
        FunctionKey key{std::move(parameters), result};
        auto [entry, inserted] = functions_.try_emplace(std::move(key), nullptr);
        if (inserted) {
            Type* type = allocate();
            type->kind = TypeKind::Function;
            type->parameters = entry->first.parameters;
            type->result = result;
            entry->second = type;
        }
        return entry->second;
    }

    // Structs are created rather than interned: each declaration gets its own
    // type, and its fields are filled in later so that they may refer back to it.
    std::pair<const Type*, StructInfo*> declareStruct(std::string moduleName, std::string name) {
        auto info = std::make_unique<StructInfo>();
        info->moduleName = std::move(moduleName);
        info->name = std::move(name);
        StructInfo* raw = info.get();
        structures_.push_back(std::move(info));

        Type* type = allocate();
        type->kind = TypeKind::Struct;
        type->structure = raw;
        return {type, raw};
    }

private:
    struct FunctionKey {
        std::vector<const Type*> parameters;
        const Type* result;

        auto operator<=>(const FunctionKey&) const = default;
    };

    Type* allocate() { return &storage_.emplace_back(); }

    const Type* intern(TypeKind kind) {
        Type* type = allocate();
        type->kind = kind;
        return type;
    }

    // A deque so that pointers handed out stay valid as more types arrive.
    std::deque<Type> storage_;
    std::vector<std::unique_ptr<StructInfo>> structures_;
    std::map<const Type*, const Type*> arrays_;
    std::map<const Type*, const Type*> pointers_;
    std::map<FunctionKey, const Type*> functions_;

    const Type* voidType_ = nullptr;
    const Type* boolType_ = nullptr;
    const Type* intType_ = nullptr;
    const Type* byteType_ = nullptr;
    const Type* charType_ = nullptr;
    const Type* float32Type_ = nullptr;
    const Type* float64Type_ = nullptr;
    const Type* stringType_ = nullptr;
    const Type* nullType_ = nullptr;
};

// Whether a value of `from` may be used where `to` is wanted. There are no
// implicit numeric conversions, so this is equality apart from `null`, which
// stands for any pointer.
bool assignable(const Type* from, const Type* to) {
    if (from == to) {
        return true;
    }
    return from->kind == TypeKind::NullPointer && to->kind == TypeKind::Pointer;
}

}  // namespace otter
