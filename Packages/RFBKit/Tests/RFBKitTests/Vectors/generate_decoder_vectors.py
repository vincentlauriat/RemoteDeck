#!/usr/bin/env python3
"""Generate RFBKit framebuffer-decoder test vectors independently of the Swift implementation.

Regenerate (from Packages/RFBKit):
    python3 Tests/RFBKitTests/Vectors/generate_decoder_vectors.py > Tests/RFBKitTests/DecoderVectors.swift

Each vector is a server -> client byte stream (the messages that follow ServerInit) and the
framebuffer expected once it has been applied, starting from an opaque black framebuffer.

Independent tools only:
- zlib: Python's `zlib.compressobj`, one object per RFB zlib stream, `Z_SYNC_FLUSH` after every
  rectangle, as servers do;
- JPEG (Tight): the libjpeg-turbo CLI, `cjpeg` to encode and `djpeg` to compute the expected pixels
  (ImageIO decodes slightly differently, so the Swift test compares within a tolerance);
- encoders below follow RFC 6143 (Raw, CopyRect, ZRLE, DesktopSize) and the rfbproto community
  specification (Tight, ExtendedDesktopSize) directly; nothing is shared with the Swift code.

Pixel format: the one RFBKit requests (32 bpp, depth 24, little-endian, shifts R16 G8 B0), so a raw
PIXEL is B, G, R, X; a ZRLE CPIXEL is the 3 least significant bytes, B, G, R; a Tight TPIXEL is R, G, B.

Output: the stream as base64; the expected framebuffer as zlib-compressed RGB bytes in base64
(the Swift test inflates it with libz directly). Content comes from a fixed LCG, so output is stable.
"""

import base64
import os
import struct
import subprocess
import sys
import tempfile
import zlib

BLACK = (0, 0, 0)


class LCG:
    """Deterministic pseudo-random numbers (Numerical Recipes constants)."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def next(self, n):
        self.state = (self.state * 1664525 + 1013904223) & 0xFFFFFFFF
        return (self.state >> 8) % n

    def colour(self):
        return (self.next(256), self.next(256), self.next(256))


class Image:
    def __init__(self, width, height, fill=BLACK):
        self.width = width
        self.height = height
        self.rows = [[fill] * width for _ in range(height)]

    def get(self, x, y):
        return self.rows[y][x]

    def put(self, x, y, colour):
        self.rows[y][x] = colour

    def blit(self, rx, ry, pixels):
        """pixels: list of rows."""
        for dy, row in enumerate(pixels):
            for dx, colour in enumerate(row):
                self.put(rx + dx, ry + dy, colour)

    def resized(self, width, height):
        # RFBKit keeps the overlapping top-left content and fills the rest with black.
        out = Image(width, height)
        for y in range(min(height, self.height)):
            for x in range(min(width, self.width)):
                out.put(x, y, self.get(x, y))
        return out

    def rgb_bytes(self):
        return bytes(c for row in self.rows for p in row for c in p)


# --- Content generators (lists of rows) -------------------------------------------------------

def noise(rng, w, h):
    return [[rng.colour() for _ in range(w)] for _ in range(h)]


def solid(colour, w, h):
    return [[colour] * w for _ in range(h)]


def from_palette(rng, palette, w, h, run_bias=0):
    """Pixels drawn from `palette`; with run_bias > 0, colours repeat in runs (for RLE)."""
    out = []
    current = palette[0]
    for _ in range(h):
        row = []
        for _ in range(w):
            if run_bias == 0 or rng.next(run_bias) == 0:
                current = palette[rng.next(len(palette))]
            row.append(current)
        out.append(row)
    return out


def smooth(w, h, seed):
    """A gradient with a sharp edge, to exercise the Tight gradient filter's clamping."""
    out = []
    for y in range(h):
        row = []
        for x in range(w):
            if x > w // 2 and y > h // 3:
                row.append((250, 5, (x * 7 + seed) & 0xFF))
            else:
                row.append(((x * 9 + seed) & 0xFF, (y * 11) & 0xFF, ((x + y) * 3) & 0xFF))
        out.append(row)
    return out


def palette_of(rng, n):
    colours = []
    while len(colours) < n:
        c = rng.colour()
        if c not in colours:
            colours.append(c)
    return colours


# --- Wire helpers ------------------------------------------------------------------------------

def u8(v):
    return struct.pack(">B", v)


def u16(v):
    return struct.pack(">H", v)


def u32(v):
    return struct.pack(">I", v)


def s32(v):
    return struct.pack(">i", v)


def update_header(count):
    return u8(0) + u8(0) + u16(count)


def rect_header(x, y, w, h, encoding):
    return u16(x) + u16(y) + u16(w) + u16(h) + s32(encoding)


def raw_pixel(c):          # PIXEL, little-endian 0x00RRGGBB -> B, G, R, X
    return bytes([c[2], c[1], c[0], 0x5A])  # padding byte deliberately non-zero


def cpixel(c):             # ZRLE CPIXEL: least significant 3 bytes of the LE pixel -> B, G, R
    return bytes([c[2], c[1], c[0]])


def tpixel(c):             # Tight TPIXEL: R, G, B
    return bytes([c[0], c[1], c[2]])


RAW, COPYRECT, TIGHT, ZRLE = 0, 1, 7, 16
DESKTOP_SIZE, CURSOR, EXT_DESKTOP_SIZE = -223, -239, -308


def raw_rect(image, x, y, pixels):
    image.blit(x, y, pixels)
    h, w = len(pixels), len(pixels[0])
    return rect_header(x, y, w, h, RAW) + b"".join(raw_pixel(c) for row in pixels for c in row)


def copy_rect(image, sx, sy, dx, dy, w, h):
    source = [[image.get(sx + i, sy + j) for i in range(w)] for j in range(h)]  # read before writing
    image.blit(dx, dy, source)
    return rect_header(dx, dy, w, h, COPYRECT) + u16(sx) + u16(sy)


# --- ZRLE ---------------------------------------------------------------------------------------

def zrle_run_length(length):
    out = b""
    v = length - 1
    while v >= 255:
        out += u8(255)
        v -= 255
    return out + u8(v)


def zrle_tile(pixels, sub, palette=None):
    flat = [c for row in pixels for c in row]
    w = len(pixels[0])
    if sub == 0:
        return u8(0) + b"".join(cpixel(c) for c in flat)
    if sub == 1:
        assert all(c == flat[0] for c in flat)
        return u8(1) + cpixel(flat[0])
    if 2 <= sub <= 16:
        assert len(palette) == sub
        bits = 1 if sub == 2 else 2 if sub <= 4 else 4
        out = u8(sub) + b"".join(cpixel(c) for c in palette)
        for row in pixels:
            acc, nbits, row_bytes = 0, 0, b""
            for c in row:
                acc = (acc << bits) | palette.index(c)
                nbits += bits
                if nbits == 8:
                    row_bytes += u8(acc)
                    acc, nbits = 0, 0
            if nbits:
                row_bytes += u8(acc << (8 - nbits))
            assert len(row_bytes) == (w * bits + 7) // 8
            out += row_bytes
        return out
    runs = []
    for c in flat:
        if runs and runs[-1][0] == c:
            runs[-1][1] += 1
        else:
            runs.append([c, 1])
    if sub == 128:
        return u8(128) + b"".join(cpixel(c) + zrle_run_length(n) for c, n in runs)
    assert 130 <= sub <= 255 and len(palette) == sub - 128
    out = u8(sub) + b"".join(cpixel(c) for c in palette)
    for c, n in runs:
        index = palette.index(c)
        out += u8(index) if n == 1 else u8(index | 0x80) + zrle_run_length(n)
    return out


def zrle_rect(image, stream, x, y, tiles):
    """tiles: dict (tx, ty) -> (pixels, sub, palette), covering the rect in 64x64 tiles."""
    w = sum(len(tiles[(tx, 0)][0][0]) for tx in range(max(k[0] for k in tiles) + 1))
    h = sum(len(tiles[(0, ty)][0]) for ty in range(max(k[1] for k in tiles) + 1))
    data = b""
    for ty in range((h + 63) // 64):
        for tx in range((w + 63) // 64):
            pixels, sub, palette = tiles[(tx, ty)]
            assert len(pixels[0]) == min(64, w - 64 * tx) and len(pixels) == min(64, h - 64 * ty)
            image.blit(x + 64 * tx, y + 64 * ty, pixels)
            data += zrle_tile(pixels, sub, palette)
    compressed = stream.compress(data) + stream.flush(zlib.Z_SYNC_FLUSH)
    return rect_header(x, y, w, h, ZRLE) + u32(len(compressed)) + compressed


def single_tile(rng_pixels, sub, palette=None):
    return {(0, 0): (rng_pixels, sub, palette)}


# --- Tight --------------------------------------------------------------------------------------

def compact_length(n):
    assert 0 <= n < 1 << 22
    out = [n & 0x7F]
    if n > 0x7F:
        out[0] |= 0x80
        out.append((n >> 7) & 0x7F)
        if n > 0x3FFF:
            out[1] |= 0x80
            out.append(n >> 14)
    return bytes(out)


class TightStreams:
    def __init__(self):
        self.streams = [zlib.compressobj(6) for _ in range(4)]

    def reset(self, index):
        self.streams[index] = zlib.compressobj(6)

    def data(self, index, raw):
        if len(raw) < 12:
            return raw
        compressed = self.streams[index].compress(raw) + self.streams[index].flush(zlib.Z_SYNC_FLUSH)
        return compact_length(len(compressed)) + compressed


def tight_control(stream, explicit_filter, resets):
    return u8((stream << 4) | (0x40 if explicit_filter else 0) | resets)


def apply_resets(streams, resets):
    for i in range(4):
        if resets & (1 << i):
            streams.reset(i)


def tight_fill(image, x, y, w, h, colour, streams=None, resets=0):
    if streams:
        apply_resets(streams, resets)
    image.blit(x, y, solid(colour, w, h))
    return rect_header(x, y, w, h, TIGHT) + u8(0x80 | resets) + tpixel(colour)


def tight_copy(image, streams, x, y, pixels, stream, explicit=True, resets=0):
    apply_resets(streams, resets)
    image.blit(x, y, pixels)
    h, w = len(pixels), len(pixels[0])
    raw = b"".join(tpixel(c) for row in pixels for c in row)
    body = tight_control(stream, explicit, resets) + (u8(0) if explicit else b"")
    return rect_header(x, y, w, h, TIGHT) + body + streams.data(stream, raw)


def tight_palette(image, streams, x, y, pixels, palette, stream, resets=0):
    apply_resets(streams, resets)
    image.blit(x, y, pixels)
    h, w = len(pixels), len(pixels[0])
    if len(palette) == 2:
        raw = b""
        for row in pixels:
            acc, nbits = 0, 0
            for c in row:
                acc = (acc << 1) | palette.index(c)
                nbits += 1
                if nbits == 8:
                    raw += u8(acc)
                    acc, nbits = 0, 0
            if nbits:
                raw += u8(acc << (8 - nbits))
    else:
        raw = bytes(palette.index(c) for row in pixels for c in row)
    body = (tight_control(stream, True, resets) + u8(1) + u8(len(palette) - 1)
            + b"".join(tpixel(c) for c in palette))
    return rect_header(x, y, w, h, TIGHT) + body + streams.data(stream, raw)


def tight_gradient(image, streams, x, y, pixels, stream, resets=0):
    apply_resets(streams, resets)
    image.blit(x, y, pixels)
    h, w = len(pixels), len(pixels[0])
    raw = bytearray()
    for j in range(h):
        for i in range(w):
            for c in range(3):
                left = pixels[j][i - 1][c] if i > 0 else 0
                up = pixels[j - 1][i][c] if j > 0 else 0
                up_left = pixels[j - 1][i - 1][c] if i > 0 and j > 0 else 0
                prediction = min(255, max(0, left + up - up_left))
                raw.append((pixels[j][i][c] - prediction) & 0xFF)
    body = tight_control(stream, True, resets) + u8(2)
    return rect_header(x, y, w, h, TIGHT) + body + streams.data(stream, bytes(raw))


def tight_jpeg(image, x, y, pixels):
    h, w = len(pixels), len(pixels[0])
    ppm = b"P6\n%d %d\n255\n" % (w, h) + b"".join(tpixel(c) for row in pixels for c in row)
    with tempfile.TemporaryDirectory() as tmp:
        source = os.path.join(tmp, "in.ppm")
        with open(source, "wb") as f:
            f.write(ppm)
        jpeg = subprocess.run(["cjpeg", "-quality", "90", "-sample", "1x1", "-baseline", source],
                              check=True, capture_output=True).stdout
        jpeg_path = os.path.join(tmp, "in.jpg")
        with open(jpeg_path, "wb") as f:
            f.write(jpeg)
        decoded = subprocess.run(["djpeg", "-pnm", jpeg_path], check=True, capture_output=True).stdout
    header_end = 0
    for _ in range(3):  # P6, size, maxval lines
        header_end = decoded.index(b"\n", header_end) + 1
    rgb = decoded[header_end:]
    assert len(rgb) == 3 * w * h
    image.blit(x, y, [[tuple(rgb[3 * (j * w + i):3 * (j * w + i) + 3]) for i in range(w)] for j in range(h)])
    return rect_header(x, y, w, h, TIGHT) + u8(0x90) + compact_length(len(jpeg)) + jpeg


# --- Vectors ------------------------------------------------------------------------------------

def vector_raw_copyrect():
    rng = LCG(1)
    image = Image(40, 30)
    s = update_header(2) + raw_rect(image, 0, 0, noise(rng, 40, 30)) + raw_rect(image, 3, 4, noise(rng, 5, 2))
    s += update_header(1) + copy_rect(image, 2, 3, 5, 7, 20, 15)           # overlap, moving down-right
    s += update_header(1) + copy_rect(image, 10, 10, 8, 6, 20, 15)         # overlap, moving up-left
    s += update_header(2) + copy_rect(image, 0, 20, 3, 20, 30, 5) + copy_rect(image, 6, 25, 1, 25, 30, 4)  # same rows
    s += update_header(1) + copy_rect(image, 30, 0, 0, 0, 10, 10)          # disjoint
    return ("raw_copyrect", 40, 30, s, image, 5, 0)


def vector_zrle():
    rng = LCG(2)
    image = Image(200, 140)
    stream = zlib.compressobj(6)
    p2, p3, p4, p5, p16 = (palette_of(rng, n) for n in (2, 3, 4, 5, 16))
    p127 = palette_of(rng, 127)
    p2rle = palette_of(rng, 2)
    s = update_header(9)
    # A 70 x 68 rect: tiles 64x64, 6x64, 64x4, 6x4 (partial edge tiles).
    s += zrle_rect(image, stream, 0, 0, {
        (0, 0): (noise(rng, 64, 64), 0, None),
        (1, 0): (solid((12, 200, 99), 6, 64), 1, None),
        (0, 1): (from_palette(rng, p2, 64, 4), 2, p2),
        (1, 1): (from_palette(rng, p3, 6, 4), 3, p3),
    })
    s += zrle_rect(image, stream, 80, 0, single_tile(from_palette(rng, p4, 13, 9), 4, p4))
    s += zrle_rect(image, stream, 100, 0, single_tile(from_palette(rng, p5, 17, 11), 5, p5))
    s += zrle_rect(image, stream, 120, 0, single_tile(from_palette(rng, p16, 33, 20), 16, p16))
    s += zrle_rect(image, stream, 80, 20, single_tile(from_palette(rng, p2, 7, 5), 2, p2))
    # Plain RLE with runs longer than 255 that cross tile rows.
    rle = [[(1, 2, 3)] * 64 for _ in range(40)]
    for j in range(40):
        for i in range(64):
            k = j * 64 + i
            rle[j][i] = (9, 9, 9) if k < 600 else (200, 1, 50) if k < 601 else (7, 77, 177) if k < 1400 else \
                ((k // 37) & 0xFF, 3, 4)
    s += zrle_rect(image, stream, 0, 80, single_tile(rle, 128))
    # Palette RLE, 2 colours: single pixels and runs.
    s += zrle_rect(image, stream, 70, 80, single_tile(from_palette(rng, p2rle, 50, 30, run_bias=5), 130, p2rle))
    # Palette RLE, 127 colours (subencoding 255).
    s += zrle_rect(image, stream, 130, 80, single_tile(from_palette(rng, p127, 64, 50, run_bias=3), 255, p127))
    # An empty rectangle still carries a (zero-tile) zlib block.
    empty = stream.compress(b"") + stream.flush(zlib.Z_SYNC_FLUSH)
    s += rect_header(5, 5, 0, 0, ZRLE) + u32(len(empty)) + empty
    # Second update on the same stream, repeating earlier content (deflate back-references).
    s += update_header(1) + zrle_rect(image, stream, 150, 30, single_tile([row[:40] for row in rle[:40]], 128))
    return ("zrle_subencodings", 200, 140, s, image, 2, 0)


def vector_tight():
    rng = LCG(3)
    image = Image(120, 90)
    streams = TightStreams()
    p2, p6, p256 = palette_of(rng, 2), palette_of(rng, 6), palette_of(rng, 256)
    rects = [
        tight_fill(image, 0, 0, 20, 10, (10, 20, 30)),
        tight_copy(image, streams, 20, 0, noise(rng, 3, 1), 0, explicit=False),        # 9 bytes: no zlib
        tight_copy(image, streams, 0, 10, noise(rng, 30, 20), 0),                        # stream 0
        tight_palette(image, streams, 30, 10, from_palette(rng, p2, 13, 7), p2, 1),     # 1 bit, 13 wide
        tight_palette(image, streams, 50, 0, from_palette(rng, p2, 5, 2), p2, 1),       # 2 bytes: no zlib
        tight_palette(image, streams, 60, 10, from_palette(rng, p6, 25, 15), p6, 2),
        tight_palette(image, streams, 0, 40, from_palette(rng, p256, 40, 20), p256, 2),
        tight_gradient(image, streams, 40, 40, smooth(40, 30, 17), 3),
        tight_copy(image, streams, 85, 0, noise(rng, 30, 20), 0),                        # stream 0 again
    ]
    s = update_header(len(rects)) + b"".join(rects)
    rects = [
        tight_palette(image, streams, 90, 30, from_palette(rng, p2, 21, 9), p2, 1, resets=0b0010),
        tight_fill(image, 0, 70, 30, 20, (240, 230, 220), streams, resets=0b1111),
        tight_gradient(image, streams, 30, 70, smooth(50, 20, 99), 3),
        tight_copy(image, streams, 82, 60, noise(rng, 38, 30), 0),
    ]
    s += update_header(len(rects)) + b"".join(rects)
    return ("tight_modes", 120, 90, s, image, 2, 0)


def vector_tight_jpeg():
    rng = LCG(4)
    image = Image(48, 32)
    pixels = smooth(32, 24, 40)
    s = update_header(2) + tight_fill(image, 0, 0, 48, 32, (0, 90, 180)) + tight_jpeg(image, 8, 4, pixels)
    return ("tight_jpeg", 48, 32, s, image, 1, 4)


def vector_desktop_size():
    rng = LCG(5)
    image = Image(16, 12)
    s = update_header(1) + raw_rect(image, 0, 0, noise(rng, 16, 12))
    image = image.resized(24, 10)
    s += update_header(2) + rect_header(0, 0, 24, 10, DESKTOP_SIZE) + raw_rect(image, 16, 0, noise(rng, 8, 10))
    return ("desktop_size", 16, 12, s, image, 2, 0)


def vector_extended_desktop_size():
    rng = LCG(6)
    image = Image(16, 12)
    s = update_header(1) + raw_rect(image, 0, 0, noise(rng, 16, 12))
    screen = u32(1) + u16(0) + u16(0) + u16(20) + u16(14) + u32(0)
    # Status 3 (y): a failed client request, the size does not change.
    s += update_header(1) + rect_header(1, 3, 99, 99, EXT_DESKTOP_SIZE) + u8(1) + b"\0\0\0" + screen
    image = image.resized(20, 14)
    s += update_header(2) + rect_header(0, 0, 20, 14, EXT_DESKTOP_SIZE) + u8(1) + b"\0\0\0" + screen
    s += raw_rect(image, 0, 12, noise(rng, 20, 2))
    return ("extended_desktop_size", 16, 12, s, image, 3, 0)


def swift_literal(data):
    text = base64.b64encode(data).decode()
    lines = [text[i:i + 100] for i in range(0, len(text), 100)] or [""]
    body = "\n".join("            " + line for line in lines)
    return '"""\n' + body + '\n            """'


def main():
    out = sys.stdout
    out.write("// GENERATED by Tests/RFBKitTests/Vectors/generate_decoder_vectors.py — do not edit.\n")
    out.write("// Encoded with Python zlib and libjpeg-turbo (cjpeg/djpeg), independently of RFBKit.\n\n")
    out.write("enum DecoderVectors {\n    static let all: [DecoderVector] = [\n")
    for name, width, height, stream, image, updates, tolerance in (
            vector_raw_copyrect(), vector_zrle(), vector_tight(), vector_tight_jpeg(),
            vector_desktop_size(), vector_extended_desktop_size()):
        out.write(f"        DecoderVector(\n            name: \"{name}\", width: {width}, height: {height},\n")
        out.write(f"            expectedWidth: {image.width}, expectedHeight: {image.height}, "
                  f"updates: {updates}, tolerance: {tolerance},\n")
        out.write(f"            stream: {swift_literal(stream)},\n")
        out.write(f"            expectedRGB: {swift_literal(zlib.compress(image.rgb_bytes(), 9))}),\n")
    out.write("    ]\n}\n")


if __name__ == "__main__":
    main()
