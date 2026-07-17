from __future__ import annotations

import ctypes
import mmap
import sys
import threading

from .assembler import ObjectCode, Reloc, RelocKind


def _fits_rel32(rel: int) -> bool:
    return -(1 << 31) <= rel < (1 << 31)


# --- Platform-specific executable pages -------------------------------------
#
# Each Page backs one region mapped TWICE: a WRITABLE view (`write_base`) code
# is copied through, and a permanently READ+EXEC view (`base`) it runs from. The
# two views alias the same physical memory, so a write appears in the exec view
# without ever flipping its protection -- functions already placed stay
# executable while a new one is copied in (no protection races). The machine
# code itself is identical across OSes; only how the pages are obtained differs.

if sys.platform == "win32":
    _k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _k32.CreateFileMappingW.restype = ctypes.c_void_p
    _k32.CreateFileMappingW.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                        ctypes.c_uint32, ctypes.c_uint32,
                                        ctypes.c_uint32, ctypes.c_wchar_p]
    _k32.MapViewOfFile.restype = ctypes.c_void_p
    _k32.MapViewOfFile.argtypes = [ctypes.c_void_p, ctypes.c_uint32,
                                   ctypes.c_uint32, ctypes.c_uint32,
                                   ctypes.c_size_t]
    _k32.UnmapViewOfFile.argtypes = [ctypes.c_void_p]
    _k32.CloseHandle.argtypes = [ctypes.c_void_p]

    _INVALID_HANDLE = ctypes.c_void_p(-1).value
    _PAGE_EXECUTE_READWRITE = 0x40
    _FILE_MAP_WRITE = 0x0002
    _FILE_MAP_READ = 0x0004
    _FILE_MAP_EXECUTE = 0x0020

    class Page:
        """A pagefile-backed section mapped twice with MapViewOfFile: a writable
        view and an execute view aliasing the same physical pages."""

        def __init__(self, size: int):
            self._hmap = _k32.CreateFileMappingW(
                ctypes.c_void_p(_INVALID_HANDLE), None,
                _PAGE_EXECUTE_READWRITE, 0, size, None)
            if not self._hmap:
                raise ctypes.WinError(ctypes.get_last_error())
            self.write_base = _k32.MapViewOfFile(
                self._hmap, _FILE_MAP_WRITE, 0, 0, size)
            self.base = _k32.MapViewOfFile(
                self._hmap, _FILE_MAP_READ | _FILE_MAP_EXECUTE, 0, 0, size)
            if not self.write_base or not self.base:
                raise ctypes.WinError(ctypes.get_last_error())
            self.size = size
            self.cursor = 0

        def remaining(self) -> int:
            return self.size - self.cursor

        def __del__(self):
            for view in (getattr(self, "write_base", 0), getattr(self, "base", 0)):
                if view:
                    try:
                        _k32.UnmapViewOfFile(ctypes.c_void_p(view))
                    except Exception:
                        pass
            if getattr(self, "_hmap", 0):
                try:
                    _k32.CloseHandle(ctypes.c_void_p(self._hmap))
                except Exception:
                    pass

else:
    _libc = ctypes.CDLL(None, use_errno=True)
    _libc.mmap.restype = ctypes.c_void_p
    _libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                           ctypes.c_int, ctypes.c_int, ctypes.c_long]

    _MFD_CLOEXEC = 0x0001
    _MAP_SHARED = 0x01
    _PROT_READ = 0x1
    _PROT_EXEC = 0x4
    _MAP_FAILED = ctypes.c_void_p(-1).value

    class Page:
        """An anonymous memfd mapped twice: a writable view (Python mmap) and an
        execute view (libc mmap) aliasing the same physical pages."""

        def __init__(self, size: int):
            # memfd_create is a Linux 3.17+ syscall; fall back to the raw
            # syscall number if the libc wrapper is absent.
            memfd = getattr(_libc, "memfd_create", None)
            if memfd is not None:
                memfd.restype = ctypes.c_int
                memfd.argtypes = [ctypes.c_char_p, ctypes.c_uint]
                self._fd = memfd(b"jit", _MFD_CLOEXEC)
            else:
                self._fd = _libc.syscall(319, b"jit", _MFD_CLOEXEC)
            if self._fd < 0:
                raise OSError(ctypes.get_errno(), "memfd_create failed")
            if _libc.ftruncate(ctypes.c_int(self._fd), ctypes.c_size_t(size)) != 0:
                raise OSError(ctypes.get_errno(), "ftruncate failed")

            # Writable view via Python's mmap (its buffer keeps the mapping alive
            # and from_buffer yields the page-aligned base address).
            self._buf = mmap.mmap(self._fd, size, flags=mmap.MAP_SHARED,
                                  prot=mmap.PROT_READ | mmap.PROT_WRITE)
            self.write_base = ctypes.addressof(ctypes.c_char.from_buffer(self._buf))

            # Execute view via libc mmap (a PROT_EXEC, non-writable mapping can't
            # be wrapped by Python's writable-buffer requirement).
            self.base = _libc.mmap(None, ctypes.c_size_t(size),
                                   _PROT_READ | _PROT_EXEC, _MAP_SHARED,
                                   ctypes.c_int(self._fd), ctypes.c_long(0))
            if self.base in (None, _MAP_FAILED):
                raise OSError(ctypes.get_errno(), "mmap (exec view) failed")

            self.size = size
            self.cursor = 0

        def remaining(self) -> int:
            return self.size - self.cursor

        def __del__(self):
            # Best-effort teardown; the process may already be exiting.
            try:
                self._buf.close()
            except Exception:
                pass
            try:
                _libc.munmap(ctypes.c_void_p(self.base), ctypes.c_size_t(self.size))
            except Exception:
                pass
            try:
                _libc.close(ctypes.c_int(self._fd))
            except Exception:
                pass


class Runtime:
    """Maps emitted code into executable memory and hands back function
    addresses. Small functions are packed into shared pages (a bump
    allocator) rather than getting a whole page each.

    Each page is backed by one physical region mapped twice (see Page): a
    writable view code is copied through and a permanently read+execute view it
    runs from. Writes never touch the R+X view, so functions already placed in a
    page stay continuously executable while add() copies a new one in — safe
    even if another thread is executing pooled code concurrently.

    A lock serializes the mutating operations (add/stage/link/define) so several
    threads may build code concurrently without corrupting the bump allocator or
    the symbol/veneer tables. Executing already-added functions takes no lock."""

    def __init__(self, align: int = 16):
        self._pages: list[Page] = []      # all pages, kept alive
        self._active: Page | None = None  # page currently being filled
        self._align = align
        self._lock = threading.Lock()      # guards the mutating operations
        self._symbols: dict[str, int] = {}  # name -> address
        self._veneers: dict[int, int] = {}  # far target -> veneer address
        # Items reserved by stage() but not yet relocated/written by link().
        self._pending: list[tuple[ObjectCode, Page, int, int]] = []

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

    def _relocate(self, blob: bytearray, base: int, relocs: tuple[Reloc, ...],
                  table: dict[str, int]) -> None:
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

    def _alloc_slot(self, n: int) -> tuple[Page, int, int]:
        page = self._page_with_room(n)
        offset = page.cursor
        page.cursor = (offset + n + self._align - 1) & ~(self._align - 1)
        return page, offset, page.base + offset

    def _write_slot(self, page: Page, offset: int, blob: bytes) -> None:
        # Copy through the writable view; the change is immediately live in the
        # aliased read+execute view. No protection flip, so other functions in
        # the page never stop being executable.
        ctypes.memmove(page.write_base + offset, bytes(blob), len(blob))

    def _page_with_room(self, n: int) -> Page:
        if self._active is not None and self._active.remaining() >= n:
            return self._active
        # Round up to whole pages so a larger-than-page function still fits.
        pagesize = mmap.PAGESIZE
        size = max(pagesize, ((n + pagesize - 1) // pagesize) * pagesize)
        page = Page(size)
        self._pages.append(page)
        self._active = page
        return page
