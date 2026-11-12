import Foundation
import Observation

/// The confirmation rules both assistants share (screen `AssistantModel`, terminal
/// `TerminalAssistantModel`), whatever the provider:
/// - one proposal waits at a time, by its id; Confirm, Skip and Stop for any other id are ignored;
/// - Confirm is accepted only `armDelay` (400 ms) after the proposal is shown (or after `arm` when
///   the proposal must be opened first), so a held ⌘Return or a double click cannot confirm the next
///   proposal unseen;
/// - Stop resolves the waiting proposal as stopped; a task already cancelled never waits;
/// - `maxStepsWithoutAction` turns in a row without a confirmed action pause the loop.
///
/// Observable: the panels read `pendingID` and `isArmed` (through their models).
@Observable
@MainActor
final class AssistantDecisionGate {
    enum Decision: Equatable { case confirmed, skipped, stopped }

    static let defaultArmDelay: Duration = .milliseconds(400)
    /// Consecutive turns without a confirmed action before the loop pauses (T5.3 M3).
    static let maxStepsWithoutAction = 8

    /// The id of the proposal waiting for Confirm or Skip.
    private(set) var pendingID: String?
    /// Confirm is accepted.
    private(set) var isArmed = false
    /// Turns in a row that confirmed no action.
    private(set) var stepsWithoutAction = 0

    @ObservationIgnored private let armDelay: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var continuation: CheckedContinuation<Decision, Never>?

    init(armDelay: Duration = AssistantDecisionGate.defaultArmDelay,
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.armDelay = armDelay
        self.sleep = sleep
    }

    var shouldPause: Bool { stepsWithoutAction >= Self.maxStepsWithoutAction }

    /// Waits for the decision on `id`. `armsNow` false: Confirm arms only after `arm(id)`.
    func decide(id: String, armsNow: Bool = true) async -> Decision {
        await withCheckedContinuation { continuation in
            if Task.isCancelled {
                continuation.resume(returning: .stopped)
                return
            }
            self.continuation = continuation
            pendingID = id
            isArmed = false
            if armsNow { arm(id) }
        }
    }

    /// Confirm arms `armDelay` from now, if `id` still waits then.
    func arm(_ id: String) {
        Task { [weak self, armDelay, sleep] in
            await sleep(armDelay)
            if let self, self.pendingID == id { self.isArmed = true }
        }
    }

    func confirm(id: String) {
        guard id == pendingID, isArmed else { return }
        resolve(.confirmed)
    }

    func skip(id: String) {
        guard id == pendingID else { return }
        resolve(.skipped)
    }

    /// Stop or a teardown: the waiting proposal (if any) is stopped.
    func stopAll() {
        resolve(.stopped)
    }

    func recordTurn(confirmedAction: Bool) {
        stepsWithoutAction = confirmedAction ? 0 : stepsWithoutAction + 1
    }

    /// The user is here (Ask, Continue): a new count.
    func resetSteps() {
        stepsWithoutAction = 0
    }

    private func resolve(_ decision: Decision) {
        pendingID = nil
        isArmed = false
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: decision)
    }
}
