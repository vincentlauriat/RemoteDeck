import Foundation
import Testing
@testable import RFBKit

/// `RFBConnection.startSession` end to end against the in-process `FakeRFBServer`.
@Suite(.serialized)
struct SessionLoopbackTests {
    static let timeout = Duration.seconds(30)
    /// SetPixelFormat (20) + SetEncodings with the 7 preferred encodings (4 + 28) + full request (10).
    static let openingLength = 20 + 4 + 4 * Encoding.preferred.count + 10

    /// Banner, security type None, SecurityResult, ClientInit and ServerInit (3.8).
    static func handshake(width: UInt16, height: UInt16) -> [FakeRFBServer.Step] {
        [
            .send(ServerMessage.banner("RFB 003.008\n")), .receive(12),
            .send([1, 1]), .receive(1),
            .send(ServerMessage.securityResult(0)), .receive(1),
            .send(ServerMessage.serverInit(width: width, height: height, name: "loopback")),
        ]
    }

    static func opening(width: UInt16, height: UInt16) -> [UInt8] {
        ClientMessage.setPixelFormat(.bgra32).wireBytes + ClientMessage.setEncodings(Encoding.preferred).wireBytes
            + ClientMessage.framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: width, height: height).wireBytes
    }

    @Test func streamsDecodedUpdatesAndRequestsMore() async throws {
        let vector = try #require(DecoderVectors.all.first { $0.name == "raw_copyrect" })
        let incremental = ClientMessage.framebufferUpdateRequest(incremental: true, x: 0, y: 0, width: 40, height: 30)
        let server = try await FakeRFBServer(script: Self.handshake(width: 40, height: 30) + [
            .receive(Self.openingLength),
            .send(vector.streamBytes + [2]),             // five updates, then a Bell
            .receive(vector.updates * incremental.wireBytes.count),
            .close,
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        _ = try await connection.open(credentials: .none, timeout: Self.timeout)
        let stream = try await connection.startSession()
        var events: [RFBEvent] = []
        do {
            for try await event in stream { events.append(event) }
            Issue.record("expected the stream to end with connectionClosed")
        } catch {
            #expect(error as? RFBError == .connectionClosed)
        }
        let updates = events.filter { if case .framebufferUpdate = $0 { true } else { false } }
        #expect(updates.count == vector.updates)
        #expect(events.last == .bell)
        let snapshot = try #require(await connection.framebufferSnapshot())
        #expect(snapshot.pixels == vector.expectedPixels)

        let received = try await server.transcript.value
        #expect(received.count == 5)
        #expect(received[3] == Self.opening(width: 40, height: 30))
        #expect(received[4] == Array([[UInt8]](repeating: incremental.wireBytes, count: vector.updates).joined()))
        await connection.close()
    }

    /// Every byte the server sent is counted once: the handshake (ServerInit included) when `open`
    /// returns, then each session chunk (SessionRecord.bytesReceived).
    @Test func countsBytesReceived() async throws {
        let handshakeBytes = ServerMessage.banner("RFB 003.008\n").count + 2 + ServerMessage.securityResult(0).count
            + ServerMessage.serverInit(width: 4, height: 4, name: "count").count
        let update = FramebufferMessage.update(FramebufferMessage.raw(0, 0, 2, 2, b: 9, g: 8, r: 7))
        var script = Self.handshake(width: 4, height: 4)
        script[script.count - 1] = .send(ServerMessage.serverInit(width: 4, height: 4, name: "count"))
        let server = try await FakeRFBServer(script: script + [
            .receive(Self.openingLength), .send(update + [2]), .close,
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        #expect(await connection.bytesReceived == 0)
        _ = try await connection.open(credentials: .none, timeout: Self.timeout)
        #expect(await connection.bytesReceived == Int64(handshakeBytes))
        let stream = try await connection.startSession(requestUpdatesAutomatically: false)
        do {
            for try await _ in stream {}
        } catch {
            #expect(error as? RFBError == .connectionClosed)
        }
        #expect(await connection.bytesReceived == Int64(handshakeBytes + update.count + 1))
        await connection.close()
        _ = try await server.transcript.value
    }

    @Test func bytesAfterServerInitAreDecodedFirst() async throws {
        // The first update arrives in the same packet as ServerInit, before the client's opening.
        let update = FramebufferMessage.update(FramebufferMessage.raw(0, 0, 2, 2, b: 9, g: 8, r: 7))
        var script = Self.handshake(width: 4, height: 4)
        script[script.count - 1] = .send(ServerMessage.serverInit(width: 4, height: 4, name: "early") + update + [2])
        let server = try await FakeRFBServer(script: script + [.receive(Self.openingLength), .expectClose])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        _ = try await connection.open(credentials: .none, timeout: Self.timeout)
        let stream = try await connection.startSession(requestUpdatesAutomatically: false)
        var iterator = stream.makeAsyncIterator()
        guard case .framebufferUpdate(let first) = try await iterator.next() else {
            Issue.record("expected an update")
            return
        }
        #expect(first.regions.first?.pixels == [UInt32](repeating: 0xFF07_0809, count: 4))
        #expect(try await iterator.next() == .bell)
        await connection.close()
        #expect(try await iterator.next() == nil)  // close() finishes the stream without error
        _ = try await server.transcript.value
    }

    @Test func cancellingTheConsumerClosesTheConnection() async throws {
        let server = try await FakeRFBServer(script: Self.handshake(width: 8, height: 8) + [
            .receive(Self.openingLength),
            .send(FramebufferMessage.update()),
            .expectClose,
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        _ = try await connection.open(credentials: .none, timeout: Self.timeout)
        let stream = try await connection.startSession()
        let (firstEvent, signal) = AsyncStream.makeStream(of: Void.self)
        let consumer = Task {
            var count = 0
            for try await _ in stream {
                count += 1
                signal.yield()
            }
            return count
        }
        var waiter = firstEvent.makeAsyncIterator()
        _ = await waiter.next()
        let cancelledAt = ContinuousClock.now
        consumer.cancel()
        let count = try await consumer.value
        let received = try await server.transcript.value
        #expect(ContinuousClock.now - cancelledAt < .seconds(5))
        #expect(count == 1)
        #expect(received.last == [])  // the server saw the socket close
        await connection.close()
    }

    @Test func malformedDataEndsTheStreamWithTheError() async throws {
        let server = try await FakeRFBServer(script: Self.handshake(width: 8, height: 8) + [
            .receive(Self.openingLength),
            .send(FramebufferMessage.update(FramebufferMessage.rect(0, 0, 9, 1, encoding: Encoding.raw))),
            .expectClose,
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        _ = try await connection.open(credentials: .none, timeout: Self.timeout)
        let stream = try await connection.startSession()
        do {
            for try await event in stream { Issue.record("unexpected event \(event)") }
            Issue.record("expected an error")
        } catch {
            #expect(isViolation(error as? RFBError, "outside the 8x8 framebuffer"))
        }
        #expect(try await server.transcript.value.last == [])
        await connection.close()
    }

    /// One update in flight: the next request goes out when the consumer takes the update, so a
    /// second update cannot be decoded while the consumer is still busy with the first.
    @Test func slowConsumerHoldsBackTheNextUpdate() async throws {
        let first = FramebufferMessage.update(FramebufferMessage.raw(0, 0, 1, 1, b: 1, g: 1, r: 1))
        let second = FramebufferMessage.update(FramebufferMessage.raw(0, 0, 1, 1, b: 2, g: 2, r: 2))
        let request = ClientMessage.framebufferUpdateRequest(incremental: true, x: 0, y: 0, width: 4, height: 4)
        let server = try await FakeRFBServer(script: Self.handshake(width: 4, height: 4) + [
            .receive(Self.openingLength),
            .send(first), .receive(request.wireBytes.count),
            .send(second), .receive(request.wireBytes.count),
            .close,
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        _ = try await connection.open(credentials: .none, timeout: Self.timeout)
        let stream = try await connection.startSession()
        // Not consuming yet: the first update is decoded, but no request may go out.
        try await Task.sleep(for: .milliseconds(400))
        #expect(await connection.framebufferSnapshot()?[0, 0] == 0xFF01_0101)
        var iterator = stream.makeAsyncIterator()
        guard case .framebufferUpdate = try await iterator.next() else {
            Issue.record("expected the first update")
            return
        }
        // Busy with the first update: the second can now arrive, but only because it was taken.
        try await Task.sleep(for: .milliseconds(400))
        #expect(await connection.framebufferSnapshot()?[0, 0] == 0xFF02_0202)
        guard case .framebufferUpdate(let update) = try await iterator.next() else {
            Issue.record("expected the second update")
            return
        }
        #expect(update.regions.first?.pixels == [0xFF02_0202])
        let received = try await server.transcript.value
        #expect(received.suffix(2) == [request.wireBytes, request.wireBytes])
        await connection.close()
    }

    /// A resize asks for a full update at the new size; the partial update handed out before the
    /// resize (old size) asks for nothing.
    @Test func resizeRequestsAFullUpdateAtTheNewSize() async throws {
        let update = FramebufferMessage.update(
            FramebufferMessage.raw(0, 0, 2, 2, b: 1, g: 2, r: 3),
            FramebufferMessage.rect(0, 0, 10, 6, encoding: Encoding.desktopSize),
            FramebufferMessage.raw(8, 4, 2, 2, b: 4, g: 5, r: 6))
        let full = ClientMessage.framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: 10, height: 6)
        let incremental = ClientMessage.framebufferUpdateRequest(incremental: true, x: 0, y: 0, width: 10, height: 6)
        let server = try await FakeRFBServer(script: Self.handshake(width: 4, height: 4) + [
            .receive(Self.openingLength),
            .send(update),
            .receive(full.wireBytes.count + incremental.wireBytes.count),
            .close,
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        _ = try await connection.open(credentials: .none, timeout: Self.timeout)
        var events: [RFBEvent] = []
        var iterator = try await connection.startSession().makeAsyncIterator()
        for _ in 0..<3 {
            guard let event = try await iterator.next() else { break }
            events.append(event)
        }
        #expect(events.dropFirst().first == .desktopResized(width: 10, height: 6))
        if case .framebufferUpdate(let partial) = events.first { #expect(!partial.completesMessage) }
        if case .framebufferUpdate(let last) = events.last { #expect(last.completesMessage && last.width == 10) }
        // Give the requests time to arrive, then hang up: a server still waiting for missing bytes
        // sees the close and its transcript fails instead of hanging.
        try await Task.sleep(for: .milliseconds(300))
        await connection.close()
        let received = try await server.transcript.value
        #expect(received.last == full.wireBytes + incremental.wireBytes)
    }

    @Test func concurrentStartSessionCallsYieldOneSession() async throws {
        let server = try await FakeRFBServer(script: Self.handshake(width: 4, height: 4) + [
            .receive(Self.openingLength),
            .send(FramebufferMessage.update(FramebufferMessage.raw(0, 0, 1, 1, b: 7, g: 7, r: 7))),
            .expectClose,
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        _ = try await connection.open(credentials: .none, timeout: Self.timeout)
        // `Result`'s async catching initializer needs Swift 6.4; CI runs 6.3.
        @Sendable func attempt() async -> Result<RFBSessionEvents, RFBError> {
            do throws(RFBError) {
                return .success(try await connection.startSession(requestUpdatesAutomatically: false))
            } catch {
                return .failure(error)
            }
        }
        async let first = attempt()
        async let second = attempt()
        let results = await [first, second]
        let streams = results.compactMap { try? $0.get() }
        #expect(streams.count == 1)
        let errors = results.compactMap { result -> RFBError? in
            if case .failure(let error) = result { return error }
            return nil
        }
        #expect(errors == [.protocolViolation("session already started")])
        var iterator = try #require(streams.first).makeAsyncIterator()
        guard case .framebufferUpdate(let update) = try await iterator.next() else {
            Issue.record("expected an update on the surviving stream")
            return
        }
        #expect(update.regions.first?.pixels == [0xFF07_0707])
        await connection.close()
        _ = try await server.transcript.value
    }

    /// `close()` racing `startSession` (before, during or after the opening send) never leaves the
    /// actor holding a half-started session.
    @Test func closeDuringStartSessionLeavesTheConnectionReusable() async throws {
        for delay in [0, 1, 5] {
            let server = try await FakeRFBServer(script: Self.handshake(width: 4, height: 4) + [.expectClose])
            let connection = RFBConnection(host: "127.0.0.1", port: server.port)
            _ = try await connection.open(credentials: .none, timeout: Self.timeout)
            let starting = Task { try await connection.startSession() }
            try await Task.sleep(for: .milliseconds(delay))
            await connection.close()
            switch await starting.result {
            case .success(let stream):
                for try await _ in stream {}   // already finished by close(): ends with nil
            case .failure(let error):
                let error = error as? RFBError
                #expect(error == .cancelled || error == .protocolViolation("not connected"), "\(String(describing: error))")
            }
            #expect(await connection.isOpen == false)
            // No stale session marker: the next call reports the closed connection, not "already started".
            await #expect(throws: RFBError.protocolViolation("not connected")) {
                _ = try await connection.startSession()
            }
            _ = try await server.transcript.value
            server.stop()
        }
    }

    @Test func sessionNeedsAnOpenConnection() async throws {
        let connection = RFBConnection(host: "127.0.0.1", port: 1)
        await #expect(throws: RFBError.protocolViolation("not connected")) {
            _ = try await connection.startSession()
        }
        await #expect(throws: RFBError.protocolViolation("session not started")) {
            try await connection.requestUpdate()
        }
    }
}
