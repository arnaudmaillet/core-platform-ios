import Testing
import UIKit
@testable import MediaCore

/// The image content view (#1085): the one "cache, else a task, then a
/// dissolve" of the app, on the loading ladder.
@MainActor
struct ImageContentViewTests {
    private func makePipeline() -> ImagePipeline { ImagePipeline(fetcher: PlaceholderImageFetcher()) }

    private func solid() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// Lets the view's load run to its end.
    private func settle(_ view: ImageContentView) async {
        for _ in 0..<200 where view.debugIsLoading {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A warm hit draws in the configure pass, with no transition.
    @Test func aWarmHitDrawsAtOnce() throws {
        let pipeline = makePipeline()
        let url = try #require(URL(string: "mock://warm/1"))
        let picture = solid()
        pipeline.store(picture, for: url, size: .avatar)
        let view = ImageContentView(size: .avatar)
        view.setImage(url, pipeline: pipeline)
        #expect(view.image != nil)
        _ = picture
        #expect(!view.debugIsLoading)
        #expect(view.ladder.transitions.last?.1 == LoadingLadder.Transition.none)
        #expect(view.ladder.isSettled)
    }

    /// A cold load lands later and dissolves in — after the bone's minimum
    /// when the bone came up (#1505).
    @Test func aColdLoadLandsAndDissolves() async throws {
        let view = ImageContentView(size: .px256)
        view.setImage(try #require(URL(string: "mock://cold/1")), pipeline: makePipeline())
        #expect(view.image == nil)
        await settle(view)
        for _ in 0..<200 where view.image == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(view.image != nil)
        // The bone leaves once the picture's dissolve has run (the fade law).
        for _ in 0..<200 where view.debugShowsBone { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!view.debugShowsBone)
        #expect(view.ladder.transitions.last?.1 == .pictureArrives)
    }

    /// ⚠️ A late answer for a reset (recycled) view lands nowhere.
    @Test func aRecycledViewNeverShowsTheOldPicture() async throws {
        let view = ImageContentView(size: .px256)
        view.setImage(try #require(URL(string: "mock://old/1")), pipeline: makePipeline())
        view.reset()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(view.image == nil)
        #expect(view.imageView.image == nil)
    }

    /// The same URL again is a reconfigure: nothing restarts or cuts.
    @Test func theSameURLAgainIsAReconfigure() throws {
        let pipeline = makePipeline()
        let url = try #require(URL(string: "mock://same/1"))
        pipeline.store(solid(), for: url, size: .avatar)
        let view = ImageContentView(size: .avatar)
        view.setImage(url, pipeline: pipeline)
        let generation = view.ladder.generation
        view.setImage(url, pipeline: pipeline)
        #expect(view.ladder.generation == generation)
    }

    /// No URL: the placeholder stays and the view settles as failed.
    @Test func noURLKeepsThePlaceholder() {
        let view = ImageContentView(size: .avatar)
        let glyph = solid()
        view.setImage(nil, pipeline: makePipeline(), placeholder: glyph)
        #expect(view.placeholderView.image === glyph)
        #expect(!view.placeholderView.isHidden)
        #expect(view.ladder.hasFailed)
    }

    /// The row loads: one per row, a warm hit drawn at once and unanimated,
    /// and a row loaded again cancels its old load.
    @Test func rowLoadsAreOnePerRow() async throws {
        let pipeline = makePipeline()
        let loads = RowImageLoads(size: .avatar)
        let row = NSObject()
        let warm = try #require(URL(string: "mock://row/warm"))
        pipeline.store(solid(), for: warm, size: .avatar)
        var applied: [Bool] = []
        loads.load(warm, using: pipeline, for: row) { _, animated in applied.append(animated) }
        #expect(applied == [false])

        let first = try #require(URL(string: "mock://row/a"))
        let second = try #require(URL(string: "mock://row/b"))
        var landed: [String] = []
        loads.load(first, using: pipeline, for: row) { _, _ in landed.append("a") }
        loads.load(second, using: pipeline, for: row) { _, _ in landed.append("b") }
        for _ in 0..<200 where loads.isLoading(for: row) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(landed == ["b"], "the row's old load landed: \(landed)")
    }
}
