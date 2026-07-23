"""Bootstrap the base class hierarchy and its primitive methods.

Only behaviour that cannot be written in the Smalltalk subset (arithmetic,
identity, reflection, I/O, collection storage) lives here as Python
primitives. ``build_kernel`` wires the classes together and returns nothing;
call it on a fresh :class:`~st.vm.VM`.
"""

from __future__ import annotations

import math
from typing import Any, Callable

from st.objects import (
    PrimitiveMethod,
    STBlock,
    STChar,
    STClass,
    STError,
    STObject,
    STSymbol,
    nil,
)
from st.vm import VM


# --- printing -------------------------------------------------------------


def py_print(vm: VM, value: Any) -> str:
    """The ``printString`` of a built-in value (developer-facing form)."""
    match value:
        case _ if value is nil:
            return "nil"
        case True:
            return "true"
        case False:
            return "false"
        case STSymbol():
            return "#" + str.__str__(value)
        case str():
            return "'" + value.replace("'", "''") + "'"
        case STChar():
            return "$" + value.value
        case bool():  # unreachable (True/False handled above), kept explicit
            return "true" if value else "false"
        case int():
            return str(value)
        case float():
            return repr(value)
        case list():
            return "(" + " ".join(py_print(vm, e) for e in value) + " )"
        case STBlock():
            return "a BlockClosure"
        case STClass():
            return value.name
        case STObject():
            return _print_object(vm, value)
        case _:
            return str(value)


def _print_object(vm: VM, value: STObject) -> str:
    ivars = value.ivars
    match value.st_class.name:
        case "Association":
            return (
                py_print(vm, ivars.get("key", nil))
                + "->"
                + py_print(vm, ivars.get("value", nil))
            )
        case "Point":
            return (
                py_print(vm, ivars.get("x", nil))
                + "@"
                + py_print(vm, ivars.get("y", nil))
            )
        case "OrderedCollection":
            items = ivars.get("items", [])
            return (
                "OrderedCollection ("
                + " ".join(py_print(vm, e) for e in items)
                + " )"
            )
        case "Dictionary":
            m = ivars.get("map", {})
            body = " ".join(
                py_print(vm, key) + "->" + py_print(vm, val)
                for key, val in m.values()
            )
            return "a Dictionary (" + body + " )"
        case name:
            article = "an" if name[:1] in "AEIOU" else "a"
            return f"{article} {name}"


def py_display(vm: VM, value: Any) -> str:
    """The ``displayString`` — like printString but strings/symbols/chars are
    shown without their literal decoration."""
    match value:
        case STSymbol():
            return str.__str__(value)
        case str():
            return value
        case STChar():
            return value.value
        case _:
            return py_print(vm, value)


# --- helpers for collection primitives ------------------------------------


def _items(coll: Any) -> list[Any]:
    """The backing Python list of an Array or OrderedCollection."""
    if isinstance(coll, list):
        return coll
    if isinstance(coll, STObject) and "items" in coll.ivars:
        return coll.ivars["items"]
    raise STError(f"not an indexable collection: {py_print_safe(coll)}")


def py_print_safe(value: Any) -> str:
    try:
        return repr(value)
    except Exception:  # pragma: no cover
        return "<?>"


def _wrap_like(vm: VM, receiver: Any, pylist: list[Any]) -> Any:
    """Wrap a computed list in the same collection kind as ``receiver``."""
    if isinstance(receiver, list):
        return pylist
    oc = _new_instance(vm, vm.classes["OrderedCollection"])
    oc.ivars["items"] = pylist
    return oc


def _st_index(i: Any) -> int:
    if not isinstance(i, int) or isinstance(i, bool):
        raise STError(f"index must be an Integer, got {i!r}")
    return i


def _new_instance(vm: VM, cls: STClass) -> STObject:
    obj = STObject(cls, {name: nil for name in cls.all_instance_variables()})
    return obj


# --- registration helpers -------------------------------------------------


class _Builder:
    def __init__(self, vm: VM):
        self.vm = vm

    def cls(
        self, name: str, superclass: STClass | None, ivars: list[str] | None = None
    ) -> STClass:
        c = STClass(
            name=name,
            superclass=superclass,
            instance_variables=list(ivars or []),
        )
        self.vm.register_class(c)
        return c

    def prim(self, cls: STClass, selector: str, fn: Callable[..., Any]) -> None:
        cls.methods[selector] = PrimitiveMethod(f"{cls.name}>>{selector}", fn)

    def cprim(self, cls: STClass, selector: str, fn: Callable[..., Any]) -> None:
        cls.class_methods[selector] = PrimitiveMethod(
            f"{cls.name} class>>{selector}", fn
        )


def build_kernel(vm: VM) -> None:
    b = _Builder(vm)

    # --- class hierarchy ---
    Object = b.cls("Object", None)
    b.cls("UndefinedObject", Object)
    Boolean = b.cls("Boolean", Object)
    TrueC = b.cls("True", Boolean)
    FalseC = b.cls("False", Boolean)
    b.cls("Class", Object)
    Magnitude = b.cls("Magnitude", Object)
    Number = b.cls("Number", Magnitude)
    Integer = b.cls("Integer", Number)
    b.cls("SmallInteger", Integer)
    b.cls("Float", Number)
    b.cls("Character", Magnitude)
    Collection = b.cls("Collection", Object)
    SequenceableCollection = b.cls("SequenceableCollection", Collection)
    b.cls("Array", SequenceableCollection)
    b.cls("String", SequenceableCollection)
    b.cls("Symbol", vm.classes["String"])
    b.cls("OrderedCollection", SequenceableCollection, ivars=["items"])
    b.cls("Dictionary", Collection, ivars=["map"])
    b.cls("Association", Magnitude, ivars=["key", "value"])
    b.cls("Point", Object, ivars=["x", "y"])
    b.cls("BlockClosure", Object)
    b.cls("Transcript", Object)
    b.cls("Error", Object, ivars=["messageText"])
    Context = b.cls("Context", Object)
    b.cls("MethodContext", Context)
    b.cls("BlockContext", Context)

    _install_object(b, Object)
    _install_undefined(b)
    _install_boolean(b, Boolean, TrueC, FalseC)
    _install_number(b, Number, Integer)
    _install_character(b)
    _install_string(b)
    _install_collections(b)
    _install_blocks(b)
    _install_point(b)
    _install_transcript(b)
    _install_error(b)
    _install_context(b)

    # Transcript is a unique global instance.
    vm.globals["Transcript"] = _new_instance(vm, vm.classes["Transcript"])
    vm.globals["Smalltalk"] = vm.globals  # crude system dictionary handle


# --- Object ---------------------------------------------------------------


def _st_equal(vm: VM, a: Any, b: Any) -> bool:
    """Structural equality for the value types; identity otherwise."""
    if a is b:
        return True
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, STChar) and isinstance(b, STChar):
        return a.value == b.value
    if isinstance(a, STSymbol) or isinstance(b, STSymbol):
        return a is b  # symbols are interned
    if isinstance(a, str) and isinstance(b, str):
        return str.__eq__(a, b) is True
    return False


def _install_object(b: _Builder, Object: STClass) -> None:
    b.prim(Object, "==", lambda vm, r, a: r is a[0])
    b.prim(Object, "~~", lambda vm, r, a: r is not a[0])
    b.prim(Object, "=", lambda vm, r, a: _st_equal(vm, r, a[0]))
    b.prim(Object, "~=", lambda vm, r, a: not _st_equal(vm, r, a[0]))
    b.prim(Object, "isNil", lambda vm, r, a: r is nil)
    b.prim(Object, "notNil", lambda vm, r, a: r is not nil)
    b.prim(Object, "yourself", lambda vm, r, a: r)
    b.prim(Object, "class", lambda vm, r, a: vm.class_of(r))
    b.prim(Object, "hash", lambda vm, r, a: _safe_hash(r))
    b.prim(Object, "identityHash", lambda vm, r, a: id(r) & 0x3FFFFFFF)
    b.prim(Object, "->", lambda vm, r, a: _make_assoc(vm, r, a[0]))
    b.prim(Object, "printString", lambda vm, r, a: py_print(vm, r))
    b.prim(Object, "displayString", lambda vm, r, a: py_display(vm, r))
    b.prim(Object, "printNl", lambda vm, r, a: _print_nl(vm, r))
    b.prim(Object, "displayNl", lambda vm, r, a: _display_nl(vm, r))
    b.prim(Object, "initialize", lambda vm, r, a: r)
    b.prim(Object, "isKindOf:", lambda vm, r, a: _is_kind_of(vm, r, a[0]))
    b.prim(Object, "isMemberOf:", lambda vm, r, a: vm.class_of(r) is a[0])
    b.prim(Object, "respondsTo:", lambda vm, r, a: _responds_to(vm, r, a[0]))
    b.prim(Object, "error:", lambda vm, r, a: _raise_error(a[0]))
    b.prim(Object, "ifNil:", lambda vm, r, a: r)
    b.prim(
        Object,
        "ifNotNil:",
        lambda vm, r, a: vm.run_block(a[0], _maybe_arg(a[0], r)),
    )
    b.prim(Object, "ifNil:ifNotNil:", lambda vm, r, a: vm.run_block(a[1], _maybe_arg(a[1], r)))
    b.prim(Object, "perform:", lambda vm, r, a: vm.send(r, str(a[0]), []))
    b.prim(
        Object,
        "perform:with:",
        lambda vm, r, a: vm.send(r, str(a[0]), [a[1]]),
    )
    b.prim(
        Object,
        "perform:withArguments:",
        lambda vm, r, a: vm.send(r, str(a[0]), list(_items(a[1]))),
    )

    # class-side (inherited by every class)
    b.cprim(Object, "new", lambda vm, r, a: _new_and_init(vm, r))
    b.cprim(Object, "basicNew", lambda vm, r, a: _new_instance(vm, r))
    b.cprim(Object, "name", lambda vm, r, a: r.name)
    b.cprim(Object, "superclass", lambda vm, r, a: r.superclass or nil)
    b.cprim(Object, "printString", lambda vm, r, a: r.name)


def _maybe_arg(block: STBlock, value: Any) -> list[Any]:
    return [value] if block.num_args == 1 else []


def _new_and_init(vm: VM, cls: STClass) -> STObject:
    obj = _new_instance(vm, cls)
    vm.send(obj, "initialize", [])
    return obj


def _make_assoc(vm: VM, key: Any, value: Any) -> STObject:
    a = _new_instance(vm, vm.classes["Association"])
    a.ivars["key"] = key
    a.ivars["value"] = value
    return a


def _safe_hash(value: Any) -> int:
    try:
        return hash(value) & 0x3FFFFFFF
    except TypeError:
        return id(value) & 0x3FFFFFFF


def _is_kind_of(vm: VM, r: Any, cls: Any) -> bool:
    if not isinstance(cls, STClass):
        return False
    return vm.class_of(r).is_kind_of(cls)


def _responds_to(vm: VM, r: Any, sel: Any) -> bool:
    selector = str(sel)
    if isinstance(r, STClass):
        return r.lookup_class_method(selector) is not None
    return vm.class_of(r).lookup(selector) is not None


def _raise_error(msg: Any) -> Any:
    raise STError(str(msg))


def _print_nl(vm: VM, r: Any) -> Any:
    vm.output(str(vm.send(r, "printString", [])) + "\n")
    return r


def _display_nl(vm: VM, r: Any) -> Any:
    vm.output(str(vm.send(r, "displayString", [])) + "\n")
    return r


# --- UndefinedObject ------------------------------------------------------


def _install_undefined(b: _Builder) -> None:
    U = b.vm.classes["UndefinedObject"]
    b.prim(U, "isNil", lambda vm, r, a: True)
    b.prim(U, "notNil", lambda vm, r, a: False)
    b.prim(U, "ifNil:", lambda vm, r, a: vm.run_block(a[0], []))
    b.prim(U, "ifNotNil:", lambda vm, r, a: nil)
    b.prim(U, "ifNil:ifNotNil:", lambda vm, r, a: vm.run_block(a[0], []))
    b.prim(U, "printString", lambda vm, r, a: "nil")


# --- Boolean --------------------------------------------------------------


def _install_boolean(b: _Builder, Boolean, TrueC, FalseC) -> None:
    b.prim(Boolean, "not", lambda vm, r, a: not r)
    b.prim(Boolean, "&", lambda vm, r, a: bool(r) and bool(a[0]))
    b.prim(Boolean, "|", lambda vm, r, a: bool(r) or bool(a[0]))
    b.prim(Boolean, "and:", lambda vm, r, a: vm.run_block(a[0], []) if r else False)
    b.prim(Boolean, "or:", lambda vm, r, a: True if r else vm.run_block(a[0], []))
    b.prim(Boolean, "xor:", lambda vm, r, a: bool(r) != bool(a[0]))
    b.prim(Boolean, "eqv:", lambda vm, r, a: bool(r) == bool(a[0]))
    b.prim(
        Boolean,
        "ifTrue:ifFalse:",
        lambda vm, r, a: vm.run_block(a[0] if r else a[1], []),
    )
    b.prim(
        Boolean,
        "ifFalse:ifTrue:",
        lambda vm, r, a: vm.run_block(a[1] if r else a[0], []),
    )
    b.prim(Boolean, "ifTrue:", lambda vm, r, a: vm.run_block(a[0], []) if r else nil)
    b.prim(Boolean, "ifFalse:", lambda vm, r, a: nil if r else vm.run_block(a[0], []))
    b.prim(TrueC, "printString", lambda vm, r, a: "true")
    b.prim(FalseC, "printString", lambda vm, r, a: "false")


# --- Number / Integer -----------------------------------------------------


def _num(x: Any) -> Any:
    if isinstance(x, bool) or not isinstance(x, (int, float)):
        raise STError(f"expected a Number, got {py_print_safe(x)}")
    return x


def _install_number(b: _Builder, Number, Integer) -> None:
    def arith(op):
        return lambda vm, r, a: op(_num(r), _num(a[0]))

    b.prim(Number, "+", arith(lambda x, y: x + y))
    b.prim(Number, "-", arith(lambda x, y: x - y))
    b.prim(Number, "*", arith(lambda x, y: x * y))
    b.prim(Number, "/", lambda vm, r, a: _divide(_num(r), _num(a[0])))
    b.prim(Number, "//", lambda vm, r, a: _num(r) // _num(a[0]))
    b.prim(Number, "\\\\", lambda vm, r, a: _num(r) % _num(a[0]))
    b.prim(Number, "rem:", lambda vm, r, a: int(math.fmod(_num(r), _num(a[0]))))
    b.prim(Number, "<", arith(lambda x, y: x < y))
    b.prim(Number, ">", arith(lambda x, y: x > y))
    b.prim(Number, "<=", arith(lambda x, y: x <= y))
    b.prim(Number, ">=", arith(lambda x, y: x >= y))
    b.prim(Number, "=", lambda vm, r, a: _num_eq(r, a[0]))
    b.prim(Number, "~=", lambda vm, r, a: not _num_eq(r, a[0]))
    b.prim(Number, "abs", lambda vm, r, a: abs(_num(r)))
    b.prim(Number, "negated", lambda vm, r, a: -_num(r))
    b.prim(Number, "max:", arith(lambda x, y: max(x, y)))
    b.prim(Number, "min:", arith(lambda x, y: min(x, y)))
    b.prim(Number, "squared", lambda vm, r, a: _num(r) * _num(r))
    b.prim(Number, "sqrt", lambda vm, r, a: math.sqrt(_num(r)))
    b.prim(Number, "asFloat", lambda vm, r, a: float(_num(r)))
    b.prim(Number, "asInteger", lambda vm, r, a: int(_num(r)))
    b.prim(Number, "truncated", lambda vm, r, a: math.trunc(_num(r)))
    b.prim(Number, "rounded", lambda vm, r, a: round(_num(r)))
    b.prim(Number, "floor", lambda vm, r, a: math.floor(_num(r)))
    b.prim(Number, "ceiling", lambda vm, r, a: math.ceil(_num(r)))
    b.prim(Number, "sin", lambda vm, r, a: math.sin(_num(r)))
    b.prim(Number, "cos", lambda vm, r, a: math.cos(_num(r)))
    b.prim(Number, "isZero", lambda vm, r, a: _num(r) == 0)
    b.prim(Number, "between:and:", lambda vm, r, a: _num(a[0]) <= _num(r) <= _num(a[1]))
    b.prim(Number, "to:", lambda vm, r, a: _interval(_num(r), _num(a[0]), 1))
    b.prim(Number, "to:by:", lambda vm, r, a: _interval(_num(r), _num(a[0]), _num(a[1])))
    b.prim(Number, "to:do:", lambda vm, r, a: _to_do(vm, r, a[0], 1, a[1]))
    b.prim(Number, "to:by:do:", lambda vm, r, a: _to_do(vm, r, a[0], a[1], a[2]))

    b.prim(Integer, "even", lambda vm, r, a: _num(r) % 2 == 0)
    b.prim(Integer, "odd", lambda vm, r, a: _num(r) % 2 == 1)
    b.prim(Integer, "factorial", lambda vm, r, a: math.factorial(_num(r)))
    b.prim(Integer, "gcd:", lambda vm, r, a: math.gcd(_num(r), _num(a[0])))
    b.prim(Integer, "isPrime", lambda vm, r, a: _is_prime(_num(r)))
    b.prim(Integer, "asCharacter", lambda vm, r, a: STChar(chr(_num(r))))
    b.prim(Integer, "timesRepeat:", lambda vm, r, a: _times_repeat(vm, r, a[0]))
    b.prim(Integer, "bitAnd:", lambda vm, r, a: _num(r) & _num(a[0]))
    b.prim(Integer, "bitOr:", lambda vm, r, a: _num(r) | _num(a[0]))
    b.prim(Integer, "bitXor:", lambda vm, r, a: _num(r) ^ _num(a[0]))
    b.prim(Integer, "bitShift:", lambda vm, r, a: _bitshift(_num(r), _num(a[0])))


def _divide(x, y):
    if y == 0:
        raise STError("ZeroDivide")
    if isinstance(x, int) and isinstance(y, int) and x % y == 0:
        return x // y
    return x / y


def _num_eq(x, y):
    return (
        isinstance(x, (int, float))
        and isinstance(y, (int, float))
        and not isinstance(x, bool)
        and not isinstance(y, bool)
        and x == y
    )


def _bitshift(x, n):
    return x << n if n >= 0 else x >> -n


def _is_prime(n: int) -> bool:
    if n < 2:
        return False
    i = 2
    while i * i <= n:
        if n % i == 0:
            return False
        i += 1
    return True


def _interval(start, stop, step) -> list[Any]:
    out: list[Any] = []
    i = start
    if step > 0:
        while i <= stop:
            out.append(i)
            i += step
    elif step < 0:
        while i >= stop:
            out.append(i)
            i += step
    else:
        raise STError("step must not be zero")
    return out


def _to_do(vm: VM, start, stop, step, block: STBlock) -> Any:
    i = start
    if step > 0:
        while i <= stop:
            vm.run_block(block, [i])
            i += step
    else:
        while i >= stop:
            vm.run_block(block, [i])
            i += step
    return start


def _times_repeat(vm: VM, n: int, block: STBlock) -> Any:
    for _ in range(int(n)):
        vm.run_block(block, [])
    return n


# --- Character ------------------------------------------------------------


def _install_character(b: _Builder) -> None:
    C = b.vm.classes["Character"]
    b.prim(C, "asInteger", lambda vm, r, a: ord(r.value))
    b.prim(C, "value", lambda vm, r, a: ord(r.value))
    b.prim(C, "asCharacter", lambda vm, r, a: r)
    b.prim(C, "asString", lambda vm, r, a: r.value)
    b.prim(C, "asUppercase", lambda vm, r, a: STChar(r.value.upper()))
    b.prim(C, "asLowercase", lambda vm, r, a: STChar(r.value.lower()))
    b.prim(C, "isVowel", lambda vm, r, a: r.value.lower() in "aeiou")
    b.prim(C, "isLetter", lambda vm, r, a: r.value.isalpha())
    b.prim(C, "isDigit", lambda vm, r, a: r.value.isdigit())
    b.prim(C, "<", lambda vm, r, a: r.value < a[0].value)
    b.prim(C, ">", lambda vm, r, a: r.value > a[0].value)
    b.prim(C, "=", lambda vm, r, a: isinstance(a[0], STChar) and r.value == a[0].value)
    b.cprim(C, "value:", lambda vm, r, a: STChar(chr(int(a[0]))))


# --- String / Symbol ------------------------------------------------------


def _install_string(b: _Builder) -> None:
    S = b.vm.classes["String"]
    Sym = b.vm.classes["Symbol"]

    b.prim(S, ",", lambda vm, r, a: str(r) + _as_str(a[0]))
    b.prim(S, "size", lambda vm, r, a: len(r))
    b.prim(S, "isEmpty", lambda vm, r, a: len(r) == 0)
    b.prim(S, "notEmpty", lambda vm, r, a: len(r) != 0)
    b.prim(S, "at:", lambda vm, r, a: _str_at(r, a[0]))
    b.prim(S, "=", lambda vm, r, a: isinstance(a[0], str) and str.__eq__(str(r), str(a[0])))
    b.prim(S, "<", lambda vm, r, a: str(r) < str(a[0]))
    b.prim(S, ">", lambda vm, r, a: str(r) > str(a[0]))
    b.prim(S, "asString", lambda vm, r, a: str(r))
    b.prim(S, "asSymbol", lambda vm, r, a: STSymbol(str(r)))
    b.prim(S, "asUppercase", lambda vm, r, a: str(r).upper())
    b.prim(S, "asLowercase", lambda vm, r, a: str(r).lower())
    b.prim(S, "reversed", lambda vm, r, a: str(r)[::-1])
    b.prim(S, "reverse", lambda vm, r, a: str(r)[::-1])
    b.prim(S, "trimmed", lambda vm, r, a: str(r).strip())
    b.prim(S, "asInteger", lambda vm, r, a: _str_to_int(r))
    b.prim(S, "includesSubstring:", lambda vm, r, a: _as_str(a[0]) in str(r))
    b.prim(S, "startsWith:", lambda vm, r, a: str(r).startswith(_as_str(a[0])))
    b.prim(S, "endsWith:", lambda vm, r, a: str(r).endswith(_as_str(a[0])))
    b.prim(S, "indexOf:", lambda vm, r, a: str(r).find(a[0].value) + 1 if isinstance(a[0], STChar) else 0)
    b.prim(S, "do:", lambda vm, r, a: _string_do(vm, r, a[0]))
    b.prim(S, "collect:", lambda vm, r, a: _string_collect(vm, r, a[0]))
    b.prim(S, "select:", lambda vm, r, a: _string_select(vm, r, a[0]))
    b.prim(S, "asArray", lambda vm, r, a: [STChar(c) for c in str(r)])
    b.prim(S, "copyReplaceAll:with:", lambda vm, r, a: str(r).replace(_as_str(a[0]), _as_str(a[1])))
    b.prim(S, "printString", lambda vm, r, a: py_print(vm, r))
    b.prim(S, "displayString", lambda vm, r, a: str(r))
    b.prim(S, "hash", lambda vm, r, a: hash(str(r)) & 0x3FFFFFFF)

    b.prim(Sym, "asString", lambda vm, r, a: str.__str__(r))
    b.prim(Sym, "asSymbol", lambda vm, r, a: r)
    b.prim(Sym, "printString", lambda vm, r, a: "#" + str.__str__(r))
    b.prim(Sym, "=", lambda vm, r, a: r is a[0])

    b.cprim(S, "new", lambda vm, r, a: "")
    b.cprim(S, "with:", lambda vm, r, a: _as_str(a[0]))


def _as_str(x: Any) -> str:
    if isinstance(x, STChar):
        return x.value
    if isinstance(x, str):
        return str(x)
    raise STError(f"expected a String, got {py_print_safe(x)}")


def _str_at(s: str, i: Any) -> STChar:
    idx = _st_index(i)
    if not (1 <= idx <= len(s)):
        raise STError("index out of bounds")
    return STChar(s[idx - 1])


def _str_to_int(s: str) -> Any:
    try:
        return int(str(s).strip())
    except ValueError:
        return nil


def _string_do(vm: VM, s: str, block: STBlock) -> Any:
    for c in str(s):
        vm.run_block(block, [STChar(c)])
    return s


def _string_collect(vm: VM, s: str, block: STBlock) -> str:
    out = []
    for c in str(s):
        out.append(_as_str(vm.run_block(block, [STChar(c)])))
    return "".join(out)


def _string_select(vm: VM, s: str, block: STBlock) -> str:
    out = []
    for c in str(s):
        if vm.run_block(block, [STChar(c)]) is True:
            out.append(c)
    return "".join(out)


# --- Collections (Array, OrderedCollection, Dictionary) -------------------


def _install_collections(b: _Builder) -> None:
    vm = b.vm
    Array = vm.classes["Array"]
    OC = vm.classes["OrderedCollection"]
    Dict = vm.classes["Dictionary"]

    # generic (Array + OrderedCollection share _items)
    for C in (Array, OC):
        b.prim(C, "size", lambda vm, r, a: len(_items(r)))
        b.prim(C, "isEmpty", lambda vm, r, a: len(_items(r)) == 0)
        b.prim(C, "notEmpty", lambda vm, r, a: len(_items(r)) != 0)
        b.prim(C, "at:", lambda vm, r, a: _seq_at(r, a[0]))
        b.prim(C, "at:put:", lambda vm, r, a: _seq_at_put(r, a[0], a[1]))
        b.prim(C, "first", lambda vm, r, a: _seq_first(r))
        b.prim(C, "last", lambda vm, r, a: _seq_last(r))
        b.prim(C, "do:", lambda vm, r, a: _seq_do(vm, r, a[0]))
        b.prim(C, "doWithIndex:", lambda vm, r, a: _seq_do_index(vm, r, a[0]))
        b.prim(C, "do:separatedBy:", lambda vm, r, a: _seq_do_sep(vm, r, a[0], a[1]))
        b.prim(C, "collect:", lambda vm, r, a: _wrap_like(vm, r, _seq_collect(vm, r, a[0])))
        b.prim(C, "select:", lambda vm, r, a: _wrap_like(vm, r, _seq_select(vm, r, a[0])))
        b.prim(C, "reject:", lambda vm, r, a: _wrap_like(vm, r, _seq_reject(vm, r, a[0])))
        b.prim(C, "detect:", lambda vm, r, a: _seq_detect(vm, r, a[0], None))
        b.prim(C, "detect:ifNone:", lambda vm, r, a: _seq_detect(vm, r, a[0], a[1]))
        b.prim(C, "inject:into:", lambda vm, r, a: _seq_inject(vm, r, a[0], a[1]))
        b.prim(C, "includes:", lambda vm, r, a: _seq_includes(vm, r, a[0]))
        b.prim(C, "indexOf:", lambda vm, r, a: _seq_index_of(vm, r, a[0]))
        b.prim(C, "anySatisfy:", lambda vm, r, a: _seq_any(vm, r, a[0]))
        b.prim(C, "allSatisfy:", lambda vm, r, a: _seq_all(vm, r, a[0]))
        b.prim(C, "count:", lambda vm, r, a: _seq_count(vm, r, a[0]))
        b.prim(C, "sum", lambda vm, r, a: _seq_sum(r))
        b.prim(C, "max", lambda vm, r, a: max(_items(r)))
        b.prim(C, "min", lambda vm, r, a: min(_items(r)))
        b.prim(C, "reverse", lambda vm, r, a: _wrap_like(vm, r, list(reversed(_items(r)))))
        b.prim(C, "reversed", lambda vm, r, a: _wrap_like(vm, r, list(reversed(_items(r)))))
        b.prim(C, "asArray", lambda vm, r, a: list(_items(r)))
        b.prim(C, "asOrderedCollection", lambda vm, r, a: _to_oc(vm, _items(r)))
        b.prim(C, ",", lambda vm, r, a: _wrap_like(vm, r, list(_items(r)) + list(_items(a[0]))))
        b.prim(C, "copyFrom:to:", lambda vm, r, a: _wrap_like(vm, r, _items(r)[_st_index(a[0]) - 1 : _st_index(a[1])]))
        b.prim(C, "with:do:", lambda vm, r, a: _seq_with_do(vm, r, a[0], a[1]))

    # Array class-side constructors
    b.cprim(Array, "new", lambda vm, r, a: [])
    b.cprim(Array, "new:", lambda vm, r, a: [nil] * int(a[0]))
    b.cprim(Array, "with:", lambda vm, r, a: [a[0]])
    b.cprim(Array, "with:with:", lambda vm, r, a: [a[0], a[1]])
    b.cprim(Array, "with:with:with:", lambda vm, r, a: [a[0], a[1], a[2]])
    b.cprim(Array, "with:with:with:with:", lambda vm, r, a: [a[0], a[1], a[2], a[3]])

    # OrderedCollection-specific
    b.prim(OC, "initialize", lambda vm, r, a: _oc_init(r))
    b.prim(OC, "add:", lambda vm, r, a: _oc_add(r, a[0]))
    b.prim(OC, "addLast:", lambda vm, r, a: _oc_add(r, a[0]))
    b.prim(OC, "addFirst:", lambda vm, r, a: _oc_add_first(r, a[0]))
    b.prim(OC, "addAll:", lambda vm, r, a: _oc_add_all(r, a[0]))
    b.prim(OC, "removeFirst", lambda vm, r, a: _items(r).pop(0))
    b.prim(OC, "removeLast", lambda vm, r, a: _items(r).pop())
    b.prim(OC, "remove:", lambda vm, r, a: _oc_remove(vm, r, a[0]))
    b.prim(OC, "removeAll", lambda vm, r, a: _oc_clear(r))
    b.cprim(OC, "withAll:", lambda vm, r, a: _to_oc(vm, list(_items(a[0]))))

    # Dictionary
    b.prim(Dict, "initialize", lambda vm, r, a: _dict_init(r))
    b.prim(Dict, "at:put:", lambda vm, r, a: _dict_at_put(vm, r, a[0], a[1]))
    b.prim(Dict, "at:", lambda vm, r, a: _dict_at(vm, r, a[0]))
    b.prim(Dict, "at:ifAbsent:", lambda vm, r, a: _dict_at_if_absent(vm, r, a[0], a[1]))
    b.prim(Dict, "at:ifAbsentPut:", lambda vm, r, a: _dict_at_if_absent_put(vm, r, a[0], a[1]))
    b.prim(Dict, "includesKey:", lambda vm, r, a: _dkey(a[0]) in r.ivars["map"])
    b.prim(Dict, "removeKey:", lambda vm, r, a: r.ivars["map"].pop(_dkey(a[0]), nil))
    b.prim(Dict, "size", lambda vm, r, a: len(r.ivars["map"]))
    b.prim(Dict, "isEmpty", lambda vm, r, a: len(r.ivars["map"]) == 0)
    b.prim(Dict, "keys", lambda vm, r, a: [k for k, _ in r.ivars["map"].values()])
    b.prim(Dict, "values", lambda vm, r, a: [v for _, v in r.ivars["map"].values()])
    b.prim(Dict, "keysAndValuesDo:", lambda vm, r, a: _dict_kv_do(vm, r, a[0]))
    b.prim(Dict, "do:", lambda vm, r, a: _dict_values_do(vm, r, a[0]))
    b.prim(Dict, "associationsDo:", lambda vm, r, a: _dict_assoc_do(vm, r, a[0]))
    b.cprim(Dict, "new", lambda vm, r, a: _new_and_init(vm, r))


def _to_oc(vm: VM, pylist: list[Any]) -> STObject:
    oc = _new_instance(vm, vm.classes["OrderedCollection"])
    oc.ivars["items"] = list(pylist)
    return oc


def _seq_at(coll, i):
    items = _items(coll)
    idx = _st_index(i)
    if not (1 <= idx <= len(items)):
        raise STError("index out of bounds")
    return items[idx - 1]


def _seq_at_put(coll, i, value):
    items = _items(coll)
    idx = _st_index(i)
    if not (1 <= idx <= len(items)):
        raise STError("index out of bounds")
    items[idx - 1] = value
    return value


def _seq_first(coll):
    items = _items(coll)
    if not items:
        raise STError("collection is empty")
    return items[0]


def _seq_last(coll):
    items = _items(coll)
    if not items:
        raise STError("collection is empty")
    return items[-1]


def _seq_do(vm, coll, block):
    for x in list(_items(coll)):
        vm.run_block(block, [x])
    return coll


def _seq_do_index(vm, coll, block):
    for i, x in enumerate(list(_items(coll)), start=1):
        vm.run_block(block, [x, i])
    return coll


def _seq_do_sep(vm, coll, block, sep):
    items = list(_items(coll))
    for i, x in enumerate(items):
        if i > 0:
            vm.run_block(sep, [])
        vm.run_block(block, [x])
    return coll


def _seq_collect(vm, coll, block):
    return [vm.run_block(block, [x]) for x in _items(coll)]


def _seq_select(vm, coll, block):
    return [x for x in _items(coll) if vm.run_block(block, [x]) is True]


def _seq_reject(vm, coll, block):
    return [x for x in _items(coll) if vm.run_block(block, [x]) is not True]


def _seq_detect(vm, coll, block, none_block):
    for x in _items(coll):
        if vm.run_block(block, [x]) is True:
            return x
    if none_block is not None:
        return vm.run_block(none_block, [])
    raise STError("element not found")


def _seq_inject(vm, coll, acc, block):
    for x in _items(coll):
        acc = vm.run_block(block, [acc, x])
    return acc


def _seq_includes(vm, coll, value):
    return any(_st_equal(vm, x, value) for x in _items(coll))


def _seq_index_of(vm, coll, value):
    for i, x in enumerate(_items(coll), start=1):
        if _st_equal(vm, x, value):
            return i
    return 0


def _seq_any(vm, coll, block):
    return any(vm.run_block(block, [x]) is True for x in _items(coll))


def _seq_all(vm, coll, block):
    return all(vm.run_block(block, [x]) is True for x in _items(coll))


def _seq_count(vm, coll, block):
    return sum(1 for x in _items(coll) if vm.run_block(block, [x]) is True)


def _seq_sum(coll):
    items = _items(coll)
    total: Any = 0
    for x in items:
        total = total + x
    return total


def _seq_with_do(vm, coll, other, block):
    xs = _items(coll)
    ys = _items(other)
    if len(xs) != len(ys):
        raise STError("collections must be the same size")
    for x, y in zip(xs, ys):
        vm.run_block(block, [x, y])
    return coll


def _oc_init(oc):
    oc.ivars["items"] = []
    return oc


def _oc_add(oc, x):
    _items(oc).append(x)
    return x


def _oc_add_first(oc, x):
    _items(oc).insert(0, x)
    return x


def _oc_add_all(oc, other):
    items = _items(oc)
    for x in _items(other):
        items.append(x)
    return other


def _oc_remove(vm, oc, value):
    items = _items(oc)
    for i, x in enumerate(items):
        if _st_equal(vm, x, value):
            return items.pop(i)
    raise STError("element not found")


def _oc_clear(oc):
    _items(oc).clear()
    return oc


# Dictionary keys are stored as hashable proxies mapping to (key, value).
def _dkey(key: Any) -> Any:
    if isinstance(key, STChar):
        return ("char", key.value)
    try:
        hash(key)
        return key
    except TypeError:
        return id(key)


def _dict_init(d):
    d.ivars["map"] = {}
    return d


def _dict_at_put(vm, d, key, value):
    d.ivars["map"][_dkey(key)] = (key, value)
    return value


def _dict_at(vm, d, key):
    entry = d.ivars["map"].get(_dkey(key))
    if entry is None:
        raise STError(f"key not found: {py_print(vm, key)}")
    return entry[1]


def _dict_at_if_absent(vm, d, key, block):
    entry = d.ivars["map"].get(_dkey(key))
    if entry is None:
        return vm.run_block(block, [])
    return entry[1]


def _dict_at_if_absent_put(vm, d, key, block):
    k = _dkey(key)
    entry = d.ivars["map"].get(k)
    if entry is None:
        value = vm.run_block(block, [])
        d.ivars["map"][k] = (key, value)
        return value
    return entry[1]


def _dict_kv_do(vm, d, block):
    for key, value in list(d.ivars["map"].values()):
        vm.run_block(block, [key, value])
    return d


def _dict_values_do(vm, d, block):
    for _key, value in list(d.ivars["map"].values()):
        vm.run_block(block, [value])
    return d


def _dict_assoc_do(vm, d, block):
    for key, value in list(d.ivars["map"].values()):
        vm.run_block(block, [_make_assoc(vm, key, value)])
    return d


# --- BlockClosure ---------------------------------------------------------


def _install_blocks(b: _Builder) -> None:
    B = b.vm.classes["BlockClosure"]
    b.prim(B, "value", lambda vm, r, a: vm.run_block(r, []))
    b.prim(B, "value:", lambda vm, r, a: vm.run_block(r, [a[0]]))
    b.prim(B, "value:value:", lambda vm, r, a: vm.run_block(r, [a[0], a[1]]))
    b.prim(B, "value:value:value:", lambda vm, r, a: vm.run_block(r, [a[0], a[1], a[2]]))
    b.prim(B, "valueWithArguments:", lambda vm, r, a: vm.run_block(r, list(_items(a[0]))))
    b.prim(B, "numArgs", lambda vm, r, a: r.num_args)
    b.prim(B, "whileTrue:", lambda vm, r, a: _while(vm, r, a[0], True))
    b.prim(B, "whileFalse:", lambda vm, r, a: _while(vm, r, a[0], False))
    b.prim(B, "whileTrue", lambda vm, r, a: _while(vm, r, None, True))
    b.prim(B, "whileFalse", lambda vm, r, a: _while(vm, r, None, False))
    b.prim(B, "repeat", lambda vm, r, a: _repeat(vm, r))
    b.prim(B, "on:do:", lambda vm, r, a: _on_do(vm, r, a[0], a[1]))
    b.prim(B, "ensure:", lambda vm, r, a: _ensure(vm, r, a[0]))


def _while(vm, cond, body, want):
    while (vm.run_block(cond, []) is True) == want:
        if body is None:
            continue
        vm.run_block(body, [])
    return nil


def _repeat(vm, block):
    while True:
        vm.run_block(block, [])


def _on_do(vm, protected, exc_class, handler):
    try:
        return vm.run_block(protected, [])
    except STError as e:
        err = _new_instance(vm, vm.classes["Error"])
        err.ivars["messageText"] = e.st_message
        if handler.num_args == 1:
            return vm.run_block(handler, [err])
        return vm.run_block(handler, [])


def _ensure(vm, protected, cleanup):
    try:
        return vm.run_block(protected, [])
    finally:
        vm.run_block(cleanup, [])


# --- Point ----------------------------------------------------------------


def _install_point(b: _Builder) -> None:
    vm = b.vm
    P = vm.classes["Point"]

    def make(x, y):
        p = _new_instance(vm, P)
        p.ivars["x"] = x
        p.ivars["y"] = y
        return p

    b.prim(P, "x", lambda vm, r, a: r.ivars["x"])
    b.prim(P, "y", lambda vm, r, a: r.ivars["y"])
    b.prim(P, "x:", lambda vm, r, a: r.ivars.__setitem__("x", a[0]) or r)
    b.prim(P, "y:", lambda vm, r, a: r.ivars.__setitem__("y", a[0]) or r)
    b.prim(P, "setX:y:", lambda vm, r, a: _point_set(r, a[0], a[1]))
    b.prim(P, "+", lambda vm, r, a: make(r.ivars["x"] + _px(a[0]), r.ivars["y"] + _py(a[0])))
    b.prim(P, "-", lambda vm, r, a: make(r.ivars["x"] - _px(a[0]), r.ivars["y"] - _py(a[0])))
    b.prim(P, "*", lambda vm, r, a: make(r.ivars["x"] * _px(a[0]), r.ivars["y"] * _py(a[0])))
    b.prim(P, "=", lambda vm, r, a: _point_eq(r, a[0]))
    b.prim(P, "dist:", lambda vm, r, a: math.hypot(r.ivars["x"] - _px(a[0]), r.ivars["y"] - _py(a[0])))
    b.prim(P, "printString", lambda vm, r, a: py_print(vm, r))
    b.cprim(P, "x:y:", lambda vm, r, a: make(a[0], a[1]))
    # Number>>@ builds a Point
    b.prim(vm.classes["Number"], "@", lambda vm, r, a: make(r, a[0]))


def _point_set(p, x, y):
    p.ivars["x"] = x
    p.ivars["y"] = y
    return p


def _px(o):
    return o.ivars["x"] if isinstance(o, STObject) else o


def _py(o):
    return o.ivars["y"] if isinstance(o, STObject) else o


def _point_eq(p, o):
    return (
        isinstance(o, STObject)
        and o.st_class.name == "Point"
        and p.ivars["x"] == o.ivars["x"]
        and p.ivars["y"] == o.ivars["y"]
    )


# --- Transcript / streams -------------------------------------------------


def _install_transcript(b: _Builder) -> None:
    T = b.vm.classes["Transcript"]

    def show(vm, r, a):
        vm.output(py_display(vm, a[0]))
        return r

    b.prim(T, "show:", show)
    b.prim(T, "showCr:", lambda vm, r, a: (vm.output(py_display(vm, a[0]) + "\n"), r)[1])
    b.prim(T, "display:", show)
    b.prim(T, "print:", lambda vm, r, a: (vm.output(str(vm.send(a[0], "printString", []))), r)[1])
    b.prim(T, "<<", lambda vm, r, a: (vm.output(py_display(vm, a[0])), r)[1])
    b.prim(T, "nextPutAll:", show)
    b.prim(T, "cr", lambda vm, r, a: (vm.output("\n"), r)[1])
    b.prim(T, "nl", lambda vm, r, a: (vm.output("\n"), r)[1])
    b.prim(T, "tab", lambda vm, r, a: (vm.output("\t"), r)[1])
    b.prim(T, "space", lambda vm, r, a: (vm.output(" "), r)[1])
    b.prim(T, "flush", lambda vm, r, a: r)


# --- Error ----------------------------------------------------------------


def _install_error(b: _Builder) -> None:
    E = b.vm.classes["Error"]
    b.prim(E, "messageText", lambda vm, r, a: r.ivars.get("messageText", nil))
    b.prim(E, "messageText:", lambda vm, r, a: r.ivars.__setitem__("messageText", a[0]) or r)
    b.prim(E, "signal", lambda vm, r, a: _raise_error(r.ivars.get("messageText", "Error")))
    b.prim(E, "signal:", lambda vm, r, a: _raise_error(a[0]))
    b.cprim(E, "signal:", lambda vm, r, a: _raise_error(a[0]))


# --- Context (reified activations: thisContext) ---------------------------


def _ctx_selector(frame: Any) -> Any:
    selector = getattr(frame.method, "selector", None)
    return STSymbol(selector) if selector is not None else nil


def _ctx_print(frame: Any) -> str:
    if frame.is_block:
        return "a BlockContext"
    method = frame.method
    selector = getattr(method, "selector", None) or "?"
    home_class = getattr(method, "defined_in", None)
    prefix = f"{home_class.name}>>" if home_class is not None else ""
    return f"a MethodContext ({prefix}{selector})"


def _install_context(b: _Builder) -> None:
    C = b.vm.classes["Context"]
    b.prim(C, "receiver", lambda vm, r, a: r.receiver)
    b.prim(C, "sender", lambda vm, r, a: r.sender if r.sender is not None else nil)
    b.prim(C, "home", lambda vm, r, a: r.home if r.home is not None else r)
    b.prim(C, "selector", lambda vm, r, a: _ctx_selector(r))
    b.prim(C, "pc", lambda vm, r, a: r.ip)
    b.prim(C, "isBlockContext", lambda vm, r, a: r.is_block)
    b.prim(C, "isDead", lambda vm, r, a: False)
    b.prim(C, "printString", lambda vm, r, a: _ctx_print(r))
