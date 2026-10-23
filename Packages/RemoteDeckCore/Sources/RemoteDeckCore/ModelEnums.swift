import Foundation

// Typed views over the enum-valued fields. SwiftData stores the raw `String`
// (BackendSchema field names) so CloudKit records stay plain and additive.

/// Machine.kind (BackendSchema › Machine).
public enum MachineKind: String, CaseIterable, Sendable {
    case macARD, vnc, anthropicVM
}

/// Machine.scalingMode.
public enum ScalingMode: String, CaseIterable, Sendable {
    case fit, actual
}

/// SessionRecord.outcome.
public enum SessionOutcome: String, CaseIterable, Sendable {
    case connected, authFailed, unreachable, cancelled, dropped
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
