import Foundation
import Testing
@testable import RFBKit

/// T3.7 / PRD acceptance criterion 4 without Docker: an in-process server shaped like the Anthropic
/// computer use reference container, whose `x11vnc -nopw -rfbport 5900` serves a 1024 × 768 Xvfb
/// display with no password (TRD › External services). Live check: `Tests/RFBKitTests/Captures/README.md`.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AnthropicVMLoopbackTests {
    static let timeout = Duration.seconds(30)
    static let banner = Array("RFB 003.008\n".utf8)

    /// KeyEvent (RFC 6143 §7.5.4) written out by hand, so the wire format is checked independently
    /// of `ClientMessage.wireBytes`: type 4, down flag, 2 padding bytes, U32 keysym.
    static func keyEvent(_ down: Bool, _ keysym: UInt32) -> [UInt8] {
        [4, down ? 1 : 0, 0, 0,
         UInt8(keysym >> 24), UInt8(truncatingIfNeeded: keysym >> 16),
         UInt8(truncatingIfNeeded: keysym >> 8), UInt8(truncatingIfNeeded: keysym)]
    }

    /// Typing "Hi" then tapping ⌘ and ⌥ on a Mac keyboard, as `SessionInputController` hands them over.
    static func typedOnMac() -> [ClientMessage] {
        var translator = InputTranslator(profile: .x11)
        var messages: [ClientMessage] = []
        messages += translator.flagsChanged(KeyInput(keyCode: 0x38, modifierFlags: [.shift, .leftShift]))
        messages += translator.keyDown(KeyInput(keyCode: 0x04, characters: "H", charactersIgnoringModifiers: "H",
                                                modifierFlags: [.shift, .leftShift]))
        messages += translator.keyUp(KeyInput(keyCode: 0x04, modifierFlags: [.shift, .leftShift]))
        messages += translator.flagsChanged(KeyInput(keyCode: 0x38))
        messages += translator.keyDown(KeyInput(keyCode: 0x22, characters: "i"))
        messages += translator.keyUp(KeyInput(keyCode: 0x22))
        messages += translator.flagsChanged(KeyInput(keyCode: 0x37, modifierFlags: [.command, .leftCommand]))
        messages += translator.flagsChanged(KeyInput(keyCode: 0x37))
        messages += translator.flagsChanged(KeyInput(keyCode: 0x3A, modifierFlags: [.option, .leftOption]))
        messages += translator.flagsChanged(KeyInput(keyCode: 0x3A))
        return messages
    }

    /// X11 keysyms: Shift_L, H, i, Super_L (⌘), Alt_L (⌥).
    static let expectedKeys: [(Bool, UInt32)] = [
        (true, 0xFFE1), (true, 0x48), (false, 0x48), (false, 0xFFE1),
        (true, 0x69), (false, 0x69),
        (true, 0xFFEB), (false, 0xFFEB),
        (true, 0xFFE9), (false, 0xFFE9),
    ]

    @Test func noPasswordServerShowsItsDesktopAndReceivesTyping() async throws {
        let width: UInt16 = 1024, height: UInt16 = 768
        let update = FramebufferMessage.update(FramebufferMessage.raw(0, 0, 2, 2, b: 0x30, g: 0x20, r: 0x10))
        let keyBytes = Self.expectedKeys.flatMap { Self.keyEvent($0.0, $0.1) }
        let server = try await FakeRFBServer(script: [
            .send(Self.banner), .receive(12),
            .send([1, 1]), .receive(1),                    // x11vnc -nopw: security type None only
            .send(ServerMessage.securityResult(0)), .receive(1),
            .send(ServerMessage.serverInit(width: width, height: height, name: "computeruse:1")),
            .receive(SessionLoopbackTests.openingLength),
            .send(update),
            .receive(keyBytes.count),
            .expectClose,
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        let result = try await connection.open(credentials: .none, timeout: Self.timeout)
        #expect(result.securityType == 1)
        #expect(result.serverInit.width == width && result.serverInit.height == height)
        // No automatic request: nothing may interleave with the key events below.
        let stream = try await connection.startSession(requestUpdatesAutomatically: false)
        var iterator = stream.makeAsyncIterator()
        guard case .framebufferUpdate(let first) = try await iterator.next() else {
            Issue.record("expected the desktop's first update")
            await connection.close()
            return
        }
        #expect(first.regions.first?.pixels == [UInt32](repeating: 0xFF10_2030, count: 4))

        try await connection.send(Self.typedOnMac())
        // `send` returns once the bytes are handed to the socket; the close flushes them, then the
        // script sees the end of the stream.
        await connection.close()
        let received = try await server.received(within: .seconds(20))
        #expect(received.count == 6)
        #expect(received.prefix(3) == [Self.banner, [1], [1]])   // version, type None, ClientInit shared
        #expect(received[4] == keyBytes)
        #expect(received[5] == [])
    }

    /// The x11vnc variant started with `-passwd`: type 2 only, and the machine has no password. The
    /// client stops before choosing a type, with the error the app shows as "This server needs a
    /// password" + Edit credentials.
    @Test func passwordOnlyServerWithoutPasswordNeedsCredentials() async throws {
        let server = try await FakeRFBServer(script: [
            .send(Self.banner), .receive(12),
            .send([1, 2]),
            .expectClose,
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        await #expect(throws: RFBError.credentialsRequired(securityType: 2)) {
            _ = try await connection.open(credentials: .none, timeout: Self.timeout)
        }
        #expect(await connection.isOpen == false)
        let received = try await server.received(within: .seconds(20))
        #expect(received == [Self.banner, []])   // no security type byte was ever sent
    }

    /// Security type choice for what x11vnc offers: `-nopw` → [1]; `-passwd` → [2]; some builds list
    /// both. A password is used only when type 2 is offered; an empty one never reaches RFBKit (the
    /// app maps it to `nil`, `RFBCredentials(kind:username:password:)`).
    @Test func x11vncSecurityTypeChoice() throws {
        let password = RFBCredentials(password: "pw")
        #expect(try RFBHandshake.selectSecurityType(offered: [1], credentials: .none) == 1)
        #expect(try RFBHandshake.selectSecurityType(offered: [1], credentials: password) == 1)
        #expect(try RFBHandshake.selectSecurityType(offered: [1, 2], credentials: .none) == 1)
        #expect(try RFBHandshake.selectSecurityType(offered: [1, 2], credentials: password) == 2)
        #expect(try RFBHandshake.selectSecurityType(offered: [2], credentials: password) == 2)
        #expect(throws: RFBError.credentialsRequired(securityType: 2)) {
            try RFBHandshake.selectSecurityType(offered: [2], credentials: .none)
        }
    }

    /// The typed keys, as decoded by the server: X11 keysyms (Super for ⌘, Alt for ⌥), never the
    /// Apple profile's Alt/Meta.
    @Test func macTypingBecomesX11Keysyms() {
        let expected = Self.expectedKeys.map { ClientMessage.keyEvent(down: $0.0, key: $0.1) }
        #expect(Self.typedOnMac() == expected)
    }
}
