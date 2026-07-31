"""Semantic types, and the symbols that carry them.

Types are monomorphic.  Records are nominal — two record types with the same
fields are different types — and everything else is structural, which for this
language means arrays compare by their element type.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True, slots=True)
class IntT:
    def __str__(self) -> str:
        return "int"


@dataclass(frozen=True, slots=True)
class StringT:
    def __str__(self) -> str:
        return "string"


@dataclass(frozen=True, slots=True)
class BoolT:
    def __str__(self) -> str:
        return "bool"


@dataclass(frozen=True, slots=True)
class UnitT:
    def __str__(self) -> str:
        return "unit"


@dataclass(frozen=True, slots=True)
class NilT:
    """The type of `nil` before it is known which record it stands for."""

    def __str__(self) -> str:
        return "nil"


@dataclass(eq=False, slots=True)
class RecordT:
    name: str
    fields: list[tuple[str, Type]] = field(default_factory=list)

    def index(self, name: str) -> int:
        for i, (fname, _) in enumerate(self.fields):
            if fname == name:
                return i
        return -1

    def field_type(self, name: str) -> Type | None:
        i = self.index(name)
        return None if i < 0 else self.fields[i][1]

    def __str__(self) -> str:
        return self.name


@dataclass(eq=False, slots=True)
class ArrayT:
    elem: Type

    def __str__(self) -> str:
        return f"{self.elem} array"


type Type = IntT | StringT | BoolT | UnitT | NilT | RecordT | ArrayT

INT = IntT()
STRING = StringT()
BOOL = BoolT()
UNIT = UnitT()
NIL = NilT()


def same(a: Type, b: Type) -> bool:
    """Type equality: nominal for records, structural for arrays."""
    match a, b:
        case RecordT(), RecordT():
            return a is b
        case ArrayT(), ArrayT():
            return same(a.elem, b.elem)
        case _:
            return type(a) is type(b)


def compatible(a: Type, b: Type) -> bool:
    """Equality, but `nil` stands in for any record."""
    match a, b:
        case NilT(), RecordT() | NilT():
            return True
        case RecordT() | NilT(), NilT():
            return True
        case _:
            return same(a, b)


# -- symbols ------------------------------------------------------------------


@dataclass(eq=False, slots=True)
class VarSym:
    """One binding occurrence of a variable.

    `depth` is the static nesting depth of the function that binds it.  A
    variable read from a deeper function escapes, and then it lives in a frame
    slot instead of a register.
    """

    name: str
    ty: Type
    mutable: bool
    depth: int
    escapes: bool = False
    slot: int = -1
    reg: int = -1

    def __str__(self) -> str:
        return self.name


@dataclass(eq=False, slots=True)
class FunSym:
    """A function.  Functions are not values, so there is no function type."""

    name: str
    label: str
    params: list[VarSym]
    result: Type
    depth: int
    builtin: str | None = None
    escapes_frame: bool = False

    def __str__(self) -> str:
        return self.name
