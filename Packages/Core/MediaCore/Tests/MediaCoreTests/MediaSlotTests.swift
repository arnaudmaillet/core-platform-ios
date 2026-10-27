import Testing
import UIKit
@testable import MediaCore

/// The media slot (#1505): one picture's contract — its load, its skeleton,
/// its arrival — and the cover that wears it under every tile, card and page.
@MainActor
struct MediaSlotTests {
    private typealias ManualClock = LoadingLadderTests.ManualClock

    private func makePipeline() -> ImagePipeline { ImagePipeline(fetcher: PlaceholderImageFetcher()) }

    private func solid() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    // MARK: - The slot

    /// ⚠️ A bone already up stays up across a new item (a recycled cell
    /// configured for another post not in memory): no flash, no second delay.
    @Test func aBoneUpStaysUpAcrossANewItem() throws {
        let time = ManualClock()
        let bone = UIView()
        let slot = MediaSlot(size: .px256, bone: bone, clock: time.clock)
        slot.begin("a")
        slot.load(try #require(URL(string: "mock://slot/a")), using: makePipeline()) { _, _ in }
        time.advance(0.15)
        #expect(slot.showsBone)
        slot.begin("b")
        #expect(slot.showsBone, "the bone left between two posts and comes back 0.15 s later")
        slot.begin(nil)
        #expect(!slot.showsBone, "nothing is coming, yet the bone stayed")
    }

    /// A picture awaited (its URL still being looked up) holds the bone, and
    /// the next item answers it: the same token, the bone kept.
    @Test func anAwaitedPictureIsAnsweredOnTheSameItem() {
        let time = ManualClock()
        let slot = MediaSlot(size: .px256, bone: UIView(), clock: time.clock)
        slot.awaitPicture()
        let waiting = slot.token
        time.advance(0.15)
        #expect(slot.showsBone)
        #expect(slot.begin(URL(string: "mock://slot/answer")) == waiting)
        #expect(slot.showsBone)
        #expect(!slot.isAwaiting)
    }

    /// ⚠️ A view reset to no item shows its ground, never a bone that would
    /// shimmer for good.
    @Test func noItemNeverSchedulesABone() {
        let time = ManualClock()
        let ladder = LoadingLadder(clock: time.clock)
        let bone = UIView()
        ladder.setView(bone, for: .skeleton)
        ladder.begin(item: nil)
        time.advance(1)
        #expect(bone.isHidden)
        #expect(ladder.rung == nil)
    }

    /// ⚠️ A SMALLER DECODE STANDS IN (#1505): the page a flight lands on finds
    /// a grid tile's 512 px decode, not its own full one — told at once, so
    /// it draws it and no bone comes; the gate's `cachedCover` finds it too.
    @Test func aSmallerDecodeInMemoryStandsIn() throws {
        let pipeline = makePipeline()
        let url = try #require(URL(string: "mock://slot/stand-in"))
        let tile = solid()
        pipeline.store(tile, for: url, size: .px512)
        let slot = MediaSlot(size: .full, bone: UIView())
        slot.begin(url)
        var stoodIn: UIImage?
        slot.load(url, using: pipeline, standIn: { stoodIn = $0 }) { _, _ in }
        #expect(stoodIn === tile)
        #expect(pipeline.cachedCover(for: url) === tile)
    }

    // MARK: - The cover

    /// The bone lives IN the cover, at its back: over the cover's own fill
    /// (the card's grey, a video's dark), under its picture and whatever the
    /// host hangs in it.
    @Test func theCoversBoneSitsAtItsBack() {
        let view = UIImageView(frame: CGRect(x: 0, y: 0, width: 120, height: 160))
        let slot = CoverSlot(view: view, size: .px256)
        #expect(view.subviews.first === slot.bone)
        #expect(slot.bone.frame == view.bounds)
        #expect(slot.bone.isHidden, "a bone before anything is loading")
    }

    /// ⚠️ THE TILE CONTRACT (#1505): a cover not in memory shows nothing for
    /// `skeletonDelay`, then the bone, and the picture arrives over it with
    /// the dissolve — never the card's flat fill and a snap.
    @Test func aColdCoverShowsTheBoneThenDissolvesIn() async throws {
        let time = ManualClock()
        let view = UIImageView()
        let slot = CoverSlot(view: view, size: .px256, clock: time.clock)
        var loaded = 0
        slot.onLoaded = { loaded += 1 }
        slot.load(try #require(URL(string: "mock://cover/cold")), pipeline: makePipeline(), item: "p1")
        #expect(!slot.showsBone, "a bone for a load that may land at once")
        time.advance(0.15)
        #expect(slot.showsBone)
        #expect(slot.image == nil)
        for _ in 0..<400 where slot.image == nil {
            try? await Task.sleep(for: .milliseconds(5))
            time.advance(0.01)
        }
        #expect(slot.image != nil)
        #expect(time.now >= 0.45, "the bone left before its minimum")
        #expect(!slot.showsBone, "the bone stayed over the picture")
        #expect(slot.ladder.transitions.last?.0 == .preview)
        #expect(slot.ladder.transitions.last?.1 == .pictureArrives)
        #expect(loaded == 1)
        #expect(!view.isHidden && view.alpha == 1)
    }

    /// ⚠️ A cover fetched while the bone has its minimum still to run waits:
    /// a parked frame put meanwhile wins and the autoplay is still told the
    /// cover loaded; a seed handed in meanwhile does not replace it.
    @Test func aCoverWaitingOutTheBoneYieldsToParkedButNotToASeed() async throws {
        let time = ManualClock()
        let slot = CoverSlot(view: UIImageView(), size: .px256, clock: time.clock)
        var loaded = 0
        slot.onLoaded = { loaded += 1 }
        slot.load(try #require(URL(string: "mock://cover/waits")), pipeline: makePipeline(), item: "p1")
        time.advance(0.15)
        for _ in 0..<400 where !slot.debugHasPending { try? await Task.sleep(for: .milliseconds(5)) }
        try #require(slot.debugHasPending, "the fetch never answered")
        slot.apply(solid())
        #expect(slot.image == nil, "a seed jumped the fetched cover")
        let parked = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        slot.showParked(parked)
        #expect(slot.image === parked)
        #expect(loaded == 1, "the fetched cover's arrival was never told")
        time.advance(1)
        #expect(slot.image === parked, "the fetched cover landed over the parked frame")
        #expect(loaded == 1)
    }

    /// A cover in memory draws in the configure pass: no bone, ever.
    @Test func aWarmCoverNeverShowsTheBone() throws {
        let time = ManualClock()
        let pipeline = makePipeline()
        let url = try #require(URL(string: "mock://cover/warm"))
        pipeline.store(solid(), for: url, size: .px256)
        let slot = CoverSlot(view: UIImageView(), size: .px256, clock: time.clock)
        slot.load(url, pipeline: pipeline, item: "p1")
        #expect(slot.image != nil)
        time.advance(1)
        #expect(!slot.showsBone)
    }

    /// A cover that fails (or a post with none) leaves the host's fill, no
    /// bone; so does a reset host.
    @Test func aFailedOrResetCoverShowsNoBone() throws {
        let time = ManualClock()
        let slot = CoverSlot(view: UIImageView(), size: .px256, clock: time.clock)
        var failed = 0
        slot.onFailed = { failed += 1 }
        slot.load(try #require(URL(string: "mock://cover/broken")), pipeline: nil, item: "p1")
        time.advance(1)
        #expect(!slot.showsBone)
        #expect(failed == 1)

        slot.load(try #require(URL(string: "mock://cover/reset")), pipeline: makePipeline(), item: "p2")
        time.advance(0.15)
        #expect(slot.showsBone)
        slot.reset()
        time.advance(1)
        #expect(!slot.showsBone, "a reset host kept its bone")
    }
}
