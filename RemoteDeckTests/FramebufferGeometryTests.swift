import CoreGraphics
import RemoteDeckCore
import Testing
@testable import RemoteDeck

struct FramebufferGeometryTests {
    @Test func fitLetterboxesAWideFramebuffer() {
        let geometry = FramebufferGeometry(remoteWidth: 1920, remoteHeight: 1080, viewSize: CGSize(width: 960, height: 960.75),
                                           backingScale: 1, mode: .fit)
        #expect(geometry.scale == 0.5)
        // Height 540 pt, centered at 210.375 pt, snapped down to the device-pixel grid.
        #expect(geometry.contentRect == CGRect(x: 0, y: 210, width: 960, height: 540))
        #expect(!geometry.isPixelExact)
        #expect(geometry.remotePixel(forViewPoint: CGPoint(x: 480, y: 100)) == nil)        // top bar
        #expect(geometry.remotePixel(forViewPoint: CGPoint(x: 480, y: 900)) == nil)        // bottom bar
        #expect(geometry.remotePixel(forViewPoint: CGPoint(x: 0, y: 210))! == (0, 0))     // top-left
        #expect(geometry.remotePixel(forViewPoint: CGPoint(x: 959.9, y: 749.9))! == (1919, 1079))
    }

    @Test func fitPillarboxesATallFramebuffer() {
        let geometry = FramebufferGeometry(remoteWidth: 1000, remoteHeight: 2400, viewSize: CGSize(width: 800, height: 600),
                                           backingScale: 1, mode: .fit)
        #expect(geometry.scale == 0.25)
        #expect(geometry.contentRect == CGRect(x: 275, y: 0, width: 250, height: 600))
        #expect(geometry.remotePixel(forViewPoint: CGPoint(x: 274.9, y: 300)) == nil)
        #expect(geometry.remotePixel(forViewPoint: CGPoint(x: 524.9, y: 599.9))! == (999, 2399))
        #expect(geometry.remotePixel(forViewPoint: CGPoint(x: 525, y: 300)) == nil)
    }

    @Test func fitScalesUpAndIsPixelExactAtOneToOne() {
        let up = FramebufferGeometry(remoteWidth: 640, remoteHeight: 400, viewSize: CGSize(width: 1280, height: 800),
                                     backingScale: 1, mode: .fit)
        #expect(up.scale == 2)
        #expect(up.contentRect == CGRect(x: 0, y: 0, width: 1280, height: 800))
        // A 2880 × 1800 framebuffer in a 1440 × 900 pt Retina view: one texel per device pixel.
        let exact = FramebufferGeometry(remoteWidth: 2880, remoteHeight: 1800, viewSize: CGSize(width: 1440, height: 900),
                                        backingScale: 2, mode: .fit)
        #expect(exact.isPixelExact)
    }

    @Test func actualSizeIsOneRemotePixelPerDevicePixelAndCentered() {
        let geometry = FramebufferGeometry(remoteWidth: 37, remoteHeight: 23, viewSize: CGSize(width: 30, height: 20),
                                           backingScale: 2, mode: .actual)
        #expect(geometry.scale == 0.5)
        #expect(geometry.isPixelExact)
        // (30 − 18.5) / 2 = 5.75 pt → 5.5 pt; (20 − 11.5) / 2 = 4.25 pt → 4 pt.
        #expect(geometry.contentRect == CGRect(x: 5.5, y: 4, width: 18.5, height: 11.5))
        #expect(geometry.remotePixel(forViewPoint: CGPoint(x: 5.5, y: 4))! == (0, 0))
        #expect(geometry.remotePixel(forViewPoint: CGPoint(x: 5.4, y: 4)) == nil)
        #expect(geometry.remotePixel(forViewPoint: CGPoint(x: 23.9, y: 15.4))! == (36, 22))
    }

    @Test func actualSizeClipsAndClampsTheScrollOffset() {
        let view = CGSize(width: 800, height: 600)
        let overscrolled = FramebufferGeometry(remoteWidth: 1920, remoteHeight: 1080, viewSize: view, backingScale: 1,
                                               mode: .actual, scrollOffset: CGPoint(x: 5000, y: -10))
        #expect(overscrolled.contentRect == CGRect(x: -1120, y: 0, width: 1920, height: 1080))
        let scrolled = FramebufferGeometry(remoteWidth: 1920, remoteHeight: 1080, viewSize: view, backingScale: 1,
                                           mode: .actual, scrollOffset: CGPoint(x: 100.7, y: 50))
        #expect(scrolled.contentRect.origin == CGPoint(x: -100, y: -50))
        #expect(scrolled.remotePixel(forViewPoint: .zero)! == (100, 50))
        // Narrow axis centered, wide axis clipped.
        let mixed = FramebufferGeometry(remoteWidth: 400, remoteHeight: 1200, viewSize: view, backingScale: 1,
                                        mode: .actual, scrollOffset: CGPoint(x: 30, y: 30))
        #expect(mixed.contentRect.origin == CGPoint(x: 200, y: -30))
    }

    @Test(arguments: [
        (1366, 768, CGSize(width: 1000, height: 700), CGFloat(2), ScalingMode.fit),
        (1366, 768, CGSize(width: 1000, height: 700), CGFloat(1), ScalingMode.actual),
        (2560, 1440, CGSize(width: 733, height: 511), CGFloat(2), ScalingMode.fit),
        (2560, 1440, CGSize(width: 733, height: 511), CGFloat(2), ScalingMode.actual),
        (1024, 768, CGSize(width: 1503, height: 997), CGFloat(1.5), ScalingMode.fit),
    ])
    func viewPointAndRemotePixelRoundTrip(width: Int, height: Int, view: CGSize, backingScale: CGFloat,
                                          mode: ScalingMode) {
        let geometry = FramebufferGeometry(remoteWidth: width, remoteHeight: height, viewSize: view,
                                           backingScale: backingScale, mode: mode, scrollOffset: CGPoint(x: 77, y: 33))
        for x in stride(from: 0, to: width, by: 37) {
            for y in stride(from: 0, to: height, by: 29) {
                // The center of a pixel maps back to that pixel; fractional positions round-trip too.
                let center = geometry.viewPoint(forRemotePoint: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
                #expect(geometry.remotePixel(forViewPoint: center).map { [$0.x, $0.y] } == [x, y])
                let remote = geometry.remotePoint(forViewPoint: geometry.viewPoint(forRemotePoint: CGPoint(x: x, y: y)))
                #expect(abs(remote.x - CGFloat(x)) < 1e-9 && abs(remote.y - CGFloat(y)) < 1e-9)
            }
        }
    }

    @Test func emptyViewMapsNothing() {
        let geometry = FramebufferGeometry(remoteWidth: 1920, remoteHeight: 1080, viewSize: .zero, backingScale: 2, mode: .fit)
        #expect(geometry.scale == 0)
        #expect(geometry.remotePixel(forViewPoint: .zero) == nil)
    }
}
