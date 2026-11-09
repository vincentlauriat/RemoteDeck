import Foundation
@testable import RemoteDeck

/// Records the URLs the app would hand to the browser (`NSWorkspace` is never called in tests).
@MainActor
final class FakeURLOpener: URLOpening {
    private(set) var opened: [URL] = []

    func open(_ url: URL) { opened.append(url) }
}
