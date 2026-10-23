import CoreGraphics
import Testing
import UIKit
@testable import HeroPage

/// Where a banner card cuts a picture taller than itself (the owner,
/// 2026-10-15): by its ratio — the centre for a square, a third of the way
/// down for a 9:16 portrait — or by its faces, always inside the picture.
struct BannerFocalCropTests {
    @Test func theFocusRisesWithThePicturesHeight() {
        #expect(BannerFocalCrop.focusY(aspect: 1.5) == 0.5)
        #expect(BannerFocalCrop.focusY(aspect: 1) == 0.5)
        #expect(abs(BannerFocalCrop.focusY(aspect: 9.0 / 16.0) - 1.0 / 3.0) < 0.001)
        #expect(abs(BannerFocalCrop.focusY(aspect: 0.3) - 1.0 / 3.0) < 0.001, "taller than 9:16 holds a third")
        let between = BannerFocalCrop.focusY(aspect: 0.75)
        #expect(between < 0.5 && between > 1.0 / 3.0)
    }

    @Test func theCutIsCentredOnTheFocusAndStaysInside() {
        let portrait = CGSize(width: 900, height: 1600)
        let cut = BannerFocalCrop.cropRect(imageSize: portrait, targetAspect: 1.3, focusY: 1.0 / 3.0)
        #expect(abs(cut.width / cut.height - 1.3) < 0.01)
        #expect(abs(cut.midY - 1600.0 / 3.0) < 1)
        let top = BannerFocalCrop.cropRect(imageSize: portrait, targetAspect: 1.3, focusY: 0.02)
        #expect(top.minY == 0, "a face at the very top cut outside the picture")
        let bottom = BannerFocalCrop.cropRect(imageSize: portrait, targetAspect: 1.3, focusY: 0.99)
        #expect(abs(bottom.maxY - 1600) < 0.5)
    }

    /// The focus lands on the middle of what the card SHOWS — the picture's
    /// frame has the parallax reserve and the card's margin hidden above it
    /// — not the middle of the cut.
    @Test func theFocusLandsOnTheCardsShownMiddle() {
        let portrait = CGSize(width: 900, height: 1600)
        let cut = BannerFocalCrop.cropRect(imageSize: portrait, targetAspect: 1, focusY: 0.5, anchor: 0.6)
        #expect(abs((800 - cut.minY) / cut.height - 0.6) < 0.01)
        let (aspect, anchor) = HeroBannerView.pictureCut
        #expect(aspect > 0.5 && aspect < 1.3)
        #expect(anchor > 0.5, "the hidden reserve above should push the shown middle down")
    }

    /// A picture as wide as the card is not cut.
    @Test func aWidePictureIsNotCut() {
        let wide = CGSize(width: 1600, height: 900)
        #expect(BannerFocalCrop.cropRect(imageSize: wide, targetAspect: 1.3, focusY: 0.3) == CGRect(origin: .zero, size: wide))
        let image = UIGraphicsImageRenderer(size: wide).image { _ in }
        #expect(!BannerFocalCrop.needsCut(image))
    }

    @MainActor @Test func aPortraitImageIsCutToTheCard() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 160), format: format).image { _ in }
        #expect(BannerFocalCrop.needsCut(image))
        let cut = BannerFocalCrop.cropped(image, focusY: 1.0 / 3.0)
        #expect(abs(cut.size.width / cut.size.height - BannerFocalCrop.bandAspect) < 0.05)
    }
}
