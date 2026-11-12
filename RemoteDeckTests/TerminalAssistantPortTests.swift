import Foundation
import Testing
@testable import RemoteDeck

// Plan (terminal assistant) Task 5: the port on `TerminalSessionModel`, over the fake connection and
// surface (no socket).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalAssistantPortTests {
    private func connected() async throws -> (TerminalHarness, TerminalSessionModel, FakeSSHSessionConnection) {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let model = harness.model()
        model.connect()
        try await harness.connected(model)
        return (harness, model, try #require(harness.last))
    }

    @Test func typeSendsCommandAndReturnInOneChunk() async throws {
        let (_, model, fake) = try await connected()
        #expect(model.assistantCanAct)
        model.assistantType("df -h")
        #expect(await waitUntil { fake.shell.writes.count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fake.shell.writes == [Data("df -h\r".utf8)])
        model.assistantType("printf 'é 🎉'")
        #expect(await waitUntil { fake.shell.writes.count == 2 })
        #expect(fake.shell.writes.last == Data("printf 'é 🎉'\r".utf8))
        await model.close()
    }

    @Test func sendKeysEncodesNamedKeys() async throws {
        let (harness, model, fake) = try await connected()
        model.assistantSendKeys([.ctrlC, .q])
        #expect(await waitUntil { fake.shell.writes.count == 1 })
        #expect(fake.shell.writes == [Data([0x03, 0x71])])
        harness.surface.cursorKeysApplication = true
        model.assistantSendKeys([.up, .return])
        #expect(await waitUntil { fake.shell.writes.count == 2 })
        #expect(fake.shell.writes.last == Data([0x1B, 0x4F, 0x41, 0x0D]))
        await model.close()
    }

    @Test func nothingIsTypedWhenNotConnected() async throws {
        let (_, model, fake) = try await connected()
        let before = harness(fake)
        await model.close()
        #expect(!model.assistantCanAct)
        model.assistantType("rm -rf /tmp/x")
        model.assistantSendKeys([.return])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fake.shell.writes.count == before)
        #expect(await model.assistantWaitForOutput(cap: .seconds(15)) == .sessionEnded)
    }

    private func harness(_ fake: FakeSSHSessionConnection) -> Int { fake.shell.writes.count }

    @Test func userInputPassesWhileWaitingForConfirm() async throws {
        let (harness, model, fake) = try await connected()
        // A proposal waits (nothing is being sent): the user's keys reach the shell.
        harness.surface.type("ls")
        #expect(await waitUntil { fake.shell.written == Data("ls".utf8) })
        await model.close()
    }

    @Test func userInputIsHeldBackWhileTheAssistantSends() async throws {
        let (harness, model, fake) = try await connected()
        model.assistantIsSending = true
        harness.surface.type("x")
        model.assistantType("uptime")
        model.assistantIsSending = false
        harness.surface.type("y")
        #expect(await waitUntil { fake.shell.written == Data("uptime\ry".utf8) })
        await model.close()
    }

    @Test func snapshotWaitsForPendingBytes() async throws {
        let (harness, model, _) = try await connected()
        harness.surface.pendingBytes = 10
        final class Box { var shot: TerminalSnapshot?? }
        let box = Box()
        Task { box.shot = .some(await model.assistantSnapshot()) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(box.shot == nil)
        harness.surface.pendingBytes = 0
        #expect(await waitUntil { box.shot != nil })
        #expect(box.shot == .some(harness.surface.snapshotValue))
        await model.close()
    }

    @Test func commandEndFromOSC133ReachesTheSettler() async throws {
        let (harness, model, fake) = try await connected()
        final class Box { var wait: OutputWait? }
        let box = Box()
        Task { box.wait = await model.assistantWaitForOutput(cap: .seconds(15)) }
        try? await Task.sleep(for: .milliseconds(50))
        fake.shell.emit("output\r\n")
        try? await Task.sleep(for: .milliseconds(50))
        harness.surface.onCommandEnd(3)
        #expect(await waitUntil { box.wait != nil })
        #expect(box.wait == .commandEnded(exitCode: 3))
        await model.close()
    }

    @Test func teardownEndsAWaitForOutput() async throws {
        let (_, model, _) = try await connected()
        final class Box { var wait: OutputWait? }
        let box = Box()
        Task { box.wait = await model.assistantWaitForOutput(cap: .seconds(15)) }
        try? await Task.sleep(for: .milliseconds(50))
        await model.close()
        #expect(await waitUntil { box.wait != nil })
        #expect(box.wait == .sessionEnded)
    }
}
