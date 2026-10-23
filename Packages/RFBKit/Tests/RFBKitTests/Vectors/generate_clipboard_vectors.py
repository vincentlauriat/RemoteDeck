#!/usr/bin/env python3
"""Generate RFBKit clipboard test vectors independently of the Swift implementation.

Regenerate (from Packages/RFBKit):
    python3 Tests/RFBKitTests/Vectors/generate_clipboard_vectors.py > Tests/RFBKitTests/ClipboardVectors.swift

Sources, followed directly (nothing is shared with the Swift code):
- RFC 6143 §7.5.6 / §7.6.4: ClientCutText (type 6) and ServerCutText (type 3), U32 length,
  ISO 8859-1 text, LF line ends;
- rfbproto "Extended Clipboard Pseudo-Encoding" (0xC0A1E5CE): S32 length, negative = extended,
  abs(length) bytes of U32 flags (formats bits 0-15: text 0, rtf 1, html 2, dib 3, files 4; actions
  caps 24, request 25, peek 26, notify 27, provide 28) + data; caps data = one U32 max size per
  format bit set; provide data = a zlib stream of U32 size + bytes per format bit set, in bit order;
  text = UTF-8, CR LF line ends, terminating NUL counted in the size.
- zlib: Python's `zlib` (`compressobj` + `Z_SYNC_FLUSH` for the sync-flushed variant, as TigerVNC's
  ZlibOutStream writes it; `zlib.compress` for a complete stream).

Server vectors: the bytes of one server message and the text RFBKit must deliver (or none).
Client vectors: the exact bytes RFBKit must send; for a client provide, the inflated payload (the
compressed bytes depend on the zlib level, so the test inflates what RFBKit sent and compares).
"""

import base64
import struct
import zlib

TEXT, RTF, HTML = 1 << 0, 1 << 1, 1 << 2
CAPS, REQUEST, PEEK, NOTIFY, PROVIDE = 1 << 24, 1 << 25, 1 << 26, 1 << 27, 1 << 28


def legacy_server(text_bytes):
    return struct.pack(">B3xI", 3, len(text_bytes)) + text_bytes


def legacy_client(text_bytes):
    return struct.pack(">B3xI", 6, len(text_bytes)) + text_bytes


def extended(message_type, flags, data=b""):
    payload = struct.pack(">I", flags) + data
    return struct.pack(">B3xi", message_type, -len(payload)) + payload


def provide_payload(entries):
    """entries: list of (format bit, bytes), in bit order."""
    return b"".join(struct.pack(">I", len(data)) + data for _, data in entries)


def utf8_text(text):
    return text.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8") + b"\0"


def sync_flushed(data):
    deflater = zlib.compressobj()
    return deflater.compress(data) + deflater.flush(zlib.Z_SYNC_FLUSH)


def b64(data):
    return base64.b64encode(data).decode("ascii")


def swift_string(text):
    out = []
    for ch in text:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ord(ch) < 0x20 or ord(ch) > 0x7E:
            out.append("\\u{%X}" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


MULTILINE = "ligne 1\nligne 2 — café\n€ 😀"
server = []   # (name, bytes, expected text or None, expected message kind)

server.append(("legacy_latin1", legacy_server("café\nnaïve".encode("latin-1")), "café\nnaïve", "text"))
server.append(("caps_text_rtf_html",
               extended(3, CAPS | TEXT | RTF | HTML | REQUEST | PEEK | NOTIFY | PROVIDE,
                        struct.pack(">III", 20 << 20, 0, 0)),
               None, "caps"))
server.append(("notify_text", extended(3, NOTIFY | TEXT), None, "notify"))
server.append(("request_text", extended(3, REQUEST | TEXT), None, "request"))
server.append(("peek", extended(3, PEEK), None, "peek"))
server.append(("provide_complete_stream",
               extended(3, PROVIDE | TEXT, zlib.compress(provide_payload([(TEXT, utf8_text(MULTILINE))]))),
               MULTILINE, "text"))
server.append(("provide_sync_flushed",
               extended(3, PROVIDE | TEXT, sync_flushed(provide_payload([(TEXT, utf8_text(MULTILINE))]))),
               MULTILINE, "text"))
# Text followed by HTML: only the text is kept.
server.append(("provide_text_and_html",
               extended(3, PROVIDE | TEXT | HTML,
                        zlib.compress(provide_payload([(TEXT, utf8_text("x\ny")), (HTML, b"<b>x</b>\0")]))),
               "x\ny", "text"))
server.append(("provide_empty_text",
               extended(3, PROVIDE | TEXT, zlib.compress(provide_payload([(TEXT, b"\0")]))), "", "text"))
# Hostile: a zlib bomb (2 MiB of zeros inside a declared 2 MiB text), dropped without ending the session.
server.append(("provide_zlib_bomb",
               extended(3, PROVIDE | TEXT, zlib.compress(struct.pack(">I", 2 << 20) + b"A" * (2 << 20), 9)),
               None, "dropped"))
# Hostile: the text size points past the inflated data.
server.append(("provide_size_past_end",
               extended(3, PROVIDE | TEXT, zlib.compress(struct.pack(">I", 1000) + b"short\0")),
               None, "dropped"))
# Hostile: caps announcing three formats with one size.
server.append(("caps_truncated", extended(3, CAPS | TEXT | RTF | HTML, struct.pack(">I", 5)), None, "dropped"))
# Corrupt zlib data.
server.append(("provide_corrupt_zlib", extended(3, PROVIDE | TEXT, b"\x78\x9c\xff\xff\xff\xff"), None, "dropped"))

client = []   # (name, text, exact bytes or None, inflated payload or None)
client.append(("legacy_latin1_replaces_outside", "café €\r\nok", legacy_client(b"caf\xe9 ?\nok"), None))
client.append(("client_caps", None,
               extended(6, CAPS | TEXT | REQUEST | PEEK | NOTIFY | PROVIDE, struct.pack(">I", 1 << 20)), None))
client.append(("client_request_text", None, extended(6, REQUEST | TEXT), None))
client.append(("client_notify_text", None, extended(6, NOTIFY | TEXT), None))
client.append(("client_notify_none", None, extended(6, NOTIFY), None))
client.append(("client_provide_multiline", MULTILINE, None, provide_payload([(TEXT, utf8_text(MULTILINE))])))

print("// Generated by Vectors/generate_clipboard_vectors.py — do not edit.")
print("// Server messages and client messages for ServerCutText/ClientCutText and the Extended Clipboard.")
print()
print("import Testing")
print()
print("struct ServerClipboardVector: Sendable, CustomTestStringConvertible {")
print("    let name: String")
print("    let message: String  // base64")
print("    /// Text delivered to the app, if any.")
print("    let text: String?")
print("    /// text, caps, notify, request, peek or dropped.")
print("    let kind: String")
print("    var testDescription: String { name }")
print("}")
print()
print("struct ClientClipboardVector: Sendable {")
print("    let name: String")
print("    let text: String?")
print("    /// Exact bytes (base64), when deterministic.")
print("    let bytes: String?")
print("    /// The inflated provide payload (base64), for a provide.")
print("    let inflated: String?")
print("}")
print()
print("enum ClipboardVectors {")
print("    static let server: [ServerClipboardVector] = [")
for name, data, text, kind in server:
    t = "nil" if text is None else swift_string(text)
    print(f'        ServerClipboardVector(name: "{name}", message: "{b64(data)}", text: {t}, kind: "{kind}"),')
print("    ]")
print()
print("    static let client: [String: ClientClipboardVector] = [")
for name, text, data, inflated in client:
    t = "nil" if text is None else swift_string(text)
    d = "nil" if data is None else f'"{b64(data)}"'
    i = "nil" if inflated is None else f'"{b64(inflated)}"'
    print(f'        "{name}": ClientClipboardVector(name: "{name}", text: {t}, bytes: {d}, inflated: {i}),')
print("    ]")
print("}")
