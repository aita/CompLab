from __future__ import annotations

import ctypes
import mmap

from .buffer import CodeBuffer


class Runtime:
    """Maps emitted code into an executable page and hands back its address."""

    def __init__(self):
        self._buffers = []

    def add(self, code: CodeBuffer) -> int:
        size = mmap.PAGESIZE
        buf = mmap.mmap(
            -1,
            size,
            flags=mmap.MAP_PRIVATE | mmap.MAP_ANON,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
        )
        buf.write(code.code)

        addr = ctypes.addressof(ctypes.c_char.from_buffer(buf))

        libc = ctypes.CDLL(None)
        page_start = addr & ~(size - 1)

        PROT_READ = 1
        PROT_EXEC = 4
        res = libc.mprotect(
            ctypes.c_void_p(page_start),
            ctypes.c_size_t(size),
            PROT_READ | PROT_EXEC,
        )
        if res != 0:
            err = ctypes.get_errno()
            raise OSError(err, "mprotect failed")

        self._buffers.append(buf)
        return addr
