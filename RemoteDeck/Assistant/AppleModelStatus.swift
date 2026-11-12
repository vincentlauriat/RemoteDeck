import Foundation
import Observation

/// Reads whether the Apple model can answer (`SystemAppleModelChecker` in a normal launch; a fixed
/// answer under XCTest and in every `-LibraryDemo` mode, which never touch the real model).
@MainActor
protocol AppleModelChecking {
    /// `nil` when the model is available for `use`.
    func unavailability(for use: AppleModelUse) -> AppleModelUnavailability?
}

extension AppleModelChecking {
    /// Screens (the screen assistant's check, as before terminals had one).
    func unavailability() -> AppleModelUnavailability? { unavailability(for: .screens) }
}

struct FixedAppleModelChecker: AppleModelChecking {
    var reason: AppleModelUnavailability?
    var terminalReason: AppleModelUnavailability?

    /// The same answer for both uses.
    init(reason: AppleModelUnavailability?) {
        self.reason = reason
        terminalReason = reason
    }

    init(reason: AppleModelUnavailability?, terminalReason: AppleModelUnavailability?) {
        self.reason = reason
        self.terminalReason = terminalReason
    }

    func unavailability(for use: AppleModelUse) -> AppleModelUnavailability? {
        use == .screens ? reason : terminalReason
    }
}

/// The Apple model's availability for Settings › Assistant and the Assistant Panel. Read again on
/// `refresh()` (the model may finish downloading, Apple Intelligence may be turned on meanwhile).
@Observable
@MainActor
final class AppleModelStatus {
    /// Screens.
    private(set) var unavailability: AppleModelUnavailability?
    private(set) var terminalUnavailability: AppleModelUnavailability?
    @ObservationIgnored let checker: any AppleModelChecking

    init(checker: any AppleModelChecking) {
        self.checker = checker
        unavailability = checker.unavailability(for: .screens)
        terminalUnavailability = checker.unavailability(for: .terminals)
    }

    /// Screens.
    var isAvailable: Bool { unavailability == nil }
    var isTerminalAvailable: Bool { terminalUnavailability == nil }
    /// The Apple row is selectable when the macOS is new enough for screens or for terminals
    /// (macOS 15: shown disabled).
    var isSupportedOS: Bool { !Self.needsNewerOS(unavailability) || !Self.needsNewerOS(terminalUnavailability) }

    private static func needsNewerOS(_ reason: AppleModelUnavailability?) -> Bool {
        if case .requiresNewerOS? = reason { return true }
        return false
    }

    func refresh() {
        let current = checker.unavailability(for: .screens)
        if current != unavailability { unavailability = current }
        let terminal = checker.unavailability(for: .terminals)
        if terminal != terminalUnavailability { terminalUnavailability = terminal }
    }
}
