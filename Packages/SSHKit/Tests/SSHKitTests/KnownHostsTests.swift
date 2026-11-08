import Foundation
import Testing
@testable import SSHKit

@Suite struct KnownHostsTests {
    private func ed25519() throws -> SSHHostKey { try SSHHostKey(openSSHPublicKey: fixture("host_ed25519.pub")) }
    private func rsa() throws -> SSHHostKey { try SSHHostKey(openSSHPublicKey: fixture("id_rsa.pub")) }
    private func other() throws -> SSHHostKey { try SSHHostKey(openSSHPublicKey: fixture("id_ed25519.pub")) }

    @Test func plainHostMatches() throws {
        let hosts = KnownHosts(parsing: "raspcorse \(try ed25519().openSSHPublicKey)\n")
        #expect(hosts.lookup(host: "raspcorse", port: 22, key: try ed25519()) == .match)
        #expect(hosts.lookup(host: "RaspCorse", port: 22, key: try ed25519()) == .match)
        #expect(hosts.lookup(host: "raspcorse", port: 2222, key: try ed25519()) == .notFound)
        #expect(hosts.lookup(host: "elsewhere", port: 22, key: try ed25519()) == .notFound)
    }

    @Test func bracketedPortEntry() throws {
        let hosts = KnownHosts(parsing: "[raspcorse]:2222 \(try ed25519().openSSHPublicKey) comment\n")
        #expect(hosts.lookup(host: "raspcorse", port: 2222, key: try ed25519()) == .match)
        #expect(hosts.lookup(host: "raspcorse", port: 22, key: try ed25519()) == .notFound)
        #expect(hosts.lookup(host: "raspcorse", port: 2223, key: try ed25519()) == .notFound)
    }

    @Test func hashedEntryMatches() throws {
        // Made with `ssh-keygen -H` from the plain names `hashedhost.example` and `[hashedhost.example]:2222`.
        let text = try fixture("known_hosts_hashed")
        #expect(text.contains("|1|"))
        #expect(!text.contains("hashedhost"))
        let hosts = KnownHosts(parsing: text)
        #expect(hosts.lookup(host: "hashedhost.example", port: 22, key: try ed25519()) == .match)
        #expect(hosts.lookup(host: "HashedHost.example", port: 22, key: try ed25519()) == .match)
        #expect(hosts.lookup(host: "hashedhost.example", port: 2222, key: try rsa()) == .match)
        #expect(hosts.lookup(host: "hashedhost.example", port: 2222, key: try ed25519()) == .notFound)
        #expect(hosts.lookup(host: "other.example", port: 22, key: try ed25519()) == .notFound)
    }

    @Test func commaSeparatedHostsAndIPs() throws {
        let hosts = KnownHosts(parsing: "raspcorse,192.168.1.20 \(try ed25519().openSSHPublicKey)\n")
        #expect(hosts.lookup(host: "raspcorse", port: 22, key: try ed25519()) == .match)
        #expect(hosts.lookup(host: "192.168.1.20", port: 22, key: try ed25519()) == .match)
        #expect(hosts.lookup(host: "192.168.1.21", port: 22, key: try ed25519()) == .notFound)
    }

    @Test func sameAlgorithmDifferentKeyIsMismatch() throws {
        let hosts = KnownHosts(parsing: "raspcorse \(try other().openSSHPublicKey)\n")
        #expect(hosts.lookup(host: "raspcorse", port: 22, key: try ed25519()) == .mismatch)
    }

    @Test func otherAlgorithmOnlyIsNotFound() throws {
        let hosts = KnownHosts(parsing: "raspcorse \(try rsa().openSSHPublicKey)\n")
        #expect(hosts.lookup(host: "raspcorse", port: 22, key: try ed25519()) == .notFound)
    }

    @Test func anyMatchingLineWinsOverAMismatch() throws {
        let text = "raspcorse \(try other().openSSHPublicKey)\nraspcorse \(try ed25519().openSSHPublicKey)\n"
        #expect(KnownHosts(parsing: text).lookup(host: "raspcorse", port: 22, key: try ed25519()) == .match)
    }

    @Test func rsaSHA2PresentedKeyComparesAsSSHRSA() throws {
        let hosts = KnownHosts(parsing: "raspcorse \(try rsa().openSSHPublicKey)\n")
        let presented = SSHHostKey(algorithm: "rsa-sha2-512", blob: try rsa().blob)
        #expect(hosts.lookup(host: "raspcorse", port: 22, key: presented) == .match)
    }

    @Test func markersAndCommentsIgnored() throws {
        let key = try ed25519().openSSHPublicKey
        let text = """
        # raspcorse \(key)
        @cert-authority raspcorse \(key)

        *.example \(key)
        broken line
        raspcorse ssh-ed25519 !!!notbase64
        """
        let hosts = KnownHosts(parsing: text)
        #expect(hosts.lookup(host: "raspcorse", port: 22, key: try ed25519()) == .notFound)
        #expect(hosts.lookup(host: "a.example", port: 22, key: try ed25519()) == .notFound)
    }

    @Test func revokedExactKeyBlocksEvenWhenAnotherLineMatches() throws {
        let key = try ed25519().openSSHPublicKey
        let text = "raspcorse \(key)\n@revoked * \(key)\n"
        let hosts = KnownHosts(parsing: text)
        #expect(hosts.lookup(host: "raspcorse", port: 22, key: try ed25519()) == .mismatch)
        #expect(hosts.lookup(host: "unrelated", port: 22, key: try ed25519()) == .mismatch)
    }

    @Test func revokedDifferentKeyHasNoEffect() throws {
        let text = "raspcorse \(try ed25519().openSSHPublicKey)\n@revoked raspcorse \(try other().openSSHPublicKey)\n"
        let hosts = KnownHosts(parsing: text)
        #expect(hosts.lookup(host: "raspcorse", port: 22, key: try ed25519()) == .match)
        #expect(hosts.lookup(host: "unrelated", port: 22, key: try ed25519()) == .notFound)
    }

    @Test func certAuthorityLineStaysIgnored() throws {
        let hosts = KnownHosts(parsing: "@cert-authority * \(try ed25519().openSSHPublicKey)\n")
        #expect(hosts.lookup(host: "raspcorse", port: 22, key: try ed25519()) == .notFound)
    }

    @Test func ipv6Hosts() throws {
        let key = try ed25519().openSSHPublicKey
        let hosts = KnownHosts(parsing: "[::1]:2222 \(key)\n::1 \(key)\n")
        #expect(hosts.lookup(host: "::1", port: 2222, key: try ed25519()) == .match)
        #expect(hosts.lookup(host: "::1", port: 22, key: try ed25519()) == .match)
        #expect(hosts.lookup(host: "::1", port: 2223, key: try ed25519()) == .notFound)
    }

    @Test func hashedEntryWithBadBase64IsSkipped() throws {
        let key = try ed25519().openSSHPublicKey
        let text = "|1|!!!|@@@ \(key)\n|1|onlyone \(key)\nraspcorse \(key)\n"
        let hosts = KnownHosts(parsing: text)
        #expect(hosts.lookup(host: "raspcorse", port: 22, key: try ed25519()) == .match)
        #expect(hosts.lookup(host: "x", port: 22, key: try ed25519()) == .notFound)
    }

    @Test func crlfLineEndingsParse() throws {
        let text = "a \(try ed25519().openSSHPublicKey)\r\nb \(try other().openSSHPublicKey)\r\n"
        let hosts = KnownHosts(parsing: text)
        #expect(hosts.lookup(host: "a", port: 22, key: try ed25519()) == .match)
        #expect(hosts.lookup(host: "b", port: 22, key: try other()) == .match)
    }
}
