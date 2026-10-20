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
