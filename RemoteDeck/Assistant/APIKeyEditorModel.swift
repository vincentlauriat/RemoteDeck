import ClaudeKit
import Foundation
import Observation
import RemoteDeckCore

/// Checks an Anthropic API key against the API (`MessagesClient.checkKey`: `GET /v1/models`, no
/// tokens billed); a fake in tests.
protocol APIKeyChecking: Sendable {
    func check(_ key: String) async throws(AnthropicError)
}

extension MessagesClient: APIKeyChecking {
    func check(_ key: String) async throws(AnthropicError) {
        try await checkKey(key)
    }
}

/// Settings Window › Claude, the API key (AppFlow › Settings Window, BackendSchema › Authorization
/// rules): the field edits a draft only; "Save" checks the `sk-ant-` prefix, then a test request, and
/// only then writes the Keychain. Nothing is written while typing. The key itself is never shown
/// back, only whether one is stored.
@Observable
@MainActor
final class APIKeyEditorModel {
    enum Status: Equatable {
        case idle
        /// "Checking…"
        case checking
        /// "Key valid" ✓: checked and stored.
        case saved
        case removed
        /// Does not start with `sk-ant-`: nothing was sent.
        case badPrefix
        /// 401/403: "Invalid key".
        case rejected
        /// No answer, rate limited, server error: the key could not be checked, nothing saved.
        case uncheckable(AnthropicError)
        /// The Keychain refused it (status).
        case keychain(Int32)
    }

    static let prefix = "sk-ant-"

    var draft = "" {
        didSet { if draft != oldValue, status != .checking { status = .idle } }
    }
    private(set) var status: Status = .idle

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let checker: any APIKeyChecking
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(settings: AppSettings, checker: any APIKeyChecking) {
        self.settings = settings
        self.checker = checker
    }

    var hasStoredKey: Bool { settings.apiKeyConfigured }

    var canSave: Bool { !trimmedDraft.isEmpty && status != .checking }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    func save() {
        let key = trimmedDraft
        guard !key.isEmpty, status != .checking else { return }
        guard key.hasPrefix(Self.prefix) else {
            status = .badPrefix
            return
        }
        generation += 1
        let generation = self.generation
        status = .checking
        task = Task { [checker] in
            let result: Result<Void, AnthropicError>
            do throws(AnthropicError) {
                try await checker.check(key)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self.finish(result, key: key, generation: generation)
        }
    }

    private func finish(_ result: Result<Void, AnthropicError>, key: String, generation: Int) {
        guard generation == self.generation else { return }
        task = nil
        switch result {
        case .success:
            do {
                try settings.storeAPIKey(key)
                draft = ""
                status = .saved
            } catch {
                status = .keychain(error.status)
            }
        case .failure(.authentication), .failure(.permission):
            status = .rejected
        case .failure(.cancelled):
            status = .idle
        case .failure(let error):
            status = .uncheckable(error)
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        if status == .checking { status = .idle }
    }

    func remove() {
        cancel()
        settings.removeAPIKey()
        draft = ""
        status = settings.keychainError == nil ? .removed : .keychain(settings.keychainError?.status ?? 0)
    }
}
