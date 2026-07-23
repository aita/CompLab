"""Loader for the optional Cython dispatch loop (`_dispatch.pyx`).

`load()` compiles the .pyx on first call (via pyximport) and returns its
`run_frame`, or None if Cython or a C compiler is unavailable -- so the VM can
fall back to pure Python. The compile happens once; the built extension is
cached by pyximport under ~/.pyxbld.
"""

from __future__ import annotations

from collections.abc import Callable

_cache: Callable | None = None
_tried = False


def load() -> Callable | None:
    """Return the compiled `run_frame(vm, code, regs, glb)`, or None."""
    global _cache, _tried
    if _tried:
        return _cache
    _tried = True
    try:
        import pyximport
        hooks = pyximport.install(language_level=3)
        try:
            from . import _dispatch
        finally:
            pyximport.uninstall(*hooks)   # don't leave the import hook installed
        _cache = _dispatch.run_frame
    except Exception:
        _cache = None
    return _cache
