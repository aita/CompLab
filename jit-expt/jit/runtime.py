from __future__ import annotations

import ctypes
import mmap

from .assembler import ObjectCode


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

    def add(self, obj: ObjectCode) -> int:
        blob = obj.code
        n = len(blob)

        page = self._page_with_room(n)
        offset = page.cursor

        # Flip to writable, copy the function in, then back to read+execute.
        self._protect(page, write=True)
        page.buf.seek(offset)
        page.buf.write(blob)
        self._protect(page, write=False)
        # obj.relocs would be applied here once we support absolute
        # references that need the now-known base address (none yet).

        # Advance the cursor, keeping the next function entry aligned.
        end = offset + n
        page.cursor = (end + self._align - 1) & ~(self._align - 1)
        return page.base + offset

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
