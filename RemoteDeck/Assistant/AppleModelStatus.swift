import Foundation
import Observation

/// Reads whether the Apple model can answer (`SystemAppleModelChecker` in a normal launch; a fixed
/// answer under XCTest and in every `-LibraryDemo` mode, which never touch the real model).
@MainActor
protocol AppleModelChecking {
    /// `nil` when the model is available.
    func unavailability() -> AppleModelUnavailability?
}

struct FixedAppleModelChecker: AppleModelChecking {
    var reason: AppleModelUnavailability?

    func unavailability() -> AppleModelUnavailability? { reason }
}

/// The Apple model's availability for Settings › Assistant and the Assistant Panel. Read again on
/// `refresh()` (the model may finish downloading, Apple Intelligence may be turned on meanwhile).
@Observable
@MainActor
final class AppleModelStatus {
    private(set) var unavailability: AppleModelUnavailability?
    @ObservationIgnored private let checker: any AppleModelChecking

    init(checker: any AppleModelChecking) {
        self.checker = checker
        unavailability = checker.unavailability()
    }

    var isAvailable: Bool { unavailability == nil }
    /// macOS 15–26: the Apple row is shown disabled.
    var isSupportedOS: Bool { unavailability != .requiresNewerOS }

    func refresh() {
        let current = checker.unavailability()
        if current != unavailability { unavailability = current }
    }
}
