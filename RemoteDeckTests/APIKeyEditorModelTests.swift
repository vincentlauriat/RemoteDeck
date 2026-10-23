import ClaudeKit
import Foundation
import Testing
@testable import RemoteDeck

/// Answers the key check with `result`, records the keys it was asked about.
actor FakeKeyChecker: APIKeyChecking {
    private let result: Result<Void, AnthropicError>
    private(set) var checked: [String] = []

    init(_ result: Result<Void, AnthropicError>) {
        self.result = result
    }

    func check(_ key: String) async throws(AnthropicError) {
        checked.append(key)
        try result.get()
    }
}

@MainActor
struct APIKeyEditorModelTests {
    let suite = "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)"
    let store = InMemoryAPIKeyStore()

    private func editor(_ checker: FakeKeyChecker) throws -> (APIKeyEditorModel, AppSettings) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, apiKeys: store)
        return (APIKeyEditorModel(settings: settings, checker: checker), settings)
    }

    @Test func typingWritesNothing() throws {
        let (editor, settings) = try editor(FakeKeyChecker(.success(())))
        for prefix in ["s", "sk", "sk-ant-", "sk-ant-api03-abc"] { editor.draft = prefix }
        #expect(store.writes == 0)
        #expect(!settings.apiKeyConfigured)
    }

    @Test func keyWithoutThePrefixIsRefusedWithoutARequest() async throws {
        let checker = FakeKeyChecker(.success(()))
        let (editor, _) = try editor(checker)
        editor.draft = "abc-123"
        editor.save()
        #expect(editor.status == .badPrefix)
        #expect(await checker.checked.isEmpty)
        #expect(store.writes == 0)
    }

    @Test func checkedKeyIsStoredOnce() async throws {
        let checker = FakeKeyChecker(.success(()))
        let (editor, settings) = try editor(checker)
        editor.draft = "  sk-ant-api03-good \n"
        editor.save()
        #expect(editor.status == .checking)
        #expect(await waitUntil { editor.status == .saved })
        #expect(await checker.checked == ["sk-ant-api03-good"])
        #expect(store.key == "sk-ant-api03-good")
        #expect(store.writes == 1)
        #expect(settings.anthropicAPIKey == "sk-ant-api03-good")
        #expect(editor.draft.isEmpty)   // the key is not shown back
        #expect(editor.hasStoredKey)
    }

    @Test func rejectedKeyIsNotStored() async throws {
        let (editor, settings) = try editor(FakeKeyChecker(.failure(.authentication)))
        editor.draft = "sk-ant-bad"
        editor.save()
        #expect(await waitUntil { editor.status == .rejected })
        #expect(store.writes == 0)
        #expect(!settings.apiKeyConfigured)
    }

    @Test func uncheckableKeyIsNotStored() async throws {
        let (editor, _) = try editor(FakeKeyChecker(.failure(.network("offline"))))
        editor.draft = "sk-ant-maybe"
        editor.save()
        #expect(await waitUntil { editor.status == .uncheckable(.network("offline")) })
        #expect(store.writes == 0)
    }

    @Test func removeDeletesTheKey() async throws {
        store.key = "sk-ant-old"
        let (editor, settings) = try editor(FakeKeyChecker(.success(())))
        #expect(editor.hasStoredKey)
        editor.remove()
        #expect(store.key == nil)
        #expect(!settings.apiKeyConfigured)
        #expect(editor.status == .removed)
    }
}
