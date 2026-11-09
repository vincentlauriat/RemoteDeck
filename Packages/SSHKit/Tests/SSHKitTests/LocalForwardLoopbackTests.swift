import Foundation
import NIOCore
import Testing
@testable import SSHKit

/// Local port forwards against the in-process `TestSSHServer`, whose `direct-tcpip` channels reach
/// a `TinyHTTPServer` or an `EchoTCPServer` on 127.0.0.1. Every forward asks for port 0 (tests run
/// in parallel) unless the test is about a given port. Every wait is bounded.
@Suite(.timeLimit(.minutes(1)))
struct LocalForwardLoopbackTests {
    private static let body = Data("forwarded-ok\n".utf8)
    private static let request = Data("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n".utf8)

    // MARK: Forwarding

    @Test func forwardsHTTPToRemotePort() async throws {
        let rig = try await Rig.start()
        let forward = try await rig.forward()
        #expect(forward.localPort != 0)
        let client = try await TestTCPClient.connect("127.0.0.1", forward.localPort)
        try await client.send(Self.request)
        #expect(await client.readToEnd() == TinyHTTPServer.response(Self.body))
        // One direct-tcpip open, for the target, from the local peer's address.
        let requests = rig.server.record.directTCPIPRequests
        #expect(requests.map(\.target) == [rig.target])
        #expect(requests.first?.originatorHost == "127.0.0.1")
        #expect(requests.first?.originatorPort == client.localPort)
        await client.close()
        await rig.stop()
    }

    @Test func finishedConnectionsReleaseTheirChannels() async throws {
        // After full exchanges (the server's EOF first, then the client's close), the forward
        // holds its two listeners only: no socket or SSH channel is left behind.
        let rig = try await Rig.start()
        let forward = try await rig.forward()
        for _ in 0 ..< 3 {
            let client = try await TestTCPClient.connect("127.0.0.1", forward.localPort)
            try await client.send(Self.request)
            #expect(await client.readToEnd() == TinyHTTPServer.response(Self.body))
            await client.close()
        }
        var count = -1
        for _ in 0 ..< 250 where count != 2 {
            count = await forward.openChannelCount
            if count != 2 { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(count == 2)
        await rig.stop()
    }

    @Test func listensOnIPv6Loopback() async throws {
        let rig = try await Rig.start()
        let forward = try await rig.forward()
        let client = try await TestTCPClient.connect("::1", forward.localPort)
        try await client.send(Self.request)
        #expect(await client.readToEnd() == TinyHTTPServer.response(Self.body))
        #expect(rig.server.record.directTCPIPRequests.first?.originatorHost == "::1")
        await client.close()
        await rig.stop()
    }

    @Test(.enabled(if: firstNonLoopbackIPv4() != nil, "this Mac has no up, non-loopback IPv4 address"))
    func listensOnLoopbackOnly() async throws {
        let address = try #require(firstNonLoopbackIPv4())
        let rig = try await Rig.start()
        let forward = try await rig.forward()
        let error = await TestTCPClient.connectError(address, forward.localPort)
        #expect(isConnectionRefused(error), "connecting to \(address):\(forward.localPort) gave \(String(describing: error))")
        // Positive control: the same port answers on loopback.
        #expect(await TestTCPClient.connectError("127.0.0.1", forward.localPort) == nil)
        await rig.stop()
    }

    @Test func largeTransfersBothWaysKeepEveryByte() async throws {
        // 8 MB each way through the SSH window and the sockets' watermarks, then a half-close
        // from the client that reaches the echo server, which closes once it has echoed all.
        let echo = try await EchoTCPServer.start()
        let rig = try await Rig.start(targetPort: echo.port)
        let forward = try await rig.forward()
        let client = try await TestTCPClient.connect("127.0.0.1", forward.localPort)
        let payload = Data((0 ..< 8 << 20).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 13) })
        try await bounded(.seconds(30)) { try await client.send(payload) }
        try await client.shutdownOutput()
        let echoed = await client.readToEnd(within: .seconds(30))
        #expect(echoed?.count == payload.count)
        #expect(echoed == payload)
        await client.close()
        await rig.stop()
        await echo.stop()
    }

    @Test func trafficCrossesARekeyWhole() async throws {
        // 2 MB echoed while the server re-keys, then 1 MB written while the client is held mid
        // re-key: every byte comes back in order, nothing stalls, and the teardown is bounded.
        let echo = try await EchoTCPServer.start()
        let rig = try await Rig.start(targetPort: echo.port)
        let forward = try await rig.forward()
        let client = try await TestTCPClient.connect("127.0.0.1", forward.localPort)
        let before = Data((0 ..< 2 << 20).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ $0 >> 11) })
        let during = Data((0 ..< 1 << 20).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 7) })
        try await bounded(.seconds(30)) { try await client.send(before) }
        // All echoed: both SSH windows are open again, so the client has data to send below.
        #expect(await client.waitForReceived(before.count, within: .seconds(30)))
        try await rig.server.rekeyHoldingClientBytes()
        #expect(await pollAsync(within: .seconds(5)) { (try? await rig.server.heldBytes()) ?? 0 > 0 })
        // The send cannot finish while the server holds everything (the SSH window runs out).
        let sending = Task { try await client.send(during) }
        // Forwarded data now waits in the client's handler, not refused.
        let connection = rig.connection
        #expect(await pollAsync(within: .seconds(5)) { (try? await deferredSSHMessageCount(connection)) ?? 0 > 0 })
        try await rig.server.releaseHeldBytes()
        try await bounded(.seconds(30)) { try await sending.value }
        try await client.shutdownOutput()
        let echoed = await client.readToEnd(within: .seconds(30))
        #expect(echoed?.count == before.count + during.count)
        #expect(echoed == before + during)
        await client.close()
        try await bounded(.seconds(5)) { await forward.stop() }
        try await bounded(.seconds(5)) { await connection.close() }
        await rig.stop()
        await echo.stop()
    }

    @Test func largeHTTPBodyArrivesWhole() async throws {
        let body = Data((0 ..< 4 << 20).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let rig = try await Rig.start(body: body)
        let forward = try await rig.forward()
        let client = try await TestTCPClient.connect("127.0.0.1", forward.localPort)
        try await client.send(Self.request)
        let received = await client.readToEnd(within: .seconds(30))
        #expect(received?.count == TinyHTTPServer.response(body).count)
        #expect(received == TinyHTTPServer.response(body))
        await client.close()
        await rig.stop()
    }

    @Test func slowReaderHoldsTheRemoteBack() async throws {
        // A client that does not read: the 16 MB response must wait at the server (SSH window,
        // socket watermarks), not pile up in the forward. With the client's 8 kB receive buffer,
        // every buffer on the path together holds well under 16 MB (macOS autotunes each socket
        // buffer up to 4 MB; the SSH window is 128 kB).
        let body = Data(repeating: 0x5A, count: 16 << 20)
        let rig = try await Rig.start(body: body)
        let forward = try await rig.forward()
        let client = try await TestTCPClient.connect("127.0.0.1", forward.localPort, autoRead: false, receiveBuffer: 8 << 10)
        try await client.send(Self.request)
        #expect(await poll(within: .seconds(5)) { rig.server.record.directTCPIPRequests.count == 1 })
        try await Task.sleep(for: .seconds(1))
        #expect(rig.http?.responsesWritten == 0)
        try await client.resumeReading()
        let received = await client.readToEnd(within: .seconds(30))
        #expect(received == TinyHTTPServer.response(body))
        #expect(rig.http?.responsesWritten == 1)
        await client.close()
        await rig.stop()
    }

    @Test(arguments: Array(stride(from: 160 << 10, through: 1184 << 10, by: 128 << 10)), [false, true])
    func remoteCloseDeliversWhatTheClientHasNotReadYet(size: Int, clientHalfCloses: Bool) async throws {
        // The client reads nothing while the server sends `size` bytes, then EOF and CLOSE at once:
        // across these sizes, some overflow the kernel buffers to the client (macOS autotunes them)
        // but fit in the forward plus the SSH window, so the tail is still in the forward's pending
        // writes when its channel closes. It must reach the client before the socket closes, also when the client had
        // half-closed first (NIO then turns an output close into a full close, dropping pending
        // writes, unless they are drained first).
        let body = Data((0 ..< size).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ $0 >> 9) })
        let rig = try await Rig.start(body: body, halfCloseTargets: false)
        let forward = try await rig.forward()
        let client = try await TestTCPClient.connect("127.0.0.1", forward.localPort, autoRead: false, receiveBuffer: 8 << 10)
        try await client.send(Self.request)
        if clientHalfCloses { try await client.shutdownOutput() }
        try await Task.sleep(for: .seconds(1))
        try await client.resumeReading()
        let received = await client.readToEnd()
        #expect(received == TinyHTTPServer.response(body), "got \(received?.count ?? -1) of \(TinyHTTPServer.response(body).count) bytes")
        await client.close()
        await rig.stop()
    }

    @Test func refusedChannelClosesOnlyThatSocket() async throws {
        let rig = try await Rig.start()
        let forward = try await rig.forward()
        rig.server.refuseForwards(true)
        let refused = try await TestTCPClient.connect("127.0.0.1", forward.localPort)
        #expect(await refused.readToEnd() == Data())
        // The forward still listens, and the next connection goes through.
        rig.server.refuseForwards(false)
        let client = try await TestTCPClient.connect("127.0.0.1", forward.localPort)
        try await client.send(Self.request)
        #expect(await client.readToEnd() == TinyHTTPServer.response(Self.body))
        #expect(rig.server.record.directTCPIPRequests.count == 2)
        await refused.close()
        await client.close()
        await rig.stop()
    }

    @Test func targetNotAllowedClosesTheSocket() async throws {
        let rig = try await Rig.start()
        let forward = try await rig.forward(remotePort: rig.target.port &+ 1)
        let client = try await TestTCPClient.connect("127.0.0.1", forward.localPort)
        #expect(await client.readToEnd() == Data())
        #expect(try await rig.shellWorks())
        await client.close()
        await rig.stop()
    }

    // MARK: Ports

    @Test func portInUseThrows() async throws {
        let rig = try await Rig.start()
        let held = try await holdPort("127.0.0.1")
        #expect(await rig.forwardError(localPort: held.port) == .portInUse(held.port))
        // The IPv6 listener was not left behind, and the connection is still usable.
        let v6 = try await holdPort("::1", held.port)
        try await v6.channel.close()
        #expect(try await rig.shellWorks())
        try await held.channel.close()
        await rig.stop()
    }

    @Test func portInUseOnIPv6ClosesTheIPv4Listener() async throws {
        let rig = try await Rig.start()
        let held = try await holdPort("::1")
        #expect(await rig.forwardError(localPort: held.port) == .portInUse(held.port))
        #expect(isConnectionRefused(await TestTCPClient.connectError("127.0.0.1", held.port)))
        #expect(try await rig.shellWorks())
        try await held.channel.close()
        await rig.stop()
    }

    @Test func portInUseWhenAnotherAppListensOnAllInterfaces() async throws {
        // SO_REUSEADDR would let 127.0.0.1:P bind over another app's 0.0.0.0:P and take its
        // loopback traffic; the forward must refuse instead.
        let rig = try await Rig.start()
        let held = try await holdPort("0.0.0.0")
        #expect(await rig.forwardError(localPort: held.port) == .portInUse(held.port))
        try await held.channel.close()
        let held6 = try await holdPort("::")
        #expect(await rig.forwardError(localPort: held6.port) == .portInUse(held6.port))
        try await held6.channel.close()
        // An IPv6-only [::] listener leaves 0.0.0.0 free: only the IPv6 probe sees it.
        let held6Only = try await holdPort("::", v6Only: true)
        #expect(await TestTCPClient.connectError("127.0.0.1", held6Only.port) != nil)
        #expect(await rig.forwardError(localPort: held6Only.port) == .portInUse(held6Only.port))
        try await held6Only.channel.close()
        #expect(try await rig.shellWorks())
        await rig.stop()
    }

    @Test func givenPortIsTheBoundPort() async throws {
        let rig = try await Rig.start()
        let free = try await holdPort("127.0.0.1")
        try await free.channel.close()
        let forward = try await rig.forward(localPort: free.port)
        #expect(forward.localPort == free.port)
        await rig.stop()
    }

    // MARK: Stopping

    @Test func stopFreesThePort() async throws {
        let rig = try await Rig.start()
        let forward = try await rig.forward()
        let port = forward.localPort
        let client = try await TestTCPClient.connect("127.0.0.1", port)
        try await client.send(Self.request)
        #expect(await client.readToEnd() == TinyHTTPServer.response(Self.body))
        await forward.stop()
        #expect(isConnectionRefused(await TestTCPClient.connectError("127.0.0.1", port)))
        #expect(isConnectionRefused(await TestTCPClient.connectError("::1", port)))
        // The app's path: the same port forwards again at once, despite the TIME_WAIT left behind.
        let again = try await rig.forward(localPort: port)
        let second = try await TestTCPClient.connect("127.0.0.1", again.localPort)
        try await second.send(Self.request)
        #expect(await second.readToEnd() == TinyHTTPServer.response(Self.body))
        await client.close()
        await second.close()
        await rig.stop()
    }

    @Test func stopClosesLiveSocketsAndIsIdempotent() async throws {
        let rig = try await Rig.start()
        let forward = try await rig.forward()
        let client = try await TestTCPClient.connect("127.0.0.1", forward.localPort)
        try await client.send(Data("GET / HTTP/1.0\r\n".utf8))  // incomplete: the server waits
        #expect(await poll(within: .seconds(5)) { rig.server.record.directTCPIPRequests.count == 1 })
        #expect(!(await client.ended(within: .milliseconds(200))))
        await forward.stop()
        #expect(await client.ended(within: .seconds(5)))
        await forward.stop()
        #expect(try await rig.shellWorks())
        await client.close()
        await rig.stop()
    }

    @Test func stopIsBoundedWhileTheServerHoldsTheOpen() async throws {
        // sshd answers CHANNEL_OPEN only once its connect to the target is done (minutes, for a
        // filtered host); until then the SSH channel cannot close. stop() must not wait for it.
        let rig = try await Rig.start(forwardOpenDelay: .seconds(30))
        let forward = try await rig.forward()
        let port = forward.localPort
        let client = try await TestTCPClient.connect("127.0.0.1", port)
        try await client.send(Self.request)
        #expect(await poll(within: .seconds(5)) { rig.server.record.directTCPIPRequests.count == 1 })
        let start = ContinuousClock.now
        try await bounded(.seconds(5)) { await forward.stop() }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(isConnectionRefused(await TestTCPClient.connectError("127.0.0.1", port)))
        #expect(isConnectionRefused(await TestTCPClient.connectError("::1", port)))
        #expect(await client.ended(within: .seconds(2)))
        // The SSH channel is still waiting for its open: the scenario did happen.
        #expect(await forward.openChannelCount == 1)
        // Closing the connection releases it.
        let connection = rig.connection
        try await bounded(.seconds(5)) { await connection.close() }
        var count = -1
        for _ in 0 ..< 250 where count != 0 {
            count = await forward.openChannelCount
            if count != 0 { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(count == 0)
        await client.close()
        await rig.stop()
    }

    @Test func closeStopsAllForwards() async throws {
        let rig = try await Rig.start()
        let first = try await rig.forward()
        let second = try await rig.forward()
        let client = try await TestTCPClient.connect("127.0.0.1", first.localPort)
        try await client.send(Data("GET / HTTP/1.0\r\n".utf8))
        #expect(await poll(within: .seconds(5)) { rig.server.record.directTCPIPRequests.count == 1 })
        await rig.connection.close()
        for port in [first.localPort, second.localPort] {
            #expect(isConnectionRefused(await TestTCPClient.connectError("127.0.0.1", port)))
            #expect(isConnectionRefused(await TestTCPClient.connectError("::1", port)))
        }
        #expect(await client.ended(within: .seconds(5)))
        await first.stop()  // already stopped: nothing happens
        await client.close()
        await rig.stop()
    }

    @Test func lostConnectionStopsForwards() async throws {
        let rig = try await Rig.start()
        let forward = try await rig.forward()
        let closed = Ending(await rig.connection.closed)
        await rig.server.stop()
        #expect(await closed.value(within: .seconds(5)) == .some(.connectionClosed))
        #expect(await poll(within: .seconds(5)) {
            // Synchronous probes: a refused connect to loopback fails at once.
            !canConnect(port: forward.localPort, ipv6: false) && !canConnect(port: forward.localPort, ipv6: true)
        })
        await rig.stop()
    }

    @Test func startOnAClosedConnectionThrows() async throws {
        let rig = try await Rig.start()
        await rig.connection.close()
        #expect(await rig.forwardError(localPort: 0) == .connectionClosed)
        let never = SSHConnection(host: "127.0.0.1", port: rig.server.port)
        do {
            _ = try await never.startLocalForward(localPort: 0, remoteHost: "localhost", remotePort: rig.target.port)
            Issue.record("forward started on a connection never opened")
        } catch {
            #expect(error == .connectionClosed)
        }
        await rig.stop()
    }
}

/// An open connection to a `TestSSHServer` that forwards `localhost:<targetPort>` to 127.0.0.1,
/// with a `TinyHTTPServer` as the default target.
private struct Rig {
    let server: TestSSHServer
    let connection: SSHConnection
    let target: TestSSHServer.ForwardTarget
    let http: TinyHTTPServer?

    static func start(
        body: Data = Data("forwarded-ok\n".utf8), targetPort: UInt16? = nil, halfCloseTargets: Bool = true,
        forwardOpenDelay: Duration = .zero
    ) async throws -> Rig {
        let http = targetPort == nil ? try await TinyHTTPServer.start(body: body) : nil
        let target = TestSSHServer.ForwardTarget(host: "localhost", port: targetPort ?? http!.port)
        let server = try await TestSSHServer.start(.init(forwardTargets: [target], halfCloseTargets: halfCloseTargets, forwardOpenDelay: forwardOpenDelay))
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await bounded {
            try await connection.open(credentials: .password(user: "tester", password: "s3cret"), timeout: .seconds(5)) { _ in true }
        }
        return Rig(server: server, connection: connection, target: target, http: http)
    }

    func forward(localPort: UInt16 = 0, remotePort: UInt16? = nil) async throws -> LocalForwardHandle {
        let connection = self.connection
        let target = self.target
        return try await bounded {
            try await connection.startLocalForward(localPort: localPort, remoteHost: target.host, remotePort: remotePort ?? target.port)
        }
    }

    func forwardError(localPort: UInt16) async -> SSHError? {
        do {
            let handle = try await forward(localPort: localPort)
            Issue.record("forward started on port \(handle.localPort)")
            await handle.stop()
            return nil
        } catch let error as SSHError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    /// Whether a shell still opens and echoes on the connection.
    func shellWorks() async throws -> Bool {
        let connection = self.connection
        let shell = try await bounded { try await connection.openShell(term: "xterm-256color", columns: 80, rows: 24) }
        let transcript = try await Transcript(shell)
        try await shell.write(Data("still usable\n".utf8))
        return await transcript.waitFor { $0.contains("still usable") }
    }

    func stop() async {
        await connection.close()
        await server.stop()
        await http?.stop()
    }
}

/// A blocking connect to 127.0.0.1 or [::1] on `port`, for a probe inside a synchronous `poll`
/// condition.
private func canConnect(port: UInt16, ipv6: Bool) -> Bool {
    let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if ipv6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}
