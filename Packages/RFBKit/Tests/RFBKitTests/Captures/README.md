# Real handshake captures (placeholder)

No real capture yet: minim6 was not reachable when T2.5 was written, so every handshake test in
`HandshakeTests.swift` uses hand-built RFC 6143 streams.

When a macOS host is reachable, record the server → client bytes of a handshake (e.g. with
`tcpdump -w` on port 5900, then extract the TCP payload) and add them here as hex or binary files:

- `macos-<version>-type30-success.bin` / `-failure.bin`
- `macos-<version>-security-types.bin` (the banner and security-type list alone, to answer PRD open
  question 3)

Never commit a capture of a real account's credentials: use a throwaway macOS account and password, and
note them in the test so the capture can be replayed (the ARD client bytes depend on random values, so
compare server-side bytes and parse results, not the client's ciphertext).

These files are excluded from the test target in `Package.swift`; switch the folder to
`resources: [.copy("Captures")]` when the first capture is added.
