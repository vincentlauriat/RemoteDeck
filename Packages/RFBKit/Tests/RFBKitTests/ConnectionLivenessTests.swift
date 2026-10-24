import Foundation
import Network
import os
import Testing
@testable import RFBKit

/// T5.1: how a session notices a dead connection (TCP keepalive, viability grace). Network.framework
/// cannot be made to report a non-viable loopback connection, so the viability side is tested on
/// the pure state and the watchdog's timers; the live check is on a real interface change.
struct ConnectionLivenessTests {
    @Test func sessionConnectionsUseKeepalive() throws {
        let liveness = ConnectionLiveness()
        #expect(liveness.keepaliveIdle == 10 && liveness.keepaliveInterval == 5 && liveness.keepaliveCount == 3)
        #expect(liveness.viabilityGrace == .seconds(5))
        let tcp = try #require(liveness.parameters().defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
        #expect(tcp.enableKeepalive)
        #expect(tcp.keepaliveIdle == 10)
        #expect(tcp.keepaliveInterval == 5)
        #expect(tcp.keepaliveCount == 3)
        #expect(RFBConnection(host: "127.0.0.1").liveness == liveness)
    }

    /// The session's real connection carries the keepalive (loopback, security type None).
    @Test(.timeLimit(.minutes(1))) func openedConnectionUsesTheKeepalive() async throws {
        let server = try await FakeRFBServer(script: [
            .send(ServerMessage.banner("RFB 003.008\n")), .receive(12),
            .send([1, 1]), .receive(1),
            .send(ServerMessage.securityResult(0)), .receive(1),
            .send(ServerMessage.serverInit(name: "loopback")),
        ])
        defer { server.stop() }
        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        _ = try await connection.open(credentials: RFBCredentials(), timeout: .seconds(10))
        let tcp = try #require(await connection.tcpOptionsInUse)
        #expect(tcp.enableKeepalive)
        #expect(tcp.keepaliveIdle == 10 && tcp.keepaliveInterval == 5 && tcp.keepaliveCount == 3)
        await connection.close()
    }

    @Test func viabilityStateCountsOnlyAnUnbrokenLoss() {
        var state = ViabilityState()
        #expect(state.update(viable: true) == nil)          // already viable: nothing to arm
        let first = state.update(viable: false)
        #expect(first == 1)
        #expect(state.update(viable: false) == nil)         // still lost: the first timer stands
        #expect(state.isDead(timerFor: 1))
        #expect(state.update(viable: true) == nil)
        #expect(!state.isDead(timerFor: 1))                 // came back before the timer
        let second = state.update(viable: false)
        #expect(second == 3)
        #expect(!state.isDead(timerFor: 1))                 // an old timer never counts
        #expect(state.isDead(timerFor: 3))
    }

    /// Timers the test fires by hand (no wall clock: deterministic under load).
    final class ManualTimers: Sendable {
        private let pending = OSAllocatedUnfairLock(initialState: [(Duration, @Sendable () -> Void)]())
        var schedule: ViabilityWatchdog.Schedule { { delay, body in self.pending.withLock { $0.append((delay, body)) } } }
        var delays: [Duration] { pending.withLock { $0.map(\.0) } }
        /// Fires the oldest pending timer.
        func fireNext() {
            let body = pending.withLock { $0.isEmpty ? nil : $0.removeFirst().1 }
            body?()
        }
    }

    @Test func watchdogCancelsOnlyALossThatOutlastsTheGrace() {
        let deaths = OSAllocatedUnfairLock(initialState: 0)

        let blipTimers = ManualTimers()
        let blip = ViabilityWatchdog(grace: .seconds(5), schedule: blipTimers.schedule) { deaths.withLock { $0 += 1 } }
        blip.viabilityChanged(true)                         // already viable: no timer
        #expect(blipTimers.delays.isEmpty)
        blip.viabilityChanged(false)
        #expect(blipTimers.delays == [.seconds(5)])
        blip.viabilityChanged(true)                         // back within the grace
        blipTimers.fireNext()
        #expect(deaths.withLock { $0 } == 0)

        let lostTimers = ManualTimers()
        let lost = ViabilityWatchdog(grace: .seconds(5), schedule: lostTimers.schedule) { deaths.withLock { $0 += 1 } }
        lost.viabilityChanged(false)
        lost.viabilityChanged(true)
        lost.viabilityChanged(false)                        // lost again: its own full grace
        #expect(lostTimers.delays == [.seconds(5), .seconds(5)])
        lostTimers.fireNext()                               // the first loss's timer: stale
        #expect(deaths.withLock { $0 } == 0)
        lostTimers.fireNext()                               // the second one, still lost: dead
        #expect(deaths.withLock { $0 } == 1)
    }

    /// The dispatch-queue timer the app uses really fires after the grace.
    @Test func queueTimerFires() async {
        let deaths = OSAllocatedUnfairLock(initialState: 0)
        let watchdog = ViabilityWatchdog(grace: .milliseconds(20), queue: DispatchQueue(label: "test.viability")) {
            deaths.withLock { $0 += 1 }
        }
        watchdog.viabilityChanged(false)
        let deadline = ContinuousClock.now + .seconds(5)
        while deaths.withLock({ $0 }) == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(deaths.withLock { $0 } == 1)
    }
}
