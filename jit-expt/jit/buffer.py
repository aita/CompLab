from __future__ import annotations


class CodeBuffer:
    """A growable buffer of emitted machine-code bytes."""

    def __init__(self):
        self.code = bytearray()

    def emit(self, byte: int):
        self.code.append(byte)

    def emit_int(self, value: int, size: int):
        self.code.extend(value.to_bytes(size, byteorder="little"))
