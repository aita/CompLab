"""Object model for the small Smalltalk.

Design: Smalltalk primitive values reuse native Python types where practical
(int, float, bool, str for String) and are wrapped only when Python has no
faithful equivalent (Symbol, Character, nil, Block). Ordinary user-level
objects are :class:`STObject` instances that carry a reference to their
:class:`STClass` and a dict of instance variables.

Method lookup walks the superclass chain. A method is either a
:class:`CompiledMethod` (a parsed Smalltalk method) or a :class:`PrimitiveMethod`
(a Python callable implementing behaviour that cannot be expressed in the
subset, e.g. integer arithmetic or ``Transcript show:``).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any, Callable

if TYPE_CHECKING:
    from st.vm import VM


# --- Unique/immediate objects ------------------------------------------------


class _Nil:
    """The unique ``nil`` object."""

    _instance: "_Nil | None" = None

    def __new__(cls) -> "_Nil":
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __repr__(self) -> str:
        return "nil"


nil = _Nil()


class STSymbol(str):
    """A Smalltalk symbol, e.g. ``#foo``. Distinct Python type so it dispatches
    to the Symbol class rather than String, but interns like a str."""

    _interned: dict[str, "STSymbol"] = {}

    def __new__(cls, value: str) -> "STSymbol":
        existing = cls._interned.get(value)
        if existing is not None:
            return existing
        obj = super().__new__(cls, value)
        cls._interned[value] = obj
        return obj

    def __repr__(self) -> str:
        return f"#{str.__str__(self)}"


@dataclass(frozen=True)
class STChar:
    """A Smalltalk character literal, e.g. ``$a``."""

    value: str  # a single-character Python str

    def __repr__(self) -> str:
        return f"${self.value}"


# --- Behaviour: classes and methods -----------------------------------------


@dataclass
class PrimitiveMethod:
    """A method implemented in Python.

    The callable receives ``(vm, receiver, args)`` and returns a Smalltalk
    value. Raising :class:`STError` (or returning normally) is how it reports
    failure/success; it may re-enter the VM via ``vm.send`` / ``vm.run_block``.
    """

    name: str
    fn: Callable[["VM", Any, list[Any]], Any]

    def __repr__(self) -> str:
        return f"<primitive {self.name}>"


# A method is either a PrimitiveMethod or a bytecode CompiledMethod
# (st.bytecode.CompiledMethod). Kept as ``Any`` here to avoid importing the
# bytecode module (which depends on this one).
Method = Any


# Sentinel distinguishing "not yet resolved" from a cached miss (``None``).
_UNRESOLVED: Any = object()


@dataclass
class STClass:
    """A Smalltalk class.

    ``methods`` holds instance-side behaviour; ``class_methods`` holds
    behaviour available when the class object itself is the receiver
    (e.g. ``new``, ``x:y:``). ``instance_variables`` lists only the ivars
    introduced by this class; the full layout is the union with superclasses.
    """

    name: str
    superclass: "STClass | None" = None
    instance_variables: list[str] = field(default_factory=list)
    methods: dict[str, Method] = field(default_factory=dict)
    class_methods: dict[str, Method] = field(default_factory=dict)

    # Per-class caches (not part of identity/repr). ``method_cache`` /
    # ``class_method_cache`` memoize resolved lookups (value ``None`` records a
    # miss); ``_ivars_cache`` memoizes the flattened ivar layout. All are
    # cleared by ``VM.flush_method_caches`` when behaviour changes.
    method_cache: dict[str, Any] = field(
        default_factory=dict, compare=False, repr=False
    )
    class_method_cache: dict[str, Any] = field(
        default_factory=dict, compare=False, repr=False
    )
    _ivars_cache: "list[str] | None" = field(
        default=None, compare=False, repr=False
    )

    # --- reflection helpers ---

    def all_instance_variables(self) -> list[str]:
        cached = self._ivars_cache
        if cached is not None:
            return cached
        ivars: list[str] = []
        chain: list[STClass] = []
        cls: STClass | None = self
        while cls is not None:
            chain.append(cls)
            cls = cls.superclass
        for cls in reversed(chain):
            ivars.extend(cls.instance_variables)
        self._ivars_cache = ivars
        return ivars

    def lookup(self, selector: str) -> Method | None:
        cache = self.method_cache
        hit = cache.get(selector, _UNRESOLVED)
        if hit is not _UNRESOLVED:
            return hit
        cls: STClass | None = self
        while cls is not None:
            method = cls.methods.get(selector)
            if method is not None:
                cache[selector] = method
                return method
            cls = cls.superclass
        cache[selector] = None
        return None

    def lookup_class_method(self, selector: str) -> Method | None:
        cache = self.class_method_cache
        hit = cache.get(selector, _UNRESOLVED)
        if hit is not _UNRESOLVED:
            return hit
        cls: STClass | None = self
        while cls is not None:
            method = cls.class_methods.get(selector)
            if method is not None:
                cache[selector] = method
                return method
            cls = cls.superclass
        cache[selector] = None
        return None

    def is_kind_of(self, other: "STClass") -> bool:
        cls: STClass | None = self
        while cls is not None:
            if cls is other:
                return True
            cls = cls.superclass
        return False

    def __repr__(self) -> str:
        return f"<class {self.name}>"


@dataclass
class STObject:
    """An ordinary user-level object instance."""

    st_class: STClass
    ivars: dict[str, Any] = field(default_factory=dict)

    def __repr__(self) -> str:
        return f"a {self.st_class.name}"


@dataclass
class STBlock:
    """A block closure ``[:a | ... ]``.

    Captures the enclosing activation (``outer``) so that references to the
    block's free variables reach the right slots, and the home method context
    so that a non-local return ``^`` returns from the home method.
    """

    node: Any  # bytecode.CompiledBlock
    outer: Any  # vm.Frame — the activation that created the block
    home_context: Any  # vm.Frame (MethodContext) | None

    @property
    def num_args(self) -> int:
        return len(self.node.params)

    def __repr__(self) -> str:
        return f"<block/{self.num_args}>"


class STError(Exception):
    """A Smalltalk-level error (doesNotUnderstand, primitive failure, etc.)."""

    def __init__(self, message: str, receiver: Any = nil):
        super().__init__(message)
        self.st_message = message
        self.receiver = receiver
