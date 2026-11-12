import Foundation

/// How a wait for a command's output ended (spec › Output settling).
enum OutputWait: Equatable, Sendable {
    /// Quiet for `quiet` after the last output (or `firstOutputGrace` with none at all).
    case settled
    /// OSC 133 COMMAND_END, when the remote shell emits marks.
    case commandEnded(exitCode: Int?)
    /// The cap passed with output still coming (a long build, `top`).
    case stillRunning(seconds: Int)
    /// A password prompt showed: the user types it, the assistant waits.
    case passwordPrompt
    /// The shell went away, or the wait was cancelled.
    case sessionEnded
}

/// Waits for a terminal's output to settle after a confirmed action: done at once on a command end
/// (OSC 133) or a password prompt, otherwise after `quiet` without output (measured from the last
/// output, or from the start when nothing comes within `firstOutputGrace`), at most `cap`. Times go
/// through an injected clock.
@MainActor
final class OutputSettler {
    static let defaultQuiet: Duration = .milliseconds(700)
    static let defaultFirstOutputGrace: Duration = .seconds(2)
    /// After a `run_command` or `send_keys`.
    static let actionCap: Duration = .seconds(15)
    /// `wait_for_output`'s longest wait.
    static let maxWaitSeconds = 120

    private let clock: any ReachabilityClock
    private let quiet: Duration
    private let firstOutputGrace: Duration

    private var waiter: CheckedContinuation<OutputWait, Never>?
    private var snapshot: (@MainActor () -> TerminalSnapshot?)?
    private var capTimer: Task<Void, Never>?
    private var phaseTimer: Task<Void, Never>?
    /// The current wait; a timer of an earlier wait or phase changes nothing.
    private var waitToken = 0
    private var phaseToken = 0

    init(clock: any ReachabilityClock, quiet: Duration = OutputSettler.defaultQuiet,
         firstOutputGrace: Duration = OutputSettler.defaultFirstOutputGrace) {
        self.clock = clock
        self.quiet = quiet
        self.firstOutputGrace = firstOutputGrace
    }

    var isWaiting: Bool { waiter != nil }

    /// Bytes of shell output were delivered.
    func outputArrived() {
        guard waiter != nil else { return }
        if checkPasswordPrompt() { return }
        startPhase(quiet)
    }

    func commandEnded(exitCode: Int?) {
        finish(.commandEnded(exitCode: exitCode))
    }

    func sessionEnded() {
        finish(.sessionEnded)
    }

    func wait(cap: Duration, snapshot: @escaping @MainActor () -> TerminalSnapshot?) async -> OutputWait {
        finish(.sessionEnded)   // one wait at a time
        waitToken += 1
        let token = waitToken
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .sessionEnded)
                    return
                }
                waiter = continuation
                self.snapshot = snapshot
                startPhase(firstOutputGrace)
                let seconds = Int(cap.components.seconds)
                capTimer = Task { [weak self, clock] in
                    do { try await clock.sleep(for: cap) } catch { return }
                    guard let self, self.waitToken == token else { return }
                    self.finish(.stillRunning(seconds: seconds))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.waitToken == token else { return }
                self.finish(.sessionEnded)
            }
        }
    }

    private func startPhase(_ duration: Duration) {
        phaseTimer?.cancel()
        phaseToken += 1
        let token = phaseToken
        phaseTimer = Task { [weak self, clock] in
            do { try await clock.sleep(for: duration) } catch { return }
            guard let self, self.phaseToken == token, self.waiter != nil else { return }
            if self.checkPasswordPrompt() { return }
            self.finish(.settled)
        }
    }

    /// Checked on every wake: a password prompt ends the wait at once.
    private func checkPasswordPrompt() -> Bool {
        guard let shot = snapshot?(), PasswordPromptDetector.isShowing(in: shot) else { return false }
        finish(.passwordPrompt)
        return true
    }

    private func finish(_ result: OutputWait) {
        guard let waiter else { return }
        self.waiter = nil
        snapshot = nil
        capTimer?.cancel()
        capTimer = nil
        phaseTimer?.cancel()
        phaseTimer = nil
        phaseToken += 1
        waiter.resume(returning: result)
    }
}
