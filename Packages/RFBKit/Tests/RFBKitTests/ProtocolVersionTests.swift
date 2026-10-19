import Foundation
import Testing
@testable import RFBKit

struct ProtocolVersionTests {
    @Test func parsesStandardBanner() {
        #expect(ProtocolVersion(banner: Data("RFB 003.008\n".utf8)) == .v3_8)
    }

    @Test func rejectsMalformedBanners() {
        #expect(ProtocolVersion(banner: Data("RFB 3.8\n".utf8)) == nil)
        #expect(ProtocolVersion(banner: Data("SSH-2.0-OpenS".utf8)) == nil)
        #expect(ProtocolVersion(banner: Data("RFB 003.008 ".utf8)) == nil)
    }

    @Test func roundTripsBanner() {
        #expect(ProtocolVersion.v3_7.banner == Data("RFB 003.007\n".utf8))
    }

    @Test func negotiatesAppleMinorDownTo38() {
        let apple = ProtocolVersion(banner: Data("RFB 003.889\n".utf8))
        #expect(apple?.negotiated() == .v3_8)
    }

    @Test func negotiatesLegacyVersions() {
        #expect(ProtocolVersion(major: 3, minor: 5).negotiated() == .v3_3)
        #expect(ProtocolVersion(major: 4, minor: 0).negotiated() == nil)
    }
}
