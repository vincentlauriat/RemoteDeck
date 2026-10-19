# Auth test vectors

`generate_auth_vectors.py` produces `../AuthVectors.swift` (VNC DES responses, modPow table, Apple DH
exchanges) with Python's `pow`/`hashlib` and the OpenSSL CLI, independently of RFBKit. Regenerate from
`Packages/RFBKit`:

```bash
python3 Tests/RFBKitTests/Vectors/generate_auth_vectors.py > Tests/RFBKitTests/AuthVectors.swift
```

Requires OpenSSL 3 with the legacy provider (DES), e.g. Homebrew `openssl@3`.
