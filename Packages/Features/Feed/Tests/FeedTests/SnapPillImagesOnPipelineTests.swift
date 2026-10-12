import CoreModels
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

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

    /// Generous: the full scheme runs ~190 suites in parallel, where a test
    /// that hops main → pool → main can wait over half a minute (measured: a
    /// fetched face landed after more than 30 s there, in under a second
    /// alone). Returns as soon as `done`.
    private static func settle(timeout: Duration = .seconds(120), until done: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !done(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
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
        let pipeline = Self.pipeline()
        let url = Self.url("face-warm")

        SnapAuthorIdentityView.warmFace(url, pipeline: pipeline)
        await Self.settle { pipeline.isDecoded(url, size: SnapAuthorIdentityView.faceBucket) }

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
        let pipeline = Self.pipeline()
        let url = Self.url("face-fetch")
        let pill = SnapAuthorIdentityView()

        pill.setAuthor(Self.model(id: "2", avatarURL: url), pipeline: pipeline, animated: false)
        #expect(pill.debugFaceImage == nil, "guard: nothing to draw before the fetch")
        await Self.settle { pill.debugFaceImage != nil }

        #expect(pill.debugFaceImage != nil, "the fetched face never landed")
        #expect(pipeline.isDecoded(url, size: .avatar) && !pipeline.isDecoded(url, size: .full),
                "the face was not decoded in the pipeline at the avatar bucket")
    }

    // MARK: - Attribution pill and sound bubble

    /// Warming the next cover decodes it in the pipeline at the cover bucket.
    @Test func warmingACoverDecodesItInThePipeline() async {
        let pipeline = Self.pipeline()
        let url = Self.url("cover-warm")
        let model = Self.model(id: "3", avatarURL: nil, thumbnailURL: url)
        let coverURL = SnapMediaAttributionView.coverURL(for: model, cover: .post)

        SnapMediaAttributionView.warmCover(for: model, cover: .post, pipeline: pipeline)
        if let coverURL {
            await Self.settle { pipeline.isDecoded(coverURL, size: SnapMediaAttributionView.coverBucket) }
        }

        #expect(coverURL != nil, "guard: the post has a cover")
        #expect(coverURL.map { pipeline.isDecoded($0, size: .avatar) } == true, "the warmed cover is not in the pipeline")
        #expect(coverURL.map { pipeline.isDecoded($0, size: .full) } == false, "the cover was decoded at full size")
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
