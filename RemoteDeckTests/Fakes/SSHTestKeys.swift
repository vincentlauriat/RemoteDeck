import Foundation
import SSHKit

/// SSH keys for the hosted tests: copies of SSHKit's test fixtures
/// (`Packages/SSHKit/Tests/SSHKitTests/Fixtures/`), generated with ssh-keygen for the tests only and
/// never used anywhere else. Embedded as text because the hosted tests run inside the (sandboxed)
/// app, which cannot read the package's source tree. Listed by name in `.gitleaks.toml`.
enum SSHTestKeys {
    /// `id_ed25519`: no passphrase.
    static let ed25519 = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCNPjmLXmCtNVVOUyLqADEnlk8Cw+6fUAgNQUTJFrMqnwAAAJA44++QOOPv
kAAAAAtzc2gtZWQyNTUxOQAAACCNPjmLXmCtNVVOUyLqADEnlk8Cw+6fUAgNQUTJFrMqnw
AAAEAdfu0Jsa0YrH2FklUEVHu5CKvPotJo4miPojeFk8zgMo0+OYteYK01VU5TIuoAMSeW
TwLD7p9QCA1BRMkWsyqfAAAAC3NzaGtpdC10ZXN0AQI=
-----END OPENSSH PRIVATE KEY-----
"""

    static let ed25519Public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII0+OYteYK01VU5TIuoAMSeWTwLD7p9QCA1BRMkWsyqf sshkit-test"

    /// `id_ed25519_encrypted`: aes256-ctr / bcrypt (16 rounds), passphrase `test-pass`.
    static let ed25519Encrypted = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAvTHHohe
QIVPSTbENUipMOAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIGrATOioZqc/3sao
GwBvy9kD4nCQBtq89/vGxVREvFjAAAAAkAI/NMvB3m4hggUYjgwsj3p3thPQ6o3g/V7e6t
Fj+dnvefJxLrOjibVVMk9rBu4OnK/EGXD9irrB8D3k8v0LYCSTrh/W2HAv1+VE96bYK5b0
Bmhf1X4SZA1z4Qy7RSLHby4wF+w9Z2Zu1Ws4vPdv28Cu7TZSYRGwRKwfR3bW71KagEneWp
9zoIoyNjrR63AMaA==
-----END OPENSSH PRIVATE KEY-----
"""

    static let ed25519EncryptedPublic = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGrATOioZqc/3saoGwBvy9kD4nCQBtq89/vGxVREvFjA sshkit-test"
    static let passphrase = "test-pass"

    static let ecdsaPublic = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOMqKxHvVPs7S7clCd9SGEWiqlIIeXh/dEpZewSzYx5rM1wttcY1Hpu5pKHomwCwjEdR2ABYRS6bKacYSOPfVCQ= sshkit-test"
    static let rsaPublic = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC+EJst40jeQVeU4pqfOPdIkVf6ymMh0LreNS9pIPs2RiRTahWz5b2t7gMl/aP97k1tYyua6iRgr9Abix+R56a7sUy80mnLW1L+0OkaYl1GSSb4bzMZb/Ve+S+5rW4DftcCU8hDGVm/jqiSJrXyAjCQ9w5pWr7hClOEG75WUMSndpbwe2NgxWMAlu0pnLx3NW3YD+vtqZ6oUpL1PiElZVG+5Ub6QHQLp3/I7VzXs9YipuNbm2IPihxmyRbQaFCOnL8lUpjmhX3l3P+cd+q10ZLs9CiLdfnr2+a+TM0qt/Ncoef4TwIyS5/IiZEHkdVxsc9c2wGFayqu1tfaFw0icugkOTrGGEyymyb0gOHRb2sErsR6YY/+d5hMclNYnlYcZDL6uh5lowN5EIJvUnuRau7+e0mvClWU265qCD3SGRlHHV31vo44OjW86Ct0awtPK1hLnAc71eYiHkgN27mS6RIz+YbiBZiJk9MdLrbzOmrfnNCe3zZMulFOxd5VKa7g6ME= sshkit-test"

    /// Public keys used as server host keys.
    static func hostKey(_ line: String) -> SSHHostKey {
        // Test data known to parse (SSHKit's own tests read the same lines).
        try! SSHHostKey(openSSHPublicKey: line)
    }
}
