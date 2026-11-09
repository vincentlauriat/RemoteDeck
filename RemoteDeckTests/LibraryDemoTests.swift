import AppKit
import Foundation
import SSHKit
import SwiftData
import Testing
import RemoteDeckCore
@testable import RemoteDeck

// Plan Task 13: `-LibraryDemo ssh` never makes a real `SSHConnection`, never reads `~/.ssh`, the
// Keychain or the user's defaults, and never shows a real panel. Driven through the demo's own
// pieces (the mode itself reads `UserDefaults`, nil under XCTest).
@MainActor
struct LibraryDemoTests {
    /// The demo's "Raspberry", its services and a terminal session over the demo's connection.
    private func demoSession() throws -> (TerminalSessionModel, FakeTerminalSurface, SSHServices) {
        let context = try makeTestContext()
        let machine = LibraryDemo.sshMachine()
        context.insert(machine)
        try context.save()
        let services = LibraryDemo.sshServices()
        let model = TerminalSessionModel(
            machine: machine, context: context, resolver: services.resolver(passwords: InMemoryPasswordStore()),
            trust: services.trustedHostKeys, secrets: services.secrets, urlOpener: FakeURLOpener(),
            makeConnection: LibraryDemo.sshConnection)
        let surface = FakeTerminalSurface()
        model.attach(surface)
        return (model, surface, services)
    }

    @Test func testSSHDemoUsesFakeConnectionOnly() async throws {
        let machine = LibraryDemo.sshMachine()
        #expect(machine.kindValue == .ssh && machine.host == "raspberrypi.local" && machine.username == "pi")
        #expect(machine.sshAuth == .keyInSSHFolder && machine.sshKeyFileName == "id_ed25519")
        #expect(machine.portForwards.map(\.localPort) == [8080, 9000])
        let connection = LibraryDemo.sshConnection(SessionTarget(machine))
        #expect(!(connection is SSHConnection))
        #expect(connection is LibraryDemo.SSHDemoConnection)

        let (model, surface, _) = try demoSession()
        model.connect()
        // First Connect: the Host Key Sheet, with the demo's fake key.
        #expect(await waitUntil { model.hostKeyPrompt != nil })
        #expect(model.hostKeyPrompt?.key == LibraryDemo.sshHostKey)
        model.trustHostKey()
        #expect(await waitUntil { model.phase == .connected })
        // The scripted banner and prompt, then the typed text echoed.
        #expect(await waitUntil { surface.fedText.contains("pi@raspberrypi") })
        #expect(surface.fedText.contains("Linux raspberrypi"))
        surface.type("ls")
        #expect(await waitUntil { surface.fedText.hasSuffix("ls") })
        // One forward listens, the other shows "port in use".
        let forwards = model.target.portForwards
        #expect(await waitUntil { forwards.allSatisfy { model.forwardStates[$0.id]?.isActive == true
                                                        || model.forwardStates[$0.id]?.isFailed == true } })
        #expect(model.forwardStates[forwards[0].id] == .active)
        #expect(model.forwardStates[forwards[1].id] == .failed(.portInUse(9000)))
        await model.close()
        #expect(model.phase == .closed)
    }

    @Test func testSSHDemoTrustIsAskedOncePerLaunch() async throws {
        let (model, _, services) = try demoSession()
        model.connect()
        #expect(await waitUntil { model.hostKeyPrompt != nil })
        model.trustHostKey()
        #expect(await waitUntil { model.phase == .connected })
        #expect(services.trustedHostKeys.decision(for: LibraryDemo.sshHostKey, host: "raspberrypi.local", port: 22)
            == .trusted)
        await model.close()
    }

    @Test func testSSHDemoUsesInMemoryServicesAndFakePanels() async throws {
        let services = LibraryDemo.sshServices()
        #expect(services.folder is InMemorySSHFolderAccess)
        #expect(services.folder.isGranted)
        #expect(services.trustedHostKeys is InMemoryTrustedHostKeys)
        #expect(services.secrets is InMemorySSHSecretStore)
        // The demo key opens without a passphrase (generated for the demo only).
        let key = try services.folder.readFile("id_ed25519")
        _ = try SSHPrivateKey.parse(openSSH: key, passphrase: nil)
        // Every panel of an SSH session is a fake in a demo mode.
        #expect(AppPanels.keyFilePicker(demo: true) is NoKeyFilePicker)
        #expect(AppPanels.fileTransferPanels(demo: true) is LibraryDemo.FileTransferPanels)
        #expect(AppPanels.keyFilePicker(demo: false) is OpenPanelKeyFilePicker)
        #expect(AppPanels.fileTransferPanels(demo: false) is SystemFileTransferPanels)
        // The demo's upload panel answers with a file it made in the app's temporary folder.
        let urls = await LibraryDemo.FileTransferPanels().chooseFilesToUpload()
        #expect(urls.count == 1)
        #expect(urls.allSatisfy { $0.path.hasPrefix(FileManager.default.temporaryDirectory.path) })
    }

    @Test func testSSHDemoUploadShowsProgressThenFinishes() async throws {
        let (model, _, _) = try demoSession()
        model.fileTransferPanels = LibraryDemo.FileTransferPanels()
        model.connect()
        #expect(await waitUntil { model.hostKeyPrompt != nil })
        model.trustHostKey()
        #expect(await waitUntil { model.phase == .connected })
        await model.chooseFilesToUpload()
        let transfer = try #require(model.fileTransfer)
        #expect(await waitUntil {
            if case .chooseDestination(let files, let directory) = transfer.step { return !files.isEmpty && directory == "/home/pi" }
            return false
        })
        transfer.start()
        var sawProgress = false
        #expect(await waitUntil(timeout: .seconds(10)) {
            if case .transferring(let done, let total) = transfer.step, done > 0, done < total { sawProgress = true }
            return transfer.step == .finished
        })
        #expect(sawProgress)
        model.endFileTransfer()
        await model.close()
    }
}
