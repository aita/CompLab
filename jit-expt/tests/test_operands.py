"""The register tables and __all__ are written out separately (so type checkers
and editors can follow the re-exports through `jit`); these keep them in step."""

from jit import operands


def test_all_lists_every_register():
    tables = (operands._R64 + operands._R32 + operands._R16 + operands._R8
              + ["AH", "CH", "DH", "BH"] + operands._XMM)
    assert set(tables) <= set(operands.__all__), \
        f"missing from __all__: {sorted(set(tables) - set(operands.__all__))}"


def test_all_names_exist_and_are_reexported():
    import jit

    for name in operands.__all__:
        assert hasattr(operands, name), f"{name} is in __all__ but undefined"
        assert hasattr(jit, name), f"{name} is not re-exported by jit"
