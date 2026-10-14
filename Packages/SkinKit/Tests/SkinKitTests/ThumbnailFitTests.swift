import CoreGraphics
import Testing
@testable import SkinKit

struct ThumbnailFitTests {
    @Test func exactFitIsOneToOne() {
        let r = ThumbnailFit.fit(maximumSize: CGSize(width: 275, height: 116), minimumSize: .zero, scale: 1)
        #expect(r.renderScale == 1)
        #expect(r.contextSize == CGSize(width: 275, height: 116))
        #expect(r.imageRect.origin == .zero)
        #expect(!r.smooth)
    }

    @Test func retinaPicksLargestIntegerScale() {
        let r = ThumbnailFit.fit(maximumSize: CGSize(width: 512, height: 512), minimumSize: .zero, scale: 2)
        #expect(r.renderScale == 3)
        #expect(r.imageRect.size == CGSize(width: 412.5, height: 174))
        #expect(!r.smooth)
    }

    @Test func tinyIconDownscalesSmoothly() {
        let r = ThumbnailFit.fit(maximumSize: CGSize(width: 64, height: 64), minimumSize: .zero, scale: 1)
        #expect(r.renderScale == 1)
        #expect(r.imageRect.size == CGSize(width: 64, height: 27))
        #expect(r.smooth)
    }

    @Test func minimumSizePadsAndCentres() {
        let r = ThumbnailFit.fit(maximumSize: CGSize(width: 275, height: 116), minimumSize: CGSize(width: 275, height: 275), scale: 1)
        #expect(r.contextSize == CGSize(width: 275, height: 275))
        #expect(r.imageRect.minY == 79.5)
    }

    @Test func neverZero() {
        let r = ThumbnailFit.fit(maximumSize: CGSize(width: 1, height: 1), minimumSize: .zero, scale: 1)
        #expect(r.renderScale == 1)
        #expect(r.contextSize.width >= 1 && r.contextSize.height >= 1)
        #expect(!r.imageRect.origin.x.isNaN && !r.imageRect.size.width.isNaN)
    }
}
