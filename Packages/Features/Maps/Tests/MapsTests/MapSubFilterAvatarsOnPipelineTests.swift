import CoreModels
import Foundation
import MediaCore
import Synchronization
import Testing
import UIKit
@testable import Maps

/// Synthesizes like `PlaceholderImageFetcher`, counts fetches per URL, and
/// lets a test await one beginning: the view's own load then decodes on the
/// pool, which a loaded runner can delay past any clock (#1059), so the test
/// awaits that load instead of timing it.
private final class CountingFetcher: ImageFetching {
    private struct State {
        var fetches: [String: Int] = [:]
        var waiters: [(url: String, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let synthesized = PlaceholderImageFetcher()
    private let state = Mutex(State())

    func fetchCount(for url: URL) -> Int { state.withLock { $0.fetches[url.absoluteString] ?? 0 } }

    /// Returns once a fetch of `url` has begun.
    func fetchBegan(of url: URL) async {
        let key = url.absoluteString
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let hasBegun = state.withLock { state -> Bool in
                guard state.fetches[key, default: 0] == 0 else { return true }
                state.waiters.append((key, continuation))
                return false
            }
            if hasBegun { continuation.resume() }
        }
    }

    func fetchImageData(for url: URL) async throws -> Data {
        let key = url.absoluteString
        let starters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.fetches[key, default: 0] += 1
            let ready = state.waiters.filter { $0.url == key }.map(\.continuation)
            state.waiters.removeAll { $0.url == key }
            return ready
        }
        for waiter in starters { waiter.resume() }
        return try await synthesized.fetchImageData(for: url)
    }
}

/// Waits for the load the view started for `url`: once its fetch has begun,
/// a visible load of the same image JOINS that decode (one fill per image and
/// bucket) and returns when it lands, however late. The fetch count then
/// shows the view's load was the only one.
@MainActor
private func viewsLoadLanded(_ url: URL, size: ImageBucket, fetcher: CountingFetcher, pipeline: ImagePipeline) async -> Bool {
    await fetcher.fetchBegan(of: url)
    _ = try? await pipeline.image(for: url, size: size)
    return fetcher.fetchCount(for: url) == 1 && pipeline.isDecoded(url, size: size)
}

/// THE SUB-FILTER PILLS KEEP NO FACES OF THEIR OWN (#894).
///
/// The pill row and the organize sheet each held a `[ProfileID: UIImage]` of
/// full-size avatars for their whole life, outside the image pipeline's
/// budget and trims. The faces now live in the pipeline, decoded at the
/// avatar bucket, and both read them back from there.
@MainActor
struct MapSubFilterAvatarsOnPipelineTests {
    private static func url(_ id: String) -> URL {
        URL(string: "mock://map-favorite/\(id)?w=1600&h=1600")!
    }

    private static func person(_ id: String) -> MapSubFilterOption {
        MapSubFilterOption.people([
            MapFavorite(profileID: ProfileID(id), title: id.uppercased(), avatarURL: url(id), handle: id)
        ])[0]
    }

    /// A look budget, not a deadline (#1059): only for the main-actor hop
    /// from a landed load to the view drawing it. The load itself is awaited
    /// (`viewsLoadLanded`): a 120 s clock on it went red on a loaded runner.
    private static func settle(until done: () -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    private static func headerImage(_ bar: MapSubFilterBarView, _ option: MapSubFilterOption) -> UIImage? {
        let section = bar.pillMenu(for: option.subFilter)?.header as? UIMenu
        return (section?.children.first as? UIAction)?.image
    }

    /// The row fetches each face through the pipeline at the avatar bucket,
    /// and the menu header is drawn from the pipeline's copy once it lands.
    @Test func theRowsFacesAreDecodedInThePipelineAtTheAvatarBucket() async {
        let fetcher = CountingFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let option = Self.person("ada")
        let url = Self.url("ada")
        let bar = MapSubFilterBarView()
        bar.imagePipeline = pipeline

        bar.setOptions([option])
        #expect(Self.headerImage(bar, option)?.isSymbolImage == true, "guard: the glyph shows before the face lands")
        #expect(await viewsLoadLanded(url, size: MapSubFilterBarView.avatarBucket, fetcher: fetcher, pipeline: pipeline),
                "the row's own load did not land")

        #expect(pipeline.isDecoded(url, size: .avatar), "the face is not in the pipeline's memory")
        #expect(!pipeline.isDecoded(url, size: .full), "the face was decoded at full size")
        #expect(await Self.settle { Self.headerImage(bar, option)?.isSymbolImage == false },
                "the menu header did not draw the pipeline's face")
    }

    /// A face the pipeline already holds is drawn at once: the row reads the
    /// pipeline's memory, no copy of its own.
    @Test func aFaceThePipelineHoldsIsReadAtOnce() async {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let option = Self.person("grace")
        _ = try? await pipeline.image(for: Self.url("grace"), size: .avatar)
        let bar = MapSubFilterBarView()
        bar.imagePipeline = pipeline

        bar.setOptions([option])

        #expect(Self.headerImage(bar, option)?.isSymbolImage == false,
                "a face already decoded was not drawn on this turn")
    }

    /// The organize sheet fetches the faces it lacks through the same
    /// pipeline, at the same bucket as the row.
    @Test func theSheetsFacesComeFromThePipeline() async {
        let fetcher = CountingFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher)
        let options = ["a", "b"].map(Self.person)
        let sheet = MapSubFilterSheetViewController(
            title: "Following",
            all: options,
            activeSubFilters: [options[0].subFilter],
            maxActive: MapSubFilterSections.defaultMaxActive,
            imagePipeline: pipeline,
            rowActions: .none,
            onOptionsChanged: { _ in }
        )
        sheet.loadViewIfNeeded()
        for id in ["a", "b"] {
            #expect(await viewsLoadLanded(Self.url(id), size: MapSubFilterBarView.avatarBucket, fetcher: fetcher, pipeline: pipeline),
                    "the sheet's own load of \(id)'s face did not land")
        }

        for id in ["a", "b"] {
            #expect(pipeline.isDecoded(Self.url(id), size: .avatar), "\(id)'s face is not in the pipeline")
            #expect(!pipeline.isDecoded(Self.url(id), size: .full), "\(id)'s face was decoded at full size")
        }
        withExtendedLifetime(sheet) {}
    }
}
