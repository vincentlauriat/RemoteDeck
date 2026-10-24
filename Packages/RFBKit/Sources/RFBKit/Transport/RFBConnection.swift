import Foundation
import Network
import os

/// Opens an RFB session over TCP: runs `RFBHandshake` on an `NWConnection` until ServerInit, then
/// (`startSession`) streams the decoded framebuffer protocol.
///
/// - The `timeout` covers the TCP connection *and* the whole handshake, so a server that accepts
///   the connection and then stays silent cannot hang the caller.
/// - Cancelling the calling task closes the connection at once and throws `RFBError.cancelled`.
/// - `RFBHandshake.receive` runs on a dedicated dispatch queue, not on the actor: Apple DH does
///   two modular exponentiations (≈ 1.5 s for both at 4096 bits in a debug build, ≈ 90 ms in release) that would
///   otherwise block a thread of Swift's small cooperative pool. Framebuffer decoding likewise runs
///   on its own queue (`FramebufferPump`).
public actor RFBConnection {
    public nonisolated let host: String
    public nonisolated let port: UInt16
    /// TCP keepalive and the viability grace (T5.1): how a dead connection is noticed.
    public nonisolated let liveness: ConnectionLiveness
    private let networkQueue = DispatchQueue(label: "RFBKit.RFBConnection.network")
    private let handshakeQueue = DispatchQueue(label: "RFBKit.RFBConnection.handshake", qos: .userInitiated)
    private var connection: NWConnection?
    /// Bytes received after ServerInit, handed to the decoder by `startSession`.
    private(set) var pendingBytes = Data()
    private var serverInit: ServerInit?
    private var pump: FramebufferPump?
    private var sessionTask: Task<Void, Never>?
    /// Identity of the current session, set as soon as `startSession` begins.
    private var sessionID: SessionID?
    private var sessionContinuation: AsyncThrowingStream<RFBEvent, any Error>.Continuation?
    /// Clipboard state of the current session (Extended Clipboard caps, the text last shared). Off
    /// until `setClipboardSharing(true)`: no clipboard text is sent or delivered before.
    private var clipboard = ClipboardNegotiation(sharing: false)

    /// Whether a connection is currently held (open or being opened).
    var isOpen: Bool { connection != nil }

    /// The TCP options of the connection held now (T5.1: keepalive), for tests.
    package var tcpOptionsInUse: NWProtocolTCP.Options? {
        connection?.parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
    }

    /// Bytes received from the server since this connection was created: the handshake (counted when
    /// `open` returns or fails) plus every chunk read by the session (SessionRecord.bytesReceived).
    public private(set) var bytesReceived: Int64 = 0

    /// Called with every chunk received from the server during `open`, before it is parsed. Only
    /// server → client bytes pass through it (never the encrypted credentials the client sends).
    /// Package-visible for the `rfb-probe` capture tool; the app does not use it.
    private let receiveObserver: (@Sendable (Data) -> Void)?

    public init(host: String, port: UInt16 = 5900, liveness: ConnectionLiveness = ConnectionLiveness()) {
        self.init(host: host, port: port, liveness: liveness, receiveObserver: nil)
    }

    package init(host: String, port: UInt16 = 5900, liveness: ConnectionLiveness = ConnectionLiveness(),
                 receiveObserver: (@Sendable (Data) -> Void)?) {
        self.host = host
        self.port = port
        self.liveness = liveness
        self.receiveObserver = receiveObserver
    }

    /// Connects and authenticates. On failure the connection is closed and a typed error thrown.
    public func open(credentials: RFBCredentials, shared: Bool = true, timeout: Duration = .seconds(10),
                     entropy: HandshakeEntropy = .system) async throws(RFBError) -> HandshakeResult {
        guard connection == nil else { throw .protocolViolation("connection already opened") }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw .network("invalid port \(port)") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: liveness.parameters())
        self.connection = connection
        // Not viable for longer than the grace (its interface went away): cancelled, so the session's
        // read fails and the app treats it as a drop.
        let watchdog = ViabilityWatchdog(grace: liveness.viabilityGrace, queue: networkQueue) { [weak connection] in
            connection?.cancel()
        }
        connection.viabilityUpdateHandler = { viable in watchdog.viabilityChanged(viable) }

        let deadline = Deadline()
        networkQueue.asyncAfter(deadline: .now() + timeout.timeInterval) {
            if deadline.expire() { connection.cancel() }
        }

        var handshake = RFBHandshake(credentials: credentials, shared: shared, entropy: entropy)
        var handshakeBytes = 0
        let outcome: Result<HandshakeResult, any Error> = await withTaskCancellationHandler {
            do {
                try await connection.startAndWaitUntilReady(queue: networkQueue)
                while true {
                    guard !Task.isCancelled else { throw RFBError.cancelled }
                    guard let chunk = try await connection.receiveChunk() else {
                        throw handshake.errorForClosedConnection()
                    }
                    receiveObserver?(chunk)
                    handshakeBytes += chunk.count
                    let step: HandshakeStep
                    (handshake, step) = try await Self.receive(chunk, into: handshake, on: handshakeQueue)
                    guard !Task.isCancelled else { throw RFBError.cancelled }
                    if !step.outgoing.isEmpty {
                        try await connection.sendAll(step.outgoing)
                    }
                    if let result = step.result {
                        return .success(result)
                    }
                }
            } catch {
                return .failure(error)
            }
        } onCancel: {
            connection.cancel()
        }

        bytesReceived += Int64(handshakeBytes)
        // Freeze the race with the deadline once: whatever happens later cannot rewrite the outcome.
        let expired = !deadline.complete()
        let cancelled = Task.isCancelled
        switch outcome {
        case .success(let result) where !expired && !cancelled:
            pendingBytes = result.remainder
            serverInit = result.serverInit
            return result
        case .success:
            release(connection)
            throw cancelled ? .cancelled : .timeout
        case .failure(let error):
            release(connection)
            throw Self.failure(error, handshake: handshake, expired: expired, cancelled: cancelled)
        }
    }

    /// Starts the framebuffer protocol after a successful `open`: sends SetPixelFormat
    /// (`PixelFormat.bgra32`), SetEncodings and a full FramebufferUpdateRequest, then decodes every
    /// server message off the cooperative pool and delivers the events in order.
    ///
    /// - With `requestUpdatesAutomatically`, one update is in flight at a time: the incremental
    ///   FramebufferUpdateRequest for the next one is sent when the consumer *takes* an update from
    ///   the sequence, not when it is decoded, so a slow consumer slows the server down instead of
    ///   piling up updates. After a resize, a full (non-incremental) request at the new size is sent
    ///   at once. Without it, call `requestUpdate`; events then queue until consumed.
    /// - The sequence throws an `RFBError`: `.connectionClosed` when the server hangs up,
    ///   `.protocolViolation` for malformed data, `.network` for a transport error. Either way the
    ///   connection is closed.
    /// - `close()`, dropping the sequence or cancelling the task iterating it ends the iteration with
    ///   `nil` (an async stream does not throw on cancellation) and closes the connection at once.
    /// - Throws `.cancelled` if `close()` runs, or the calling task is cancelled, while the opening
    ///   messages are being sent.
    public func startSession(encodings: [Int32] = Encoding.preferred,
                             requestUpdatesAutomatically: Bool = true) async throws(RFBError) -> RFBSessionEvents {
        guard let connection, let serverInit else { throw .protocolViolation("not connected") }
        guard sessionID == nil else { throw .protocolViolation("session already started") }
        // Claimed before the first suspension so a concurrent call sees it (actor reentrancy).
        let id = SessionID()
        sessionID = id
        clipboard = ClipboardNegotiation(sharing: clipboard.sharing)   // no caps from an earlier session
        let pump = try FramebufferPump(width: Int(serverInit.width), height: Int(serverInit.height))
        self.pump = pump
        let initial = pendingBytes
        pendingBytes = Data()
        let opening = ClientMessage.setPixelFormat(.bgra32).wireBytes + ClientMessage.setEncodings(encodings).wireBytes
            + ClientMessage.framebufferUpdateRequest(incremental: false, x: 0, y: 0,
                                                     width: serverInit.width, height: serverInit.height).wireBytes
        var failure: RFBError?
        do {
            try await withTaskCancellationHandler {
                try await connection.sendAll(Data(opening))
            } onCancel: {
                connection.cancel()
            }
        } catch {
            failure = Task.isCancelled ? .cancelled : (error as? RFBError) ?? .network(String(describing: error))
        }
        // `close()` (and maybe a newer `open()`) may have run while the opening was being sent.
        guard sessionID === id, self.connection === connection else {
            connection.cancel()
            throw .cancelled
        }
        if let failure {
            sessionID = nil
            self.pump = nil
            release(connection)
            throw failure
        }

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RFBEvent.self)
        // Untyped task closure: a typed-throws `Task` closure crashes the Swift 6.4 compiler (IRGen).
        let task = Task {
            do {
                var chunk: Data? = initial
                while let received = chunk {
                    if !received.isEmpty {
                        for event in try await pump.receive(received) {
                            switch event {
                            case .serverCutText, .extendedClipboard:
                                // Answered here (caps, request, peek, notify); only text reaches the consumer.
                                let (replies, text) = self.clipboard.handle(event)
                                if !replies.isEmpty { try await connection.sendAll(Data(replies.flatMap(\.wireBytes))) }
                                if let text { continuation.yield(.serverCutText(text)) }
                                continue
                            default:
                                continuation.yield(event)
                            }
                            guard requestUpdatesAutomatically, case .desktopResized(let width, let height) = event else {
                                continue
                            }
                            let request = ClientMessage.framebufferUpdateRequest(
                                incremental: false, x: 0, y: 0, width: UInt16(width), height: UInt16(height))
                            try await connection.sendAll(Data(request.wireBytes))
                        }
                    }
                    guard !Task.isCancelled else { break }
                    chunk = try await connection.receiveChunk()
                    // `initial` was counted by `open` (it is the tail of a handshake chunk).
                    self.bytesReceived += Int64(chunk?.count ?? 0)
                }
                // After `close()` or the consumer's cancellation the stream is already finished: no-op.
                continuation.finish(throwing: Task.isCancelled ? nil : RFBError.connectionClosed)
            } catch {
                continuation.finish(throwing: Task.isCancelled ? nil : (error as? RFBError) ?? .network(String(describing: error)))
            }
            self.sessionDidEnd(id)
        }
        continuation.onTermination = { _ in
            task.cancel()
            connection.cancel()
        }
        sessionTask = task
        sessionContinuation = continuation
        guard requestUpdatesAutomatically else { return RFBSessionEvents(stream: stream, onUpdateConsumed: nil) }
        return RFBSessionEvents(stream: stream) { @Sendable (update: FramebufferUpdate) in
            let request = ClientMessage.framebufferUpdateRequest(
                incremental: true, x: 0, y: 0, width: UInt16(update.width), height: UInt16(update.height))
            // Fire and forget: a send failure also fails the receive loop, which reports it.
            connection.send(content: Data(request.wireBytes), completion: .contentProcessed { _ in })
        }
    }

    /// Forgets a session whose stream ended, unless `close()` (and maybe a newer session) replaced it.
    private func sessionDidEnd(_ id: SessionID) {
        guard sessionID === id else { return }
        connection?.cancel()
        sessionID = nil
        sessionContinuation = nil
        sessionTask = nil
        serverInit = nil
        connection = nil   // the pump stays: `framebufferSnapshot()` still returns the last frame
    }

    /// Turns the shared clipboard on or off for this connection (Machine.sharedClipboard). Off, nothing
    /// is sent, the server's requests get no text, and received text is dropped. Turning it off also
    /// forgets the text last shared.
    public func setClipboardSharing(_ on: Bool) {
        clipboard.sharing = on
    }

    /// Shares local clipboard text with the server: an extended provide (UTF-8), or a notify the
    /// server answers with a request, when its caps allow; Latin-1 ClientCutText otherwise
    /// (`ClipboardText.latin1Bytes`). Nothing is sent when sharing is off or the text is too large
    /// (`ClipboardShare`).
    @discardableResult
    public func shareClipboard(_ text: String) async throws(RFBError) -> ClipboardShare {
        let (messages, outcome) = clipboard.share(text)
        if !messages.isEmpty { try await send(messages) }
        return outcome
    }

    /// Asks for an update of the whole framebuffer (incremental: only what changed).
    public func requestUpdate(incremental: Bool = true) async throws(RFBError) {
        guard let pump else { throw .protocolViolation("session not started") }
        let size = await pump.framebufferSize
        try await send(.framebufferUpdateRequest(incremental: incremental, x: 0, y: 0,
                                                 width: UInt16(size.width), height: UInt16(size.height)))
    }

    /// Sends one client message (key and pointer events, update requests…).
    public func send(_ message: ClientMessage) async throws(RFBError) {
        try await send([message])
    }

    /// Sends several client messages in one write, in order (see `InputSender`).
    public func send(_ messages: [ClientMessage]) async throws(RFBError) {
        guard let connection else { throw .protocolViolation("not connected") }
        do {
            try await connection.sendAll(Data(messages.flatMap(\.wireBytes)))
        } catch {
            throw (error as? RFBError) ?? .network(String(describing: error))
        }
    }

    /// A copy of the current framebuffer once the session has started (still the last frame after
    /// the server hung up, until `close()`).
    public func framebufferSnapshot() async -> Framebuffer? {
        await pump?.framebuffer
    }

    /// Closes the connection. A running session stream finishes without error.
    public func close() {
        sessionID = nil
        sessionContinuation?.finish()
        sessionContinuation = nil
        sessionTask?.cancel()
        sessionTask = nil
        pump = nil
        serverInit = nil
        connection?.cancel()
        connection = nil
    }

    /// Cancels `connection` and forgets it, unless `close()` and a newer `open()` already replaced it
    /// while this call was suspended (actor reentrancy).
    private func release(_ connection: NWConnection) {
        connection.cancel()
        if self.connection === connection { self.connection = nil }
    }

    /// The error reported for a failed `open`, by priority: cancellation, deadline, then the error
    /// itself. A transport error (e.g. ECONNRESET) right after the credentials were sent goes through
    /// the same EOF heuristic as a clean close (`RFBHandshake.errorForClosedConnection`).
    static func failure(_ error: any Error, handshake: RFBHandshake, expired: Bool, cancelled: Bool) -> RFBError {
        if cancelled { return .cancelled }
        if expired { return .timeout }
        let error = (error as? RFBError) ?? .network(String(describing: error))
        if case .network = error, case .authFailed = handshake.errorForClosedConnection() {
            return handshake.errorForClosedConnection()
        }
        return error
    }

    /// Runs `handshake.receive(chunk)` on `queue` and hands back the advanced state machine.
    private static func receive(_ chunk: Data, into handshake: RFBHandshake,
                                on queue: DispatchQueue) async throws -> (RFBHandshake, HandshakeStep) {
        let (advanced, result) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(RFBHandshake, Result<HandshakeStep, RFBError>), Never>) in
            queue.async {
                var handshake = handshake
                let result: Result<HandshakeStep, RFBError>
                do throws(RFBError) {
                    result = .success(try handshake.receive(chunk))
                } catch {
                    result = .failure(error)
                }
                continuation.resume(returning: (handshake, result))
            }
        }
        return (advanced, try result.get())
    }
}

/// Identity token of one `startSession` call.
private final class SessionID: Sendable {}

/// The events of a session (see `RFBConnection.startSession`). With automatic update requests, taking
/// a complete `.framebufferUpdate` from the iterator is what asks the server for the next one.
public struct RFBSessionEvents: AsyncSequence, Sendable {
    public typealias Element = RFBEvent

    let stream: AsyncThrowingStream<RFBEvent, any Error>
    let onUpdateConsumed: (@Sendable (FramebufferUpdate) -> Void)?

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: stream.makeAsyncIterator(), onUpdateConsumed: onUpdateConsumed)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<RFBEvent, any Error>.AsyncIterator
        let onUpdateConsumed: (@Sendable (FramebufferUpdate) -> Void)?

        public mutating func next() async throws -> RFBEvent? {
            let event = try await base.next()
            // A partial update (before a mid-message resize) is followed by the rest of its message.
            if case .framebufferUpdate(let update)? = event, update.completesMessage {
                onUpdateConsumed?(update)
            }
            return event
        }
    }
}

/// One-shot race between the handshake completing and the timeout firing.
private final class Deadline: Sendable {
    private enum Outcome { case pending, completed, expired }
    private let outcome = OSAllocatedUnfairLock(initialState: Outcome.pending)

    /// Marks the deadline as passed; `true` if the handshake had not completed.
    func expire() -> Bool {
        outcome.withLock { outcome in
            guard outcome == .pending else { return false }
            outcome = .expired
            return true
        }
    }

    /// Marks the attempt as finished; `false` if the deadline had already passed.
    func complete() -> Bool {
        outcome.withLock { outcome in
            guard outcome == .pending else { return false }
            outcome = .completed
            return true
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
