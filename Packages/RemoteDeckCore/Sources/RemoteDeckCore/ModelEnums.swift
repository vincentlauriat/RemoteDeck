import Foundation

// Typed views over the enum-valued fields. SwiftData stores the raw `String`
// (BackendSchema field names) so CloudKit records stay plain and additive.

/// Machine.kind (BackendSchema › Machine). `ssh` is schema V3: a terminal session, not a screen.
public enum MachineKind: String, CaseIterable, Sendable {
    case macARD, vnc, anthropicVM, ssh

    /// The port a new machine of this kind starts with: 5900 (RFB), or 22 for SSH.
    public var defaultPort: Int {
        self == .ssh ? 22 : 5900
    }
}

/// Machine.sshAuthMethod (schema V3): how an SSH machine authenticates. The password is the
/// machine's `machine.<id>` item; a key in `~/.ssh` is used in place (`sshKeyFileName`); an imported
/// key lives in the Keychain (`sshKey.<id>`).
public enum SSHAuthMethod: String, CaseIterable, Sendable {
    case password, keyInSSHFolder, importedKey
}

/// Machine.scalingMode.
public enum ScalingMode: String, CaseIterable, Sendable {
    case fit, actual
}

/// SessionRecord.outcome. `hostKeyRejected` (SSH, V3): the server's host key was refused before
/// authentication; a new raw value of the local store, so no migration.
public enum SessionOutcome: String, CaseIterable, Sendable {
    case connected, authFailed, unreachable, cancelled, dropped, hostKeyRejected
}

/// AssistantAction.kind: one per member of the computer use toolset that the assistant runs. Stored as
/// its raw String, so new cases need no migration.
public enum AssistantActionKind: String, CaseIterable, Sendable {
    case click, doubleClick, type, key, scroll, screenshot
    case tripleClick, rightClick, middleClick, drag, mouseMove, holdKey, wait, zoom, cursorPosition
}

/// AssistantAction.decision. `automatic`: a read-only action (screenshot, zoom, cursor position,
/// wait) that runs without asking, as no input reaches the remote.
public enum AssistantDecision: String, CaseIterable, Sendable {
    case pending, confirmed, rejected, cancelled, automatic
}
