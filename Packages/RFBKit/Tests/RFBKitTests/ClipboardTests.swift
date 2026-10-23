import Foundation
import Testing
import zlib
@testable import RFBKit

func base64Bytes(_ text: String) -> [UInt8] { [UInt8](Data(base64Encoded: text)!) }

/// One-shot libz `uncompress` of a whole zlib stream, independent of RFBKit's `Inflater`.
func uncompressAll(_ data: [UInt8], limit: Int = 4 << 20) -> [UInt8]? {
    var output = [UInt8](repeating: 0, count: limit)
    var length = uLongf(limit)
    guard zlib.uncompress(&output, &length, data, uLong(data.count)) == Z_OK else { return nil }
    return Array(output.prefix(Int(length)))
}

/// Splits an extended ClientCutText written by RFBKit: (flags, data after the flags).
func parseExtendedClient(_ bytes: [UInt8]) -> (flags: UInt32, data: [UInt8])? {
    guard bytes.count >= 12, bytes[0] == 6 else { return nil }
    let length = Int32(bitPattern: bytes[4..<8].reduce(0) { $0 << 8 | UInt32($1) })
    guard length < 0, Int(-length) == bytes.count - 8 else { return nil }
    return (bytes[8..<12].reduce(0) { $0 << 8 | UInt32($1) }, Array(bytes[12...]))
}

/// Server messages from the generated, independent vectors (ClipboardVectors.swift).
struct ClipboardDecoderTests {
    @Test(arguments: ClipboardVectors.server, Chunking.allCases)
    func decodesServerVector(vector: ServerClipboardVector, chunking: Chunking) throws {
        // A Bell after each message: a dropped message must not desynchronise the stream.
        let (_, events) = try decode(base64Bytes(vector.message) + [2], width: 8, height: 8, chunking: chunking)
        #expect(events.last == .bell)
        let messages = Array(events.dropLast())
        switch vector.kind {
        case "dropped":
            #expect(messages.isEmpty)
        case "text":
            var negotiation = ClipboardNegotiation(sharing: true)
            let texts = messages.compactMap { negotiation.handle($0).text }
            #expect(texts == [vector.text])
        case "caps":
            #expect(messages == [.extendedClipboard(.caps(
                flags: ExtendedClipboard.caps | 0x1F00_0007, maxSizes: [1: 20 << 20, 2: 0, 4: 0]))])
        case "notify":
            #expect(messages == [.extendedClipboard(.notify(formats: ExtendedClipboard.text))])
        case "request":
            #expect(messages == [.extendedClipboard(.request(formats: ExtendedClipboard.text))])
        case "peek":
            #expect(messages == [.extendedClipboard(.peek)])
        default:
            Issue.record("unknown kind \(vector.kind)")
        }
    }

    /// The length is an S32: negative lengths beyond the cap (Int32.min included) are skipped
    /// without buffering, and the stream goes on after them.
    @Test func oversizedExtendedMessagesAreSkipped() throws {
        var decoder = try ServerMessageDecoder(width: 8, height: 8)
        #expect(try decoder.receive([3, 0, 0, 0, 0x80, 0, 0, 0] + [UInt8](repeating: 0, count: 64)).isEmpty)
        #expect(decoder.bufferedCount == 0)

        let length = ExtendedClipboard.maxMessageLength + 1
        var stream: [UInt8] = [3, 0, 0, 0] + UInt32(bitPattern: -Int32(length)).bigEndianBytes
        stream += [UInt8](repeating: 0x41, count: length) + [2]
        let (skipping, events) = try decode(stream, width: 8, height: 8, chunking: .whole)
        #expect(events == [.bell])
        #expect(skipping.bufferedCount == 0)
    }

    /// Reserved flag bits (16–23, 29–31) do not hide the action.
    @Test func reservedFlagBitsAreIgnored() throws {
        let flags = ExtendedClipboard.request | ExtendedClipboard.text | 1 << 20 | 1 << 30
        let message: [UInt8] = [3, 0, 0, 0] + UInt32(bitPattern: -4).bigEndianBytes + flags.bigEndianBytes
        let (_, events) = try decode(message, width: 8, height: 8, chunking: .whole)
        #expect(events == [.extendedClipboard(.request(formats: ExtendedClipboard.text))])
    }

    @Test func extendedMessageShorterThanItsFlagsIsDropped() throws {
        let (_, events) = try decode([3, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFE, 0x10, 0x00, 2], width: 8, height: 8,
                                     chunking: .whole)
        #expect(events == [.bell])
    }
}

/// Client messages against the generated vectors, and the negotiation rules.
struct ClipboardNegotiationTests {
    static let serverCaps = RFBEvent.extendedClipboard(.caps(
        flags: ExtendedClipboard.caps | ExtendedClipboard.text | ExtendedClipboard.request | ExtendedClipboard.peek
            | ExtendedClipboard.notify | ExtendedClipboard.provide,
        maxSizes: [ExtendedClipboard.text: 20 << 20]))

    func vector(_ name: String) throws -> ClientClipboardVector {
        try #require(ClipboardVectors.client[name])
    }

    @Test func latin1PathReplacesCharactersOutsideLatin1() throws {
        let vector = try vector("legacy_latin1_replaces_outside")
        var negotiation = ClipboardNegotiation(sharing: true)
        let (messages, outcome) = negotiation.share(try #require(vector.text))
        #expect(messages.flatMap(\.wireBytes) == base64Bytes(try #require(vector.bytes)))
        // What the server holds, and so what an echo looks like: `?` for €, LF line ends.
        #expect(outcome == .sent(echo: "caf\u{E9} ?\nok"))
    }

    @Test func capsAreAnsweredWithTheClientCaps() throws {
        var negotiation = ClipboardNegotiation(sharing: true)
        let (replies, text) = negotiation.handle(Self.serverCaps)
        #expect(text == nil)
        #expect(replies.flatMap(\.wireBytes) == base64Bytes(try #require(vector("client_caps").bytes)))
        #expect(negotiation.usesExtended)
    }

    @Test func extendedProvideCarriesUTF8WithCRLFAndNUL() throws {
        let vector = try vector("client_provide_multiline")
        var negotiation = ClipboardNegotiation(sharing: true)
        _ = negotiation.handle(Self.serverCaps)
        let bytes = negotiation.share(try #require(vector.text)).messages.flatMap(\.wireBytes)
        let parsed = try #require(parseExtendedClient(bytes))
        #expect(parsed.flags == ExtendedClipboard.provide | ExtendedClipboard.text)
        #expect(uncompressAll(parsed.data) == base64Bytes(try #require(vector.inflated)))
    }

    @Test func notifyIsAnsweredWithARequestAndRequestWithTheSharedText() throws {
        var negotiation = ClipboardNegotiation(sharing: true)
        _ = negotiation.handle(Self.serverCaps)
        let notify = negotiation.handle(.extendedClipboard(.notify(formats: ExtendedClipboard.text)))
        #expect(notify.replies.flatMap(\.wireBytes) == base64Bytes(try #require(vector("client_request_text").bytes)))

        // Nothing shared yet: a peek gets an empty notify, a request a provide without text.
        let emptyPeek = negotiation.handle(.extendedClipboard(.peek))
        #expect(emptyPeek.replies.flatMap(\.wireBytes) == base64Bytes(try #require(vector("client_notify_none").bytes)))
        let emptyRequest = negotiation.handle(.extendedClipboard(.request(formats: ExtendedClipboard.text)))
        #expect(parseExtendedClient(emptyRequest.replies.flatMap(\.wireBytes))?.flags == ExtendedClipboard.provide)

        let text = try #require(vector("client_provide_multiline").text)
        _ = negotiation.share(text)
        let peek = negotiation.handle(.extendedClipboard(.peek))
        #expect(peek.replies.flatMap(\.wireBytes) == base64Bytes(try #require(vector("client_notify_text").bytes)))
        let request = negotiation.handle(.extendedClipboard(.request(formats: ExtendedClipboard.text)))
        let provide = try #require(parseExtendedClient(request.replies.flatMap(\.wireBytes)))
        #expect(uncompressAll(provide.data) == base64Bytes(try #require(vector("client_provide_multiline").inflated)))
    }

    /// A server whose text limit is 0 (rfbproto's recommendation) gets a notify, then asks.
    @Test func zeroUnsolicitedSizeSendsANotify() throws {
        var negotiation = ClipboardNegotiation(sharing: true)
        _ = negotiation.handle(.extendedClipboard(.caps(
            flags: ExtendedClipboard.caps | ExtendedClipboard.text | ExtendedClipboard.request
                | ExtendedClipboard.notify | ExtendedClipboard.provide,
            maxSizes: [ExtendedClipboard.text: 0])))
        #expect(negotiation.share("hello").messages.flatMap(\.wireBytes)
            == base64Bytes(try #require(vector("client_notify_text").bytes)))
    }

    @Test func sharingOffSendsAndDeliversNothing() throws {
        var negotiation = ClipboardNegotiation(sharing: false)
        #expect(negotiation.share("secret").messages.isEmpty)
        #expect(negotiation.share("secret").outcome == .notSharing)
        #expect(negotiation.handle(.serverCutText("remote")).text == nil)
        _ = negotiation.handle(Self.serverCaps)   // caps are still answered: that is protocol, not data
        #expect(negotiation.handle(.extendedClipboard(.notify(formats: ExtendedClipboard.text))).replies.isEmpty)
        #expect(negotiation.handle(.extendedClipboard(.provide(text: "remote"))).text == nil)
        let request = negotiation.handle(.extendedClipboard(.request(formats: ExtendedClipboard.text)))
        #expect(parseExtendedClient(request.replies.flatMap(\.wireBytes))?.flags == ExtendedClipboard.provide)

        // Turned off after sharing: the text is forgotten, a later request gets none.
        var later = ClipboardNegotiation(sharing: true)
        _ = later.handle(Self.serverCaps)
        _ = later.share("was shared")
        later.sharing = false
        let answer = later.handle(.extendedClipboard(.request(formats: ExtendedClipboard.text)))
        #expect(parseExtendedClient(answer.replies.flatMap(\.wireBytes))?.flags == ExtendedClipboard.provide)
    }

    @Test func textOverTheLimitIsNotSent() {
        var negotiation = ClipboardNegotiation(sharing: true)
        let big = String(repeating: "a", count: ServerMessageDecoder.maxCutTextLength + 1)
        #expect(negotiation.share(big).messages.isEmpty)
        #expect(negotiation.share(big).outcome == .tooLarge)
        #expect(negotiation.share(String(repeating: "a", count: ServerMessageDecoder.maxCutTextLength)).messages.count == 1)
    }

    @Test func lineEndConversions() {
        #expect(ClipboardText.toCRLF("a\nb\r\nc") == "a\r\nb\r\nc")
        #expect(ClipboardText.normalizedLF("a\r\nb\rc\r") == "a\nb\nc\n")
        // A lone CR is a line end too, the same way in both directions.
        #expect(ClipboardText.toCRLF("a\rb") == "a\r\nb")
        #expect(ClipboardText.toCRLF("x\r\r\ny") == "x\r\n\r\ny")
        #expect(ClipboardText.normalizedLF("x\r\r\ny") == "x\n\ny")
        #expect(ClipboardText.normalizedLF(ClipboardText.toCRLF("x\r\r\ny")) == ClipboardText.normalizedLF("x\r\r\ny"))
        #expect(ClipboardText.latin1Bytes("a\rb") == [0x61, 0x0A, 0x62])
    }

    /// The extended echo is the text with LF line ends, as the server's provide comes back.
    @Test func extendedEchoUsesLFLineEnds() {
        var negotiation = ClipboardNegotiation(sharing: true)
        _ = negotiation.handle(Self.serverCaps)
        #expect(negotiation.share("10 €\r\n").outcome == .sent(echo: "10 €\n"))
    }

    /// A server that takes unsolicited provides up to 4 bytes and has no notify: a longer text is not
    /// sent at all (it would be over its limit), and reported too large.
    @Test func overTheServerLimitWithoutNotifySendsNothing() {
        var negotiation = ClipboardNegotiation(sharing: true)
        _ = negotiation.handle(.extendedClipboard(.caps(
            flags: ExtendedClipboard.caps | ExtendedClipboard.text | ExtendedClipboard.request | ExtendedClipboard.provide,
            maxSizes: [ExtendedClipboard.text: 4])))
        #expect(negotiation.share("abc").messages.count == 1)   // 3 bytes + NUL fit
        let long = negotiation.share("abcd")
        #expect(long.messages.isEmpty)
        #expect(long.outcome == .tooLarge)
    }

    /// Received legacy text gets LF line ends as well.
    @Test func legacyTextIsNormalisedToLF() {
        var negotiation = ClipboardNegotiation(sharing: true)
        #expect(negotiation.handle(.serverCutText("a\r\nb")).text == "a\nb")
    }
}

/// Both clipboard paths end to end through `RFBConnection` and the in-process `FakeRFBServer`.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ClipboardLoopbackTests {
    static let timeout = Duration.seconds(30)

    static func connect(_ server: FakeRFBServer, sharing: Bool) async throws
        -> (RFBConnection, RFBSessionEvents.AsyncIterator) {
        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        _ = try await connection.open(credentials: .none, timeout: timeout)
        await connection.setClipboardSharing(sharing)
        let stream = try await connection.startSession(requestUpdatesAutomatically: false)
        return (connection, stream.makeAsyncIterator())
    }

    /// x11vnc-like server without the pseudo-encoding: Latin-1 both ways.
    @Test func latin1BothWays() async throws {
        let vector = try #require(ClipboardVectors.client["legacy_latin1_replaces_outside"])
        let expected = base64Bytes(try #require(vector.bytes))
        let legacy = try #require(ClipboardVectors.server.first { $0.name == "legacy_latin1" })
        let server = try await FakeRFBServer(script: SessionLoopbackTests.handshake(width: 4, height: 4) + [
            .receive(SessionLoopbackTests.openingLength),
            .send(base64Bytes(legacy.message)),
            .receive(expected.count),
            .expectClose,
        ])
        defer { server.stop() }
        let (connection, events) = try await Self.connect(server, sharing: true)
        var iterator = events
        #expect(try await iterator.next() == .serverCutText(try #require(legacy.text)))
        #expect(try await connection.shareClipboard(try #require(vector.text)) == .sent(echo: "caf\u{E9} ?\nok"))
        try await Task.sleep(for: .milliseconds(200))
        await connection.close()
        let received = try await server.received(within: .seconds(10))
        #expect(received.dropLast().last == expected)
    }

    /// A server with the Extended Clipboard: caps, notify → request → provide (server to client),
    /// then the client's provide, the server's request and peek.
    @Test func extendedBothWays() async throws {
        let text = try #require(ClipboardVectors.client["client_provide_multiline"]?.text)
        let inflated = base64Bytes(try #require(ClipboardVectors.client["client_provide_multiline"]?.inflated))
        let caps = try #require(ClipboardVectors.server.first { $0.name == "caps_text_rtf_html" })
        let notify = try #require(ClipboardVectors.server.first { $0.name == "notify_text" })
        let provide = try #require(ClipboardVectors.server.first { $0.name == "provide_sync_flushed" })
        let request = try #require(ClipboardVectors.server.first { $0.name == "request_text" })
        let peek = try #require(ClipboardVectors.server.first { $0.name == "peek" })
        let clientCaps = base64Bytes(try #require(ClipboardVectors.client["client_caps"]?.bytes))
        let clientRequest = base64Bytes(try #require(ClipboardVectors.client["client_request_text"]?.bytes))
        let clientNotify = base64Bytes(try #require(ClipboardVectors.client["client_notify_text"]?.bytes))
        // Only the length comes from RFBKit's own encoder (zlib output is not fixed); the content is
        // checked by inflating with libz below.
        let provideLength = ExtendedClipboard.provideMessage(text: text).wireBytes.count
        let server = try await FakeRFBServer(script: SessionLoopbackTests.handshake(width: 4, height: 4) + [
            .receive(SessionLoopbackTests.openingLength),
            .send(base64Bytes(caps.message)), .receive(clientCaps.count),
            .send(base64Bytes(notify.message)), .receive(clientRequest.count),
            .send(base64Bytes(provide.message)),
            .receive(provideLength),
            .send(base64Bytes(request.message)), .receive(provideLength),
            .send(base64Bytes(peek.message)), .receive(clientNotify.count),
            .expectClose,
        ])
        defer { server.stop() }
        let (connection, events) = try await Self.connect(server, sharing: true)
        var iterator = events
        #expect(try await iterator.next() == .serverCutText(try #require(provide.text)))
        #expect(try await connection.shareClipboard(text) == .sent(echo: text))
        try await Task.sleep(for: .milliseconds(300))
        await connection.close()
        let received = try await server.received(within: .seconds(10))
        // Handshake (3 blobs) and the opening, then the clipboard replies in order.
        let clipboard = Array(received.dropFirst(4).dropLast())
        #expect(clipboard.count == 5)
        guard clipboard.count == 5 else { return }
        #expect(clipboard[0] == clientCaps)
        #expect(clipboard[1] == clientRequest)
        for blob in [clipboard[2], clipboard[3]] {
            let parsed = try #require(parseExtendedClient(blob))
            #expect(parsed.flags == ExtendedClipboard.provide | ExtendedClipboard.text)
            #expect(uncompressAll(parsed.data) == inflated)
        }
        #expect(clipboard[4] == clientNotify)
    }

    /// Machine.sharedClipboard off: no text delivered or sent, no request for the server's notify.
    @Test func sharingOffExchangesNoText() async throws {
        let caps = try #require(ClipboardVectors.server.first { $0.name == "caps_text_rtf_html" })
        let notify = try #require(ClipboardVectors.server.first { $0.name == "notify_text" })
        let provide = try #require(ClipboardVectors.server.first { $0.name == "provide_complete_stream" })
        let legacy = try #require(ClipboardVectors.server.first { $0.name == "legacy_latin1" })
        let clientCaps = base64Bytes(try #require(ClipboardVectors.client["client_caps"]?.bytes))
        let update = FramebufferMessage.update(FramebufferMessage.raw(0, 0, 1, 1, b: 1, g: 2, r: 3))
        let server = try await FakeRFBServer(script: SessionLoopbackTests.handshake(width: 4, height: 4) + [
            .receive(SessionLoopbackTests.openingLength),
            .send(base64Bytes(caps.message)), .receive(clientCaps.count),
            .send(base64Bytes(notify.message) + base64Bytes(provide.message) + base64Bytes(legacy.message) + update),
            .expectClose,
        ])
        defer { server.stop() }
        let (connection, events) = try await Self.connect(server, sharing: false)
        var iterator = events
        guard case .framebufferUpdate = try await iterator.next() else {
            Issue.record("expected only the update")
            await connection.close()
            return
        }
        #expect(try await connection.shareClipboard("secret") == .notSharing)
        try await Task.sleep(for: .milliseconds(200))
        await connection.close()
        let received = try await server.received(within: .seconds(10))
        #expect(received.dropFirst(4).first == clientCaps)
        #expect(received.last == [])   // nothing after the caps: the close
        #expect(received.count == 6)
    }
}
