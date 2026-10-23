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

Real captures stay local: `Captures/new/` is git-ignored and they are not committed (decision of 2026-10-20); record findings in `MEMORY.md` instead. Use `--port N` for a
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

## Anthropic computer use container (T3.7, acceptance criterion 4)

Facts below come from [anthropic-quickstarts/computer-use-demo](https://github.com/anthropics/anthropic-quickstarts/tree/main/computer-use-demo)
(README, `Dockerfile`, `image/x11vnc_startup.sh`, `image/entrypoint.sh`), read on 2026-10-23. Nothing was pulled or run.

- VNC is `x11vnc -display $DISPLAY -forever -shared -wait 50 -rfbport 5900 -nopw`. There is no password, so the
  container should offer security type 1 only. This is inferred from `-nopw`; step 2 below confirms it.
- The desktop is Xvfb `:1` at 1024 × 768 × 24 with mutter and tint2 on Ubuntu 22.04. The image also has
  Firefox ESR, xterm, gedit, LibreOffice and galculator. The scripts set no keyboard layout.
- Ports: 5900 (VNC), 6080 (noVNC, `http://localhost:6080/vnc.html`), 8501 (Streamlit) and 8080 (combined UI).
- `ANTHROPIC_API_KEY`: `entrypoint.sh` never checks it, so the desktop and VNC start without it. Only the
  Claude agent loop in the Streamlit UI needs it, which this check doesn't use. What Streamlit does without
  a key was not checked.
- Image: `ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest`, index digest
  `sha256:b608f4197682b6e93d1cfc2c850ed4e150b7ad4821b84ca1630072a7365b6625` (2026-10-23). The download is
  about 1.2 GB compressed: arm64 is 1.16 GB and amd64 is 1.20 GB, summed from the layer sizes in the GHCR
  manifests. It takes more space once unpacked. The tag moves, so check the size before you pull:
  `docker manifest inspect -v ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest`.
- Security: the upstream README publishes `-p 5900:5900` on every interface, and that VNC has no password.
  Always bind to `127.0.0.1`.

### Running it for RemoteDeck

This Mac's own Screen Sharing already listens on 5900, so map the container's 5900 to host port **5901**.
AC4's "port 5900" is the container side.

```bash
lsof -nP -iTCP:5901 -sTCP:LISTEN          # must print nothing
docker run --rm -it --name computer-use \
    -p 127.0.0.1:5901:5900 \
    -p 127.0.0.1:6080:6080 \
    ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest
# Add `-e ANTHROPIC_API_KEY` (and `-p 127.0.0.1:8080:8080 -p 127.0.0.1:8501:8501`) only to also try the agent UI.
# GHCR has an arm64 image, so Apple silicon needs no --platform flag.
```

Wait for `Computer Use Demo is ready!`, then check the desktop at `http://localhost:6080/vnc.html`.

### AC4 checklist

1. **Before the pull:** check the size with `docker manifest inspect -v …` (see above) and check free disk space.
2. **Handshake (T1.4 record),** from `Packages/RFBKit`:
   `swift run rfb-probe 127.0.0.1 --port 5901 --capture Tests/RFBKitTests/Captures/new`.
   Expect banner `RFB 003.008`, types `[1]` and chosen type 1. If it also offers 2, note it.
3. **A real frame per decoder:**
   `swift run rfb-probe 127.0.0.1 --port 5901 --frame ~/Desktop/cu-tight.png --encodings tight,raw`, then the
   same with `zrle,raw`. Both PNGs should show the 1024 × 768 desktop with the tint2 panel. Keep these files
   local, because they contain the screen.
4. **In RemoteDeck:** Add machine (⌘N) with kind **Anthropic VM** (sparkles icon), name `Computer use`,
   host `127.0.0.1`, port `5901` and an empty password. There is no user field. Press Test, expect
   "Reachable, auth OK", then Save. The sidebar row shows the sparkles icon and `127.0.0.1:5901`.
5. **Connect** (double-click). The desktop should appear within 5 s, and Session History records the connect time.
6. **Typing** (AC4). Open xterm from the tint2 panel, click into it, and type
   `echo Hello 123 ;:!?` then Return. The line should echo exactly. Then:
   - AZERTY characters: `é è à ç @ # { } [ ] | ~ €`. Characters typed with ⌥ go out with Alt held (TRD › Input),
     so xterm may print them with an ESC prefix. Accented characters depend on the container's US keymap and on
     x11vnc's keysym handling. Note what you see; the profile does not change in T3.7.
   - Shortcuts: on Linux, copy and paste are **⌃C / ⌃V** (in gedit), and ⌃C interrupts `sleep 30` in xterm.
     ⌘ is sent as Super (⌘C becomes Super+C, which Linux apps ignore). ⌘ alone may trigger mutter's overview.
   - Mouse: click, drag a window, scroll in Firefox.
   - ⌃⌥⌘R releases the keyboard.
7. **Missing password banner** (optional). Restart x11vnc with a password. This recipe is unverified, because
   `x11vnc_startup.sh` runs a watchdog that restarts the `-nopw` server:
   `docker exec computer-use bash -c 'pkill -f x11vnc_startup; pkill x11vnc; sleep 1; x11vnc -display :1 -forever -shared -rfbport 5900 -passwd test -bg'`.
   Connect with the password empty. Expect "This server needs a password" with Edit credentials. Enter
   `test`, Save, and the session retries and connects.
8. **Clean up:** `docker stop computer-use`, then `docker rmi ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest`
   to get the disk space back. Keep the capture local (`Captures/new/` is git-ignored) and put the results in
   `MEMORY.md`. Real captures are not committed (decision of 2026-10-20).

Without Docker, `AnthropicVMLoopbackTests` plays this server in-process. It sends banner 3.8, types [1]
(and a [2]-only variant), ServerInit at 1024 × 768 and one update, then checks the KeyEvent bytes for "Hi",
⌘ and ⌥ under the `.x11` profile.
