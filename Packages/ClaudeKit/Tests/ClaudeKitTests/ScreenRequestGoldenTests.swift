import Foundation
import Testing
@testable import ClaudeKit

/// The screen assistant's request body, frozen byte for byte. The fixtures were captured from the code
/// before ClaudeKit learned custom tools (terminal assistant): any change to them is a change to every
/// screen request. Re-record only on purpose: `CLAUDEKIT_RECORD_GOLDEN=1 swift test --filter ScreenRequestGoldenTests`.
struct ScreenRequestGoldenTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    /// A fixed prompt with a fixed screenshot, a member call answered with a text and an image result,
    /// and an owed result opening the next user message.
    private func body(_ desktop: RemoteDesktopKind) -> Data {
        var conversation = Conversation(configuration: RequestConfiguration(desktop: desktop))
        let png = EncodedImage(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01]),
                               mediaType: "image/png", width: 1280, height: 800)
        conversation.appendUser([ContentBlock.image(png), ContentBlock.text("Open Terminal, s'il te plaît")])
        conversation.appendAssistant([
            ["type": "thinking", "thinking": "Opening the dock.", "signature": "sig-1"],
            toolUse("toolu_1", "left_click", ["coordinate": [10, 20]]),
            toolUse("toolu_2", "screenshot"),
        ])
        conversation.appendUser([
            ContentBlock.toolResult(id: "toolu_1", text: ToolResultText.ok),
            ContentBlock.toolResult(id: "toolu_2", content: [ContentBlock.image(png)]),
        ])
        conversation.appendAssistant([toolUse("toolu_3", "key", ["text": "Return"])])
        conversation.deferResults([ContentBlock.toolResult(id: "toolu_3", text: ToolResultText.stopped, isError: true)])
        conversation.appendUser([ContentBlock.text("next")])
        return conversation.requestBody()
    }

    private func check(_ desktop: RemoteDesktopKind, _ name: String) throws {
        let url = Self.fixtures.appendingPathComponent(name)
        let body = body(desktop)
        if ProcessInfo.processInfo.environment["CLAUDEKIT_RECORD_GOLDEN"] == "1" {
            try body.write(to: url)
        }
        let fixture = try Data(contentsOf: url)
        #expect(body == fixture, "the screen request body changed: \(String(decoding: body, as: UTF8.self))")
    }

    @Test func screenRequestBodyIsUnchanged() throws {
        try check(.mac, "screen-request.json")
    }

    @Test func screenRequestBodyIsUnchangedForX11() throws {
        try check(.x11, "screen-request-x11.json")
    }
}
