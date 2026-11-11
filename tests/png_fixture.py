"""Test images: a plain 256 x 256 RGB PNG writer for fixtures (dev only)."""

import struct
import zlib

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
SIZE = 256


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def encode_png(pixels):
    """A 256 x 256 RGB8 PNG of `pixels` (196608 bytes)."""
    assert len(pixels) == SIZE * SIZE * 3
    rows = b"".join(b"\0" + pixels[i : i + SIZE * 3] for i in range(0, len(pixels), SIZE * 3))
    return (
        PNG_MAGIC
        + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )
