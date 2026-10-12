import CoreModels
import DesignSystem
import Foundation
import MediaCore
import Synchronization
import Testing
import UIKit
@testable import Feed

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

/// THE SNAP PILLS KEEP NO PICTURES OF THEIR OWN (#894).
///
/// The author pill's faces and the attribution pill's covers (with the sound
/// bubble that shares them) used to sit in two static FIFO dictionaries beside
/// the image pipeline: outside its byte budget, its trims and its logout. They
/// now live in the pipeline's memory, decoded at the avatar bucket, and the
/// pills read them back synchronously from there.
@MainActor
struct SnapPillImagesOnPipelineTests {
    private static func pipeline() -> ImagePipeline {
        ImagePipeline(fetcher: PlaceholderImageFetcher())
    }

    private static func counted() -> (CountingFetcher, ImagePipeline) {
        let fetcher = CountingFetcher()
        return (fetcher, ImagePipeline(fetcher: fetcher))
    }

    /// A large picture: decoded at full it would be 1200 px on its long side.
    private static func url(_ name: String) -> URL {
        URL(string: "mock://pill/\(name)?w=1600&h=1600")!
    }

    private static func model(id: String, avatarURL: URL?, thumbnailURL: URL? = nil) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("author-\(id)"),
            authorName: "Ada \(id)", metaText: "@ada · 2h", avatarURL: avatarURL,
            caption: "c", mediaURL: URL(string: "mock://media/\(id)"),
            mediaKind: .image, thumbnailURL: thumbnailURL, audioText: nil
        )
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

    private static func longSide(_ image: UIImage?) -> Int {
        guard let cgImage = image?.cgImage else { return 0 }
        return max(cgImage.width, cgImage.height)
    }

    // MARK: - Author pill

    /// Warming the next author's face decodes it in the pipeline at the avatar
    /// bucket — never at full size, which the blurred stills would have to
    /// scale on the main thread.
    @Test func warmingAFaceDecodesItInThePipelineAtTheAvatarBucket() async {
        let (fetcher, pipeline) = Self.counted()
        let url = Self.url("face-warm")

        SnapAuthorIdentityView.warmFace(url, pipeline: pipeline)
        #expect(await viewsLoadLanded(url, size: SnapAuthorIdentityView.faceBucket, fetcher: fetcher, pipeline: pipeline),
                "the warm's own load did not land")

        #expect(pipeline.isDecoded(url, size: .avatar), "the warmed face is not in the pipeline's memory")
        #expect(!pipeline.isDecoded(url, size: .full), "the face was decoded at full size")
        let side = Self.longSide(pipeline.cachedImage(for: url, size: .avatar))
        #expect(side > 0 && side <= 128, "the face is \(side) px, not the avatar bucket")
    }

    /// A face the pipeline holds is drawn in the same pass as the name: the
    /// pill reads the pipeline synchronously, no copy of its own.
    @Test func aFaceThePipelineHoldsIsDrawnAtOnce() async {
        let pipeline = Self.pipeline()
        let url = Self.url("face-ready")
        _ = try? await pipeline.image(for: url, size: .avatar)
        let decoded = pipeline.cachedImage(for: url, size: .avatar)

        let pill = SnapAuthorIdentityView()
        pill.setAuthor(Self.model(id: "1", avatarURL: url), pipeline: pipeline, animated: false)

        #expect(decoded != nil, "guard: the face is decoded")
        #expect(pill.debugFaceImage === decoded, "the pill did not draw the pipeline's face on this turn")
    }

    /// A face not decoded yet is fetched through the pipeline at the avatar
    /// bucket and lands on the disc.
    @Test func aMissingFaceIsFetchedThroughThePipeline() async {
        let (fetcher, pipeline) = Self.counted()
        let url = Self.url("face-fetch")
        let pill = SnapAuthorIdentityView()

        pill.setAuthor(Self.model(id: "2", avatarURL: url), pipeline: pipeline, animated: false)
        #expect(pill.debugFaceImage == nil, "guard: nothing to draw before the fetch")
        #expect(await viewsLoadLanded(url, size: SnapAuthorIdentityView.faceBucket, fetcher: fetcher, pipeline: pipeline),
                "the pill's own load did not land")

        #expect(await Self.settle { pill.debugFaceImage != nil }, "the fetched face never landed on the pill")
        #expect(pipeline.isDecoded(url, size: .avatar) && !pipeline.isDecoded(url, size: .full),
                "the face was not decoded in the pipeline at the avatar bucket")
    }

    // MARK: - Attribution pill and sound bubble

    /// Warming the next cover decodes it in the pipeline at the cover bucket.
    @Test func warmingACoverDecodesItInThePipeline() async throws {
        let (fetcher, pipeline) = Self.counted()
        let url = Self.url("cover-warm")
        let model = Self.model(id: "3", avatarURL: nil, thumbnailURL: url)
        let coverURL = try #require(SnapMediaAttributionView.coverURL(for: model, cover: .post), "guard: the post has a cover")

        SnapMediaAttributionView.warmCover(for: model, cover: .post, pipeline: pipeline)
        #expect(await viewsLoadLanded(coverURL, size: SnapMediaAttributionView.coverBucket, fetcher: fetcher, pipeline: pipeline),
                "the warm's own load did not land")

        #expect(pipeline.isDecoded(coverURL, size: .avatar), "the warmed cover is not in the pipeline")
        #expect(!pipeline.isDecoded(coverURL, size: .full), "the cover was decoded at full size")
    }

    /// A cover the pipeline holds is drawn by the attribution pill on this
    /// turn, and the sound bubble's face reads the same picture.
    @Test func aCoverThePipelineHoldsIsDrawnAtOnceByBothPills() async throws {
        let pipeline = Self.pipeline()
        let url = Self.url("cover-ready")
        let model = Self.model(id: "4", avatarURL: nil, thumbnailURL: url)
        let coverURL = try #require(SnapMediaAttributionView.coverURL(for: model, cover: .post))
        _ = try? await pipeline.image(for: coverURL, size: SnapMediaAttributionView.coverBucket)
        let decoded = try #require(pipeline.cachedImage(for: coverURL, size: .avatar))

        let pill = SnapMediaAttributionView()
        pill.setPost(model, pipeline: pipeline, animated: false)
        let face = SnapSoundFace(coverURL: coverURL, isAvailable: true, isMuted: false, pipeline: pipeline)

        #expect(pill.debugCoverImage === decoded, "the attribution pill did not draw the pipeline's cover")
        #expect(face.cachedCover === decoded, "the sound bubble did not read the pipeline's cover")
    }

    /// A remote cover the bubble has to wait for is fetched into the pipeline,
    /// and the face then reads it; without a pipeline a remote cover draws
    /// nothing (it is never fetched behind the host's back).
    @Test func theSoundBubblesRemoteCoverComesFromThePipeline() async {
        let pipeline = Self.pipeline()
        let url = Self.url("bubble-remote")
        let face = SnapSoundFace(coverURL: url, isAvailable: true, isMuted: false, pipeline: pipeline)
        #expect(face.cachedCover == nil, "guard: a remote cover drew before its fetch")

        let fetched = await SnapSoundFace.fetchCover(url, pipeline: pipeline)

        #expect(fetched != nil)
        #expect(face.cachedCover === fetched, "the face does not read what the fetch decoded")
        #expect(SnapSoundFace(coverURL: url, isAvailable: true, isMuted: false).cachedCover == nil,
                "a face with no pipeline found a remote cover somewhere else")
    }

    /// A file cover is read once and kept in the pipeline's memory, so the
    /// next face for it reads the same picture without the disk.
    @Test func aFileCoverIsKeptInThePipeline() throws {
        let pipeline = Self.pipeline()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pill-cover-\(UUID().uuidString).png")
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
        try png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let first = SnapSoundFace(coverURL: file, isAvailable: true, isMuted: false, pipeline: pipeline).cachedCover
        try FileManager.default.removeItem(at: file)
        let second = SnapSoundFace(coverURL: file, isAvailable: true, isMuted: false, pipeline: pipeline).cachedCover

        #expect(first != nil, "the file cover was not read")
        #expect(second === first, "the second face read the disk again instead of the pipeline")
    }

    /// The pipeline is not part of what a face IS: two faces that draw the
    /// same cover are equal, so a host never redraws for a pipeline alone.
    @Test func aFacesPipelineIsNotPartOfItsEquality() {
        let url = Self.url("equal")
        #expect(SnapSoundFace(coverURL: url, isAvailable: true, isMuted: false, pipeline: Self.pipeline())
            == SnapSoundFace(coverURL: url, isAvailable: true, isMuted: false))
    }
}
