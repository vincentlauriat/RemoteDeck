import AppKit
import SwiftUI

/// Session Tabs (PRD › Session Tabs, AppFlow › Navigation rules): every session is a native macOS
/// window tab of one Session Window.
///
/// SwiftUI has no tabbing API (the macOS SDK's SwiftUI interface has no `tabbing` symbol), so this is
/// an AppKit bridge. Each tab stays its own `NSWindow` (that is how AppKit tabs work), created by the
/// `WindowGroup(for: UUID.self)` scene: one window, one `SessionWindowView`, one `SessionModel` and
/// connection per tab. When a session window first gets its content it gets the shared
/// `tabbingIdentifier` and `tabbingMode = .preferred` at once (`prepare`), then, one main-queue turn
/// later, joins the group of the frontmost visible session window, else of the session window opened
/// last (`adopt`). The user can still move a tab to its own window or merge windows (Window menu): a
/// window is tabbed only on its first attachment, so a moved tab stays where the user put it, and the
/// next session joins the frontmost group.
@MainActor
enum SessionTabs {
    static let tabbingIdentifier = "fr.vincentlauriat.remotedeck.session"

    /// The session windows, in the order they got content (weak: a freed window drops out), each with
    /// the rank of its session's Connect (`SessionModel.openOrder`).
    private static var opened: [OpenedWindow] = []
    /// Windows that closed (`forget`): never registered or used as a host again, even if AppKit has not
    /// freed them yet or an `adopt` scheduled before the close runs after it.
    private static var closed: [WeakWindow] = []

    private struct OpenedWindow {
        weak var window: NSWindow?
        let order: Int
    }

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    /// Open session windows, in the order they got content.
    static var openWindows: [NSWindow] {
        opened.removeAll { $0.window == nil }
        return opened.compactMap(\.window)
    }

    /// Synchronous part, as soon as the window gets the session's content (before SwiftUI orders it on
    /// screen where possible), so AppKit treats it as a session tab from the start.
    static func prepare(_ window: NSWindow) {
        window.tabbingIdentifier = tabbingIdentifier
        window.tabbingMode = .preferred
    }

    /// Deferred part, one main-queue turn after `prepare` (SwiftUI has finished setting the window up):
    /// tab it with the others. `order` is the rank of the session's Connect: SwiftUI does not create
    /// the windows of several Connects in one turn in call order (the demo's three came up NAS, Studio,
    /// Mac mini for Mac mini, NAS, Studio), so the tab goes before the first tab of a later Connect, and
    /// the bar reads in Connect order. Only the first attachment of a window counts; a closed window is
    /// ignored (`forget` may run before this).
    static func adopt(_ window: NSWindow, order: Int) {
        guard !isClosed(window), !openWindows.contains(where: { $0 === window }) else { return }
        let host = host(for: window, ordered: NSApp.orderedWindows, opened: openWindows)
        register(window, order: order)
        prepare(window)
        guard let host else { return }
        if let group = host.tabGroup {
            let orders = group.windows.map { tab in opened.first { $0.window === tab }?.order ?? Int.min }
            group.insertWindow(window, at: insertionIndex(order: order, tabOrders: orders))
        } else {
            host.addTabbedWindow(window, ordered: .above)
        }
        select(window)
    }

    /// A session window is closing: it can no longer host a new tab, nor be registered again.
    static func forget(_ window: NSWindow) {
        opened.removeAll { $0.window == nil || $0.window === window }
        closed.removeAll { $0.window == nil }
        if !isClosed(window) { closed.append(WeakWindow(window: window)) }
    }

    private static func isClosed(_ window: NSWindow) -> Bool {
        closed.contains { $0.window === window }
    }

    /// Records `window` without tabbing it (`adopt`, tests); ignored once it closed.
    static func register(_ window: NSWindow, order: Int) {
        guard !isClosed(window), !opened.contains(where: { $0.window === window }) else { return }
        opened.append(OpenedWindow(window: window, order: order))
    }

    /// Forgets every window (tests only: the registry is process-wide).
    static func resetForTesting() {
        opened = []
        closed = []
    }

    /// Where a tab of Connect rank `order` goes in a bar whose tabs have `tabOrders`: before the first
    /// later one, else at the end (tabs the user dragged keep their place).
    static func insertionIndex(order: Int, tabOrders: [Int]) -> Int {
        tabOrders.firstIndex { $0 > order } ?? tabOrders.count
    }

    /// The window whose tab group `window` joins: the frontmost (`ordered`, front to back:
    /// `NSApp.orderedWindows`) visible, not minimised session window other than `window`, else the
    /// session window opened last; `nil` (stays on its own) when there is none, or when `window`
    /// already shares a group with another session window (AppKit's own automatic tabbing did it).
    static func host(for window: NSWindow, ordered: [NSWindow], opened: [NSWindow]) -> NSWindow? {
        let others = opened.filter { $0 !== window }
        if let group = window.tabGroup?.windows, group.contains(where: { $0 !== window && others.contains($0) }) {
            return nil
        }
        return frontmost(ordered: ordered, among: others) ?? others.last
    }

    /// The first of `ordered` that is one of `windows`, visible and not minimised.
    static func frontmost(ordered: [NSWindow], among windows: [NSWindow]) -> NSWindow? {
        ordered.first { candidate in
            candidate.isVisible && !candidate.isMiniaturized && windows.contains { $0 === candidate }
        }
    }

    /// Shows `window`'s tab and makes it key (Connect on a machine whose tab is open, ⌘1…⌘9).
    static func select(_ window: NSWindow) {
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// ⌘1…⌘9 (`index` 0…8): the tab at `index` in the key window's group if the key window is a session
    /// window, else in the frontmost session window's group, else the last opened one's.
    @discardableResult
    static func selectTab(at index: Int) -> Bool {
        let windows = openWindows
        let key = NSApp.keyWindow.flatMap { key in windows.first { $0 === key } }
            ?? frontmost(ordered: NSApp.orderedWindows, among: windows)
        guard let window = window(forTab: index, key: key, opened: windows) else { return false }
        select(window)
        return true
    }

    /// The window shown by tab `index` (0-based, in tab-bar order) in `key`'s group (`key` must be one
    /// of `opened`), else in the last opened window's; `nil` past the last tab.
    static func window(forTab index: Int, key: NSWindow?, opened: [NSWindow]) -> NSWindow? {
        guard index >= 0 else { return nil }
        let anchor = key.flatMap { key in opened.first { $0 === key } } ?? opened.last
        guard let anchor else { return nil }
        let tabs = anchor.tabGroup?.windows ?? [anchor]
        return index < tabs.count ? tabs[index] : nil
    }
}

/// Watches the window that hosts it, for the Session Window: `onAttach` each time it joins a window,
/// and `onClose` when the window it is in really closes (`NSWindow.willCloseNotification`: the close
/// button, ⌘W, the tab's close button, Disconnect/Cancel via `dismissWindow`).
///
/// This is the only close signal of a session. Switching tabs, minimising, entering or leaving full
/// screen, and moving or merging tabs between windows hide, move or re-order the same `NSWindow`
/// without closing it, so they never end a session (SwiftUI's `onDisappear`, the T3.5 signal, is not
/// tied to a close). Detached from its window (SwiftUI rebuilt the content), it stops observing it: a
/// later close of that window is reported by the observer that is in it then, not by this one.
final class SessionWindowObserver: NSView {
    var onAttach: ((NSWindow) -> Void)?
    var onClose: ((NSWindow) -> Void)?

    private weak var observedWindow: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?
    private var closed = false

    /// Observing a window's close (tests).
    var isObserving: Bool { closeObserver != nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== observedWindow, !closed else { return }
        stopObserving()
        guard let window else { return }
        observedWindow = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowWillClose() }
        }
        onAttach?(window)
    }

    private func stopObserving() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        observedWindow = nil
    }

    private func windowWillClose() {
        guard !closed, let window = observedWindow else { return }
        closed = true
        stopObserving()
        onClose?(window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// SwiftUI wrapper for `SessionWindowObserver`.
struct SessionWindowAccessor: NSViewRepresentable {
    var onAttach: (NSWindow) -> Void
    var onClose: (NSWindow) -> Void

    func makeNSView(context: Context) -> SessionWindowObserver {
        let view = SessionWindowObserver(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SessionWindowObserver, context: Context) {
        view.onAttach = onAttach
        view.onClose = onClose
    }
}

/// ⌘1…⌘9 (AppFlow › Navigation rules): Window › Session Tabs › Tab 1…9. While the keyboard is
/// captured, `SessionInputController` leaves exactly these combos to AppKit (`LocalShortcut`), so the
/// menu takes them in every state.
struct SessionTabCommands: Commands {
    let settings: AppSettings
    let sessions: SessionManager

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Menu(settings.t("menu_session_tabs")) {
                ForEach(1...9, id: \.self) { number in
                    Button(settings.t("menu_session_tab", number)) { SessionTabs.selectTab(at: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                        .disabled(sessions.sessions.count < number)
                }
            }
        }
    }
}
