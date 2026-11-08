import Foundation
import Testing
@testable import SSHKit

@Suite struct HostKeyTests {
    @Test func fingerprintMatchesSSHKeygen() throws {
        // `ssh-keygen -lf Fixtures/host_ed25519.pub`:
        // 256 SHA256:wsm0OJwEkE/IpK6xhzqT+5Upq7rQfzKp+JkelrTAJqo sshkit-test-host (ED25519)
        #expect(try SSHHostKey(openSSHPublicKey: fixture("host_ed25519.pub")).fingerprintSHA256
            == "SHA256:wsm0OJwEkE/IpK6xhzqT+5Upq7rQfzKp+JkelrTAJqo")
    }

    @Test func readsAlgorithmAndBlob() throws {
        let key = try SSHHostKey(openSSHPublicKey: fixture("host_ed25519.pub"))
        #expect(key.algorithm == "ssh-ed25519")
        // string "ssh-ed25519" (4 + 11 bytes) + string of the 32-byte point (4 + 32 bytes).
        #expect(key.blob.count == 51)
    }

    @Test func fingerprintHasNoPadding() throws {
        let key = try SSHHostKey(openSSHPublicKey: fixture("id_rsa.pub"))
        #expect(key.algorithm == "ssh-rsa")
        #expect(key.fingerprintSHA256.hasPrefix("SHA256:"))
        #expect(!key.fingerprintSHA256.hasSuffix("="))
        #expect(key.fingerprintSHA256.count == 7 + 43)
    }

    @Test func rejectsMalformedPublicKeys() {
        #expect(throws: SSHKeyError.malformed) { try SSHHostKey(openSSHPublicKey: "") }
        #expect(throws: SSHKeyError.malformed) { try SSHHostKey(openSSHPublicKey: "ssh-ed25519") }
        #expect(throws: SSHKeyError.malformed) { try SSHHostKey(openSSHPublicKey: "ssh-ed25519 not*base64") }
    }

    @Test func rejectsABlobWhoseTypeDiffersFromTheAlgorithm() throws {
        let ed25519 = try fixture("host_ed25519.pub").split(separator: " ")
        #expect(throws: SSHKeyError.malformed) { try SSHHostKey(openSSHPublicKey: "ssh-rsa \(ed25519[1])") }
    }
}
