import Testing
@testable import SSHKit

@Suite struct SSHConfigFileTests {
    @Test func parsesVincentsRaspcorseBlock() {
        let text = "Host raspcorse\n    HostName raspcorse\n    User vincent\n    IdentityFile ~/.ssh/id_ed25519\n    IdentitiesOnly yes\n    ServerAliveInterval 30\n"
        #expect(SSHConfigFile.parse(text) == [SSHConfigHost(alias: "raspcorse", hostName: "raspcorse", user: "vincent", port: nil, identityFile: "id_ed25519")])
    }

    @Test func skipsWildcardAndMultiAliasHosts() {
        #expect(SSHConfigFile.parse("Host *\n  User root\n") == [])
        #expect(SSHConfigFile.parse("Host a b\n  User root\n") == [])
        #expect(SSHConfigFile.parse("Host web-?\n  User root\nHost !bad\n  User root\n") == [])
    }

    @Test func parsesPortAndIsCaseInsensitive() {
        #expect(SSHConfigFile.parse("host x\n  PORT 2222") == [SSHConfigHost(alias: "x", hostName: nil, user: nil, port: 2222, identityFile: nil)])
    }

    @Test func ignoresCommentsBlankLinesAndGlobalOptions() {
        let text = """
        # global
        User nobody

        Host a   # a trailing comment ends the line, as in OpenSSH
          User alice # here too
        Host b
          # HostName commented.example
          HostName b.example
        """
        #expect(SSHConfigFile.parse(text) == [
            SSHConfigHost(alias: "a", hostName: nil, user: "alice", port: nil, identityFile: nil),
            SSHConfigHost(alias: "b", hostName: "b.example", user: nil, port: nil, identityFile: nil),
        ])
    }

    @Test func acceptsEqualsSignsQuotesAndTabs() {
        let text = "Host=nas\n\tHostName = \"nas.local\"\n\tUser=admin\n\tPort\t22\n"
        #expect(SSHConfigFile.parse(text) == [SSHConfigHost(alias: "nas", hostName: "nas.local", user: "admin", port: 22, identityFile: nil)])
    }

    @Test func keepsTheFirstValueOfAKeywordAsSSHDoes() {
        #expect(SSHConfigFile.parse("Host x\n  User first\n  User second\n").first?.user == "first")
    }

    @Test func dropsAnInvalidPort() {
        #expect(SSHConfigFile.parse("Host x\n  Port ssh\n").first?.port == nil)
        #expect(SSHConfigFile.parse("Host x\n  Port 70000\n").first?.port == nil)
    }

    @Test func stripsOnlyTheDotSSHPrefixFromIdentityFile() {
        let text = "Host a\n  IdentityFile ~/.ssh/keys/work\nHost b\n  IdentityFile /opt/keys/b\n"
        #expect(SSHConfigFile.parse(text).map(\.identityFile) == ["keys/work", "/opt/keys/b"])
    }

    @Test func stopsAHostBlockAtMatch() {
        let text = "Host a\n  User one\nMatch host b\n  User two\n"
        #expect(SSHConfigFile.parse(text) == [SSHConfigHost(alias: "a", hostName: nil, user: "one", port: nil, identityFile: nil)])
    }
}
