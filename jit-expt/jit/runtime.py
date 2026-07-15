from __future__ import annotations

import ctypes
import mmap

from .assembler import ObjectCode, RelocKind


def _fits_rel32(rel: int) -> bool:
    return -(1 << 31) <= rel < (1 << 31)


class _Page:
    """One executable mmap and a bump cursor into it."""

    def __init__(self, size: int):
        self.buf = mmap.mmap(
            -1,
            size,
            flags=mmap.MAP_PRIVATE | mmap.MAP_ANON,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
        )
        self.size = size
        self.cursor = 0
        # Capture the base address while the page is still writable
        # (c_char.from_buffer requires a writable buffer). mmap always
        # returns a page-aligned address, so this is a valid mprotect base.
        self.base = ctypes.addressof(ctypes.c_char.from_buffer(self.buf))

    def remaining(self) -> int:
        return self.size - self.cursor


class Runtime:
    """Maps emitted code into executable memory and hands back function
    addresses. Small functions are packed into shared pages (a bump
    allocator) rather than getting a whole page each.

    Each page keeps W^X: it is flipped back to writable only while a new
    function is copied in, then restored to read+execute. That briefly makes
    earlier functions in the same page non-executable, so this is only safe
    when no other thread is executing pooled code during add()."""

    def __init__(self, align: int = 16):
        self._pages: list[_Page] = []      # all pages, kept alive
        self._active: _Page | None = None  # page currently being filled
        self._align = align
        self._libc = ctypes.CDLL(None, use_errno=True)
        self._symbols: dict[str, int] = {}  # name -> address
        self._veneers: dict[int, int] = {}  # far target -> veneer address
        # Items reserved by stage() but not yet relocated/written by link().
        self._pending: list[tuple[ObjectCode, _Page, int, int]] = []

    def define(self, name: str, addr: int) -> None:
        """Register an external address (e.g. a C function) under `name` so
        code added later can reference it as Symbol(name)."""
        self._symbols[name] = addr

    def add(self, obj: ObjectCode, name: str | None = None,
            symbols: dict[str, int] | None = None) -> int:
        blob = bytearray(obj.code)
        page, offset, addr = self._alloc_slot(len(blob))

        # The symbol table for this add: the runtime's registry, plus any
        # one-off symbols, plus this function's own name (so it can recurse).
        table = {**self._symbols, **(symbols or {})}
        if name is not None:
            self._symbols[name] = addr
            table[name] = addr

        # Reserving the slot above means any veneers created while relocating
        # are placed after this function, not on top of it.
        self._relocate(blob, addr, obj.relocs, table)
        self._write_slot(page, offset, blob)
        return addr

    def stage(self, obj: ObjectCode, name: str | None = None) -> int:
        """Reserve a slot for `obj` and register `name -> addr` now, but defer
        relocation and the byte-write until link(). Staging several functions
        before linking lets them reference each other's names (mutual
        recursion), since every name is registered up front. Returns the
        reserved address."""
        page, offset, addr = self._alloc_slot(len(obj.code))
        if name is not None:
            self._symbols[name] = addr
        self._pending.append((obj, page, offset, addr))
        return addr

    def link(self) -> None:
        """Relocate and write every staged function now that all names are
        registered. A no-op when nothing is staged."""
        pending, self._pending = self._pending, []
        for obj, page, offset, addr in pending:
            blob = bytearray(obj.code)
            self._relocate(blob, addr, obj.relocs, self._symbols)
            self._write_slot(page, offset, blob)

    def _relocate(self, blob: bytearray, base: int, relocs, table: dict[str, int]):
        for r in relocs:
            if r.symbol not in table:
                raise KeyError(f"unresolved symbol {r.symbol!r}")
            target = table[r.symbol]
            if r.kind is RelocKind.ABS64:
                blob[r.offset:r.offset + 8] = target.to_bytes(8, "little")
            else:  # REL32: distance from the end of the 4-byte field
                rel = target - (base + r.offset + 4)
                if not _fits_rel32(rel):
                    # Too far for a direct call: route through a near veneer
                    # that jumps to the absolute target.
                    rel = self._veneer(target) - (base + r.offset + 4)
                    if not _fits_rel32(rel):
                        raise ValueError(
                            f"symbol {r.symbol!r} unreachable even via a veneer")
                blob[r.offset:r.offset + 4] = rel.to_bytes(4, "little", signed=True)

    def _veneer(self, target: int) -> int:
        """Address of a stub near the code that jumps to `target` (created and
        cached on first use). Lets a rel32 call reach an arbitrary address."""
        if target not in self._veneers:
            stub = (b"\x49\xbb" + target.to_bytes(8, "little")  # movabs r11, target
                    + b"\x41\xff\xe3")                          # jmp r11
            self._veneers[target] = self._place(stub)
        return self._veneers[target]

    def _place(self, blob: bytes) -> int:
        """Bump-allocate `blob` into an executable page and return its address."""
        page, offset, addr = self._alloc_slot(len(blob))
        self._write_slot(page, offset, blob)
        return addr

    def _alloc_slot(self, n: int) -> tuple[_Page, int, int]:
        page = self._page_with_room(n)
        offset = page.cursor
        page.cursor = (offset + n + self._align - 1) & ~(self._align - 1)
        return page, offset, page.base + offset

    def _write_slot(self, page: _Page, offset: int, blob: bytes) -> None:
        # Flip to writable, copy the bytes in, then back to read+execute.
        self._protect(page, write=True)
        page.buf.seek(offset)
        page.buf.write(blob)
        self._protect(page, write=False)

    def _page_with_room(self, n: int) -> _Page:
        if self._active is not None and self._active.remaining() >= n:
            return self._active
        # Round up to whole pages so a larger-than-page function still fits.
        pagesize = mmap.PAGESIZE
        size = max(pagesize, ((n + pagesize - 1) // pagesize) * pagesize)
        page = _Page(size)
        self._pages.append(page)
        self._active = page
        return page

    def _protect(self, page: _Page, *, write: bool) -> None:
        prot = mmap.PROT_READ | (mmap.PROT_WRITE if write else mmap.PROT_EXEC)
        res = self._libc.mprotect(
            ctypes.c_void_p(page.base),
            ctypes.c_size_t(page.size),
            prot,
        )
        if res != 0:
            raise OSError(ctypes.get_errno(), "mprotect failed")
