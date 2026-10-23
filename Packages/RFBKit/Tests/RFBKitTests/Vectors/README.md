# Auth test vectors

`generate_auth_vectors.py` produces `../AuthVectors.swift` (VNC DES responses, modPow table, Apple DH
exchanges) with Python's `pow`/`hashlib` and the OpenSSL CLI, independently of RFBKit. Regenerate from
`Packages/RFBKit`:

```bash
python3 Tests/RFBKitTests/Vectors/generate_auth_vectors.py > Tests/RFBKitTests/AuthVectors.swift
```

Requires OpenSSL 3 with the legacy provider (DES), e.g. Homebrew `openssl@3`.

# Decoder test vectors

`generate_decoder_vectors.py` produces `../DecoderVectors.swift`: server → client streams after
ServerInit (Raw, CopyRect with overlaps, every ZRLE tile subencoding on one persistent zlib stream,
every Tight mode and filter with stream resets, Tight JPEG, DesktopSize, ExtendedDesktopSize) and the
framebuffer each one must produce. It uses Python's `zlib` and the libjpeg-turbo CLI (`cjpeg`/`djpeg`,
e.g. Homebrew `jpeg-turbo`), independently of RFBKit, and is deterministic. Regenerate from
`Packages/RFBKit`:

```bash
python3 Tests/RFBKitTests/Vectors/generate_decoder_vectors.py > Tests/RFBKitTests/DecoderVectors.swift
```

# Clipboard test vectors

`generate_clipboard_vectors.py` produces `../ClipboardVectors.swift`: legacy ServerCutText /
ClientCutText (Latin-1, LF) and Extended Clipboard messages (caps, notify, request, peek, provide as a
complete and as a sync-flushed zlib stream, text + HTML, plus hostile ones: zlib bomb, size past the
end, truncated caps, corrupt zlib), written from RFC 6143 and the rfbproto Extended Clipboard section
with Python's `zlib`, independently of RFBKit. Regenerate from `Packages/RFBKit`:

```bash
python3 Tests/RFBKitTests/Vectors/generate_clipboard_vectors.py > Tests/RFBKitTests/ClipboardVectors.swift
```
