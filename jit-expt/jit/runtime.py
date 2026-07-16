from __future__ import annotations

import ctypes
import mmap
import threading

from .assembler import ObjectCode, RelocKind


def _fits_rel32(rel: int) -> bool:
    return -(1 << 31) <= rel < (1 << 31)


_MFD_CLOEXEC = 0x0001
_MAP_SHARED = 0x01
_PROT_READ = 0x1
_PROT_EXEC = 0x4
_MAP_FAILED = ctypes.c_void_p(-1).value


class _Page:
    """One physical memory region mapped TWICE from the same memfd: a WRITABLE
    view code is copied through, and a permanently READ+EXEC view functions are
    executed from. Both views alias the same physical pages, so a write to the
    writable view is instantly visible (and executable) through the R+X view.

    Because the R+X view is never flipped writable, functions already placed in
    the page stay executable while a new one is copied in — no mprotect races.

    Holds a bump cursor into the region."""

    def __init__(self, size: int, libc):
        self._libc = libc
        # Anonymous file whose pages we map twice. memfd_create is a Linux
        # 3.17+ syscall; fall back to the raw syscall number if the libc
        # wrapper is absent.
        memfd = getattr(libc, "memfd_create", None)
        if memfd is not None:
            memfd.restype = ctypes.c_int
            memfd.argtypes = [ctypes.c_char_p, ctypes.c_uint]
            self.fd = memfd(b"jit", _MFD_CLOEXEC)
        else:
            self.fd = libc.syscall(319, b"jit", _MFD_CLOEXEC)  # __NR_memfd_create
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "memfd_create failed")

        res = libc.ftruncate(ctypes.c_int(self.fd), ctypes.c_size_t(size))
        if res != 0:
            raise OSError(ctypes.get_errno(), "ftruncate failed")

        # Writable view: use Python's mmap so its buffer keeps the mapping
        # alive and from_buffer can read out the (page-aligned) base address.
        self.buf = mmap.mmap(
            self.fd, size,
            flags=mmap.MAP_SHARED,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
        )
        self.write_base = ctypes.addressof(ctypes.c_char.from_buffer(self.buf))

        # Executable view: mapped via libc mmap because a PROT_EXEC (non-writable)
        # mapping can't be wrapped by Python's writable-buffer requirement.
        self.base = libc.mmap(
            None, ctypes.c_size_t(size), _PROT_READ | _PROT_EXEC,
            _MAP_SHARED, ctypes.c_int(self.fd), ctypes.c_long(0),
        )
        if self.base in (None, _MAP_FAILED):
            raise OSError(ctypes.get_errno(), "mmap (exec view) failed")

        self.size = size
        self.cursor = 0

    def remaining(self) -> int:
        return self.size - self.cursor

    def __del__(self):
        # Best-effort teardown; the process may already be exiting.
        try:
            self.buf.close()
        except Exception:
            pass
        try:
            self._libc.munmap(ctypes.c_void_p(self.base), ctypes.c_size_t(self.size))
        except Exception:
            pass
        try:
            self._libc.close(ctypes.c_int(self.fd))
        except Exception:
            pass


class Runtime:
    """Maps emitted code into executable memory and hands back function
    addresses. Small functions are packed into shared pages (a bump
    allocator) rather than getting a whole page each.

    Each page is backed by one physical region mapped twice (see _Page): a
    writable view code is copied through and a permanently read+execute view it
    runs from. Writes never touch the R+X view, so functions already placed in a
    page stay continuously executable while add() copies a new one in — safe
    even if another thread is executing pooled code concurrently.

    A lock serializes the mutating operations (add/stage/link/define) so several
    threads may build code concurrently without corrupting the bump allocator or
    the symbol/veneer tables. Executing already-added functions takes no lock."""

    def __init__(self, align: int = 16):
        self._pages: list[_Page] = []      # all pages, kept alive
        self._active: _Page | None = None  # page currently being filled
        self._align = align
        self._lock = threading.Lock()      # guards the mutating operations
        self._libc = ctypes.CDLL(None, use_errno=True)
        # mmap returns a pointer; declare it so ctypes doesn't truncate the
        # address to a 32-bit C int.
        self._libc.mmap.restype = ctypes.c_void_p
        self._libc.mmap.argtypes = [
            ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
            ctypes.c_int, ctypes.c_int, ctypes.c_long,
        ]
        self._symbols: dict[str, int] = {}  # name -> address
        self._veneers: dict[int, int] = {}  # far target -> veneer address
        # Items reserved by stage() but not yet relocated/written by link().
        self._pending: list[tuple[ObjectCode, _Page, int, int]] = []

    def define(self, name: str, addr: int) -> None:
        """Register an external address (e.g. a C function) under `name` so
        code added later can reference it as Symbol(name)."""
        with self._lock:
            self._symbols[name] = addr

    def add(self, obj: ObjectCode, name: str | None = None,
            symbols: dict[str, int] | None = None) -> int:
        with self._lock:
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
        with self._lock:
            page, offset, addr = self._alloc_slot(len(obj.code))
            if name is not None:
                self._symbols[name] = addr
            self._pending.append((obj, page, offset, addr))
            return addr

    def link(self) -> None:
        """Relocate and write every staged function now that all names are
        registered. A no-op when nothing is staged."""
        with self._lock:
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
        # Copy through the writable view; the change is immediately live in the
        # aliased read+execute view. No protection flip, so other functions in
        # the page never stop being executable.
        ctypes.memmove(page.write_base + offset, bytes(blob), len(blob))

    def _page_with_room(self, n: int) -> _Page:
        if self._active is not None and self._active.remaining() >= n:
            return self._active
        # Round up to whole pages so a larger-than-page function still fits.
        pagesize = mmap.PAGESIZE
        size = max(pagesize, ((n + pagesize - 1) // pagesize) * pagesize)
        page = _Page(size, self._libc)
        self._pages.append(page)
        self._active = page
        return page
