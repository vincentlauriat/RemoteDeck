import Foundation
import Network
import os
import Testing
@testable import RFBKit

/// T5.3 security review fixes on the RFBKit side: the address classifier behind the public-Internet
/// warning (H1), the Apple DH requirement for Macs with a user name (M4), and the display of
/// server-controlled and Claude-proposed text (L8, M2).
struct AddressScopeTests {
    static func v4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> AddressScope? {
        AddressScope(addressBytes: [a, b, c, d])
    }

    static func v6(_ text: String) -> AddressScope? {
        AddressScope(literal: text)
    }

    @Test(arguments: [
        // Loopback and "this host".
        ("127.0.0.1", AddressScope.loopback), ("127.255.255.255", .loopback), ("0.0.0.0", .loopback),
        ("126.255.255.255", .publicInternet), ("128.0.0.1", .publicInternet),
        // RFC 1918 and their edges.
        ("10.0.0.0", .privateNetwork), ("10.255.255.255", .privateNetwork),
        ("9.255.255.255", .publicInternet), ("11.0.0.0", .publicInternet),
        ("172.16.0.0", .privateNetwork), ("172.31.255.255", .privateNetwork),
        ("172.15.255.255", .publicInternet), ("172.32.0.0", .publicInternet),
        ("192.168.0.0", .privateNetwork), ("192.168.255.255", .privateNetwork),
        ("192.167.255.255", .publicInternet), ("192.169.0.0", .publicInternet),
        // RFC 6598 (CGNAT, Tailscale).
        ("100.64.0.0", .sharedAddressSpace), ("100.127.255.255", .sharedAddressSpace),
        ("100.63.255.255", .publicInternet), ("100.128.0.0", .publicInternet),
        ("100.100.100.100", .sharedAddressSpace),
        // Link-local.
        ("169.254.0.0", .linkLocal), ("169.254.255.255", .linkLocal),
        ("169.253.255.255", .publicInternet), ("169.255.0.0", .publicInternet),
        // Public.
        ("8.8.8.8", .publicInternet), ("203.0.113.5", .publicInternet), ("255.255.255.255", .publicInternet),
    ])
    func ipv4(_ text: String, _ scope: AddressScope) {
        #expect(AddressScope(literal: text) == scope)
        let bytes = text.split(separator: ".").map { UInt8($0)! }
        #expect(AddressScope(addressBytes: bytes) == scope)
    }

    @Test(arguments: [
        ("::1", AddressScope.loopback), ("::", .loopback), ("::2", .publicInternet),
        // fe80::/10 and its edges.
        ("fe80::1", .linkLocal), ("febf:ffff::1", .linkLocal), ("fe7f::1", .publicInternet), ("fec0::1", .publicInternet),
        // fc00::/7 and its edges.
        ("fc00::1", .uniqueLocal), ("fdff:ffff::1", .uniqueLocal), ("fd7a:115c:a1e0::1", .uniqueLocal),
        ("fbff::1", .publicInternet), ("fe00::1", .publicInternet),
        ("2001:db8::1", .publicInternet), ("2a00:1450:4007::200e", .publicInternet),
        // IPv4-mapped: classified as the IPv4 address.
        ("::ffff:192.168.1.2", .privateNetwork), ("::ffff:127.0.0.1", .loopback),
        ("::ffff:100.64.0.1", .sharedAddressSpace), ("::ffff:8.8.8.8", .publicInternet),
        ("::ffff:c0a8:0102", .privateNetwork),
        // Not mapped (::fffe:…, IPv4-compatible ::a.b.c.d): an ordinary public IPv6 address.
        ("::fffe:c0a8:102", .publicInternet), ("::192.168.1.2", .publicInternet),
    ])
    func ipv6(_ text: String, _ scope: AddressScope) {
        #expect(AddressScope(literal: text) == scope)
    }

    @Test func literalsAsTypedInTheEditor() {
        #expect(AddressScope(literal: "[::1]") == .loopback)
        #expect(AddressScope(literal: "[fe80::1%en0]") == .linkLocal)
        #expect(AddressScope(literal: "fe80::1%en0") == .linkLocal)
        #expect(AddressScope(literal: "  203.0.113.5 \n") == .publicInternet)
        // Not an address for inet_pton: a host name, classified once resolved.
        for name in ["1", "10.1", "010.1.1.1", "1.2.3", "1.2.3.4.5", "256.1.1.1", "minim6.local", "", "[]", "::g"] {
            #expect(AddressScope(literal: name) == nil, "\(name)")
        }
    }

    @Test func onlyFourOrSixteenBytesAreAnAddress() {
        #expect(AddressScope(addressBytes: []) == nil)
        #expect(AddressScope(addressBytes: [10, 0, 0]) == nil)
        #expect(AddressScope(addressBytes: [UInt8](repeating: 0, count: 15)) == nil)
        #expect(AddressScope(addressBytes: [UInt8](repeating: 0, count: 15) + [1]) == .loopback)
    }

    @Test func anEndpointThatIsNotAnIPAddressCountsAsPublic() {
        #expect(RemoteAddress(endpoint: nil, fallbackText: "proxy").scope == .publicInternet)
        #expect(RemoteAddress(endpoint: .hostPort(host: "minim6.local", port: 5900), fallbackText: "x").scope
            == .publicInternet)
        let local = RemoteAddress(endpoint: .hostPort(host: .ipv4(IPv4Address("192.168.1.9")!), port: 5900),
                                  fallbackText: "x")
        #expect(local == RemoteAddress(text: "192.168.1.9", scope: .privateNetwork))
        let ula = RemoteAddress(endpoint: .hostPort(host: .ipv6(IPv6Address("fd00::5")!), port: 5900), fallbackText: "x")
        #expect(ula.scope == .uniqueLocal)
    }
}


struct RequiredSecurityTypeTests {
    static let ard = RFBCredentials(username: "vincent", password: "pw", requiredSecurityType: 30)

    @Test func appleDHIsTheOnlyChoiceWhenRequired() throws {
        #expect(try RFBHandshake.selectSecurityType(offered: [1, 2, 30], credentials: Self.ard) == 30)
        #expect(try RFBHandshake.selectSecurityType(offered: [30], credentials: Self.ard) == 30)
        for offered: [UInt8] in [[2], [1], [1, 2], [2, 35], [33, 35, 36]] {
            #expect(throws: RFBError.requiredSecurityTypeMissing(required: 30, offered: offered)) {
                try RFBHandshake.selectSecurityType(offered: offered, credentials: Self.ard)
            }
        }
        // A user name without a password: never type 1 instead (it used to connect unauthenticated).
        let noPassword = RFBCredentials(username: "vincent", requiredSecurityType: 30)
        #expect(throws: RFBError.credentialsRequired(securityType: 30)) {
            try RFBHandshake.selectSecurityType(offered: [1, 30], credentials: noPassword)
        }
        // Without the requirement, the usual preference is unchanged.
        #expect(try RFBHandshake.selectSecurityType(offered: [1, 30], credentials: RFBCredentials(username: "vincent")) == 1)
    }

    /// Nothing but the version banner goes out: no security type byte, no DES response, no ClientInit.
    @Test(arguments: [[UInt8]([1, 2]), [1, 1], [2, 1, 2]])
    func a38ServerWithoutType30GetsOnlyTheBanner(list: [UInt8]) throws {
        var handshake = RFBHandshake(credentials: Self.ard)
        let step = try handshake.receive(Array("RFB 003.008\n".utf8))
        #expect(step.outgoing == Data("RFB 003.008\n".utf8))
        #expect(throws: RFBError.requiredSecurityTypeMissing(required: 30, offered: Array(list.dropFirst()))) {
            _ = try handshake.receive(list + [0, 0, 0, 0] + Array(repeating: 0xAA, count: 16))
        }
    }

    /// RFB 3.3: the server imposes the type (U32). 1 would send ClientInit at once and 2 the DES
    /// response; with the requirement both stop, and so does any other type. 0 stays a refusal.
    @Test(arguments: [UInt32(1), 2, 30, 31, 255])
    func a33ServerImposingAnotherTypeStops(type: UInt32) throws {
        var handshake = RFBHandshake(credentials: Self.ard)
        _ = try handshake.receive(Array("RFB 003.003\n".utf8))
        let bytes = type.bigEndianBytes + Array(repeating: 0xAA, count: 16)
        if type == 30 {
            // Type 30 cannot be chosen by a 3.3 server (RFC 6143 §7.1.2): rejected as before.
            #expect(throws: RFBError.unsupportedSecurityTypes([30])) { _ = try handshake.receive(bytes) }
        } else {
            #expect(throws: RFBError.requiredSecurityTypeMissing(required: 30, offered: [UInt8(type)])) {
                _ = try handshake.receive(bytes)
            }
        }
    }

    /// T5.3 review: a configured password never ends in a session without authentication; type 2
    /// stays allowed for VNC and for a Mac without a user name.
    @Test func aPasswordNeverFallsBackToNoAuthentication() throws {
        let vnc = RFBCredentials(password: "pw")
        for offered: [UInt8] in [[1], [1, 33], [1, 35]] {
            #expect(throws: RFBError.requiredSecurityTypeMissing(required: 2, offered: offered)) {
                try RFBHandshake.selectSecurityType(offered: offered, credentials: vnc)
            }
        }
        #expect(throws: RFBError.credentialsRequired(securityType: 30)) {
            try RFBHandshake.selectSecurityType(offered: [1, 30], credentials: vnc)
        }
        #expect(try RFBHandshake.selectSecurityType(offered: [1, 2], credentials: vnc) == 2)
        #expect(try RFBHandshake.selectSecurityType(offered: [2, 30], credentials: vnc) == 2)
        #expect(try RFBHandshake.selectSecurityType(offered: [1], credentials: .none) == 1)
        // RFB 3.3 imposing type 1 while a password is set: stopped before ClientInit.
        var handshake = RFBHandshake(credentials: vnc)
        _ = try handshake.receive(Array("RFB 003.003\n".utf8))
        #expect(throws: RFBError.requiredSecurityTypeMissing(required: 2, offered: [1])) {
            _ = try handshake.receive(UInt32(1).bigEndianBytes)
        }
        var open = RFBHandshake(credentials: .none)
        _ = try open.receive(Array("RFB 003.003\n".utf8))
        #expect(try open.receive(UInt32(1).bigEndianBytes).outgoing == Data([1]))   // ClientInit, no password
    }

    @Test func a33RefusalIsStillARefusal() throws {
        var handshake = RFBHandshake(credentials: Self.ard)
        _ = try handshake.receive(Array("RFB 003.003\n".utf8))
        #expect(throws: RFBError.connectionRefused(reason: "busy")) {
            _ = try handshake.receive(UInt32(0).bigEndianBytes + ServerMessage.string("busy"))
        }
    }

    @Test func credentialsNeverPrintTheRequirementOrThePassword() {
        #expect(!String(describing: Self.ard).contains("pw"))
    }
}

/// Over loopback: the server records what the client actually wrote.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SecurityLoopbackTests {
    static let timeout = Duration.seconds(30)
    static let banner38 = Array("RFB 003.008\n".utf8)
    static let banner33 = Array("RFB 003.003\n".utf8)

    @Test(arguments: [[UInt8]([1, 2]), [1, 1]])
    func ardWithAUserNameNeverSendsVNCAuthOrConnectsWithout(list: [UInt8]) async throws {
        let server = try await FakeRFBServer(script: [
            .send(Self.banner38), .receive(12),
            .send(list + [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            .expectClose,
        ])
        defer { server.stop() }
        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        await #expect(throws: RFBError.requiredSecurityTypeMissing(required: 30, offered: [list[1]])) {
            _ = try await connection.open(credentials: RequiredSecurityTypeTests.ard, timeout: Self.timeout)
        }
        #expect(try await server.received(within: .seconds(20)) == [Self.banner38, []])
    }

    @Test(arguments: [UInt32(1), 2])
    func ardWithAUserNameStopsWhenA33ServerImposesAnotherType(type: UInt32) async throws {
        let server = try await FakeRFBServer(script: [
            .send(Self.banner33), .receive(12),
            .send(type.bigEndianBytes + [UInt8](repeating: 0x5A, count: 16)),
            .expectClose,
        ])
        defer { server.stop() }
        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        await #expect(throws: RFBError.requiredSecurityTypeMissing(required: 30, offered: [UInt8(type)])) {
            _ = try await connection.open(credentials: RequiredSecurityTypeTests.ard, timeout: Self.timeout)
        }
        #expect(try await server.received(within: .seconds(20)) == [Self.banner33, []])
    }

    /// Refused by `admit`: closed right after TCP, before reading the banner or writing anything.
    @Test func anAddressNotAdmittedGetsNoByte() async throws {
        let server = try await FakeRFBServer(script: [.send(Self.banner38), .expectClose])
        defer { server.stop() }
        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        let seen = Seen()
        await #expect(throws: RFBError.publicAddressNotAdmitted(address: "127.0.0.1")) {
            _ = try await connection.open(credentials: RequiredSecurityTypeTests.ard, timeout: Self.timeout) { address in
                seen.set(address)
                return false
            }
        }
        #expect(seen.value == RemoteAddress(text: "127.0.0.1", scope: .loopback))
        #expect(await connection.isOpen == false)
        #expect(await connection.remoteAddress == nil)
        #expect(try await server.received(within: .seconds(20)) == [[]])
    }

    /// The scope comes from the endpoint the connection reached once TCP was up.
    @Test func theAddressReachedIsClassified() async throws {
        let server = try await FakeRFBServer(script: [
            .send(Self.banner38), .receive(12),
            .send([1, 1]), .receive(1),
            .send(ServerMessage.securityResult(0)), .receive(1),
            .send(ServerMessage.serverInit(name: "loopback")),
        ])
        defer { server.stop() }
        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        _ = try await connection.open(credentials: .none, timeout: Self.timeout)
        #expect(await connection.remoteAddress == RemoteAddress(text: "127.0.0.1", scope: .loopback))
        await connection.close()
    }

    /// A host *name*: the scope is the resolved address the connection reached, not the name (which
    /// would count as public). The fake server listens on 127.0.0.1 only, so "localhost" ends there.
    @Test func aHostNameIsClassifiedByTheAddressItResolvedTo() async throws {
        let server = try await FakeRFBServer(script: [
            .send(Self.banner38), .receive(12),
            .send([1, 1]), .receive(1),
            .send(ServerMessage.securityResult(0)), .receive(1),
            .send(ServerMessage.serverInit(name: "loopback")),
        ])
        defer { server.stop() }
        let connection = RFBConnection(host: "localhost", port: server.port)
        _ = try await connection.open(credentials: .none, timeout: Self.timeout)
        #expect(await connection.remoteAddress == RemoteAddress(text: "127.0.0.1", scope: .loopback))
        await connection.close()
    }

    /// The rule the app uses (session and Test): a public address only when confirmed.
    @Test func thePublicAddressPolicy() {
        let pub = RemoteAddress(text: "203.0.113.5", scope: .publicInternet)
        #expect(!PublicAddressPolicy.admits(pub, confirmed: false))
        #expect(PublicAddressPolicy.admits(pub, confirmed: true))
        for scope: AddressScope in [.loopback, .privateNetwork, .sharedAddressSpace, .linkLocal, .uniqueLocal] {
            #expect(PublicAddressPolicy.admits(RemoteAddress(text: "x", scope: scope), confirmed: false))
        }
    }

    /// `open(…, allowsPublicInternet:)` as the app calls it, on a connection that "reaches" a public
    /// address: refused before any byte unless confirmed.
    @Test(arguments: [false, true])
    func openWithThePolicyOnAPublicAddress(confirmed: Bool) async throws {
        let server = try await FakeRFBServer(script: confirmed ? [
            .send(Self.banner38), .receive(12),
            .send([1, 1]), .receive(1),
            .send(ServerMessage.securityResult(0)), .receive(1),
            .send(ServerMessage.serverInit(name: "public")),
        ] : [.send(Self.banner38), .expectClose])
        defer { server.stop() }
        let connection = RFBConnection(host: "127.0.0.1", port: server.port, receiveObserver: nil) { _, _ in
            RemoteAddress(text: "203.0.113.5", scope: .publicInternet)
        }
        if confirmed {
            _ = try await connection.open(credentials: .none, timeout: Self.timeout, allowsPublicInternet: true)
            #expect(await connection.remoteAddress?.scope == .publicInternet)
            await connection.close()
        } else {
            await #expect(throws: RFBError.publicAddressNotAdmitted(address: "203.0.113.5")) {
                _ = try await connection.open(credentials: .none, timeout: Self.timeout, allowsPublicInternet: false)
            }
            #expect(try await server.received(within: .seconds(20)) == [[]])
        }
    }

    @Test func connectionsPreferNoProxy() {
        #expect(ConnectionLiveness().parameters().preferNoProxies)
    }

    final class Seen: Sendable {
        private let lock = OSAllocatedUnfairLockBox<RemoteAddress?>(nil)
        func set(_ address: RemoteAddress) { lock.set(address) }
        var value: RemoteAddress? { lock.get() }
    }
}


final class OSAllocatedUnfairLockBox<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }
    func set(_ value: Value) { lock.withLock { $0 = value } }
    func get() -> Value { lock.withLock { $0 } }
}

struct DisplayTextTests {
    @Test func everyInvisibleScalarOfATypeProposalIsShown() {
        #expect(DisplayText.revealingInvisibles("ls -la\n") == "ls -la⏎\n")
        #expect(DisplayText.revealingInvisibles("a\tb") == "a⇥b")
        // Bidi override: "evil‮txt.exe" would read "evilexe.txt".
        #expect(DisplayText.revealingInvisibles("evil\u{202E}txt.exe") == "evil\\u{202E}txt.exe")
        #expect(DisplayText.revealingInvisibles("pass\u{200B}word\u{FEFF}") == "pass\\u{200B}word\\u{FEFF}")
        #expect(DisplayText.revealingInvisibles("\u{1B}[2J\u{7F}\u{85}\u{9B}") == "\\u{1B}[2J\\u{7F}\\u{85}\\u{9B}")
        #expect(DisplayText.revealingInvisibles("a\rb") == "a\\u{D}b")
        #expect(DisplayText.revealingInvisibles("a\u{2028}b\u{2029}") == "a\\u{2028}b\\u{2029}")
        #expect(DisplayText.revealingInvisibles("\u{E0041}") == "\\u{E0041}")   // tag character
        #expect(DisplayText.revealingInvisibles("\u{2066}x\u{2069}") == "\\u{2066}x\\u{2069}")
        #expect(DisplayText.revealingInvisibles("Héllo wörld 👋 日本") == "Héllo wörld 👋 日本")
        // T5.3 review: default-ignorable scalars and non-ASCII spaces.
        for scalar: Unicode.Scalar in ["\u{FE0F}", "\u{FE00}", "\u{034F}", "\u{115F}", "\u{1160}", "\u{3164}",
                                       "\u{FFA0}", "\u{180B}", "\u{180F}", "\u{E0100}", "\u{00A0}", "\u{3000}",
                                       "\u{2009}", "\u{202F}", "\u{2002}"] {
            let shown = DisplayText.revealingInvisibles("a\(scalar)b")
            #expect(shown == "a\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}b", "\(scalar.value)")
        }
        #expect(DisplayText.revealingInvisibles("a b") == "a b")
        #expect(DisplayText.serverString("pass\u{3164}word") == "pass\\u{3164}word")
        let long = String(repeating: "x", count: 4000)
        #expect(DisplayText.revealingInvisibles(long) == long)   // never truncated
    }

    @Test func serverStringsAreBoundedAndOnOneLine() {
        #expect(DisplayText.serverString("Authentication failure") == "Authentication failure")
        #expect(DisplayText.serverString("bad\npassword\r\n") == "bad\\u{A}password\\u{D}\\u{A}")
        #expect(DisplayText.serverString("x\u{202E}y") == "x\\u{202E}y")
        let long = String(repeating: "é", count: 500)
        #expect(DisplayText.serverString(long) == String(repeating: "é", count: 200) + "…")
        #expect(DisplayText.serverString(String(repeating: "a", count: 200)) == String(repeating: "a", count: 200))
        // One character with a thousand combining marks is bounded too (scalars, not characters).
        let zalgo = "a" + String(repeating: "\u{0301}", count: 1000)
        #expect(DisplayText.serverString(zalgo).unicodeScalars.count == 201)
        #expect(DisplayText.serverString("abc", limit: 2) == "ab…")
    }
}
