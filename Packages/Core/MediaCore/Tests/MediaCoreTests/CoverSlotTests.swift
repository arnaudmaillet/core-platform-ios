import Testing
import UIKit
@testable import MediaCore

/// A hero source's cover on the ladder (#1088).
@MainActor
struct CoverSlotTests {
    private func makePipeline() -> ImagePipeline { ImagePipeline(fetcher: PlaceholderImageFetcher()) }

    private func solid(_ color: UIColor = .systemTeal) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// A warm cover is drawn in the configure pass and is its poster at once.
    @Test func aWarmCoverDrawsAtOnce() throws {
        let pipeline = makePipeline()
        let url = try #require(URL(string: "mock://slot/warm"))
        pipeline.store(solid(), for: url, size: .full)
        let slot = CoverSlot(view: UIImageView(), size: .full)
        var posters = 0, loaded = 0
        slot.onChange = { _ in posters += 1 }
        slot.onLoaded = { loaded += 1 }
        slot.load(url, pipeline: pipeline, item: "p1")
        #expect(slot.image != nil)
        #expect(posters == 1 && loaded == 0)
    }

    /// ⚠️ The view is never hidden nor faded (hooks 1 and 2): a load in
    /// flight, a late landing and a reset leave its visibility alone.
    @Test func theViewsVisibilityIsNeverTouched() async throws {
        let view = UIImageView()
        let slot = CoverSlot(view: view, size: .full)
        var loaded = 0
        slot.onLoaded = { loaded += 1 }
        slot.load(try #require(URL(string: "mock://slot/late")), pipeline: makePipeline(), item: "p1")
        #expect(!view.isHidden && view.alpha == 1)
        for _ in 0..<200 where loaded == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(loaded == 1 && slot.image != nil)
        #expect(!view.isHidden && view.alpha == 1)
        slot.reset()
        #expect(!view.isHidden && view.alpha == 1 && slot.image == nil)
    }

    /// The parked frame wins over a thumbnail landing after it (hook 7), and
    /// a reconfigure of the same post keeps it (hook 8).
    @Test func aParkedFrameOutranksALateThumbnailAndSurvivesAReconfigure() async throws {
        let url = try #require(URL(string: "mock://slot/parked"))
        let pipeline = makePipeline()
        let slot = CoverSlot(view: UIImageView(), size: .full)
        slot.load(url, pipeline: pipeline, item: "p1")
        let parked = solid(.systemOrange)
        slot.showParked(parked)
        for _ in 0..<200 where slot.isLoading { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(slot.image === parked)
        slot.load(url, pipeline: pipeline, item: "p1")
        #expect(slot.image === parked, "a reconfigure dropped the parked frame")
    }

    /// What the host derives from the picture (a page's framing) runs with
    /// every picture it draws: warm, parked, or handed in.
    @Test func whatTheHostDerivesRunsWithEveryPicture() throws {
        let pipeline = makePipeline()
        let url = try #require(URL(string: "mock://slot/framed"))
        pipeline.store(solid(), for: url, size: .full)
        let slot = CoverSlot(view: UIImageView(), size: .full, dissolving: UIView())
        var derived: [UIImage] = []
        slot.alongside = { derived.append($0) }
        slot.load(url, pipeline: pipeline, item: "p1")
        let parked = solid(.systemOrange)
        slot.showParked(parked)
        #expect(derived.count == 2)
        #expect(derived.last === parked)
    }

    /// A new post cuts: the old cover goes, and its late answer lands nowhere.
    @Test func aNewPostNeverShowsThePreviousCover() async throws {
        let pipeline = makePipeline()
        let warm = try #require(URL(string: "mock://slot/a"))
        pipeline.store(solid(), for: warm, size: .full)
        let slot = CoverSlot(view: UIImageView(), size: .full)
        slot.load(warm, pipeline: pipeline, item: "a")
        slot.load(try #require(URL(string: "mock://slot/b")), pipeline: pipeline, item: "b")
        #expect(slot.image == nil, "the previous post's cover stayed")
        slot.reset()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(slot.image == nil, "a late cover landed on a reset slot")
    }
}
