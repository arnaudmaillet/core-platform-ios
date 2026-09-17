import CoreGraphics
import Lottie
import Testing
import UIKit
@testable import StickerKit

/// The twelve stickers moved here from Chat: they load from THIS package's
/// bundle, draw a first frame, and loop on screen.
@MainActor
struct StickerCatalogTests {
    @Test func everyStickerLoads() async throws {
        #expect(StickerCatalog.stickers.count == 12)
        #expect(Set(StickerCatalog.stickers.map(\.id)).count == 12)
        for sticker in StickerCatalog.stickers {
            let file = try #require(await StickerCatalog.file(for: sticker), "\(sticker.id) did not load")
            let animation = try #require(file.animations.first?.animation, "\(sticker.id) has no animation")
            #expect(animation.duration > 2, "\(sticker.id) lasts \(animation.duration)s")
        }
    }

    @Test func anIdentifierFindsItsSticker() {
        #expect(StickerCatalog.sticker(id: "Taxi")?.emoji == "🚕")
        #expect(StickerCatalog.sticker(id: "Nope") == nil)
    }

    /// The still Chat's strip shows at rest: real ink, drawn once, then handed
    /// back from the cache in the same turn.
    @Test func aFirstFrameHasInkAndIsCached() async throws {
        let sticker = try #require(StickerCatalog.sticker(id: "NoEntry"))
        let size = CGSize(width: 28, height: 28)
        var first: UIImage?
        StickerCatalog.firstFrame(for: sticker, size: size) { first = $0 }
        try await settle { first != nil }
        let image = try #require(first)
        let pixels = try #require(image.cgImage)
        #expect(TestPictures.inkedPixels(in: pixels) > pixels.width * pixels.height / 4)

        var again: UIImage?
        StickerCatalog.firstFrame(for: sticker, size: size) { again = $0 }
        #expect(again === image)
    }

    /// ⚠️ The load resets `loopMode` to the manifest's single pass; a loop set
    /// before it would play once and freeze.
    @Test func aLoopViewLoopsAfterItsLoad() async throws {
        let sticker = try #require(StickerCatalog.sticker(id: "Idea"))
        let view = StickerLoopView(sticker: sticker)
        view.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
        try await settle { view.isLooping }
        try #require(view.isLooping)
        #expect(view.player.animation != nil)
        #expect(view.player.loopMode == .loop)
        #expect(view.player.isAnimationPlaying)
        #expect(view.player.configuration.renderingEngine == .coreAnimation)
        #expect(!view.isUserInteractionEnabled)
    }
}
