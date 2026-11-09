#if DEBUG
import Foundation

/// The `-LibraryDemo ssh` key file and host key: generated with `ssh-keygen -t ed25519 -N ""` for the
/// demo only (2026-11-09), never authorised on any machine, never read from `~/.ssh`. The demo's
/// in-memory `~/.ssh` serves it as `id_ed25519`, so the real credential path parses a real key while
/// the connection stays fake. Listed by path in `.gitleaks.toml`.
enum LibraryDemoKey {
    static let privateKey = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACB4uOednyicyBsPub41VjWepHMhZjK4Hz0UPQASEhkHtwAAAJjwPopS8D6K
UgAAAAtzc2gtZWQyNTUxOQAAACB4uOednyicyBsPub41VjWepHMhZjK4Hz0UPQASEhkHtw
AAAEBvsaTOEOJ29P6ZWMY+6cMogvsfeJn/vZdtNdZPEYhsDXi4552fKJzIGw+5vjVWNZ6k
cyFmMrgfPRQ9ABISGQe3AAAAD3JlbW90ZWRlY2stZGVtbwECAwQFBg==
-----END OPENSSH PRIVATE KEY-----

"""

    static let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHi4552fKJzIGw+5vjVWNZ6kcyFmMrgfPRQ9ABISGQe3 remotedeck-demo"

    /// The fake "raspberrypi.local" host key the Host Key Sheet shows (public half only).
    static let hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF7DXC+rnCJOFi1xjQb2Wb7Rlbe+8/adQL4tXKQW31u+ raspberrypi-host"
}
#endif
