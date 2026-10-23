import Testing
@testable import RFBKit

struct KeyChordTests {
    @Test func namedKeysAndAliases() throws {
        let cases: [(String, UInt32)] = [
            ("Return", Keysym.return), ("Enter", Keysym.return), ("return", Keysym.return), ("Tab", Keysym.tab),
            ("Escape", Keysym.escape), ("Esc", Keysym.escape), ("BackSpace", Keysym.backSpace),
            ("Delete", Keysym.delete), ("Page_Down", Keysym.pageDown), ("Next", Keysym.pageDown),
            ("Prior", Keysym.pageUp), ("Up", Keysym.up), ("Left", Keysym.left), ("Home", Keysym.home),
            ("space", Keysym.space), ("F1", Keysym.f(1)), ("F12", Keysym.f(12)), ("minus", 0x2D), ("slash", 0x2F),
            ("a", 0x61), ("A", 0x41), ("1", 0x31), ("é", 0xE9), ("€", 0x0100_20AC),
        ]
        for (name, keysym) in cases {
            #expect(try KeyChord.parse(name, profile: .x11).keysyms == [keysym], "\(name)")
        }
    }

    @Test func combosPressInOrderAndReleaseInReverse() throws {
        let chord = try KeyChord.parse("ctrl+shift+t", profile: .x11)
        #expect(chord.keysyms == [Keysym.controlL, Keysym.shiftL, 0x74])
        #expect(chord.pressAndRelease == [
            .keyEvent(down: true, key: Keysym.controlL), .keyEvent(down: true, key: Keysym.shiftL),
            .keyEvent(down: true, key: 0x74), .keyEvent(down: false, key: 0x74),
            .keyEvent(down: false, key: Keysym.shiftL), .keyEvent(down: false, key: Keysym.controlL),
        ])
        #expect(try KeyChord.parse("alt+Tab", profile: .x11).keysyms == [Keysym.altL, Keysym.tab])
        #expect(try KeyChord.parse("ctrl++", profile: .x11).keysyms == [Keysym.controlL, 0x2B])
        #expect(try KeyChord.parse("+", profile: .x11).keysyms == [0x2B])
        #expect(try KeyChord.parse(" ctrl + s ", profile: .x11).keysyms == [Keysym.controlL, 0x73])
        // A letter with a modifier is the key: ctrl+C is ctrl+c; alone, C stays the capital.
        #expect(try KeyChord.parse("ctrl+C", profile: .x11).keysyms == [Keysym.controlL, 0x63])
        #expect(try KeyChord.parse("super+shift+T", profile: .x11).keysyms == [Keysym.superL, Keysym.shiftL, 0x74])
        #expect(try KeyChord.parse("C", profile: .x11).keysyms == [0x43])
    }

    @Test func superAndAltFollowTheMachineProfile() throws {
        #expect(try KeyChord.parse("super+c", profile: .appleRemoteDesktop).keysyms == [Keysym.altL, 0x63])
        #expect(try KeyChord.parse("alt", profile: .appleRemoteDesktop).keysyms == [Keysym.metaL])
        #expect(try KeyChord.parse("cmd+v", profile: .appleRemoteDesktop).keysyms == [Keysym.altL, 0x76])
        #expect(try KeyChord.parse("super+c", profile: .x11).keysyms == [Keysym.superL, 0x63])
        #expect(try KeyChord.parse("alt_r", profile: .x11).keysyms == [Keysym.altR])
    }

    @Test func unknownKeysAreErrors() {
        #expect(throws: KeyChord.ParseError.unknownKey("Hyper")) { try KeyChord.parse("ctrl+Hyper", profile: .x11) }
        #expect(throws: KeyChord.ParseError.unknownKey("XF86AudioPlay")) { try KeyChord.parse("XF86AudioPlay", profile: .x11) }
        #expect(throws: KeyChord.ParseError.empty) { try KeyChord.parse("  ", profile: .x11) }
        #expect(throws: KeyChord.ParseError.unknownKey("ctrl++a")) { try KeyChord.parse("ctrl++a", profile: .x11) }
    }

    @Test func modifierTextAcceptsOnlyModifiers() throws {
        #expect(try KeyChord.parseModifiers("", profile: .x11).keysyms.isEmpty)
        #expect(try KeyChord.parseModifiers("ctrl+shift", profile: .x11).keysyms == [Keysym.controlL, Keysym.shiftL])
        #expect(throws: KeyChord.ParseError.notAModifier("a")) { try KeyChord.parseModifiers("ctrl+a", profile: .x11) }
    }

    @Test func typingTurnsNewlinesAndTabsIntoKeys() {
        #expect(KeyChord.typing("a\tb\r\n") == [
            .keyEvent(down: true, key: 0x61), .keyEvent(down: false, key: 0x61),
            .keyEvent(down: true, key: Keysym.tab), .keyEvent(down: false, key: Keysym.tab),
            .keyEvent(down: true, key: 0x62), .keyEvent(down: false, key: 0x62),
            .keyEvent(down: true, key: Keysym.return), .keyEvent(down: false, key: Keysym.return),
        ])
        #expect(KeyChord.typing("bell\u{7}") == nil)
        #expect(KeyChord.typing("") == [])
    }
}
