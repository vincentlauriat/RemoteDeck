import Foundation
import Network
import os

/// How an established session notices a connection that died without a FIN or a reset (T5.1): the
/// Mac switched from Wi-Fi to Ethernet with the path still satisfied, the server lost power, a NAT
/// forgot the flow. Without this an idle session would stay "connected" on a dead socket until the
/// next write timed out.
///
/// - TCP keepalive: after `keepaliveIdle` s without traffic, a probe every `keepaliveInterval` s;
///   `keepaliveCount` unanswered probes and the kernel resets the connection (≈ 25 s with the
///   defaults: 10 + 3 × 5), which ends the session's read with an error.
/// - Viability: Network.framework reports the connection not viable when its interface goes away;
///   if it stays so for `viabilityGrace`, the connection is cancelled (a shorter blip is ignored).
public struct ConnectionLiveness: Sendable, Equatable {
    public var keepaliveIdle = 10
    public var keepaliveInterval = 5
    public var keepaliveCount = 3
    public var viabilityGrace: Duration = .seconds(5)

    public init() {}

    /// TCP options for an RFB session: keepalive on, with these timings.
    public func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = keepaliveIdle
        tcp.keepaliveInterval = keepaliveInterval
        tcp.keepaliveCount = keepaliveCount
        return tcp
    }

    public func parameters() -> NWParameters {
        NWParameters(tls: nil, tcp: tcpOptions())
    }
}

/// Pure: whether a connection whose path stopped being viable counts as dead. Each change of
/// viability starts a new period; a timer armed for one period only counts if nothing changed since.
package struct ViabilityState: Sendable, Equatable {
    package private(set) var isViable = true
    package private(set) var period = 0

    package init() {}

    /// Returns the period to arm the grace timer for when the connection just became not viable.
    package mutating func update(viable: Bool) -> Int? {
        guard viable != isViable else { return nil }
        isViable = viable
        period += 1
        return viable ? nil : period
    }

    /// The timer armed for `period` fired: dead if the connection has stayed not viable since.
    package func isDead(timerFor period: Int) -> Bool {
        !isViable && period == self.period
    }
}

/// Feeds `NWConnection.viabilityUpdateHandler` into `ViabilityState` and calls `onDead` when a loss
/// of viability outlasts `grace` (only the latest loss's timer can count).
package final class ViabilityWatchdog: Sendable {
    /// Runs `body` after `delay` (a dispatch queue in the app; a manual timer in tests).
    package typealias Schedule = @Sendable (_ delay: Duration, _ body: @escaping @Sendable () -> Void) -> Void

    private let state = OSAllocatedUnfairLock(initialState: ViabilityState())
    private let grace: Duration
    private let schedule: Schedule
    private let onDead: @Sendable () -> Void

    package init(grace: Duration, schedule: @escaping Schedule, onDead: @escaping @Sendable () -> Void) {
        self.grace = grace
        self.schedule = schedule
        self.onDead = onDead
    }

    package convenience init(grace: Duration, queue: DispatchQueue, onDead: @escaping @Sendable () -> Void) {
        self.init(grace: grace, schedule: { delay, body in
            let (seconds, attoseconds) = delay.components
            queue.asyncAfter(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18, execute: body)
        }, onDead: onDead)
    }

    package func viabilityChanged(_ viable: Bool) {
        guard let period = state.withLock({ $0.update(viable: viable) }) else { return }
        schedule(grace) { [self] in
            if state.withLock({ $0.isDead(timerFor: period) }) { onDead() }
        }
    }
}
