import AppKit
import Foundation
import SwiftData
import Testing
import RemoteDeckCore
import RFBKit
@testable import RemoteDeck

/// A window whose key state the test sets: the hosted tests run in an app that is not active, so
/// AppKit never makes a window key there. Changing `key` posts the notification AppKit would.
@MainActor
final class TabWindow: NSWindow {
    var key = false {
        didSet {
            guard key != oldValue else { return }
            NotificationCenter.default.post(name: key ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification,
                                            object: self)
        }
    }

    /// On screen and minimised as the test says (the test windows are never ordered in).
    var onScreen = false
    var minimised = false

    override var isKeyWindow: Bool { key }
    override var canBecomeKey: Bool { true }
    override var isVisible: Bool { onScreen }
    override var isMiniaturized: Bool { minimised }

    static func make(_ title: String) -> TabWindow {
        let window = TabWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable,
                               .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        return window
    }
}

// MARK: - Close signal

@MainActor
struct SessionWindowCloseSignalTests {
    /// Everything a tab goes through without being closed: selected away (its window resigns key and
    /// is ordered out), minimised, full screen in and out, occlusion changes, moved to another tab group
    /// (AppKit removes and adds the same window). None of it closes; a real close does, once.
    @Test func onlyARealCloseEndsTheSession() {
        let window = TabWindow.make("Mac mini")
        let observer = SessionWindowObserver(frame: .zero)
        var attached: [NSWindow] = []
        var closes = 0
        observer.onAttach = { attached.append($0) }
        observer.onClose = { closed in
            #expect(closed === window)
            closes += 1
        }
        window.contentView?.addSubview(observer)
        #expect(attached.count == 1 && attached.first === window)

        window.key = true
        window.key = false          // another tab selected
        window.orderOut(nil)        // AppKit hides an unselected tab's window
        let center = NotificationCenter.default
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMoveNotification] {
            center.post(name: name, object: window)
        }
        // Another window closing is not this one's close.
        let other = TabWindow.make("NAS")
        other.close()
        // SwiftUI rebuilding the content detaches and re-attaches the observer: attached again (adopt
        // then ignores a window it knows), still not a close.
        observer.removeFromSuperview()
        window.contentView?.addSubview(observer)
        #expect(attached.count == 2 && observer.isObserving)
        #expect(closes == 0)

        window.close()
        #expect(closes == 1)
        window.close()
        #expect(closes == 1)
    }

    /// Detached from its window, the observer stops observing it: that window's close is not reported
    /// by it (the observer in the window then reports it), and it observes the next window it joins.
    @Test func aDetachedObserverReportsNoClose() {
        let window = TabWindow.make("Mac mini"), next = TabWindow.make("NAS")
        let observer = SessionWindowObserver(frame: .zero)
        var closes: [NSWindow] = []
        observer.onClose = { closes.append($0) }
        window.contentView?.addSubview(observer)
        #expect(observer.isObserving)
        observer.removeFromSuperview()
        #expect(!observer.isObserving)
        window.close()
        #expect(closes.isEmpty)
        next.contentView?.addSubview(observer)
        #expect(observer.isObserving)
        next.close()
        #expect(closes.count == 1 && closes.first === next)
    }

    /// Two sessions, each wired to its own window's close as the Session Window does: switching from
    /// one tab to the other keeps both connections; closing one tab tears down that session only.
    @Test func closingOneTabTearsDownOnlyItsSession() async throws {
        let context = try makeTestContext()
        let mini = Machine(name: "Mac mini", host: "mini.local", username: "vincent")
        let nas = Machine(name: "NAS", kind: .vnc, host: "nas.local", port: 5901)
        context.insert(mini)
        context.insert(nas)
        try context.save()
        let logs = [mini.id: SessionLog(), nas.id: SessionLog()]
        var connections: [UUID: FakeSessionConnection] = [:]
        let manager = SessionManager(context: context, passwords: FakePasswordStore(), tester: FakeConnectionTester(),
                                     makeConnection: { target in
                                         let connection = FakeSessionConnection(log: logs[target.machineID]!)
                                         connections[target.machineID] = connection
                                         return connection
                                     }, makeDisplay: { nil }, pasteboard: InMemoryPasteboard())
        var windows: [UUID: TabWindow] = [:]
        for machine in [mini, nas] {
            let session = try #require(manager.session(for: machine.id))
            #expect(await waitUntilAsync { await connections[machine.id]?.hasEvents == true })
            await connections[machine.id]?.emit(frame)
            #expect(await waitUntil { session.phase == .connected })
            let window = TabWindow.make(machine.name)
            let observer = SessionWindowObserver(frame: .zero)
            let id = machine.id
            observer.onClose = { _ in manager.close(id) }
            window.contentView?.addSubview(observer)
            windows[id] = window
        }
        let miniSession = try #require(manager.sessions[mini.id])
        let nasSession = try #require(manager.sessions[nas.id])

        // The Mac mini tab is selected; ⌘2: the NAS tab is shown, the Mac mini tab hidden.
        windows[mini.id]?.key = true
        windows[mini.id]?.key = false
        windows[mini.id]?.orderOut(nil)
        windows[nas.id]?.key = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: windows[mini.id])
        try await Task.sleep(for: .milliseconds(50))
        #expect(miniSession.phase == .connected && nasSession.phase == .connected)
        #expect(manager.sessions.count == 2)
        #expect(!logs[mini.id]!.all.contains("close") && !logs[nas.id]!.all.contains("close"))

        // The NAS tab is closed (its close button, or ⌘W with the keyboard released).
        windows[nas.id]?.close()
        #expect(manager.sessions[nas.id] == nil)
        #expect(await waitUntil { logs[nas.id]!.all.contains("close") })
        #expect(miniSession.phase == .connected)
        #expect(manager.sessions[mini.id] === miniSession)
        #expect(!logs[mini.id]!.all.contains("close"))

        windows[mini.id]?.close()
        #expect(manager.sessions.isEmpty)
        #expect(await waitUntil { logs[mini.id]!.all.contains("close") })
    }
}

// MARK: - Tab placement and ⌘1…⌘9

@MainActor
struct SessionTabPlacementTests {
    /// SwiftUI creates the windows of Connects made in one turn in another order: each tab goes before
    /// the first tab of a later Connect, so the bar reads in Connect order.
    @Test func tabsReadInConnectOrder() {
        #expect(SessionTabs.insertionIndex(order: 1, tabOrders: []) == 0)
        #expect(SessionTabs.insertionIndex(order: 1, tabOrders: [2]) == 0)
        #expect(SessionTabs.insertionIndex(order: 3, tabOrders: [1, 2]) == 2)
        #expect(SessionTabs.insertionIndex(order: 2, tabOrders: [1, 3]) == 1)
        // A tab the user dragged keeps its place; a newer Connect goes at the end.
        #expect(SessionTabs.insertionIndex(order: 4, tabOrders: [3, 1, 2]) == 3)
    }

    /// AppFlow: a new session joins the frontmost Session Window. Front to back: the Library, a
    /// minimised session window, a visible one, another visible one behind; else the last opened.
    @Test func hostIsTheFrontmostVisibleSessionWindowElseTheLastOpened() {
        let first = TabWindow.make("A"), second = TabWindow.make("B"), third = TabWindow.make("C")
        let new = TabWindow.make("D"), library = TabWindow.make("Library")
        let opened: [NSWindow] = [first, second, third, new]
        library.onScreen = true
        second.onScreen = true
        second.minimised = true
        first.onScreen = true
        third.onScreen = true
        new.onScreen = true
        let ordered: [NSWindow] = [new, library, second, first, third]
        #expect(SessionTabs.host(for: new, ordered: ordered, opened: []) == nil)
        #expect(SessionTabs.host(for: new, ordered: ordered, opened: opened) === first)
        // Nothing visible (all minimised, or on another Space): the session window opened last.
        [first, second, third].forEach { $0.onScreen = false }
        #expect(SessionTabs.host(for: new, ordered: ordered, opened: opened) === third)
        #expect(SessionTabs.host(for: new, ordered: [], opened: [first, new]) === first)
    }

    /// The last tab closed, then a Connect: the new session opens its own window, not a tab of the
    /// closed one (still alive until AppKit frees it).
    @Test func aClosedWindowHostsNoNewTab() {
        SessionTabs.resetForTesting()
        defer { SessionTabs.resetForTesting() }
        let closed = TabWindow.make("Mac mini"), new = TabWindow.make("NAS")
        SessionTabs.register(closed, order: 1)
        #expect(SessionTabs.host(for: new, ordered: [], opened: SessionTabs.openWindows) === closed)
        SessionTabs.forget(closed)
        #expect(SessionTabs.host(for: new, ordered: [], opened: SessionTabs.openWindows) == nil)
        #expect(!SessionTabs.openWindows.contains { $0 === closed })
    }

    /// The window closed before its deferred `adopt` ran (`forget` first): it is not registered again,
    /// so it can never host the next Connect's tab.
    @Test func adoptAfterTheCloseRegistersNothing() {
        SessionTabs.resetForTesting()
        defer { SessionTabs.resetForTesting() }
        let host = TabWindow.make("NAS"), window = TabWindow.make("Mac mini")
        SessionTabs.register(host, order: 1)
        SessionTabs.forget(window)
        SessionTabs.adopt(window, order: 2)
        SessionTabs.register(window, order: 2)
        #expect(SessionTabs.openWindows.count == 1 && SessionTabs.openWindows.first === host)
        #expect(window.tabbingMode == .automatic)   // not tabbed into the NAS's group either
    }

    /// The synchronous step, at the first attachment, before the deferred insertion: AppKit already
    /// treats the window as a session tab, so it is not shown as a standalone window first.
    @Test func prepareMakesItASessionTabAtOnce() {
        let window = TabWindow.make("Mac mini")
        SessionTabs.prepare(window)
        #expect(window.tabbingIdentifier == SessionTabs.tabbingIdentifier)
        #expect(window.tabbingMode == .preferred)
    }

    /// A window is tabbed on its first attachment only: when SwiftUI re-attaches the accessor (a tab the
    /// user moved to its own window), it is not put back into a group.
    @Test func aKnownWindowIsNotTabbedAgain() {
        SessionTabs.resetForTesting()
        defer { SessionTabs.resetForTesting() }
        let host = TabWindow.make("Mac mini"), moved = TabWindow.make("NAS")
        SessionTabs.register(host, order: 1)
        SessionTabs.register(moved, order: 2)   // attached before, then moved out by the user
        SessionTabs.adopt(moved, order: 2)
        #expect(moved.tabbingMode == .automatic)   // `adopt` returned before touching it
        #expect(host.tabGroup?.windows.contains { $0 === moved } != true)
        #expect(SessionTabs.openWindows.count == 2)
    }

    /// Without a tab bar (a single window), ⌘1 is that window and ⌘2 nothing.
    @Test func tabIndexOutsideTheBarSelectsNothing() {
        let only = TabWindow.make("A")
        #expect(SessionTabs.window(forTab: 0, key: only, opened: [only]) === only)
        #expect(SessionTabs.window(forTab: 1, key: only, opened: [only]) == nil)
        #expect(SessionTabs.window(forTab: -1, key: only, opened: [only]) == nil)
        #expect(SessionTabs.window(forTab: 0, key: nil, opened: []) == nil)
    }

    /// ⌘1…⌘9 typed into the view (captured or not) select a tab by key code, AZERTY included; the
    /// event still goes on to AppKit.
    @Test func commandDigitAsksForItsTab() throws {
        let window = TabWindow.make("A")
        let view = FramebufferView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.systemShortcuts.isTrusted = { false }
        view.systemShortcuts.requestTrust = {}
        var shortcuts: [LocalShortcut] = []
        view.onLocalShortcut = { shortcuts.append($0) }
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        window.key = true
        #expect(view.input.isCapturing)
        // AZERTY: the 2 key types "é" without Shift.
        let down = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "é", charactersIgnoringModifiers: "é", isARepeat: false, keyCode: 0x13))
        #expect(down.window === window)
        #expect(!view.handleMonitoredKey(down))   // left to AppKit (menus) as well
        #expect(shortcuts == [.switchTab(2)])
        view.tearDownInput()
        window.close()
    }
}

// MARK: - Capture, tap and clipboard follow the selected tab

@MainActor
struct SessionTabFocusTests {
    /// Two tabs, each with its view, fake tap and recorded output; the first is selected and captures
    /// with a key held.
    @MainActor
    final class Tab {
        let window: TabWindow
        let view = FramebufferView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var sent: [ClientMessage] = []
        var windowKey: [Bool] = []
        var taps: [FakeEventTap] = []

        init(_ title: String) {
            window = TabWindow.make(title)
            view.systemShortcuts.isTrusted = { true }
            view.systemShortcuts.requestTrust = {}
            view.systemShortcuts.trustNotificationCenter = NotificationCenter()
            view.systemShortcuts.makeTap = { [weak self] _ in
                let fake = FakeEventTap()
                self?.taps.append(fake)
                return fake
            }
            view.input.onInput = { [weak self] in self?.sent += $0 }
            view.onWindowKeyChange = { [weak self] in self?.windowKey.append($0) }
            window.contentView?.addSubview(view)
            window.makeFirstResponder(view)
        }

        var tapInstalled: Bool { view.systemShortcuts.isInstalled }
    }

    @Test func onlyTheSelectedTabCaptures() throws {
        let mini = Tab("Mac mini"), nas = Tab("NAS")
        defer {
            [mini, nas].forEach { $0.view.tearDownInput(); $0.window.close() }
        }
        mini.window.key = true
        #expect(mini.view.input.isCapturing && mini.tapInstalled && mini.windowKey.last == true)
        #expect(!nas.view.input.isCapturing && !nas.tapInstalled && nas.windowKey.last != true)

        // ⌘ and A held on the Mac mini's remote.
        let cmd: CGEventFlags = [.maskCommand, CGEventFlags(rawValue: 0x08)]
        #expect(mini.view.input.handleKey(try SessionInputControllerTests.flags(0x37, cmd)))
        #expect(mini.view.input.handleKey(try SessionInputControllerTests.key(.keyDown, 0x00, "a", flags: [.command])))
        mini.sent = []

        // ⌘2: the NAS tab becomes the key window.
        mini.window.key = false
        nas.window.key = true
        #expect(mini.sent == [.keyEvent(down: false, key: 0x61), .keyEvent(down: false, key: Keysym.altL)])
        #expect(!mini.view.input.isCapturing && !mini.tapInstalled && mini.taps.first?.invalidated == true)
        #expect(mini.windowKey.last == false)
        #expect(nas.view.input.isCapturing && nas.tapInstalled && nas.windowKey.last == true)
        #expect(nas.sent.isEmpty)   // nothing pressed there by the switch

        // ⌘1: back.
        nas.window.key = false
        mini.window.key = true
        #expect(!nas.view.input.isCapturing && !nas.tapInstalled && nas.windowKey.last == false)
        #expect(mini.view.input.isCapturing && mini.tapInstalled)
    }

    /// The clipboard bridge of a session reads the pasteboard only while its tab's window is key.
    @Test func onlyTheSelectedTabPollsTheClipboard() {
        let pasteboard = InMemoryPasteboard()
        let mini = ClipboardBridge(pasteboard: pasteboard, isEnabled: true, pollInterval: nil)
        let nas = ClipboardBridge(pasteboard: pasteboard, isEnabled: true, pollInterval: nil)
        var sentMini: [String] = [], sentNAS: [String] = []
        mini.send = { sentMini.append($0) }
        nas.send = { sentNAS.append($0) }
        mini.sessionStarted()
        nas.sessionStarted()
        let tabMini = Tab("Mac mini"), tabNAS = Tab("NAS")
        defer { [tabMini, tabNAS].forEach { $0.view.tearDownInput(); $0.window.close() } }
        tabMini.view.onWindowKeyChange = { mini.windowKeyChanged($0) }
        tabNAS.view.onWindowKeyChange = { nas.windowKeyChanged($0) }

        tabMini.window.key = true
        pasteboard.content = .text("for the mini")
        mini.poll(); nas.poll()
        tabMini.window.key = false
        tabNAS.window.key = true
        pasteboard.content = .text("for the NAS")
        mini.poll(); nas.poll()
        #expect(sentMini == ["for the mini"])   // nothing copied while its tab was in the background
        // The pasteboard as it was when its tab became key, then the new copy; nothing before that.
        #expect(sentNAS == ["for the mini", "for the NAS"])
        #expect(!mini.isKey && nas.isKey)
    }
}

// MARK: - Background tabs do not draw

@MainActor
struct BackgroundTabDrawingTests {
    @Test func hiddenTabPausesTheDisplayLinkAndDrawsOnceShown() {
        let window = TabWindow.make("Mac mini")
        defer { window.close() }
        let view = FramebufferView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.systemShortcuts.isTrusted = { false }
        view.systemShortcuts.requestTrust = {}
        var visible = true
        view.isWindowVisible = { _ in visible }
        window.contentView?.addSubview(view)
        #expect(view.isDisplayLinkRunning)   // the first frame is owed

        visible = false   // another tab selected
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!view.isDisplayLinkRunning)
        view.updateLayer()   // what a new update does (renderer.onChange → contentChanged)
        #expect(!view.isDisplayLinkRunning)

        visible = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(view.isDisplayLinkRunning)
        view.tearDownInput()
    }
}
