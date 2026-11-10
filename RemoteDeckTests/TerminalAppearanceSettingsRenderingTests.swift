import AppKit
import Foundation
import GhosttyEngine
import SwiftUI
import Testing
@testable import RemoteDeck

// Settings › Terminal drawn offscreen (font, size, theme, preview, colours), light and dark. The PNGs
// land in `$TMPDIR/RemoteDeckTerminalSettingsSnapshots/` to be read by eye; the test checks that the
// preview is painted with the chosen theme's background.
@MainActor
struct TerminalAppearanceSettingsRenderingTests {
    let suiteName = "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)"

    private func render(dark: Bool, name: String, configure: (AppSettings) -> Void) throws -> NSBitmapImageRep {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, apiKeys: InMemoryAPIKeyStore())
        settings.languageRaw = AppLanguage.fr.rawValue
        configure(settings)
        let form = Form { Section(settings.t("settings_terminal")) { TerminalAppearanceSettings(expandsColors: true) } }
            .formStyle(.grouped)
            .frame(width: 480, height: 760)
            .environment(settings)
        let host = NSHostingView(rootView: form)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = NSSize(width: 480, height: 760)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteDeckTerminalSettingsSnapshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?
            .write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        return rep
    }

    /// Whether some pixel of the bitmap has this colour (within 2 per channel). The raw samples are
    /// read: the bitmap is drawn in sRGB, but `colorAt` tags it calibrated RGB, so converting it to
    /// sRGB would shift every colour.
    private func contains(_ rep: NSBitmapImageRep, _ color: VTColor) -> Bool {
        guard rep.bitsPerSample == 8, rep.samplesPerPixel >= 3 else { return false }
        var pixel = [Int](repeating: 0, count: rep.samplesPerPixel)
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                rep.getPixel(&pixel, atX: x, y: y)
                if abs(pixel[0] - Int(color.r)) <= 2, abs(pixel[1] - Int(color.g)) <= 2,
                   abs(pixel[2] - Int(color.b)) <= 2 { return true }
            }
        }
        return false
    }

    @Test func settingsRenderWithTheChosenTheme() throws {
        let automatic = try render(dark: true, name: "terminal-settings-automatic") { _ in }
        #expect(contains(automatic, TerminalTheme.dark.background))
        #expect(!contains(automatic, VTColor(hex: 0x3A1F5D)))   // the probe tells a colour that is not drawn
        let dracula = try render(dark: false, name: "terminal-settings-dracula-menlo") {
            $0.terminalThemeRaw = TerminalThemeChoice.dracula.rawValue
            $0.terminalFontFamily = "Menlo"
        }
        #expect(contains(dracula, TerminalTheme.dracula.background))
        let custom = try render(dark: true, name: "terminal-settings-custom") {
            $0.setTerminalColor(.background, to: VTColor(hex: 0x3A1F5D), isDark: true)
        }
        #expect(contains(custom, VTColor(hex: 0x3A1F5D)))
    }
}
