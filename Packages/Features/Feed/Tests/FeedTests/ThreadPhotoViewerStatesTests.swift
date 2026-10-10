import MediaCore
import Synchronization
import Testing
import UIKit
@testable import Feed

/// The thread's full-screen photo in the charter's states (#831): the
/// cache's picture on the first layout, a bone while it loads, and a failed
/// state whose Try Again loads again.
@MainActor
struct ThreadPhotoViewerStatesTests {
    /// Fails the first `failures` fetches, then serves a small PNG.
    private final class FlakyFetcher: ImageFetching {
        private let remainingFailures: Mutex<Int>
        private let fetchCount = Mutex(0)

        init(failures: Int) {
            remainingFailures = Mutex(failures)
        }

        var fetches: Int { fetchCount.withLock { $0 } }

        func fetchImageData(for url: URL) async throws -> Data {
            fetchCount.withLock { $0 += 1 }
            let fails = remainingFailures.withLock { (remaining: inout Int) -> Bool in
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
            if fails { throw URLError(.notConnectedToInternet) }
            return Self.png
        }

        static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
    }

    private static let photoURL = URL(string: "https://cdn.example/thread/photo.jpg")!

    /// Looks, not wall-clock time: a budget of looks spends nothing while the
    /// process is not scheduled.
    @discardableResult
    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            await Task.yield()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func laidOut(_ viewer: ThreadPhotoViewerController) -> ThreadPhotoViewerController {
        viewer.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        viewer.view.layoutIfNeeded()
        return viewer
    }

    private func button(in view: UIView) -> UIButton? {
        if let button = view as? UIButton, !button.isHidden { return button }
        for subview in view.subviews {
            if let found = button(in: subview) { return found }
        }
        return nil
    }

    @Test func aPhotoTheCacheHoldsIsInTheViewersFirstLayout() {
        let fetcher = FlakyFetcher(failures: 0)
        let pipeline = ImagePipeline(fetcher: fetcher)
        let cached = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).image { _ in }
        pipeline.store(cached, for: Self.photoURL)

        let viewer = laidOut(ThreadPhotoViewerController(image: nil, url: Self.photoURL, pipeline: pipeline))

        #expect(viewer.phase == .content)
        #expect(viewer.debugImage === cached)
        #expect(viewer.debugShowsPlaceholder == false)
        #expect(viewer.debugFailedState == nil)
        #expect(fetcher.fetches == 0)
    }

    @Test func aPhotoStillOnItsWayShowsABoneThenThePicture() async {
        let pipeline = ImagePipeline(fetcher: FlakyFetcher(failures: 0))
        let viewer = laidOut(ThreadPhotoViewerController(
            image: nil, url: Self.photoURL, pipeline: pipeline, aspectRatio: 4.0 / 3.0
        ))

        #expect(viewer.phase == .loading)
        #expect(viewer.debugShowsPlaceholder)
        #expect(viewer.debugImage == nil)

        await settle { viewer.phase == .content }
        #expect(viewer.phase == .content)
        #expect(viewer.debugImage != nil)
    }

    @Test func aFailedLoadSaysSoAndTryAgainLoadsThePicture() async throws {
        let fetcher = FlakyFetcher(failures: 1)
        let pipeline = ImagePipeline(fetcher: fetcher)
        let viewer = laidOut(ThreadPhotoViewerController(image: nil, url: Self.photoURL, pipeline: pipeline))

        await settle { viewer.phase == .failed }
        #expect(viewer.phase == .failed)
        let failed = try #require(viewer.debugFailedState)
        failed.layoutIfNeeded()
        let tryAgain = try #require(button(in: failed))
        #expect(tryAgain.configuration?.title == "Try Again")
        #expect(viewer.debugImage == nil)

        tryAgain.sendActions(for: .primaryActionTriggered)
        #expect(viewer.phase == .loading)
        #expect(viewer.debugFailedState == nil)
        #expect(viewer.debugShowsPlaceholder)

        await settle { viewer.phase == .content }
        #expect(viewer.phase == .content)
        #expect(viewer.debugImage != nil)
        #expect(fetcher.fetches == 2)
    }

    @Test func aPhotoWithNoAddressFailsWithoutOfferingToTryAgain() {
        let viewer = laidOut(ThreadPhotoViewerController(image: nil, url: nil, pipeline: nil))

        #expect(viewer.phase == .failed)
        let failed = viewer.debugFailedState
        #expect(failed != nil)
        #expect(failed.flatMap { button(in: $0) } == nil)
    }

    @Test func theBoneStandsWhereTheFittedPhotoWill() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let landscape = ThreadPhotoViewerController.fittedRect(aspectRatio: 2, in: bounds)
        #expect(landscape.width == 390)
        #expect(landscape.height == 195)
        #expect(landscape.midY == bounds.midY)

        let tall = ThreadPhotoViewerController.fittedRect(aspectRatio: 0.25, in: bounds)
        #expect(tall.height == 844)
        #expect(tall.width == 211)

        let unknown = ThreadPhotoViewerController.fittedRect(aspectRatio: nil, in: bounds)
        #expect(unknown.width == unknown.height)
    }
}
