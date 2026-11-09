import Foundation
import SSHKit
import Testing
import RemoteDeckCore
@testable import RemoteDeck

// Plan Task 11 (AppFlow › Terminal tab › Port forwards, PRD AC 15, plan Review Focus 3): a machine's
// saved local forwards run with its terminal session. Fakes only: the hosted tests never bind a
// socket (`FakeSSHSessionConnection` hands out `FakeForward`s; real loopback binds are SSHKit's).

private let web = PortForward(label: "Pi web UI", localPort: 8080, remotePort: 80)
private let dns = PortForward(localPort: 8443, remoteHost: "pihole", remotePort: 443)
private let reconnectDelay: Duration = .seconds(2)

@MainActor
struct TerminalForwardTests {
    private func connectedHarness(failures: [UInt16: SSHError] = [:], hangs: Set<UInt16> = [])
        async throws -> (TerminalHarness, TerminalSessionModel) {
        let harness = try TerminalHarness(forwards: [web, dns])
        harness.trustServerKey()
        harness.makeFake = { _, log in
            FakeSSHSessionConnection(log: log, hostKey: serverKey, forwardFailures: failures, forwardHangs: hangs)
        }
        let model = harness.model()
        model.connect()
        return (harness, model)
    }

    private func allStopped(_ model: TerminalSessionModel) -> Bool {
        model.forwardStates[web.id] == .stopped && model.forwardStates[dns.id] == .stopped
    }

    private func allActive(_ model: TerminalSessionModel) -> Bool {
        model.forwardStates[web.id] == .active && model.forwardStates[dns.id] == .active
    }

    @Test func testForwardsStartWhenConnectedAndStopOnClose() async throws {
        let (harness, model) = try await connectedHarness()
        #expect(model.forwardStates[web.id] == .starting)   // "Starting…" while connecting
        try await harness.connected(model)
        #expect(await waitUntil { allActive(model) })
        let fake = try #require(harness.last)
        let starts = await fake.forwardStarts.map { "\($0.localPort)→\($0.remoteHost):\($0.remotePort)" }
        #expect(starts == ["8080→localhost:80", "8443→pihole:443"])
        // Started once the shell was open, never before.
        let log = harness.log.all
        #expect(try #require(log.firstIndex(of: "forward:8080")) > #require(log.firstIndex(of: "shell")))

        await model.close()
        #expect(allStopped(model))
        #expect(await fake.runningForwardCount == 0)
        // Close order: forwards → shell → connection.
        let after = harness.log.all
        let stops = [after.firstIndex(of: "forwardStopped:8080"), after.firstIndex(of: "forwardStopped:8443")]
        let shellClosed = try #require(after.firstIndex(of: "shellClosed"))
        let closed = try #require(after.lastIndex(of: "close"))
        for stop in stops { #expect(try #require(stop) < shellClosed) }
        #expect(shellClosed < closed)
    }

    /// Review Focus 3: another app (or another machine's session) holds 8080.
    @Test func testPortInUseFailsOnlyThatForward() async throws {
        let (harness, model) = try await connectedHarness(failures: [8080: .portInUse(8080)])
        try await harness.connected(model)
        #expect(await waitUntil { model.forwardStates[web.id] == .failed(.portInUse(8080)) })
        #expect(await waitUntil { model.forwardStates[dns.id] == .active })
        #expect(model.phase == .connected)
        #expect(model.failure == nil)
        #expect(model.forwardStates[web.id]?.message(english) == "Port 8080 is already in use")
        // The shell still takes input.
        harness.surface.type("ls\r")
        let shell = try #require(harness.last).shell
        #expect(await waitUntil { shell.written == Data("ls\r".utf8) })
        await model.close()
        #expect(allStopped(model))
    }

    @Test func testForwardsRestartAfterAutomaticReconnect() async throws {
        let (harness, model) = try await connectedHarness()
        try await harness.connected(model)
        #expect(await waitUntil { allActive(model) })
        let first = try #require(harness.last)

        await first.drop()
        #expect(await waitUntil { model.phase == .waiting(.retryDelay) && harness.reconnectClock.pending(reconnectDelay) == 1 })
        #expect(allStopped(model))
        #expect(await waitUntilAsync { await first.runningForwardCount == 0 })

        harness.reconnectClock.fire(reconnectDelay)
        #expect(await waitUntil { harness.made == 2 })
        try await harness.connected(model)
        #expect(await waitUntil { allActive(model) })
        let second = try #require(harness.last)
        #expect(await second.forwardStartCount == 2)
        #expect(await second.runningForwards(8080) == 1)
        await model.close()
    }

    @Test func testOpenInBrowserURL() async throws {
        let (harness, model) = try await connectedHarness(failures: [8443: .channelFailed("refused")])
        try await harness.connected(model)
        #expect(await waitUntil { model.forwardStates[web.id] == .active })
        #expect(await waitUntil { model.forwardStates[dns.id] == .failed(.channelFailed("refused")) })

        model.openInBrowser(dns.id)   // failed: nothing to open
        #expect(harness.urlOpener.opened.isEmpty)
        model.openInBrowser(web.id)
        #expect(harness.urlOpener.opened == [URL(string: "http://localhost:8080")!])
        #expect(model.forwardStates[dns.id]?.message(english) == "The server refused the forward")

        await model.close()
        model.openInBrowser(web.id)   // stopped
        #expect(harness.urlOpener.opened.count == 1)
    }

    /// A bind that completes after the tab closed: the late handle is stopped at once and the state
    /// stays stopped.
    @Test func testForwardFinishingStartAfterCloseIsStopped() async throws {
        let (harness, model) = try await connectedHarness(hangs: [8080])
        try await harness.connected(model)
        let fake = try #require(harness.last)
        #expect(await waitUntilAsync { await fake.isWaitingForForward(8080) })
        #expect(model.forwardStates[web.id] == .starting)

        await model.close()
        #expect(allStopped(model))
        await fake.finishForwardStart(8080)
        #expect(await waitUntil { harness.log.all.contains("forwardStopped:8080") })
        #expect(await fake.runningForwards(8080) == 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.forwardStates[web.id] == .stopped)
    }

    @Test func testSleepStopsForwardsAndWakeRestartsThem() async throws {
        let (harness, model) = try await connectedHarness()
        try await harness.connected(model)
        #expect(await waitUntil { allActive(model) })
        let first = try #require(harness.last)

        model.suspendForSleep()
        #expect(model.phase == .waiting(.asleep))
        #expect(allStopped(model))
        #expect(await waitUntilAsync { await first.runningForwardCount == 0 })

        model.resumeAfterWake()
        #expect(await waitUntil { harness.made == 2 })
        try await harness.connected(model)
        #expect(await waitUntil { allActive(model) })
        await model.close()
    }

    @Test func testRetryRestartsOnlyTheFailedForward() async throws {
        let (harness, model) = try await connectedHarness(failures: [8080: .portInUse(8080)])
        try await harness.connected(model)
        #expect(await waitUntil { model.forwardStates[web.id] == .failed(.portInUse(8080)) })
        #expect(await waitUntil { model.forwardStates[dns.id] == .active })
        let fake = try #require(harness.last)

        model.retryForward(dns.id)   // active: nothing to retry
        await fake.clearForwardFailure(8080)   // the other app quit
        model.retryForward(web.id)
        #expect(model.forwardStates[web.id] == .starting)
        #expect(await waitUntil { model.forwardStates[web.id] == .active })
        #expect(await fake.forwardStarts.map(\.localPort) == [8080, 8443, 8080])
        #expect(await fake.runningForwards(8443) == 1)
        await model.close()
    }

    @Test func testShellExitStopsForwards() async throws {
        let (harness, model) = try await connectedHarness()
        try await harness.connected(model)
        #expect(await waitUntil { allActive(model) })
        let fake = try #require(harness.last)
        fake.shell.finish()
        #expect(await waitUntil { model.phase == .ended })
        #expect(allStopped(model))
        #expect(await waitUntilAsync { await fake.runningForwards(8080) == 0 })
        model.retryForward(web.id)   // no shell: nothing starts
        #expect(model.forwardStates[web.id] == .stopped)
    }

    @Test func testForwardTitle() {
        #expect(web.displayTitle == "Pi web UI")
        #expect(dns.displayTitle == "localhost:8443 → pihole:443")
    }
}
