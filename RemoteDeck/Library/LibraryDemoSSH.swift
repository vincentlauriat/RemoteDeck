#if DEBUG
import ClaudeKit
import Foundation
import RemoteDeckCore
import SSHKit

/// `-LibraryDemo ssh` (plan Task 13): one "Raspberry" SSH machine (`pi@raspberrypi.local`, key
/// `id_ed25519` in `~/.ssh`) with two forwards, connected at launch. The first Connect of the run
/// shows the Host Key Sheet (a fake key); Trust opens a scripted shell (login banner, prompt, typed
/// text echoed); "Web UI" (8080 → 80) listens, the 9000 forward fails with "port in use"; Upload
/// File… (⌘U) takes a sample file the demo writes in the app's temporary folder and shows the
/// progress of a fake upload. Never a real `SSHConnection`, socket, Keychain item, panel or `~/.ssh`:
/// the services are in memory (`sshServices`) and every SSH connection of every demo mode is
/// `SSHDemoConnection`.
extension LibraryDemo {
    static var showsSSH: Bool { mode == "ssh" || scriptsTerminalAssistant }
    /// `-LibraryDemo ssh-assistant`: the "Raspberry" connected at launch (its key already trusted),
    /// a canned `df -h` on the screen, and the Terminal Assistant Panel open on a scripted engine
    /// (`TerminalDemoEngine`): it explains the output, proposes `du -sh /var/log/*`, Confirm types it
    /// and the scripted shell prints a canned answer. Never the Messages API or FoundationModels.
    static var scriptsTerminalAssistant: Bool { mode == "ssh-assistant" }
    static let terminalDemoQuestion = "Why is the disk almost full?"
    static let terminalDemoCommand = "du -sh /var/log/*"
    static let sshMachineName = "Raspberry"
    /// The local port of the second forward: the demo's "already in use".
    static let busyLocalPort: UInt16 = 9000

    static let sshHostKey: SSHHostKey = {
        // A fixed public key the demo ships (`LibraryDemoKey.hostKey`): known to parse.
        guard let key = try? SSHHostKey(openSSHPublicKey: LibraryDemoKey.hostKey) else {
            preconditionFailure("LibraryDemoKey.hostKey does not parse")
        }
        return key
    }()

    static func sshMachine() -> Machine {
        Machine(name: sshMachineName, kind: .ssh, host: "raspberrypi.local", port: 22, username: "pi",
                sshAuthMethod: .keyInSSHFolder, sshKeyFileName: "id_ed25519",
                portForwards: [PortForward(label: "Web UI", localPort: 8080, remotePort: 80),
                               PortForward(localPort: Int(busyLocalPort), remotePort: 9000)])
    }

    /// A `~/.ssh` granted in memory, holding the demo key and a `config` to import from; trusted
    /// host keys and SSH secrets in memory too.
    @MainActor
    static func sshServices(trustsDemoHost: Bool = scriptsTerminalAssistant) -> SSHServices {
        let folder = InMemorySSHFolderAccess(files: [
            "id_ed25519": LibraryDemoKey.privateKey,
            "id_ed25519.pub": LibraryDemoKey.publicKey + "\n",
            "config": sampleSSHConfig,
        ])
        let trust = InMemoryTrustedHostKeys(folder: folder)
        if trustsDemoHost { trust.trust(sshHostKey, host: "raspberrypi.local", port: 22) }
        return SSHServices(folder: folder, trustedHostKeys: trust, secrets: InMemorySSHSecretStore())
    }

    static let sampleSSHConfig = """
    Host raspberry
        HostName raspberrypi.local
        User pi
        IdentityFile ~/.ssh/id_ed25519

    Host build
        HostName build.example.com
        User admin
        Port 2222
    """

    static func sshConnection(_ target: SessionTarget) -> any SSHSessionConnection {
        SSHDemoConnection()
    }

    // MARK: Connection

    /// Presents `sshHostKey`, then authenticates whatever the credentials (the resolver already
    /// parsed the demo key); a shell, forwards and SFTP all fake.
    final class SSHDemoConnection: SSHSessionConnection {
        private let ends = AsyncStream.makeStream(of: SSHError?.self, bufferingPolicy: .bufferingNewest(1))
        /// The shell answers `df -h` and `du -sh /var/log/*` (`ssh-assistant`).
        private let scriptsAssistant: Bool

        init(scriptsAssistant: Bool = LibraryDemo.scriptsTerminalAssistant) {
            self.scriptsAssistant = scriptsAssistant
        }

        var closed: AsyncStream<SSHError?> { ends.stream }

        func open(credentials: SSHCredentials, timeout: Duration,
                  validateHostKey: @escaping @Sendable (SSHHostKey) async -> Bool) async throws(SSHError) {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                throw .connectionClosed
            }
            guard await validateHostKey(LibraryDemo.sshHostKey) else {
                ends.continuation.yield(.hostKeyRejected(LibraryDemo.sshHostKey))
                ends.continuation.finish()
                throw .hostKeyRejected(LibraryDemo.sshHostKey)
            }
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                throw .connectionClosed
            }
        }

        func openShell(term: String, columns: Int, rows: Int) async throws(SSHError) -> any SSHShellChannel {
            SSHDemoShell(scriptsAssistant: scriptsAssistant)
        }

        func startLocalForward(localPort: UInt16, remoteHost: String, remotePort: UInt16) async throws(SSHError)
            -> any LocalForwarding {
            try? await Task.sleep(for: .milliseconds(200))
            if localPort == LibraryDemo.busyLocalPort { throw .portInUse(localPort) }
            return SSHDemoForward(localPort: localPort)
        }

        func fileTransfer() async throws(SSHError) -> any FileTransferring {
            SSHDemoFileTransfer()
        }

        func close() async {
            ends.continuation.yield(nil)
            ends.continuation.finish()
        }
    }

    /// Nothing listens: Open in Browser opens `http://localhost:8080`, which answers nothing.
    final class SSHDemoForward: LocalForwarding {
        let localPort: UInt16

        init(localPort: UInt16) {
            self.localPort = localPort
        }

        func stop() async {}
    }

    // MARK: Shell

    /// A scripted login: the banner and prompt at once, then each typed key echoed; Return answers
    /// that nothing runs, `exit` ends the shell, ⌃C abandons the line.
    actor SSHDemoShell: SSHShellChannel {
        nonisolated let output: AsyncThrowingStream<Data, any Error>
        private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
        private var line = ""
        private let scriptsAssistant: Bool

        static let prompt = "\u{1B}[1;32mpi@raspberrypi\u{1B}[0m:\u{1B}[1;34m~ $\u{1B}[0m "

        static let banner = """
        Linux raspberrypi 6.6.51+rpt-rpi-v8 #1 SMP PREEMPT Debian 1:6.6.51-1+rpt3 (2024-10-08) aarch64\r
        \r
        The programs included with the Debian GNU/Linux system are free software;\r
        the exact distribution terms for each program are described in the\r
        individual files in /usr/share/doc/*/copyright.\r
        \r
        Debian GNU/Linux comes with ABSOLUTELY NO WARRANTY, to the extent\r
        permitted by applicable law.\r
        \u{1B}[2m(RemoteDeck demo: a scripted shell, nothing runs on a real machine.)\u{1B}[0m\r
        Last login: Sun Nov  8 18:42:07 2026 from 192.0.2.20\r

        """

        init(scriptsAssistant: Bool = false) {
            self.scriptsAssistant = scriptsAssistant
            (output, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
            var start = Self.banner + Self.prompt
            if scriptsAssistant { start += "df -h\r\n" + Self.dfOutput + Self.prompt }
            continuation.yield(Data(start.utf8))
        }

        static let dfOutput = """
        Filesystem      Size  Used Avail Use% Mounted on\r
        /dev/root        29G   27G  1.4G  95% /\r
        devtmpfs        1.8G     0  1.8G   0% /dev\r
        tmpfs           1.9G     0  1.9G   0% /dev/shm\r
        /dev/mmcblk0p1  510M   64M  447M  13% /boot/firmware\r

        """

        static let duOutput = """
        4.0K\t/var/log/alternatives.log\r
        2.1G\t/var/log/journal\r
        312M\t/var/log/nginx\r
        48M\t/var/log/syslog\r
        1.2M\t/var/log/auth.log\r

        """

        func write(_ data: Data) async throws(SSHError) {
            var reply = ""
            for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
                switch scalar {
                case "\r", "\n":
                    let command = line.trimmingCharacters(in: .whitespaces)
                    line = ""
                    if command == "exit" {
                        continuation.yield(Data((reply + "\r\nlogout\r\n").utf8))
                        continuation.finish()
                        return
                    }
                    reply += "\r\n"
                    if scriptsAssistant, command == LibraryDemo.terminalDemoCommand {
                        reply += Self.duOutput
                    } else if scriptsAssistant, command == "df -h" {
                        reply += Self.dfOutput
                    } else if !command.isEmpty {
                        reply += "\(command.split(separator: " ").first ?? ""): demo shell, nothing runs here\r\n"
                    }
                    reply += Self.prompt
                case "\u{7F}", "\u{8}":
                    if !line.isEmpty {
                        line.removeLast()
                        reply += "\u{8} \u{8}"
                    }
                case "\u{3}":
                    line = ""
                    reply += "^C\r\n" + Self.prompt
                default:
                    guard scalar.value >= 0x20 else { continue }   // other control keys: ignored
                    line.unicodeScalars.append(scalar)
                    reply.unicodeScalars.append(scalar)
                }
            }
            if !reply.isEmpty { continuation.yield(Data(reply.utf8)) }
        }

        func resize(columns: Int, rows: Int) async {}
    }

    // MARK: File transfer

    /// `/home/pi` with a `Documents` folder and a `notes.txt`; an upload reports its progress over
    /// about three seconds and stores nothing.
    final class SSHDemoFileTransfer: FileTransferring {
        static let home = "/home/pi"
        static let folders: Set<String> = ["/", "/home", "/home/pi", "/home/pi/Documents", "/tmp"]
        static let notes = "/home/pi/notes.txt"

        func homeDirectory() async throws(SSHError) -> String { Self.home }

        func exists(_ remotePath: String) async throws(SSHError) -> Bool {
            try? await Task.sleep(for: .milliseconds(150))
            var path = remotePath
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return Self.folders.contains(path) || path == Self.notes
        }

        func upload(_ local: URL, toDirectory: String, overwrite: Bool,
                    progress: @Sendable (Int64, Int64) -> Void) async throws(SSHError) {
            let size = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try await Self.pretend(size: size, progress: progress)
        }

        func download(_ remotePath: String, to local: URL,
                      progress: @Sendable (Int64, Int64) -> Void) async throws(SSHError) {
            let text = Data("Demo file from raspberrypi.local (RemoteDeck -LibraryDemo ssh).\n".utf8)
            try await Self.pretend(size: Int64(text.count), progress: progress)
            do {
                try text.write(to: local)
            } catch {
                throw .remote("demo: \(error.localizedDescription)")
            }
        }

        func close() async {}

        /// 30 steps of 100 ms; a cancelled transfer ends as the real one does.
        private static func pretend(size: Int64, progress: @Sendable (Int64, Int64) -> Void) async throws(SSHError) {
            let steps: Int64 = 30
            for step in 1...steps {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    throw .connectionClosed
                }
                progress(size * step / steps, size)
            }
        }
    }

    // MARK: Panels

    /// Open in Browser: printed on stderr, never opened (nothing listens on the demo's ports).
    struct URLOpener: URLOpening {
        func open(_ url: URL) {
            FileHandle.standardError.write(Data("[LibraryDemo ssh] open in browser: \(url.absoluteString)\n".utf8))
        }
    }

    /// Upload File… answers with a sample file written in the app's temporary folder (an accented
    /// name, 1.2 MB); Download File… saves into that folder. Never a real panel.
    @MainActor
    struct FileTransferPanels: RemoteDeck.FileTransferPanels {
        static let sampleName = "config été.toml"

        /// Written once per run, then reused (the temporary folder keeps one copy).
        func chooseFilesToUpload() async -> [URL] {
            let url = FileManager.default.temporaryDirectory.appending(path: Self.sampleName)
            if FileManager.default.fileExists(atPath: url.path) { return [url] }
            let line = "# RemoteDeck demo: sample configuration, uploaded nowhere\n"
            let text = String(repeating: line, count: 1_200_000 / line.utf8.count)
            guard (try? Data(text.utf8).write(to: url)) != nil else { return [] }
            return [url]
        }

        func chooseDownloadDestination(suggestedName: String) async -> URL? {
            FileManager.default.temporaryDirectory.appending(path: suggestedName)
        }

        func cancelPanels() {}
    }
}
// MARK: - Terminal assistant (`-LibraryDemo ssh-assistant`)

extension LibraryDemo {
    @MainActor
    static func terminalAssistantEngine() -> any TerminalAssistantEngine {
        TerminalDemoEngine()
    }

    /// Claude-shaped scripted turns, no request: an explanation and one proposed command, then a
    /// final answer once the command's output came back.
    @MainActor
    final class TerminalDemoEngine: TerminalAssistantEngine {
        let provider = AssistantProvider.claude
        let isReady = true
        let notReadyReason: AssistantFailure? = nil
        private(set) var hasConversation = false
        var canResend: Bool { hasConversation }
        private var turns = 0

        func begin(prompt: String, snapshot: TerminalSnapshot?) {
            hasConversation = true
        }

        func nextTurn() async throws(AssistantEngineError) -> TerminalTurn {
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                throw .cancelled
            }
            turns += 1
            if turns == 1 {
                return TerminalTurn(blocks: [
                    .progress("Reading the df output on the screen."),
                    .answer("The root filesystem (/dev/root) is 95% full: 27 G used of 29 G. Logs are a usual suspect on a Raspberry Pi, so let's see what /var/log holds."),
                    .action(TerminalTurnAction(id: "demo-du", action: .runCommand(LibraryDemo.terminalDemoCommand),
                                               reason: "List the size of each log folder (read-only).")),
                ], stop: .actions, usage: TokenUsage(inputTokens: 1840, outputTokens: 160, cacheCreationInputTokens: 2300))
            }
            return TerminalTurn(blocks: [
                .answer("/var/log/journal takes 2.1 G. `sudo journalctl --vacuum-size=200M` would free most of it; I can propose it if you want. (Demo: scripted answer, no request was sent.)"),
            ], stop: .done, usage: TokenUsage(inputTokens: 120, outputTokens: 60, cacheReadInputTokens: 4140))
        }

        func deliver(_ outcomes: [TerminalActionOutcome]) {}
        func deferOutcomes(_ outcomes: [TerminalActionOutcome]) {}

        func reset() {
            hasConversation = false
            turns = 0
        }
    }
}
#endif
