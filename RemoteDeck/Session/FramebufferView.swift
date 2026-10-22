import AppKit
import QuartzCore
import RemoteDeckCore
import RFBKit
import SwiftUI

/// The remote screen: an NSView backed by a `CAMetalLayer`, drawn by the view's display link.
///
/// The display link runs only while there is something to draw (new pixels, a resize, a scaling,
/// scroll or backing-scale change) and pauses itself after the frame, so a static desktop costs no
/// frame and no wake-up at all. The coordinate system is flipped (origin top-left) to match the
/// framebuffer and `FramebufferGeometry`.
///
/// Input: keys, clicks, drags, moves and scrolls are handed to `input` (`SessionInputController`),
/// which captures the keyboard while the view is focused. While capturing, `systemShortcuts` (an event
/// tap, Accessibility permission) also takes the combos macOS keeps for itself. The local arrow cursor
/// stays visible (the remote cursor shape is not drawn yet).
final class FramebufferView: NSView {
    let input = SessionInputController()
    let systemShortcuts = SystemShortcutTap()

    /// Called when the keyboard capture starts or stops (for the toolbar's "Keyboard captured" pill).
    var onCaptureChange: ((Bool) -> Void)?

    /// `false` while the system-shortcut tap cannot run (no Accessibility permission): T3.5's toolbar
    /// shows "System shortcuts need Accessibility access — Open Settings"
    /// (`SystemShortcutTap.openAccessibilitySettings()`).
    var systemShortcutsAvailable: Bool { systemShortcuts.systemShortcutsAvailable }

    var renderer: FramebufferRenderer? {
        didSet {
            guard renderer !== oldValue else { return }
            oldValue?.onChange = nil
            renderer?.onChange = { [weak self] in self?.redraw.contentChanged() }
            metalLayer.device = renderer?.device
            redraw.contentChanged()
        }
    }

    var scalingMode: ScalingMode {
        get { redraw.scalingMode }
        set { redraw.setScalingMode(newValue) }
    }

    /// Top-left of the visible part in `actual` mode when the framebuffer is larger than the view
    /// (points, clamped by `FramebufferGeometry`).
    var scrollOffset: CGPoint {
        get { redraw.scrollOffset }
        set { redraw.setScrollOffset(newValue) }
    }

    /// Frames drawn, for the debug counters.
    private(set) var drawCount = 0

    private let metalLayer = CAMetalLayer()
    private var displayLink: CADisplayLink?
    private var keyMonitor: Any?
    private var windowObservers: [any NSObjectProtocol] = []
    private var redraw = FramebufferRedrawState() {
        didSet { displayLink?.isPaused = redraw.isPaused }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        metalLayer.pixelFormat = FramebufferRenderer.drawableFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = CGColor.black
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // During a live resize, keep the last frame unscaled (black around it) until the next draw.
        metalLayer.contentsGravity = .topLeft
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        input.onCaptureChange = { [weak self] capturing in
            self?.updateSystemShortcutTap()
            self?.onCaptureChange?(capturing)
        }
        systemShortcuts.onKey = { [weak self] key, down in self?.handleTappedKey(key, down: down) ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { metalLayer }

    /// AppKit asks for a redisplay (e.g. during a live resize): draw on the next display refresh.
    override func updateLayer() {
        redraw.contentChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        redraw.setBackingScale(scale)
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Invalidated when leaving the window: the link retains the view.
        displayLink?.invalidate()
        displayLink = nil
        updateInputObservers()
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        // Up to ProMotion's 120 Hz; the system clamps it to the display the window is on.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = redraw.isPaused
        link.add(to: .main, forMode: .common)
        displayLink = link
        viewDidChangeBackingProperties()
    }

    /// The current placement of the framebuffer, `nil` before its size is known. The view size is the
    /// drawable's (whole pixels) in points, so content edges land exactly on drawable pixels even when
    /// the bounds are fractional.
    var geometry: FramebufferGeometry? {
        guard let size = renderer?.framebufferSize else { return nil }
        let scale = redraw.backingScale
        let viewSize = CGSize(width: redraw.drawableSize.width / scale, height: redraw.drawableSize.height / scale)
        return FramebufferGeometry(remoteWidth: size.width, remoteHeight: size.height, viewSize: viewSize,
                                   backingScale: scale, mode: scalingMode, scrollOffset: scrollOffset)
    }

    private func updateDrawableSize() {
        let scale = redraw.backingScale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if size != metalLayer.drawableSize { metalLayer.drawableSize = size }
        redraw.setDrawableSize(size)
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        // Setting `redraw` pauses the link once no frame is owed.
        if redraw.needsRedraw {
            let drawn = draw()   // reads `redraw` (geometry): not inside the mutating call
            redraw.tick(drawSucceeded: drawn)
        } else {
            link.isPaused = true
        }
    }

    /// `false` only when a frame could not be produced (no drawable): the next tick retries. Nothing to
    /// draw yet (no renderer, empty view) counts as done; whatever changes that owes a new frame.
    private func draw() -> Bool {
        guard let renderer, metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0 else { return true }
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = renderer.render(to: drawable.texture, geometry: geometry) else { return false }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        drawCount += 1
        return true
    }
}

// MARK: - Input

extension FramebufferView {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        input.setFocus(window?.isKeyWindow ?? false)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        input.setFocus(false)
        return true
    }

    /// While capturing, key events never get here (the local monitor takes them). With the keyboard
    /// released they do; dropping them avoids a beep per key. Menu shortcuts still work: AppKit
    /// offers them to `performKeyEquivalent` and the menus first.
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { tearDownInput() }
    }

    /// Removes the key monitor, the system-shortcut tap and the window observers, and releases
    /// everything held on the remote. Runs when the view leaves its window and when SwiftUI dismantles
    /// it, so a closed session leaves no monitor or tap behind.
    func tearDownInput() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        input.setFocus(false)
        systemShortcuts.tearDown()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        // A click takes the keyboard back (after ⌃⌥⌘R or when another view had focus).
        input.requestCapture()
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        forwardPointer(event)
    }

    override func rightMouseDown(with event: NSEvent) { forwardPointer(event) }
    override func otherMouseDown(with event: NSEvent) { forwardPointer(event) }
    override func mouseUp(with event: NSEvent) { forwardPointer(event) }
    override func rightMouseUp(with event: NSEvent) { forwardPointer(event) }
    override func otherMouseUp(with event: NSEvent) { forwardPointer(event) }
    override func mouseMoved(with event: NSEvent) { forwardPointer(event) }
    override func mouseDragged(with event: NSEvent) { forwardPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { forwardPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { forwardPointer(event) }
    override func scrollWheel(with event: NSEvent) { forwardPointer(event) }

    private func forwardPointer(_ event: NSEvent) {
        input.handlePointer(event, at: convert(event.locationInWindow, from: nil), geometry: geometry)
    }

    /// Installs, for the current window, the key monitor and the key-window observers.
    fileprivate func updateInputObservers() {
        tearDownInput()
        guard let window else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleMonitoredKey(event) ?? false }
            return consumed ? nil : event
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.updateFocus() }
            })
        }
        updateFocus()
    }

    private func updateFocus() {
        input.setFocus(window?.isKeyWindow == true && window?.firstResponder === self)
        updateSystemShortcutTap()
    }

    /// The tap runs only while capturing in the key window; removed at once otherwise.
    private func updateSystemShortcutTap() {
        systemShortcuts.update(capturing: input.isCapturing, windowKey: window?.isKeyWindow == true)
    }

    /// A key event from the system-shortcut tap (any app's, but the tap only runs while this view's
    /// window is key and captures). `true` swallows it.
    private func handleTappedKey(_ key: KeyInput, down: Bool) -> Bool {
        guard let window, window.isKeyWindow, window.firstResponder === self else { return false }
        return input.handleSystemKey(key, down: down)
    }

    /// Only events for this view's key window while it is first responder; the rest go on as usual.
    private func handleMonitoredKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow, window.firstResponder === self else {
            return false
        }
        return input.handleKey(event)
    }
}

/// SwiftUI wrapper for `FramebufferView`.
struct FramebufferViewRepresentable: NSViewRepresentable {
    let renderer: FramebufferRenderer?
    var scalingMode: ScalingMode
    var modifierProfile: ModifierProfile = .appleRemoteDesktop
    /// Receives the input messages, in order (e.g. `InputSender.enqueue`).
    var onInput: (([ClientMessage]) -> Void)?
    /// Called once with the created view (e.g. to read its counters).
    var onCreate: ((FramebufferView) -> Void)?

    func makeNSView(context: Context) -> FramebufferView {
        let view = FramebufferView(frame: .zero)
        updateNSView(view, context: context)
        onCreate?(view)
        return view
    }

    static func dismantleNSView(_ view: FramebufferView, coordinator: ()) {
        view.tearDownInput()
    }

    func updateNSView(_ view: FramebufferView, context: Context) {
        view.renderer = renderer
        view.scalingMode = scalingMode
        view.input.profile = modifierProfile
        view.input.onInput = onInput
    }
}
