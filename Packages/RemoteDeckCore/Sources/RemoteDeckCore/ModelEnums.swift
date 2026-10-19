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

/// AssistantAction.kind.
public enum AssistantActionKind: String, CaseIterable, Sendable {
    case click, doubleClick, type, key, scroll, screenshot
}

/// AssistantAction.decision.
public enum AssistantDecision: String, CaseIterable, Sendable {
    case pending, confirmed, rejected, cancelled
}
