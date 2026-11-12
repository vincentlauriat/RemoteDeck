import Foundation
import Testing
@testable import RemoteDeck

// Plan (terminal assistant) Task 4: when the output of a confirmed command has settled, on a fake clock.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OutputSettlerTests {
    private let clock = FakeReachabilityClock()
    private let quiet = Duration.milliseconds(700)
    private let grace = Duration.seconds(2)
    private let cap = Duration.seconds(15)

    private final class Screen {
        var snapshot = TerminalSnapshot(screen: ["pi@raspberrypi:~ $ sudo apt update"], cursorRow: 0, cursorColumn: 34)
    }

    private func start(_ settler: OutputSettler, screen: Screen = Screen(), cap: Duration? = nil) -> Task<OutputWait, Never> {
        let cap = cap ?? self.cap
        return Task { await settler.wait(cap: cap) { screen.snapshot } }
    }

    /// The task's value, or nil if it does not end within 3 s (a failure, never a hang).
    private func finished(_ task: Task<OutputWait, Never>) async -> OutputWait? {
        final class Box { var value: OutputWait? }
        let box = Box()
        Task { box.value = await task.value }
        _ = await waitUntil { box.value != nil }
        return box.value
    }

    @Test func settlesAfterQuietPeriod() async {
        let settler = OutputSettler(clock: clock)
        let wait = start(settler)
        #expect(await waitUntil { clock.pending(grace) == 1 })
        #expect(clock.pending(cap) == 1)
        settler.outputArrived()
        #expect(await waitUntil { clock.pending(quiet) == 1 && clock.pending(grace) == 0 })
        // More output restarts the quiet period: the earlier one no longer counts.
        settler.outputArrived()
        // The earlier sleep goes away (cancelled), the new one registers: both asynchronously.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await waitUntil { clock.pending(quiet) == 1 })
        clock.fire(quiet)
        #expect(await finished(wait) == .settled)
        #expect(await waitUntil { clock.pendingCount == 0 })
    }

    @Test func noOutputSettlesAfterGrace() async {
        let settler = OutputSettler(clock: clock)
        let wait = start(settler)
        #expect(await waitUntil { clock.pending(grace) == 1 })
        clock.fire(grace)
        #expect(await finished(wait) == .settled)
    }

    @Test func commandEndWinsAtOnce() async {
        let settler = OutputSettler(clock: clock)
        let wait = start(settler)
        #expect(await waitUntil { clock.pending(grace) == 1 })
        settler.outputArrived()
        settler.commandEnded(exitCode: 1)
        #expect(await finished(wait) == .commandEnded(exitCode: 1))
        #expect(await waitUntil { clock.pendingCount == 0 })
    }

    @Test func capGivesStillRunning() async {
        let settler = OutputSettler(clock: clock)
        let wait = start(settler)
        #expect(await waitUntil { clock.pending(cap) == 1 })
        settler.outputArrived()
        clock.fire(cap)
        #expect(await finished(wait) == .stillRunning(seconds: 15))

        let long = start(settler, cap: .seconds(120))
        #expect(await waitUntil { clock.pending(.seconds(120)) == 1 })
        clock.fire(.seconds(120))
        #expect(await finished(long) == .stillRunning(seconds: 120))
    }

    @Test func passwordPromptEndsTheWaitAtOnce() async {
        let settler = OutputSettler(clock: clock)
        let screen = Screen()
        let wait = start(settler, screen: screen)
        #expect(await waitUntil { clock.pending(grace) == 1 })
        screen.snapshot = TerminalSnapshot(screen: ["$ sudo apt update", "[sudo] password for pi:"], cursorRow: 1,
                                           cursorColumn: 23)
        settler.outputArrived()
        #expect(await finished(wait) == .passwordPrompt)
        #expect(await waitUntil { clock.pendingCount == 0 })
    }

    @Test func passwordPromptAtAQuietWakeEndsTheWait() async {
        let settler = OutputSettler(clock: clock)
        let screen = Screen()
        let wait = start(settler, screen: screen)
        #expect(await waitUntil { clock.pending(grace) == 1 })
        screen.snapshot = TerminalSnapshot(screen: ["Password:"], cursorRow: 0, cursorColumn: 9)
        clock.fire(grace)
        #expect(await finished(wait) == .passwordPrompt)
    }

    @Test func sessionEndedEndsTheWait() async {
        let settler = OutputSettler(clock: clock)
        let wait = start(settler)
        #expect(await waitUntil { clock.pending(grace) == 1 })
        settler.sessionEnded()
        #expect(await finished(wait) == .sessionEnded)
        #expect(await waitUntil { clock.pendingCount == 0 })
    }

    @Test func cancellingTheWaitEndsIt() async {
        let settler = OutputSettler(clock: clock)
        let wait = start(settler)
        #expect(await waitUntil { clock.pending(grace) == 1 })
        wait.cancel()
        #expect(await finished(wait) == .sessionEnded)
        #expect(await waitUntil { clock.pendingCount == 0 })
    }
}
