# Real handshake captures

No capture is committed yet. `HandshakeTests.swift` uses hand-built RFC 6143 streams, and the generated
vectors cover the Apple DH math (including the 4096-bit group that macOS 26 uses). Record real captures
with the `rfb-probe` tool.

## Recording a capture

From `Packages/RFBKit`, on the same LAN as the host:

```bash
# Banner and security types only (no credentials are sent):
swift run rfb-probe 192.168.100.96 --capture Tests/RFBKitTests/Captures/new
# Type 30 failure path, with a made-up user name and a random wrong password:
swift run rfb-probe 192.168.100.96 --user rfbprobe-nouser --wrong-password --capture Tests/RFBKitTests/Captures/new
# Type 30 success, with a throwaway macOS account (the password is read without echo):
swift run rfb-probe 192.168.100.96 --user <throwaway> --password-prompt --capture Tests/RFBKitTests/Captures/new
```

Each run writes two files:
- `<timestamp>-server.bin` holds the server → client bytes only. The client's bytes are never recorded,
  because they carry the encrypted credentials and the client public key.
- `<timestamp>-summary.json` holds the banner, the offered security types, the chosen type, the Apple DH
  generator and key length, the ServerInit fields and the error.

Rename the files (e.g. `macos-<version>-type30-failure.bin`) before committing them. Use `--port N` for a
port other than 5900, and `--password-env VAR` to read the password from an environment variable.

Don't hammer a real machine: macOS rate-limits failed logins.

## What minim6 (macOS 26) sends

- Banner `RFB 003.889`, security types `[30, 33, 36, 2, 35]`.
- Type 30: generator 5, key length 512, i.e. the RFC 3526 group 16 (4096-bit) prime.
- After a failed login, the 3.8 failure reason (`Authentication or authorization failure`) is followed by
  one extra NUL byte, which its length field does not count.

## Rules

Never commit a capture of a real account's credentials. Use a throwaway macOS account and password, and
note them in the test so the capture can be replayed. The ARD client bytes depend on random values, so
compare the server-side bytes and the parse results, not the client's ciphertext.

These files are excluded from the test target in `Package.swift`. Switch the folder to
`resources: [.copy("Captures")]` when the first capture is added.

## Decoding a real frame

`--frame FILE.png` authenticates, starts a session, decodes updates until every pixel has been written once, and saves the framebuffer as a PNG. `--encodings` restricts the offered encodings (`tight`, `zrle`, `copyrect`, `raw`; pseudo-encodings are always added) so each decoder can be checked against a real server. With `--frame`, the capture also contains the screen contents: keep it local.

```
swift run rfb-probe <host> --user NAME --password-prompt --frame ~/Desktop/frame-tight.png --encodings tight,raw --capture DIR
```
