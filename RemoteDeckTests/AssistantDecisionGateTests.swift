import Foundation
import Testing
@testable import RemoteDeck

/// A sleep that returns only when the test opens it (arming under control).
@MainActor
final class ManualArming {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiters.count }

    nonisolated func sleep(_: Duration) async {
        await withCheckedContinuation { continuation in
            Task { @MainActor in self.waiters.append(continuation) }
        }
    }

    func open() {
        let open = waiters
        waiters = []
        open.forEach { $0.resume() }
    }
}

// Plan (terminal assistant) Task 3: the confirmation rules shared by the screen and terminal assistants.
@MainActor
struct AssistantDecisionGateTests {
    private func pending(_ gate: AssistantDecisionGate, _ id: String) -> Task<AssistantDecisionGate.Decision, Never> {
        Task { await gate.decide(id: id) }
    }

    @Test func confirmBeforeArmingIsIgnored() async {
        let arming = ManualArming()
        let gate = AssistantDecisionGate(armDelay: .milliseconds(400), sleep: { await arming.sleep($0) })
        let decision = pending(gate, "a")
        #expect(await waitUntil { gate.pendingID == "a" && arming.count == 1 })
        gate.confirm(id: "a")
        #expect(gate.pendingID == "a")
        #expect(!gate.isArmed)
        arming.open()
        #expect(await waitUntil { gate.isArmed })
        gate.confirm(id: "a")
        #expect(await decision.value == .confirmed)
    }

    @Test func confirmAfterArmingResolves() async {
        let gate = AssistantDecisionGate(armDelay: .zero)
        let decision = pending(gate, "a")
        #expect(await waitUntil { gate.isArmed })
        gate.confirm(id: "a")
        #expect(await decision.value == .confirmed)
        #expect(gate.pendingID == nil)
        #expect(!gate.isArmed)
    }

    @Test func confirmWithAnotherIDIsIgnored() async {
        let gate = AssistantDecisionGate(armDelay: .zero)
        let decision = pending(gate, "a")
        #expect(await waitUntil { gate.isArmed })
        gate.confirm(id: "b")
        gate.skip(id: "b")
        #expect(gate.pendingID == "a")
        gate.skip(id: "a")
        #expect(await decision.value == .skipped)
    }

    @Test func stopResolvesPendingAsStopped() async {
        let gate = AssistantDecisionGate(armDelay: .zero)
        let decision = pending(gate, "a")
        #expect(await waitUntil { gate.pendingID == "a" })
        gate.stopAll()
        #expect(await decision.value == .stopped)
        #expect(gate.pendingID == nil)
        // Nothing pending: harmless.
        gate.stopAll()
    }

    @Test func aCancelledTaskIsStoppedWithoutWaiting() async {
        let gate = AssistantDecisionGate(armDelay: .zero)
        let decision = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await gate.decide(id: "a")
        }
        #expect(await decision.value == .stopped)
        #expect(gate.pendingID == nil)
    }

    @Test func armingCanWaitForAReveal() async {
        let gate = AssistantDecisionGate(armDelay: .zero)
        let decision = Task { await gate.decide(id: "a", armsNow: false) }
        #expect(await waitUntil { gate.pendingID == "a" })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!gate.isArmed)
        gate.arm("a")
        #expect(await waitUntil { gate.isArmed })
        gate.confirm(id: "a")
        #expect(await decision.value == .confirmed)
    }

    @Test func pausesAfterEightTurnsWithoutAction() {
        let gate = AssistantDecisionGate()
        #expect(AssistantDecisionGate.maxStepsWithoutAction == 8)
        for turn in 1...7 {
            gate.recordTurn(confirmedAction: false)
            #expect(gate.stepsWithoutAction == turn)
            #expect(!gate.shouldPause)
        }
        gate.recordTurn(confirmedAction: false)
        #expect(gate.shouldPause)
        gate.resetSteps()
        #expect(gate.stepsWithoutAction == 0)
        #expect(!gate.shouldPause)
    }

    @Test func aConfirmedActionResetsTheCounter() {
        let gate = AssistantDecisionGate()
        for _ in 1...5 { gate.recordTurn(confirmedAction: false) }
        gate.recordTurn(confirmedAction: true)
        #expect(gate.stepsWithoutAction == 0)
    }
}
