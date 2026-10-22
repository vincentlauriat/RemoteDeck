import Foundation
import Testing
import RemoteDeckCore
import RFBKit
@testable import RemoteDeck

struct TestConnectionFailureTests {
    @Test(arguments: [
        (RFBError.network("refused"), TestConnectionFailure.unreachable, "Unreachable — check VPN or network"),
        (.timeout, .timedOut, "Unreachable — no answer within 5 s"),
        (.connectionClosed, .connectionClosed, "The server closed the connection"),
        (.connectionRefused(reason: "Too many connections"), .refused(reason: "Too many connections"),
         "Connection refused by the server — Too many connections"),
        (.authFailed(reason: nil), .authFailed(reason: nil), "Authentication failed"),
        (.authFailed(reason: " bad password "), .authFailed(reason: " bad password "),
         "Authentication failed — bad password"),
        (.unsupportedSecurityTypes([16, 19]), .unsupportedSecurityType(offered: [16, 19], apple: false),
         "Unsupported security type (16, 19)"),
        (.unsupportedAppleSecurityTypes([33, 36]), .unsupportedSecurityType(offered: [33, 36], apple: true),
         "Unsupported security type: this Mac only offers newer Apple authentication (33, 36)"),
        (.credentialsRequired(securityType: 30), .credentialsRequired(username: true),
         "This Mac needs a user name and password"),
        (.credentialsRequired(securityType: 2), .credentialsRequired(username: false), "This server needs a password"),
        (.credentialTooLong, .credentialTooLong, "User name or password too long (63 bytes max)"),
        (.unsupportedVersion("HTTP/1.1"), .notRFBServer(banner: "HTTP/1.1"), "Not a VNC / Screen Sharing server"),
        (.protocolViolation("x"), .unexpectedResponse, "Unexpected response from the server"),
        (.cryptoFailure(status: -4300), .unexpectedResponse, "Unexpected response from the server"),
    ])
    func mapsEveryRFBError(_ error: RFBError, _ failure: TestConnectionFailure, _ message: String) {
        #expect(TestConnectionFailure(error) == failure)
        #expect(failure.message(english) == message)
    }

    @Test func cancellationIsNotAFailure() {
        #expect(TestConnectionFailure(.cancelled) == nil)
    }

    /// The real tester against a closed loopback port: no server, so the TCP connect is refused.
    @Test func realTesterReportsAClosedLoopbackPortAsUnreachable() async {
        do {
            try await RFBConnectionTester().test(host: "127.0.0.1", port: 1, credentials: .none, timeout: .seconds(5))
            Issue.record("expected a failure")
        } catch {
            #expect(TestConnectionFailure(error) == .unreachable)
        }
    }
}

struct ValidationMessageTests {
    @Test func everyReasonHasAnEnglishMessage() {
        let cases: [(MachineValidator.Reason, MachineValidator.Field, String)] = [
            (.empty, .name, "Enter a name."),
            (.tooLong(max: 64), .name, "Use at most 64 characters."),
            (.empty, .host, "Enter a host name or IP address."),
            (.invalidHost, .host, english("err_host_invalid")),
            (.outOfRange, .port, "The port must be between 1 and 65535."),
            (.empty, .username, "A user name is required for a Mac."),
            (.duplicate, .host, "Another machine already uses this host and port."),
            (.empty, .groupName, "Enter a group name."),
            (.tooLong(max: 40), .groupName, "Use at most 40 characters."),
            (.duplicate, .groupName, "A group with this name already exists."),
        ]
        for (reason, field, message) in cases {
            #expect(reason.message(for: field, english) == message)
        }
    }
}

struct StringsTests {
    @Test func frenchAndEnglishHaveTheSameKeys() throws {
        let fr = try #require(Strings.table["fr"])
        let en = try #require(Strings.table["en"])
        #expect(Set(fr.keys).subtracting(en.keys).sorted() == [])
        #expect(Set(en.keys).subtracting(fr.keys).sorted() == [])
    }
}

struct LibraryStoreTests {
    /// An in-memory library must not write machine passwords to the real Keychain.
    @MainActor
    @Test func inMemoryLibraryGetsInMemoryPasswords() {
        #expect(LibraryStore.passwordStore(isInMemory: true) is InMemoryPasswordStore)
        #expect(LibraryStore.passwordStore(isInMemory: false) is KeychainStore)
    }

    @Test func detectsTestHosts() {
        #expect(LibraryStore.isRunningTests(["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        #expect(LibraryStore.isRunningTests(["XCTestSessionIdentifier": "ABC"]))
        #expect(LibraryStore.isRunningTests(["XCTestBundlePath": "/tmp/RemoteDeckTests.xctest"]))
        #expect(!LibraryStore.isRunningTests([:]))
        #expect(!LibraryStore.isRunningTests(["HOME": "/Users/x"]))
    }

    /// This very process is the hosted test run: the app must have taken the in-memory branch.
    @Test func thisTestHostIsDetected() {
        #expect(LibraryStore.isRunningTests())
    }

    @MainActor
    @Test func inMemoryOpenUsesNoFile() {
        let (container, isInMemory, error) = LibraryStore.open(inMemory: true)
        #expect(error == nil)
        #expect(isInMemory)
        let inMemory = container.configurations.map(\.isStoredInMemoryOnly)
        #expect(inMemory == [true, true])
    }
}
