import Testing
import UIKit
import MediaCore
@testable import Maps

/// A marker's pictures on the media slot (#1505): the cover and a text
/// marker's author face show the bone while they are late — never the black
/// ground, never the glyph first — and a preview sheet's frame zero outranks
/// the wire's thumbnail still loading.
@MainActor
struct PinCardMediaSlotTests {
    private static let side: CGFloat = 56

    private func makeCard(_ face: PinCardView.Face) -> PinCardView {
        let card = PinCardView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        card.setFace(face)
        return card
    }

    private func solid(_ color: UIColor = .systemTeal) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private func art() -> AnimatedIconArt {
        .sheet(AnimatedIconSheet(sheet: solid(.systemPink), frameCount: 1, columns: 1, frameDuration: 0.1))
    }

    /// Lets the slot's skeleton delay run out on the real clock.
    private func waitForBone(_ shows: () -> Bool) async {
        for _ in 0..<100 where !shows() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// A cover not in memory shows the bone after the delay — not the card's
    /// black ground — and a reset marker shows none.
    @Test func aLateCoverWearsTheBone() async throws {
        let card = makeCard(.media)
        let pipeline = ImagePipeline(fetcher: SilentFetcher())
        card.coverSlot.load(try #require(URL(string: "mock://pin/late")), pipeline: pipeline, item: "p1")
        #expect(!card.coverSlot.showsBone, "a bone for a load that may land at once")
        await waitForBone { card.coverSlot.showsBone }
        #expect(card.coverSlot.showsBone)
        card.resetCover()
        #expect(!card.coverSlot.showsBone)
        #expect(card.imageView.image == nil)
    }

    /// A cover in memory is drawn in the configure pass: the marker arrives
    /// dressed, with no bone.
    @Test func aWarmCoverDrawsAtOnce() throws {
        let card = makeCard(.media)
        let pipeline = ImagePipeline(fetcher: SilentFetcher())
        let url = try #require(URL(string: "mock://pin/warm"))
        pipeline.store(solid(), for: url, size: .full)
        card.coverSlot.load(url, pipeline: pipeline, item: "p1")
        #expect(card.imageView.image != nil)
        #expect(!card.coverSlot.showsBone)
    }

    /// ⚠️ THE SHEET OUTRANKS THE WIRE: its frame zero, parked on the cover,
    /// takes the bone down and is never replaced by the thumbnail landing
    /// after it.
    @Test func aPreviewSheetsFrameZeroOutranksTheThumbnail() async throws {
        let card = makeCard(.media)
        let pipeline = ImagePipeline(fetcher: SilentFetcher())
        card.coverSlot.load(try #require(URL(string: "mock://pin/sheet")), pipeline: pipeline, item: "p1")
        await waitForBone { card.coverSlot.showsBone }
        card.setPreviewSheet((art(), 0))
        #expect(card.imageView.image != nil, "frame zero never reached the cover")
        #expect(!card.coverSlot.showsBone, "the bone stayed over the sheet's frame zero")
        #expect(card.coverSlot.ladder.previewSource == .parked)
    }

    /// The avatar contract on a text marker: an author WITH a face shows the
    /// round bone, never the glyph first; a face that fails falls back to the
    /// glyph.
    @Test func aTextMarkersFaceWearsTheBoneNeverTheGlyphFirst() async throws {
        let card = makeCard(.text)
        card.loadTextAvatar(try #require(URL(string: "mock://pin/face")), pipeline: ImagePipeline(fetcher: SilentFetcher()))
        #expect(card.debugTextFaceGlyph.isHidden, "the glyph stood in for a face that exists")
        await waitForBone { !card.debugTextFaceBone.isHidden }
        #expect(!card.debugTextFaceBone.isHidden)

        let failing = makeCard(.text)
        failing.loadTextAvatar(try #require(URL(string: "mock://pin/broken")), pipeline: nil)
        #expect(!failing.debugTextFaceGlyph.isHidden, "a failed face left the disc empty")
        #expect(failing.debugTextFaceBone.isHidden)

        card.setTextAvatar(nil)
        #expect(card.debugTextFaceBone.isHidden, "a reset marker kept its bone")
        #expect(!card.debugTextFaceGlyph.isHidden)
    }
}

/// Asked, and never answers — a picture genuinely outstanding.
private struct SilentFetcher: ImageFetching {
    func fetchImageData(for url: URL) async throws -> Data {
        try await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
        return Data()
    }
}
