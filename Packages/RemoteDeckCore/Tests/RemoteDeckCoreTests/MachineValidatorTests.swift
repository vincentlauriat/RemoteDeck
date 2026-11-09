import Foundation
import Testing
@testable import RemoteDeckCore

struct MachineValidatorTests {
    let validator = MachineValidator()

    func draft(
        name: String = "Studio",
        kind: MachineKind = .macARD,
        host: String = "studio.local",
        port: Int = 5900,
        username: String? = "vincent"
    ) -> MachineDraft {
        MachineDraft(name: name, kind: kind, host: host, port: port, username: username)
    }

    @Test func acceptsValidMachine() {
        #expect(validator.validate(draft()).isEmpty)
    }

    // MARK: name

    @Test(arguments: ["A", "  Mac mini  ", String(repeating: "x", count: 64), "Bureau é 🖥️"])
    func acceptsNames(_ name: String) {
        #expect(validator.validate(draft(name: name)).isEmpty)
    }

    @Test func rejectsEmptyOrBlankName() {
        #expect(validator.validate(draft(name: "")) == [.init(.name, .empty)])
        #expect(validator.validate(draft(name: " \n\t ")) == [.init(.name, .empty)])
    }

    @Test func rejectsNameOver64AfterTrimming() {
        #expect(validator.validate(draft(name: String(repeating: "x", count: 65)))
            == [.init(.name, .tooLong(max: 64))])
        // Trimming happens before counting.
        #expect(validator.validate(draft(name: "  " + String(repeating: "x", count: 64) + "  ")).isEmpty)
    }

    // MARK: host

    @Test(arguments: [
        "studio.local", "localhost", "my-mac", "a.b.c.example.com", "example.com.", "1password.com",
        "192.168.1.10", "0.0.0.0", "255.255.255.255",
        "::1", "2001:db8::1", "fe80::1%en0", "::ffff:1.2.3.4",
        "fe80::1%en9", "fe80::1%bridge100", "fe80::1%7",  // zone syntax only: en9 does not exist here
        "10.0.0.1", "100.200.0.1",
        String(repeating: "a", count: 63) + ".com",
    ])
    func acceptsHosts(_ host: String) {
        #expect(MachineValidator.isValidHost(host), "\(host)")
    }

    @Test(arguments: [
        "vnc://studio.local", "studio.local/path", "studio.local:5900", "1.2.3.4:5900",
        "[::1]", " studio.local", "studio local", "studio.local\n",
        "-studio.local", "studio-.local", "stu_dio.local", "studio..local", ".studio", "..",
        "256.1.1.1", "1.2.3", "10.1", "1", "01.2.3.4.5", "1.2.3.4%en0", "1.2.3.4.",
        "::1 ", "12345::1", "café.local",
        "fe80::1%", "fe80::1%/x", "fe80::1%café", "::1%25en0", "fe80::1%a%b", "fe80::1% en0",
        "010.0.0.1", "1.02.3.4", "00.0.0.0",
        String(repeating: "a", count: 64) + ".com",
        Array(repeating: String(repeating: "a", count: 63), count: 4).joined(separator: "."),
    ])
    func rejectsHosts(_ host: String) {
        #expect(!MachineValidator.isValidHost(host), "\(host)")
    }

    @Test func reportsHostErrorsByField() {
        #expect(validator.validate(draft(host: "")) == [.init(.host, .empty)])
        #expect(validator.validate(draft(host: "vnc://x")) == [.init(.host, .invalidHost)])
    }

    // MARK: port

    @Test(arguments: [1, 5900, 65535])
    func acceptsPorts(_ port: Int) {
        #expect(validator.validate(draft(port: port)).isEmpty)
    }

    @Test(arguments: [0, -1, 65536, 100_000])
    func rejectsPorts(_ port: Int) {
        #expect(validator.validate(draft(port: port)) == [.init(.port, .outOfRange)])
    }

    // MARK: username

    @Test func requiresUsernameForMacARD() {
        #expect(validator.validate(draft(kind: .macARD, username: nil)) == [.init(.username, .empty)])
        #expect(validator.validate(draft(kind: .macARD, username: "  ")) == [.init(.username, .empty)])
    }

    @Test(arguments: [MachineKind.vnc, .anthropicVM])
    func usernameOptionalForOtherKinds(_ kind: MachineKind) {
        #expect(validator.validate(draft(kind: kind, username: nil)).isEmpty)
    }

    // MARK: SSH machines

    func ssh(
        username: String? = "azureuser",
        auth: SSHAuthMethod = .password,
        keyFile: String? = nil,
        forwards: [PortForward] = []
    ) -> MachineDraft {
        MachineDraft(name: "Azure VM", kind: .ssh, host: "vm.example.com", port: 22, username: username,
                     sshAuth: auth, sshKeyFileName: keyFile, portForwards: forwards)
    }

    @Test func acceptsValidSSHMachine() {
        #expect(validator.validate(ssh()).isEmpty)
        #expect(validator.validate(ssh(auth: .importedKey)).isEmpty)
        #expect(validator.validate(ssh(auth: .keyInSSHFolder, keyFile: "id_ed25519")).isEmpty)
        #expect(validator.validate(ssh(auth: .keyInSSHFolder, keyFile: "azure/vm_key")).isEmpty)
        #expect(validator.validate(ssh(forwards: [PortForward(localPort: 1024, remotePort: 1),
                                                  PortForward(localPort: 65535, remotePort: 65535)])).isEmpty)
    }

    @Test func sshRequiresUserName() {
        #expect(validator.validate(ssh(username: nil)) == [.init(.username, .empty)])
        #expect(validator.validate(ssh(username: " ")) == [.init(.username, .empty)])
    }

    @Test(arguments: [nil, "", "  ", "../id_rsa", "a/../b", "keys/..", "/etc/ssh/id_rsa", "x/..y"])
    func keyInFolderRequiresFileName(_ name: String?) {
        #expect(validator.validate(ssh(auth: .keyInSSHFolder, keyFile: name)) == [.init(.sshKeyFileName, .missingKeyFile)])
    }

    /// Only a key used in place needs a file name; a stale one left by another method is not checked.
    @Test(arguments: [SSHAuthMethod.password, .importedKey])
    func fileNameIgnoredForOtherMethods(_ auth: SSHAuthMethod) {
        #expect(validator.validate(ssh(auth: auth, keyFile: "../x")).isEmpty)
    }

    @Test(arguments: [0, 22, 80, 1023, 65536])
    func forwardLocalPortBelow1024IsInvalid(_ port: Int) {
        let forward = PortForward(localPort: port, remotePort: 80)
        #expect(validator.validate(ssh(forwards: [forward]))
            == [.init(.portForwards, .invalidForwardPort, forwardID: forward.id)])
    }

    @Test(arguments: [0, -1, 65536])
    func forwardRemotePortOutsideRangeIsInvalid(_ port: Int) {
        let forward = PortForward(localPort: 8080, remotePort: port)
        #expect(validator.validate(ssh(forwards: [forward]))
            == [.init(.portForwards, .invalidForwardPort, forwardID: forward.id)])
    }

    @Test func duplicateLocalPortsAreInvalid() {
        let forwards = [PortForward(localPort: 8080, remotePort: 80),
                        PortForward(localPort: 8080, remoteHost: "other", remotePort: 81),
                        PortForward(localPort: 8443, remotePort: 443)]
        // The row that repeats an earlier local port carries the error, not the first one.
        #expect(validator.validate(ssh(forwards: forwards))
            == [.init(.portForwards, .duplicateLocalPort, forwardID: forwards[1].id)])
    }

    /// Each faulty row gets its own issue (the editor shows it under that row), in list order.
    @Test func forwardIssuesNameTheirRow() {
        let good = PortForward(localPort: 8080, remotePort: 80)
        let badLocal = PortForward(localPort: 80, remotePort: 80)
        let badRemote = PortForward(localPort: 9000, remotePort: 0)
        let repeated = PortForward(localPort: 8080, remotePort: 81)
        #expect(validator.validate(ssh(forwards: [good, badLocal, badRemote, repeated])) == [
            .init(.portForwards, .invalidForwardPort, forwardID: badLocal.id),
            .init(.portForwards, .invalidForwardPort, forwardID: badRemote.id),
            .init(.portForwards, .duplicateLocalPort, forwardID: repeated.id),
        ])
    }

    /// Screen machines keep their rules: SSH fields are not looked at.
    @Test func sshFieldsIgnoredForScreenKinds() {
        var vnc = ssh(username: nil, auth: .keyInSSHFolder, keyFile: nil,
                      forwards: [PortForward(localPort: 1, remotePort: 0)])
        vnc.kind = .vnc
        vnc.port = 5900
        #expect(validator.validate(vnc).isEmpty)
    }

    @Test func draftCopiesSSHFieldsFromMachine() {
        let forward = PortForward(localPort: 8080, remotePort: 80)
        let machine = Machine(name: "VM", kind: .ssh, host: "vm", port: 22, username: "u")
        machine.sshAuth = .keyInSSHFolder
        machine.sshKeyFileName = "id_ed25519"
        machine.portForwards = [forward]
        let draft = MachineDraft(machine)
        #expect(draft.sshAuth == .keyInSSHFolder && draft.sshKeyFileName == "id_ed25519")
        #expect(draft.portForwards == [forward])
    }

    // MARK: uniqueness

    @Test func normalizedKeyLowercasesHost() {
        #expect(MachineValidator.normalizedKey(host: "Studio.LOCAL", port: 5900) == "studio.local:5900")
        #expect(MachineValidator.normalizedKey(host: "2001:DB8::1", port: 5901) == "2001:db8::1:5901")
    }

    @Test(arguments: [
        ("2001:DB8:0:0::1", "2001:db8::1"),
        ("FE80::1%EN0", "fe80::1%en0"),
        ("studio.local.", "studio.local"),
        ("Studio.Local.", "studio.local"),
    ])
    func equivalentHostsShareKey(_ pair: (String, String)) {
        #expect(MachineValidator.normalizedKey(host: pair.0, port: 5900)
            == MachineValidator.normalizedKey(host: pair.1, port: 5900))
    }

    @Test func zoneIsPartOfIPv6Key() {
        #expect(MachineValidator.normalizedKey(host: "fe80::1%en0", port: 5900)
            != MachineValidator.normalizedKey(host: "fe80::1%en1", port: 5900))
        #expect(MachineValidator.normalizedKey(host: "fe80::1%en9", port: 5900) == "fe80::1%en9:5900")
    }

    @Test func equivalentIPv6IsDuplicate() {
        let existing = [UUID(): MachineValidator.normalizedKey(host: "2001:db8::1", port: 5900)]
        #expect(validator.validate(draft(host: "2001:DB8:0:0::1"), existingKeys: existing)
            == [.init(.host, .duplicate)])
    }

    @Test func rejectsDuplicateHostPortCaseInsensitively() {
        let existing = [UUID(): "studio.local:5900"]
        #expect(validator.validate(draft(host: "STUDIO.local"), existingKeys: existing)
            == [.init(.host, .duplicate)])
    }

    @Test func sameHostOtherPortIsNotDuplicate() {
        let existing = [UUID(): "studio.local:5900"]
        #expect(validator.validate(draft(port: 5901), existingKeys: existing).isEmpty)
    }

    @Test func editingMachineDoesNotClashWithItself() {
        let id = UUID()
        let existing = [id: "studio.local:5900", UUID(): "other.local:5900"]
        #expect(validator.validate(draft(), existingKeys: existing, editingID: id).isEmpty)
        // …but still clashes with another machine.
        #expect(validator.validate(draft(host: "other.local"), existingKeys: existing, editingID: id)
            == [.init(.host, .duplicate)])
    }

    @Test func reportsAllFieldErrorsTogether() {
        let issues = validator.validate(draft(name: "", host: "bad host", port: 0, username: nil))
        #expect(issues == [
            .init(.name, .empty), .init(.host, .invalidHost),
            .init(.port, .outOfRange), .init(.username, .empty),
        ])
    }

    // MARK: MachineGroup name

    @Test func acceptsGroupNames() {
        #expect(validator.validateGroupName("Office").isEmpty)
        #expect(validator.validateGroupName(String(repeating: "g", count: 40)).isEmpty)
    }

    @Test func rejectsEmptyOrLongGroupNames() {
        #expect(validator.validateGroupName("   ") == [.init(.groupName, .empty)])
        #expect(validator.validateGroupName(String(repeating: "g", count: 41))
            == [.init(.groupName, .tooLong(max: 40))])
    }

    @Test func groupNamesAreUniqueCaseInsensitively() {
        let id = UUID()
        let existing = [id: "Office", UUID(): "Home"]
        #expect(validator.validateGroupName("office", existingNames: existing) == [.init(.groupName, .duplicate)])
        #expect(validator.validateGroupName(" HOME ", existingNames: existing) == [.init(.groupName, .duplicate)])
        #expect(validator.validateGroupName("OFFICE", existingNames: existing, editingID: id).isEmpty)
        #expect(validator.validateGroupName("Lab", existingNames: existing).isEmpty)
        #expect(validator.validateGroupName("STRASSE", existingNames: [UUID(): "Straße"])
            == [.init(.groupName, .duplicate)])
    }
}
