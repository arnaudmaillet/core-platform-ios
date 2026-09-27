import CoreModels
import CoreNavigation
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The fullscreen feed frames a picture by its shape — fill, fit on its
/// blurred extension, or fit on black — and tells a hero how, so the flight is
/// the page's own composition at both ends.
@MainActor
struct SnapMediaAspectTests {
    // MARK: - The rule, at and around its boundaries

    @Test func tallPicturesFill() {
        #expect(SnapMediaAspect.presentation(forAspect: 9.0 / 16.0) == .fill)
        #expect(SnapMediaAspect.presentation(forAspect: 0.666) == .fill)
    }

    /// Exactly 2:3 fills — and a real 2:3 photo's pixels ARE exactly 2:3.
    @Test func exactlyTwoThirdsFills() {
        #expect(SnapMediaAspect.presentation(forAspect: 2.0 / 3.0) == .fill)
        #expect(SnapMediaAspect.presentation(for: CGSize(width: 1080, height: 1620)) == .fill)
        #expect(SnapMediaAspect.presentation(for: CGSize(width: 720, height: 1080)) == .fill)
    }

    /// Just past 2:3 the picture is shown whole, on its blurred extension.
    @Test func justWiderThanTwoThirdsFitsBlurred() {
        #expect(SnapMediaAspect.presentation(forAspect: 0.6667) == .fitBlurred)
        #expect(SnapMediaAspect.presentation(forAspect: 0.667) == .fitBlurred)
        #expect(SnapMediaAspect.presentation(for: CGSize(width: 1080, height: 1350)) == .fitBlurred)
        #expect(SnapMediaAspect.presentation(for: CGSize(width: 1440, height: 1920)) == .fitBlurred)
    }

    @Test func exactlySquareFitsBlurred() {
        #expect(SnapMediaAspect.presentation(forAspect: 1.0) == .fitBlurred)
        #expect(SnapMediaAspect.presentation(for: CGSize(width: 1080, height: 1080)) == .fitBlurred)
    }

    /// Past square it is landscape: black bands, no tolerance.
    @Test func widerThanSquareFitsOnBlack() {
        #expect(SnapMediaAspect.presentation(forAspect: 1.001) == .fitBlack)
        #expect(SnapMediaAspect.presentation(for: CGSize(width: 1440, height: 1080)) == .fitBlack)
        #expect(SnapMediaAspect.presentation(forAspect: 16.0 / 9.0) == .fitBlack)
    }

    @Test func aDegenerateShapeFills() {
        #expect(SnapMediaAspect.presentation(forAspect: 0) == .fill)
        #expect(SnapMediaAspect.presentation(forAspect: -1) == .fill)
        #expect(SnapMediaAspect.presentation(forAspect: .infinity) == .fill)
        #expect(SnapMediaAspect.presentation(for: CGSize(width: 10, height: 0)) == .fill)
    }
}

@MainActor
struct SnapMediaFramingTests {
    // MARK: - A single picture on the page

    @Test func aTallPhotoFillsExactlyAsBefore() {
        let card = SnapMediaCardView()
        card.configure(kind: .image)
        card.setImage(Self.image(CGSize(width: 90, height: 160)))
        #expect(card.framing == .fill)
        #expect(card.imageView.contentMode == .scaleAspectFill)
        #expect(card.renderView.videoGravity == .resizeAspectFill)
        #expect(card.backdropImage == nil)
    }

    @Test func aFourByFivePhotoFitsOnItsBlurredExtension() {
        let card = SnapMediaCardView()
        card.configure(kind: .image)
        card.setImage(Self.image(CGSize(width: 80, height: 100)))
        #expect(card.framing == .fitBlurred)
        #expect(card.imageView.contentMode == .scaleAspectFit)
        #expect(card.backdropImage != nil)
    }

    @Test func aLandscapePhotoFitsOnBlack() {
        let card = SnapMediaCardView()
        card.configure(kind: .image)
        card.setImage(Self.image(CGSize(width: 160, height: 90)))
        #expect(card.framing == .fitBlack)
        #expect(card.imageView.contentMode == .scaleAspectFit)
        #expect(card.backdropImage == nil)
    }

    /// ⚠️ A clip's poster is a THUMBNAIL — the mock corpus serves 168×168
    /// squares for 9:16 clips — so the declared shape wins over it. Trusted,
    /// the square framed every portrait clip as a blurred square.
    @Test func aClipsDeclaredShapeWinsOverItsPoster() {
        let card = SnapMediaCardView()
        card.configure(kind: .video)
        card.setDeclaredAspect(CGSize(width: 9, height: 16))
        card.setPoster(Self.image(CGSize(width: 168, height: 168)))
        #expect(card.framing == .fill)
        #expect(card.renderView.videoGravity == .resizeAspectFill)
    }

    /// A fitted clip: fit gravity, its ground off so the backdrop shows in the
    /// bands, and its poster framed to the clip's rect.
    @Test func aSquareClipFitsWithItsGroundOffAndItsPosterFramed() {
        let card = SnapMediaCardView()
        card.configure(kind: .video)
        card.setDeclaredAspect(CGSize(width: 1, height: 1))
        card.setPoster(Self.image(CGSize(width: 168, height: 168)))
        #expect(card.framing == .fitBlurred)
        #expect(card.renderView.videoGravity == .resizeAspect)
        #expect(card.renderView.paintsOpaqueGround == false)
        #expect(card.renderView.posterAspect == CGSize(width: 1, height: 1))
        #expect(card.backdropImage != nil)
    }

    /// The ground goes back on only on a surface the card took it off — a
    /// flight card's surface arrives with it off and must keep it that way.
    @Test func aFillingCardLeavesAnAdoptedSurfacesGroundAlone() {
        let card = SnapMediaCardView()
        card.configure(kind: .video)
        card.setDeclaredAspect(CGSize(width: 9, height: 16))
        let arriving = VideoRenderView()
        arriving.paintsOpaqueGround = false
        card.restoreRenderView(arriving)
        #expect(arriving.paintsOpaqueGround == false)
        #expect(arriving.videoGravity == .resizeAspectFill)
    }

    /// A landing hands the page a GRID tile's surface, which fills. The page
    /// stamps its own framing on it.
    @Test func aSurfaceAdoptedAtLandingTakesThePagesFraming() {
        let card = SnapMediaCardView()
        card.configure(kind: .video)
        card.setDeclaredAspect(CGSize(width: 16, height: 9))
        let arriving = VideoRenderView()
        #expect(arriving.videoGravity == .resizeAspectFill)
        card.restoreRenderView(arriving)
        #expect(card.renderView === arriving)
        #expect(arriving.videoGravity == .resizeAspect)
        // …and hands its ground back when it leaves for a grid.
        card.restoreGround(of: arriving)
        #expect(arriving.paintsOpaqueGround)
    }

    /// A recycled card forgets the last post's shape.
    @Test func reconfiguringForgetsTheDeclaredShape() {
        let card = SnapMediaCardView()
        card.configure(kind: .video)
        card.setDeclaredAspect(CGSize(width: 1, height: 1))
        #expect(card.framing == .fitBlurred)
        card.configure(kind: .video)
        #expect(card.framing == .fill)
    }

    // MARK: - The destination's answer to a hero

    @Test func aFillingPageAsksForNoFraming() {
        let feed = feed([Self.model("m", media: true, aspect: 9.0 / 16.0)])
        #expect(feed.zoomPageFraming(sourcePicture: nil) == nil)
    }

    @Test func aFourByFivePageFramesBlurredWithABackdrop() throws {
        let feed = feed([Self.model("m", media: true, aspect: 0.8)])
        let framing = try #require(feed.zoomPageFraming(sourcePicture: Self.image(CGSize(width: 80, height: 100))))
        #expect(abs(framing.mediaAspect.width / framing.mediaAspect.height - 0.8) < 0.001)
        guard case .picture = framing.backdrop else {
            Issue.record("a blurred page must hand the flight its backdrop")
            return
        }
    }

    @Test func aLandscapePageFramesOnBlack() throws {
        let feed = feed([Self.model("m", media: true, aspect: 16.0 / 9.0)])
        let framing = try #require(feed.zoomPageFraming(sourcePicture: nil))
        guard case .black = framing.backdrop else {
            Issue.record("a landscape page's bands are black")
            return
        }
    }

    /// A text page has no picture; its flight is not a hero at all.
    @Test func aTextPageAsksForNoFraming() {
        let feed = feed([Self.model("t", media: false, aspect: nil)])
        #expect(feed.zoomPageFraming(sourcePicture: Self.image(CGSize(width: 80, height: 100))) == nil)
    }

    /// No shape anyone can vouch for flies the filling hero — never the source
    /// picture's shape, which is a (possibly cropped) thumbnail.
    @Test func anUnknownShapeAsksForNoFramingWhateverTheThumbnail() {
        let feed = feed([Self.model("m", media: true, aspect: nil)])
        #expect(feed.zoomPageFraming(sourcePicture: Self.image(CGSize(width: 168, height: 168))) == nil)
    }

    // MARK: - Where the declared shape comes from

    @Test func aGridSeedCarriesTheTilesShape() {
        let seeded = GalleryPostProjection.seedModel(from: GalleryPost(
            id: PostID("p"), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "https://example.test/p.jpg"),
            aspectRatio: 0.8, caption: "", publishedAtMS: 0
        ))
        #expect(seeded.headAspectRatio == 0.8)
    }

    // MARK: - Helpers

    private func feed(_ models: [FeedItemDisplayModel]) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: FramingMuteFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.seedProjection(models)
        controller.view.layoutIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        return controller
    }

    private static func model(_ id: String, media: Bool, aspect: Double?) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "A", metaText: "",
            avatarURL: nil, caption: "caption",
            mediaURL: media ? URL(string: "https://example.test/\(id).jpg") : nil,
            mediaKind: .image, thumbnailURL: nil, audioText: nil,
            headAspectRatio: aspect
        )
    }

    private static func image(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

/// Vends nothing: these are about the question the feed answers, not about what
/// it loads through the repository.
private final class FramingMuteFeedProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(
                id: id, authorID: ProfileID("p"), caption: "",
                attachments: [], publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(
                id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil
            ),
            likeCount: 0
        )
    }
}
