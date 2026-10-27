import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import HeroPage

/// The banner contract (#1752), the avatar's (#1750) at a banner's size: a
/// picture in memory in the configure pass; else nothing, then the skeleton
/// after `skeletonDelay`, then the picture; a failure leaves the neutral
/// backdrop with no bone; one bone for the redaction and the load.
@MainActor
struct HeroBannerContractTests {
    /// A fetch that never answers in a test's time.
    private struct HangingFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data {
            try await Task.sleep(for: .seconds(60))
            return Data()
        }
    }

    /// A fetch that fails at once (no decodable bytes).
    private struct BrokenFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// A clock a test steps by hand.
    @MainActor
    final class ManualClock {
        var now: TimeInterval = 0
        private var pending: [(at: TimeInterval, work: @MainActor () -> Void)] = []
        var clock: LoadingLadder.Clock {
            LoadingLadder.Clock(now: { [weak self] in self?.now ?? 0 }, after: { [weak self] delay, work in
                guard let self else { return }
                pending.append((now + delay, work))
            })
        }
        func advance(_ seconds: TimeInterval) {
            now += seconds
            while let index = pending.indices.filter({ pending[$0].at <= now }).min(by: { pending[$0].at < pending[$1].at }) {
                pending.remove(at: index).work()
            }
        }
    }

    private func solid() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
    }

    @Test func aColdPictureShowsNothingThenTheSkeleton() throws {
        let time = ManualClock()
        let banner = HeroBannerView(imagePipeline: ImagePipeline(fetcher: HangingFetcher()), clock: time.clock)
        banner.setImageURL(try #require(URL(string: "mock://banner/cold")))
        #expect(!banner.debugShowsBone, "a bone for a load that may land at once")
        time.advance(0.15)
        #expect(banner.debugShowsBone)
        #expect(banner.ladder.rung == .skeleton)
        #expect(!banner.isPictureSettled)
    }

    @Test func aWarmPictureDrawsInTheConfigurePass() throws {
        let pipeline = ImagePipeline(fetcher: HangingFetcher())
        let url = try #require(URL(string: "mock://banner/warm"))
        pipeline.store(solid(), for: url, size: .full)
        let time = ManualClock()
        let banner = HeroBannerView(imagePipeline: pipeline, clock: time.clock)
        banner.setImageURL(url)
        #expect(banner.debugHasPicture)
        #expect(banner.ladder.rung == .content)
        #expect(banner.ladder.transitions.last?.1 == LoadingLadder.Transition.none)
        time.advance(1)
        #expect(!banner.debugShowsBone, "a bone for a picture already there")
        #expect(banner.isPictureSettled)
    }

    @Test func aFailureLeavesTheBackdropWithNoBone() async throws {
        let time = ManualClock()
        let banner = HeroBannerView(imagePipeline: ImagePipeline(fetcher: BrokenFetcher()), clock: time.clock)
        banner.setImageURL(try #require(URL(string: "mock://banner/broken")))
        for _ in 0..<200 where !banner.isPictureSettled { try? await Task.sleep(for: .milliseconds(5)) }
        time.advance(1)
        #expect(banner.isPictureSettled)
        #expect(!banner.debugHasPicture)
        #expect(!banner.debugShowsBone)
        #expect(banner.ladder.hasFailed)
        // The media ground (#1771): the bone's own grey, loading or failed.
        #expect(banner.backgroundColor == Surface.mediaGround)
    }

    @Test func noBannerShowsNoBoneEver() {
        let time = ManualClock()
        let banner = HeroBannerView(imagePipeline: ImagePipeline(fetcher: HangingFetcher()), clock: time.clock)
        banner.setImageURL(nil)
        time.advance(1)
        #expect(!banner.debugShowsBone)
        #expect(banner.isPictureSettled)
    }

    /// ⚠️ ONE BONE: the profile's redaction hands over to the picture's load
    /// without the bone leaving and coming back.
    @Test func theRedactionBoneIsTheLoadsBone() throws {
        let time = ManualClock()
        let banner = HeroBannerView(imagePipeline: ImagePipeline(fetcher: HangingFetcher()), clock: time.clock)
        banner.setRedacted(true)
        #expect(banner.debugShowsBone)
        // The profile lands: its banner URL, then the reveal.
        banner.setImageURL(try #require(URL(string: "mock://banner/after-redaction")))
        #expect(banner.debugShowsBone, "the bone left between the redaction and the load")
        banner.setRedacted(false)
        #expect(banner.debugShowsBone, "the reveal took the load's bone away")
        #expect(banner.ladder.rung == .skeleton)
    }

    /// ⚠️ ONE LOOK WHILE THERE IS NO PICTURE: a flat grey, no ramp, no
    /// scrim — a black ramp over the bone read grey on the tall profile band
    /// and black on the short profile card (the owner, 2026-10-27). The
    /// ramp comes with the picture.
    @Test func aBannerWithoutAPictureIsFlat() throws {
        let time = ManualClock()
        let cold = HeroBannerView(imagePipeline: ImagePipeline(fetcher: HangingFetcher()), clock: time.clock)
        cold.setFormat(.band)
        cold.setImageURL(try #require(URL(string: "mock://banner/flat")))
        time.advance(0.15)
        #expect(!cold.debugIsDressed)
        #expect(!cold.hasPicture)

        let pipeline = ImagePipeline(fetcher: HangingFetcher())
        let url = try #require(URL(string: "mock://banner/dressed"))
        pipeline.store(solid(), for: url, size: .full)
        let warm = HeroBannerView(imagePipeline: pipeline, clock: time.clock)
        warm.setFormat(.band)
        warm.setImageURL(url)
        #expect(warm.debugIsDressed)
        #expect(warm.hasPicture)
    }

    /// A banner that may come (a place whose posts are loading): its
    /// skeleton, and the URL that answers loads under the same bone.
    @Test func anAwaitedBannerHoldsTheSkeletonUntilItsURL() throws {
        let time = ManualClock()
        let banner = HeroBannerView(imagePipeline: ImagePipeline(fetcher: HangingFetcher()), clock: time.clock)
        banner.awaitImage()
        time.advance(0.15)
        #expect(banner.debugShowsBone)
        banner.setImageURL(try #require(URL(string: "mock://banner/top-post")))
        #expect(banner.debugShowsBone, "the answer's load restarted the bone")
        // None after all (a text-only top post): the bone goes.
        let none = HeroBannerView(imagePipeline: ImagePipeline(fetcher: HangingFetcher()), clock: time.clock)
        none.awaitImage()
        time.advance(0.15)
        none.setImageURL(nil)
        time.advance(1)
        #expect(!none.debugShowsBone)
    }
}
