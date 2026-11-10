import SwiftUI
import GhosttyEngine

/// Settings › Terminal (AppFlow › Settings Window › Terminal options): font family and size, theme,
/// every colour, and a preview drawn with the same font and colours as a terminal tab. Every change
/// is stored in `AppSettings` (UserDefaults, this Mac only) and applied to open terminals at once.
struct TerminalAppearanceSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    /// Installed monospaced families, read once when the section appears.
    @State private var families: [String] = []
    @State private var showsColors: Bool

    /// `expandsColors`: the Colors group starts open (offscreen renders).
    init(expandsColors: Bool = false) {
        _showsColors = State(initialValue: expandsColors)
    }

    private var isDark: Bool { colorScheme == .dark }
    private var theme: TerminalTheme { settings.terminalTheme(isDark: isDark) }

    var body: some View {
        @Bindable var settings = settings

        Picker(settings.t("settings_terminal_font"), selection: $settings.terminalFontFamily) {
            Text(settings.t("settings_terminal_font_bundled")).tag("")
            // The stored family always has a row (before the list is read, and once it is gone).
            if !settings.terminalFontFamily.isEmpty, !families.contains(settings.terminalFontFamily) {
                Text(families.isEmpty ? settings.terminalFontFamily
                                      : settings.t("settings_terminal_font_missing", settings.terminalFontFamily))
                    .tag(settings.terminalFontFamily)
            }
            Divider()
            ForEach(families, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .onAppear { if families.isEmpty { families = TerminalFonts.monospacedFamilies() } }

        Stepper(value: $settings.terminalFontSize, in: AppSettings.terminalFontSizeRange, step: 1) {
            Text(settings.t("settings_terminal_font_size", Int(settings.terminalFontSize)))
        }
        Text(settings.t("settings_terminal_font_size_help"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

        Picker(settings.t("settings_terminal_theme"), selection: $settings.terminalThemeRaw) {
            ForEach(TerminalThemeChoice.builtIn) { choice in
                Text(settings.t(choice.titleKey)).tag(choice.rawValue)
            }
            if settings.terminalCustomTheme != nil || settings.terminalThemeChoice == .custom {
                Divider()
                Text(settings.t(TerminalThemeChoice.custom.titleKey)).tag(TerminalThemeChoice.custom.rawValue)
            }
        }

        TerminalPreview(theme: theme, fonts: TerminalFonts(size: CGFloat(settings.terminalFontSize),
                                                           family: settings.terminalFontFamily))
            .accessibilityLabel(settings.t("settings_terminal_preview"))

        DisclosureGroup(settings.t("settings_terminal_colors"), isExpanded: $showsColors) {
            colorRow("settings_terminal_color_foreground", .foreground)
            colorRow("settings_terminal_color_background", .background)
            colorRow("settings_terminal_color_cursor", .cursor)
            colorRow("settings_terminal_color_selection_background", .selectionBackground)
            colorRow("settings_terminal_color_selection_foreground", .selectionForeground)
            ansiRow("settings_terminal_ansi_normal", range: 0..<8)
            ansiRow("settings_terminal_ansi_bright", range: 8..<16)
            Text(settings.t("settings_terminal_colors_help"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        Button(settings.t("settings_terminal_reset")) { settings.resetTerminalAppearance() }
    }

    private func colorRow(_ key: String, _ slot: TerminalTheme.Slot) -> some View {
        ColorPicker(settings.t(key), selection: binding(slot), supportsOpacity: false)
    }

    private func ansiRow(_ key: String, range: Range<Int>) -> some View {
        LabeledContent(settings.t(key)) {
            HStack(spacing: 4) {
                ForEach(Array(range), id: \.self) { index in
                    ColorPicker(settings.t("settings_terminal_ansi_color", index), selection: binding(.ansi(index)),
                                supportsOpacity: false)
                        .labelsHidden()
                }
            }
        }
    }

    private func binding(_ slot: TerminalTheme.Slot) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: theme.color(slot).nsColor) },
            set: { color in
                guard let value = VTColor(nsColor: NSColor(color)) else { return }
                settings.setTerminalColor(slot, to: value, isDark: isDark)
            })
    }
}

/// A few lines in the terminal's font and colours: a prompt, a coloured `ls`, a selected word, the
/// cursor, and the 16 ANSI colours.
private struct TerminalPreview: View {
    let theme: TerminalTheme
    let fonts: TerminalFonts

    private func color(_ slot: TerminalTheme.Slot) -> Color { Color(nsColor: theme.color(slot).nsColor) }

    private func run(_ text: String, _ slot: TerminalTheme.Slot, bold: Bool = false,
                     background: TerminalTheme.Slot? = nil) -> AttributedString {
        var run = AttributedString(text)
        run.font = Font(fonts.font(bold: bold, italic: false))
        run.foregroundColor = color(slot)
        if let background { run.backgroundColor = color(background) }
        return run
    }

    private var lines: [AttributedString] {
        [
            run("pi@raspberrypi", .ansi(2), bold: true) + run(":", .foreground) + run("~", .ansi(4), bold: true)
                + run("$ ", .foreground) + run("ls -l", .foreground),
            run("config.toml  ", .foreground) + run("logs/", .ansi(4), bold: true) + run("  run.sh", .ansi(2))
                + run("  backup.tar.gz", .ansi(1)),
            run("warning: ", .ansi(3), bold: true) + run("disk ", .foreground)
                + run("82%", .selectionForeground, background: .selectionBackground) + run(" full", .foreground),
            run("pi@raspberrypi", .ansi(2), bold: true) + run(":", .foreground) + run("~", .ansi(4), bold: true)
                + run("$ ", .foreground) + run(" ", .background, background: .cursor),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).lineLimit(1)
                }
            }
            HStack(spacing: 2) {
                ForEach(0..<16, id: \.self) { index in
                    Rectangle().fill(color(.ansi(index))).frame(width: 14, height: 10)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(.background))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .ignore)
    }
}
