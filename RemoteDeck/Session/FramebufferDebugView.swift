#if DEBUG
import Foundation
import Metal
import RemoteDeckCore
import RFBKit
import SwiftUI

/// Debug builds only: a window that renders a synthetic 1920 × 1080 desktop through the real
/// `SessionDisplayModel` → `FramebufferRenderer` → `FramebufferView` path, without a server.
/// Launch with `-FramebufferDebug static` (one full frame, then nothing) or `-FramebufferDebug stream`
/// (plus a 200 × 200 region repainted at 120 updates/s). Counters go to stderr once a second.
/// The stream's frames are computed up front and paced off the main actor, so the measured CPU is
/// the display path's, not the generator's.
///
/// Input (T3.3): keys, clicks and scrolls in the window are translated as for a session and logged to
/// stderr as RFB events instead of being sent. `-InputDebug x11` uses the X11 modifier profile
/// (⌘ = Super), anything else the Apple Remote Desktop one (⌘ = Alt).
enum FramebufferDebug {
    static var mode: String? { UserDefaults.standard.string(forKey: "FramebufferDebug") }
    static var modifierProfile: ModifierProfile {
        UserDefaults.standard.string(forKey: "InputDebug") == "x11" ? .x11 : .appleRemoteDesktop
    }

    /// One line per message, e.g. `input key down 0xffe9 Alt_L` or `input pointer mask=1 x=10 y=20`.
    static func log(_ messages: [ClientMessage]) {
        let lines = messages.map { message -> String in
            switch message {
            case .keyEvent(let down, let key):
                "input key \(down ? "down" : "up  ") 0x\(String(key, radix: 16)) \(keyName(key))"
            case .pointerEvent(let mask, let x, let y):
                "input pointer mask=\(mask) x=\(x) y=\(y)"
            default:
                "input \(message)"
            }
        }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static func keyName(_ key: UInt32) -> String {
        let names: [UInt32: String] = [
            Keysym.shiftL: "Shift_L", Keysym.shiftR: "Shift_R", Keysym.controlL: "Control_L",
            Keysym.controlR: "Control_R", Keysym.metaL: "Meta_L", Keysym.metaR: "Meta_R", Keysym.altL: "Alt_L",
            Keysym.altR: "Alt_R", Keysym.superL: "Super_L", Keysym.superR: "Super_R", Keysym.capsLock: "Caps_Lock",
            Keysym.return: "Return", Keysym.tab: "Tab", Keysym.escape: "Escape", Keysym.backSpace: "BackSpace",
            Keysym.delete: "Delete", Keysym.kpEnter: "KP_Enter",
        ]
        if let name = names[key] { return name }
        let code = key >= 0x0100_0000 ? key - 0x0100_0000 : key
        guard key < 0xFF00 || key >= 0x0100_0000, let scalar = Unicode.Scalar(code) else { return "" }
        return "'\(Character(scalar))'"
    }
}

struct FramebufferDebugView: View {
    @State private var model = Self.makeModel()
    @State private var scalingMode: ScalingMode = .fit
    @State private var view: FramebufferView?

    var body: some View {
        FramebufferViewRepresentable(renderer: model?.renderer, scalingMode: scalingMode,
                                     modifierProfile: FramebufferDebug.modifierProfile,
                                     onInput: FramebufferDebug.log) { created in
            Task { @MainActor in view = created }   // not during the view update
        }
            .frame(minWidth: 640, minHeight: 400)
            .toolbar {
                Picker("Scaling", selection: $scalingMode) {
                    Text("Fit").tag(ScalingMode.fit)
                    Text("Actual size").tag(ScalingMode.actual)
                }
                .pickerStyle(.segmented)
            }
            .task { await run() }
    }

    private static func makeModel() -> SessionDisplayModel? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? FramebufferRenderer(device: device) else { return nil }
        return SessionDisplayModel(renderer: renderer)
    }

    private func run() async {
        guard let model else { return }
        let width = 1920, height = 1080
        model.handle(.framebufferUpdate(FramebufferUpdate(
            width: width, height: height,
            regions: [.init(rect: RFBRect(x: 0, y: 0, width: width, height: height),
                            pixels: Self.testPattern(width: width, height: height))])))
        // Only the latest square is kept if the main actor falls behind: no backlog builds up.
        let (events, continuation) = AsyncThrowingStream.makeStream(of: RFBEvent.self, bufferingPolicy: .bufferingNewest(1))
        let stream = FramebufferDebug.mode == "stream"
        let producer = Task.detached {
            guard stream else { return }
            let region = RFBRect(x: (width - 200) / 2, y: (height - 200) / 2, width: 200, height: 200)
            let updates = (0..<60).map { tick in
                RFBEvent.framebufferUpdate(FramebufferUpdate(
                    width: width, height: height, regions: [.init(rect: region, pixels: Self.square(tick: tick))]))
            }
            let clock = ContinuousClock()
            let interval = Duration.nanoseconds(1_000_000_000 / 120)
            var deadline = clock.now
            var tick = 0
            while !Task.isCancelled {
                continuation.yield(updates[tick % updates.count])
                tick += 1
                // Paced on deadlines, not sleep durations, so the rate stays at 120/s; never catches up in bursts.
                deadline = max(deadline + interval, clock.now)
                try? await clock.sleep(until: deadline)
            }
        }
        let stats = Task {
            var last = (draws: 0, uploads: 0)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = (draws: view?.drawCount ?? 0, uploads: model.renderer.uploadCount)
                FileHandle.standardError.write(Data(
                    "framebuffer-debug draws/s=\(now.draws - last.draws) uploads/s=\(now.uploads - last.uploads) \(Self.cpuLine())\n".utf8))
                last = now
            }
        }
        try? await model.consume(events)
        producer.cancel()
        stats.cancel()
    }

    /// Process CPU time so far (user + system), to compute CPU % from deltas.
    private static func cpuLine() -> String {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return String(format: "cpu-time=%.3fs", seconds)
    }

    /// Color bars over a gradient, with a 1-pixel grid every 64 pixels (shows 1:1 vs scaled sampling).
    nonisolated static func testPattern(width: Int, height: Int) -> [UInt32] {
        let bars: [UInt32] = [0xFFC0_C0C0, 0xFFC0_C000, 0xFF00_C0C0, 0xFF00_C000, 0xFFC0_00C0, 0xFFC0_0000, 0xFF00_00C0]
        var pixels = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let pixel: UInt32
                if x % 64 == 0 || y % 64 == 0 {
                    pixel = 0xFFFF_FFFF
                } else if y < height / 2 {
                    pixel = bars[x * bars.count / width]
                } else {
                    let level = UInt32(x * 255 / width)
                    pixel = 0xFF00_0000 | level << 16 | level << 8 | UInt32(y * 255 / height)
                }
                pixels[y * width + x] = pixel
            }
        }
        return pixels
    }

    /// A 200 × 200 square of moving diagonal stripes whose color cycles with `tick`.
    nonisolated static func square(tick: Int) -> [UInt32] {
        var pixels = [UInt32](repeating: 0, count: 200 * 200)
        let hue = UInt32(tick * 3 % 256)
        for y in 0..<200 {
            for x in 0..<200 {
                let stripe = (x + y + tick * 2) % 40 < 20
                pixels[y * 200 + x] = stripe ? 0xFF00_0000 | hue << 16 | (255 - hue) << 8 | 0x40 : 0xFF20_2020
            }
        }
        return pixels
    }
}
#endif
