// Added for RemoteDeck (see Packages/Vendor/PATCHES.md).
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded
@testable import NIOSSH
import XCTest

/// Accepts every host key, except that it can hold one validation until the test releases it:
/// the client then stays mid re-key (after the peer's NEWKEYS, before its own).
private final class HoldingHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    var holdNext = false
    var held: EventLoopPromise<Void>?

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if self.holdNext {
            self.holdNext = false
            self.held = validationCompletePromise
        } else {
            validationCompletePromise.succeed(())
        }
    }
}

private final class ArrivalLog {
    var entries: [String] = []
}

/// Records, into one log shared by every server channel, what each channel receives.
private final class ArrivalRecorder: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    let name: String
    let log: ArrivalLog

    init(name: String, log: ArrivalLog) {
        self.name = name
        self.log = log
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = self.unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        let kind = message.type == .channel ? "data" : "stderr"
        self.log.entries.append("\(self.name) \(kind) \(String(buffer: buffer))")
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case ChannelEvent.inputClosed:
            self.log.entries.append("\(self.name) eof")
        case let exec as SSHChannelRequestEvent.ExecRequest:
            self.log.entries.append("\(self.name) exec \(exec.command)")
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.log.entries.append("\(self.name) close")
        context.fireChannelInactive()
    }
}

private final class ByteCounter: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    var bytes = 0

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .byteBuffer(let buffer) = self.unwrapInboundIn(data).data {
            self.bytes += buffer.readableBytes
        }
    }
}

/// RFC 4253 §7: between sending KEXINIT and sending NEWKEYS a party sends no connection-layer
/// message. swift-nio-ssh refused them (`protocolViolation`); the RemoteDeck patch queues them in
/// `NIOSSHHandler` and writes them, in order, right after our NEWKEYS.
final class RekeyChannelMessageQueueTests: XCTestCase {
    /// Where the re-key stands while the test writes.
    enum RekeyPoint: CaseIterable {
        /// We sent KEXINIT, the peer has not answered (`sentKexInitWhenActive`).
        case localKexInit
        /// The peer's KEXINIT arrived and we answered with ours (`rekeying`).
        case peerKexInit
        /// The whole exchange ran, our NEWKEYS waits for the host key validation
        /// (`rekeyingReceivedNewKeysState`; the NEWKEYS then leaves from a future callback).
        case awaitingHostKeyValidation
    }

    private var channel: BackToBackEmbeddedChannel!
    private var hostKeys: HoldingHostKeyDelegate!

    override func setUp() {
        self.channel = BackToBackEmbeddedChannel()
        self.hostKeys = HoldingHostKeyDelegate()
    }

    override func tearDown() {
        try? self.channel?.finish()
        self.channel = nil
        self.hostKeys = nil
    }

    private func connect() throws {
        var harness = TestHarness()
        harness.clientServerAuthDelegate = self.hostKeys
        try self.channel.configureWithHarness(harness)
        try self.channel.activate()
        try self.channel.interactInMemory()
    }

    private func beginRekey(_ point: RekeyPoint) throws {
        switch point {
        case .localKexInit:
            try self.channel.clientSSHHandler!._rekey()
        case .peerKexInit:
            try self.channel.serverSSHHandler!._rekey()
            // Hand the server's KEXINIT to the client, and nothing more: the client answers it
            // with its own KEXINIT and the key exchange init, which stay in its outbound buffer.
            self.channel.run()
            let kexInit = try XCTUnwrap(try self.channel.server.readOutbound(as: IOData.self))
            try self.channel.client.writeInbound(kexInit)
        case .awaitingHostKeyValidation:
            self.hostKeys.holdNext = true
            try self.channel.serverSSHHandler!._rekey()
            try self.channel.interactInMemory()
            XCTAssertNotNil(self.hostKeys.held, "the re-key should be waiting for the host key validation")
        }
    }

    private func finishRekey(_ point: RekeyPoint) throws {
        if point == .awaitingHostKeyValidation {
            let held = try XCTUnwrap(self.hostKeys.held)
            self.hostKeys.held = nil
            held.succeed(())
        }
        try self.channel.interactInMemory()
    }

    private func data(_ text: String, _ type: SSHChannelData.DataType = .channel) -> SSHChannelData {
        SSHChannelData(type: type, data: .byteBuffer(ByteBuffer(string: text)))
    }

    /// Discards what is still in flight, so `finish()` sees clean channels after a test that
    /// closed one side.
    private func discardInFlight() throws {
        while try self.channel.client.readOutbound(as: IOData.self) != nil {}
        while try self.channel.server.readOutbound(as: IOData.self) != nil {}
    }

    // MARK: Order

    func testChannelMessagesWrittenDuringARekeyArriveInOrderAfterIt() throws {
        for (index, point) in RekeyPoint.allCases.enumerated() {
            if index > 0 {
                self.tearDown()
                self.setUp()
            }
            try self.checkOrder(point)
        }
    }

    private func checkOrder(_ point: RekeyPoint) throws {
        try self.connect()
        let a = try self.channel.createNewChannel()
        let b = try self.channel.createNewChannel()
        try self.channel.interactInMemory()
        XCTAssertEqual(self.channel.activeServerChannels.count, 2, "\(point)")

        let log = ArrivalLog()
        for (name, serverChannel) in zip(["a", "b"], self.channel.activeServerChannels) {
            try serverChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).wait()
            try serverChannel.pipeline.addHandler(ArrivalRecorder(name: name, log: log)).wait()
        }

        try self.beginRekey(point)

        var results: [String: Result<Void, Error>] = [:]
        func track(_ name: String, _ future: EventLoopFuture<Void>) {
            future.whenComplete { results[name] = $0 }
        }
        track("a data", a.writeAndFlush(self.data("a1")))
        track("b data", b.writeAndFlush(self.data("b1")))
        track("a exec", a.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: "uname", wantReply: false)))
        track("b stderr", b.writeAndFlush(self.data("b2", .stdErr)))
        track("a data 2", a.writeAndFlush(self.data("a2")))
        track("a eof", a.close(mode: .output))
        track("b close", b.close())
        let opened = self.channel.client.eventLoop.makePromise(of: Channel.self)
        self.channel.clientSSHHandler!.createChannel(opened, nil)
        var openResult: Result<Channel, Error>?
        opened.futureResult.whenComplete { openResult = $0 }

        // Queued, not refused: nothing has completed, nothing has failed.
        self.channel.run()
        XCTAssertEqual(results.count, 0, "\(point): \(results)")
        XCTAssertNil(openResult, "\(point)")
        XCTAssertEqual(log.entries, [], "\(point)")

        try self.finishRekey(point)

        for name in ["a data", "b data", "a exec", "b stderr", "a data 2", "a eof", "b close"] {
            switch results[name] {
            case .success:
                break
            case .failure(let error):
                XCTFail("\(point): \(name) failed: \(error)")
            case nil:
                XCTFail("\(point): \(name) never completed")
            }
        }
        XCTAssertEqual(log.entries, [
            "a data a1", "b data b1", "a exec uname", "b stderr b2", "a data a2", "a eof", "b close",
        ], "\(point)")
        guard case .success = openResult else {
            XCTFail("\(point): the channel opened during the re-key gave \(String(describing: openResult))")
            return
        }
        XCTAssertEqual(self.channel.activeServerChannels.count, 2, "\(point): a and the new channel (b is closed)")
    }

    // MARK: Window adjust

    func testAWindowAdjustSentDuringARekeyReachesThePeer() throws {
        for (index, point) in RekeyPoint.allCases.enumerated() {
            if index > 0 {
                self.tearDown()
                self.setUp()
            }
            try self.checkWindowAdjust(point)
        }
    }

    private func checkWindowAdjust(_ point: RekeyPoint) throws {
        try self.connect()
        let counter = ByteCounter()
        var created: Channel?
        self.channel.clientSSHHandler!.createChannel(nil) { channel, _ in
            created = channel
            return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                channel.pipeline.addHandler(counter)
            }
        }
        try self.channel.interactInMemory()
        let clientChannel = try XCTUnwrap(created)
        let serverChannel = try XCTUnwrap(self.channel.activeServerChannels.first)

        // More than half the client's window (its maximum packet size, 128 kB): delivering it
        // makes the client send a window adjust.
        let chunk = String(repeating: "x", count: 100_000)
        try serverChannel.writeAndFlush(self.data(chunk)).wait()
        try self.channel.interactInMemory()
        XCTAssertEqual(counter.bytes, 0, "\(point): autoRead is off")

        try self.beginRekey(point)
        clientChannel.read()
        XCTAssertEqual(counter.bytes, 100_000, "\(point)")
        try self.finishRekey(point)

        // Only the window adjust lets the whole second chunk through (31 kB of window are left).
        serverChannel.writeAndFlush(self.data(chunk), promise: nil)
        try self.channel.interactInMemory()
        clientChannel.read()
        XCTAssertEqual(counter.bytes, 200_000, "\(point)")
        // Deliver that read's own window adjust, so the channels end clean.
        try self.channel.interactInMemory()
    }

    // MARK: Close mid re-key

    func testMessagesQueuedWhenTheConnectionClosesAreFailed() throws {
        for (index, point) in [RekeyPoint.localKexInit, .peerKexInit].enumerated() {
            if index > 0 {
                self.tearDown()
                self.setUp()
            }
            try self.checkCloseFailsQueued(point)
        }
    }

    private func checkCloseFailsQueued(_ point: RekeyPoint) throws {
        try self.connect()
        let a = try self.channel.createNewChannel()
        try self.channel.interactInMemory()

        try self.beginRekey(point)
        var results: [Result<Void, Error>] = []
        a.writeAndFlush(self.data("lost")).whenComplete { results.append($0) }
        a.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: "x", wantReply: false)).whenComplete { results.append($0) }
        self.channel.run()
        XCTAssertEqual(results.count, 0, "\(point)")

        try self.channel.client.close().wait()
        self.channel.run()
        XCTAssertEqual(results.count, 2, "\(point): every queued write completes")
        for result in results {
            guard case .failure = result else {
                XCTFail("\(point): a write queued on a closed connection succeeded")
                continue
            }
        }
        try self.discardInFlight()
    }

    // MARK: EOF after the peer's EOF

    /// RFC 4254 §5.3: each side sends its EOF on its own, so an EOF may follow the peer's.
    func testEOFCanBeSentAfterThePeersEOF() throws {
        try self.connect()
        var clientEvents: [String] = []
        final class EOFWatcher: ChannelInboundHandler {
            typealias InboundIn = SSHChannelData
            let record: (String) -> Void
            init(record: @escaping (String) -> Void) { self.record = record }
            func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
                if case ChannelEvent.inputClosed = event { self.record("eof") }
                context.fireUserInboundEventTriggered(event)
            }
        }
        var created: Channel?
        self.channel.clientSSHHandler!.createChannel(nil) { channel, _ in
            created = channel
            return channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                channel.pipeline.addHandler(EOFWatcher { clientEvents.append($0) })
            }
        }
        try self.channel.interactInMemory()
        let clientChannel = try XCTUnwrap(created)
        let serverChannel = try XCTUnwrap(self.channel.activeServerChannels.first)
        let log = ArrivalLog()
        try serverChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).wait()
        try serverChannel.pipeline.addHandler(ArrivalRecorder(name: "s", log: log)).wait()

        // The server's EOF first, then the client's.
        try serverChannel.close(mode: .output).wait()
        try self.channel.interactInMemory()
        XCTAssertEqual(clientEvents, ["eof"])

        var clientEOF: Result<Void, Error>?
        clientChannel.close(mode: .output).whenComplete { clientEOF = $0 }
        try self.channel.interactInMemory()
        guard case .success = clientEOF else {
            XCTFail("the client's EOF after the server's gave \(String(describing: clientEOF))")
            return
        }
        XCTAssertEqual(log.entries, ["s eof"])

        // A second EOF from the same side is still refused.
        var second: Result<Void, Error>?
        clientChannel.close(mode: .output).whenComplete { second = $0 }
        self.channel.run()
        guard case .failure = second else {
            XCTFail("a second EOF gave \(String(describing: second))")
            return
        }
        clientChannel.close(promise: nil)
        try self.channel.interactInMemory()
    }
}
