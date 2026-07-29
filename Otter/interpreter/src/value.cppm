export module otter.value;

import std;
import otter.ast;
import otter.diagnostics;
import otter.types;

export namespace otter {

struct Value;
struct GcObject;
struct StringObject;
struct ArrayObject;
struct StructObject;
struct Cell;
struct Closure;
struct Environment;
struct NativeEntry;
class Marker;
class Heap;

// What `void` evaluates to. Every expression produces a value, so the ones
// that produce nothing produce this.
struct Unit {
    bool operator==(const Unit&) const = default;
};

// A struct is a value type, so this handle is cloned rather than shared
// wherever the value is copied.
struct StructValue {
    StructInfo* info = nullptr;
    StructObject* object = nullptr;

    bool operator==(const StructValue&) const = default;
};

// A pointer names a slot inside a heap object. The object is what keeps the
// slot reachable; the slot itself is an interior pointer, which is sound
// because nothing in this heap moves.
struct Pointer {
    GcObject* owner = nullptr;
    Value* slot = nullptr;

    bool operator==(const Pointer&) const = default;
};

struct Value {
    using Storage =
        std::variant<Unit, bool, std::int64_t, std::uint8_t, char32_t, float, double,
                     StringObject*, ArrayObject*, StructValue, Pointer, Closure*,
                     const NativeEntry*>;
    Storage storage;

    Value() : storage(Unit{}) {}

    // Narrow enough that a stray pointer cannot slip in as one of the
    // alternatives by accident.
    template <typename T>
        requires(!std::same_as<std::remove_cvref_t<T>, Value> &&
                 std::constructible_from<Storage, T>)
    Value(T value) : storage(std::move(value)) {}

    template <typename T>
    const T& as() const {
        return std::get<T>(storage);
    }
    template <typename T>
    T& as() {
        return std::get<T>(storage);
    }
    template <typename T>
    bool is() const {
        return std::holds_alternative<T>(storage);
    }
};

// ---------------------------------------------------------------------------
// The heap
// ---------------------------------------------------------------------------

// Everything the collector owns. The mark bit and the link are the only state
// the collector needs; `trace` is how an object names what it keeps alive.
struct GcObject {
    virtual ~GcObject() = default;
    virtual void trace(Marker& marker) = 0;

    GcObject* next = nullptr;
    bool marked = false;
};

// Strings never change once made, so nothing points out of one.
struct StringObject : GcObject {
    explicit StringObject(std::string text) : text(std::move(text)) {}

    void trace(Marker&) override {}

    std::string text;
};

// An array's length is fixed when it is made, so the elements never move and
// an interior pointer into them stays good.
struct ArrayObject : GcObject {
    void trace(Marker& marker) override;

    const Type* element = nullptr;
    std::vector<Value> elements;
};

struct StructObject : GcObject {
    void trace(Marker& marker) override;

    std::vector<Value> fields;
};

// One variable's storage. Variables live in cells rather than in the scope's
// map so that their addresses survive the map growing.
struct Cell : GcObject {
    void trace(Marker& marker) override;

    Value value;
};

// A block of named cells. Lookup walks outwards, which is how a closure body
// reaches the variables of the function that made it.
struct Environment : GcObject {
    void trace(Marker& marker) override;

    Environment* parent = nullptr;
    std::unordered_map<std::string, Cell*> slots;

    Cell* find(const std::string& name) {
        for (Environment* scope = this; scope != nullptr; scope = scope->parent) {
            auto entry = scope->slots.find(name);
            if (entry != scope->slots.end()) {
                return entry->second;
            }
        }
        return nullptr;
    }
};

// A function value: the code, and the scope it was written in. A named
// function at the top level has no scope to carry.
struct Closure : GcObject {
    void trace(Marker& marker) override;

    const FunctionDefinition* definition = nullptr;
    Environment* environment = nullptr;
};

// A function the host provides, standing behind a body-less declaration. These
// are not collected: the table outlives every program.
struct NativeEntry {
    std::string name;
    std::function<Value(Heap&, std::span<Value>, const Span&)> call;
};

// Blackens objects, keeping the work to find in a list rather than on the C++
// stack so that a long list or a deep structure cannot overflow it.
class Marker {
public:
    void visit(GcObject* object) {
        if (object == nullptr || object->marked) {
            return;
        }
        object->marked = true;
        pending_.push_back(object);
    }

    void visit(const Value& value) {
        std::visit(
            [this](const auto& held) {
                using Held = std::decay_t<decltype(held)>;
                if constexpr (std::same_as<Held, StringObject*> ||
                              std::same_as<Held, ArrayObject*> ||
                              std::same_as<Held, Closure*>) {
                    visit(static_cast<GcObject*>(held));
                } else if constexpr (std::same_as<Held, StructValue>) {
                    visit(static_cast<GcObject*>(held.object));
                } else if constexpr (std::same_as<Held, Pointer>) {
                    visit(held.owner);
                }
            },
            value.storage);
    }

    void visit(const std::vector<Value>& values) {
        for (const Value& value : values) {
            visit(value);
        }
    }

    void drain() {
        while (!pending_.empty()) {
            GcObject* object = pending_.back();
            pending_.pop_back();
            object->trace(*this);
        }
    }

private:
    std::vector<GcObject*> pending_;
};

inline void ArrayObject::trace(Marker& marker) { marker.visit(elements); }

inline void StructObject::trace(Marker& marker) { marker.visit(fields); }

inline void Cell::trace(Marker& marker) { marker.visit(value); }

inline void Environment::trace(Marker& marker) {
    marker.visit(parent);
    for (const auto& [name, cell] : slots) {
        marker.visit(cell);
    }
}

inline void Closure::trace(Marker& marker) { marker.visit(environment); }

// A mark-and-sweep heap.
//
// Nothing moves, so a raw pointer stays good for as long as the object it
// names is reachable. What the collector needs in return is that every value
// the evaluator is holding at the moment of a collection is reachable from a
// root, which is what the shadow stack below is for.
class Heap {
public:
    Heap() {
        // Setting this to 1 collects at every allocation, which is how a value
        // held without a root gets caught.
        if (const char* setting = std::getenv("OTTER_GC_THRESHOLD")) {
            std::size_t requested = 0;
            std::string_view text(setting);
            if (std::from_chars(text.data(), text.data() + text.size(), requested).ec ==
                    std::errc{} &&
                requested > 0) {
                threshold_ = requested;
                fixedThreshold_ = requested;
            }
        }
    }

    ~Heap() {
        for (GcObject* object = objects_; object != nullptr;) {
            GcObject* next = object->next;
            delete object;
            object = next;
        }
    }

    template <typename T, typename... Args>
    T* allocate(Args&&... arguments) {
        if (live_ >= threshold_) {
            collect();
        }
        T* object = new T(std::forward<Args>(arguments)...);
        object->next = objects_;
        objects_ = object;
        ++live_;
        return object;
    }

    StringObject* makeString(std::string text) {
        return allocate<StringObject>(std::move(text));
    }

    // Called before a collection to reach whatever the evaluator holds outside
    // the shadow stack: its globals, and the value a `return` is carrying.
    void setRootScanner(std::function<void(Marker&)> scanner) {
        scanner_ = std::move(scanner);
    }

    void pushRoot(Value* value) { valueRoots_.push_back(value); }
    void popRoot() { valueRoots_.pop_back(); }

    void pushRoot(std::vector<Value>* values) { vectorRoots_.push_back(values); }
    void popVectorRoot() { vectorRoots_.pop_back(); }

    void pushRoot(GcObject** object) { objectRoots_.push_back(object); }
    void popObjectRoot() { objectRoots_.pop_back(); }

    void collect() {
        Marker marker;
        for (Value* root : valueRoots_) {
            marker.visit(*root);
        }
        for (std::vector<Value>* root : vectorRoots_) {
            marker.visit(*root);
        }
        for (GcObject** root : objectRoots_) {
            marker.visit(*root);
        }
        if (scanner_) {
            scanner_(marker);
        }
        marker.drain();

        std::size_t survivors = 0;
        GcObject** link = &objects_;
        while (*link != nullptr) {
            GcObject* object = *link;
            if (object->marked) {
                object->marked = false;
                ++survivors;
                link = &object->next;
            } else {
                *link = object->next;
                delete object;
            }
        }

        live_ = survivors;
        threshold_ = fixedThreshold_ != 0 ? fixedThreshold_
                                          : std::max(minimumThreshold, survivors * 2);
        ++collections_;
    }

    std::size_t live() const { return live_; }
    std::size_t collections() const { return collections_; }

    // How many objects may pile up before a collection is worth the walk.
    static constexpr std::size_t minimumThreshold = 4096;

private:
    GcObject* objects_ = nullptr;
    std::size_t live_ = 0;
    std::size_t threshold_ = minimumThreshold;
    std::size_t fixedThreshold_ = 0;
    std::size_t collections_ = 0;

    std::vector<Value*> valueRoots_;
    std::vector<std::vector<Value>*> vectorRoots_;
    std::vector<GcObject**> objectRoots_;
    std::function<void(Marker&)> scanner_;
};

// ---------------------------------------------------------------------------
// Roots
//
// A value held in a C++ local is invisible to the collector, so anything the
// evaluator keeps across a point where more memory can be asked for is held in
// one of these instead. They nest strictly, which is what lets the shadow
// stack be a stack.
// ---------------------------------------------------------------------------

class Root {
public:
    explicit Root(Heap& heap) : heap_(heap) { heap_.pushRoot(&value_); }
    Root(Heap& heap, Value value) : heap_(heap), value_(std::move(value)) {
        heap_.pushRoot(&value_);
    }
    ~Root() { heap_.popRoot(); }

    Root(const Root&) = delete;
    Root& operator=(const Root&) = delete;

    Value& operator*() { return value_; }
    Value* operator->() { return &value_; }
    Value& get() { return value_; }
    const Value& get() const { return value_; }

    Root& operator=(Value value) {
        value_ = std::move(value);
        return *this;
    }

private:
    Heap& heap_;
    Value value_;
};

class RootVector {
public:
    explicit RootVector(Heap& heap) : heap_(heap) { heap_.pushRoot(&values_); }
    ~RootVector() { heap_.popVectorRoot(); }

    RootVector(const RootVector&) = delete;
    RootVector& operator=(const RootVector&) = delete;

    std::vector<Value>& get() { return values_; }
    std::vector<Value>* operator->() { return &values_; }

private:
    Heap& heap_;
    std::vector<Value> values_;
};

// Holds a heap object directly, for the scopes and half-built objects that are
// not yet named by any value.
template <typename T>
class RootObject {
public:
    RootObject(Heap& heap, T* object) : heap_(heap), object_(object) {
        heap_.pushRoot(&object_);
    }
    ~RootObject() { heap_.popObjectRoot(); }

    RootObject(const RootObject&) = delete;
    RootObject& operator=(const RootObject&) = delete;

    T* get() const { return static_cast<T*>(object_); }
    T* operator->() const { return static_cast<T*>(object_); }

private:
    Heap& heap_;
    GcObject* object_;
};

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

// Copies a value the way assignment does: structs field by field, everything
// else by naming the same object again.
Value copyOf(Heap& heap, const Value& value) {
    const auto* structure = std::get_if<StructValue>(&value.storage);
    if (structure == nullptr) {
        return value;
    }

    Root source(heap, value);
    auto* object = heap.allocate<StructObject>();
    RootObject<StructObject> held(heap, object);

    const std::vector<Value>& fields = source.get().as<StructValue>().object->fields;
    held->fields.reserve(fields.size());
    for (std::size_t index = 0; index < fields.size(); ++index) {
        held->fields.push_back(copyOf(heap, fields[index]));
    }
    return Value(StructValue{source.get().as<StructValue>().info, held.get()});
}

// What a value of this type starts out as. Only array elements need it, since
// the language has no uninitialised variables.
Value zeroOf(const Type* type) {
    switch (type->kind) {
        case TypeKind::Bool:
            return Value(false);
        case TypeKind::Int:
            return Value(std::int64_t{0});
        case TypeKind::Byte:
            return Value(std::uint8_t{0});
        case TypeKind::Char:
            return Value(char32_t{0});
        case TypeKind::Float32:
            return Value(0.0f);
        case TypeKind::Float64:
            return Value(0.0);
        case TypeKind::Pointer:
            return Value(Pointer{});
        default:
            return Value();
    }
}

// Compares two values of the same type. Strings compare by content and structs
// field by field; arrays, closures and pointers compare by identity.
bool equalValues(const Value& left, const Value& right) {
    if (left.storage.index() != right.storage.index()) {
        return false;
    }
    if (const auto* text = std::get_if<StringObject*>(&left.storage)) {
        return (*text)->text == std::get<StringObject*>(right.storage)->text;
    }
    if (const auto* structure = std::get_if<StructValue>(&left.storage)) {
        const StructValue& other = std::get<StructValue>(right.storage);
        const auto& ours = structure->object->fields;
        const auto& theirs = other.object->fields;
        if (ours.size() != theirs.size()) {
            return false;
        }
        for (std::size_t index = 0; index < ours.size(); ++index) {
            if (!equalValues(ours[index], theirs[index])) {
                return false;
            }
        }
        return true;
    }
    return left.storage == right.storage;
}

}  // namespace otter
