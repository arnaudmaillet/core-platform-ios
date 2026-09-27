import CoreModels
import CoreNavigation
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// `-snap-media-fit`: the fullscreen feed draws its media aspect-FIT, and tells
/// a hero where the fitted picture is so the flight lands on it.
///
/// Both halves are pinned in both states, because the contract is asymmetric:
/// ON, the page letterboxes and the hero lands on the picture; OFF, not one
/// thing may differ from the feed that existed before the flag — the page
/// fills and the destination answers nil, which is what makes every flight
/// the page-sized one it always was.
///
/// ⚠️ The flag is flipped through `fitsMediaOverride` and every test that
/// flips it is SYNCHRONOUS and restores it in a `defer`: suites run
/// concurrently on the main actor, and a synchronous test cannot be
/// interleaved with another, so the override can never leak into one.
@MainActor
struct SnapMediaFitTests {
    // MARK: - The page's own drawing

    @Test func offTheCardFillsExactlyAsBefore() {
        let card = SnapMediaCardView(fitsMedia: false)
        #expect(card.imageView.contentMode == .scaleAspectFill)
        #expect(card.renderView.videoGravity == .resizeAspectFill)
    }

    @Test func onTheCardFitsItsPhotoAndItsVideo() {
        let card = SnapMediaCardView(fitsMedia: true)
        #expect(card.imageView.contentMode == .scaleAspectFit)
        #expect(card.renderView.videoGravity == .resizeAspect)
    }

    /// A landing hands the page a GRID tile's surface, which fills. The page
    /// must stamp its own framing on it, or the landed video is a crop of a
    /// page that letterboxes everything else.
    @Test func aSurfaceAdoptedAtLandingTakesThePagesFraming() {
        let card = SnapMediaCardView(fitsMedia: true)
        let arriving = VideoRenderView()
        #expect(arriving.videoGravity == .resizeAspectFill)
        card.restoreRenderView(arriving)
        #expect(card.renderView === arriving)
        #expect(arriving.videoGravity == .resizeAspect)
    }

    @Test func offAnAdoptedSurfaceIsLeftAlone() {
        let card = SnapMediaCardView(fitsMedia: false)
        let arriving = VideoRenderView()
        card.restoreRenderView(arriving)
        #expect(arriving.videoGravity == .resizeAspectFill)
    }

    /// The picture a hero must land on is the one being DRAWN — here a photo
    /// whose pixels are 3:2.
    @Test func theDrawnAspectIsThePhotosPixels() {
        let card = SnapMediaCardView(fitsMedia: true)
        card.configure(kind: .image)
        #expect(card.drawnMediaAspect == nil)
        card.setImage(Self.image(CGSize(width: 30, height: 20)))
        #expect(card.drawnMediaAspect == CGSize(width: 30, height: 20))
    }

    // MARK: - The carousel's pages (PostGrid, shared with the grid's cards)

    @Test func aCarouselFillsItsPagesUnlessAskedToFit() {
        let pages = [GalleryPost.MediaPage(thumbnailURL: nil), GalleryPost.MediaPage(thumbnailURL: nil)]
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

        let card = MediaCarouselView(style: .card, frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        card.configure(with: pages, imagePipeline: pipeline)
        #expect(Self.coverModes(in: card) == [.scaleAspectFill, .scaleAspectFill])

        let page = MediaCarouselView(style: .page, frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        page.configure(with: pages, imagePipeline: pipeline)
        page.pageContentMode = .scaleAspectFit
        // Applied to the pages already built…
        #expect(Self.coverModes(in: page) == [.scaleAspectFit, .scaleAspectFit])
        // …and to every page built after.
        page.configure(with: pages + [GalleryPost.MediaPage(thumbnailURL: nil)], imagePipeline: pipeline)
        #expect(Self.coverModes(in: page) == [.scaleAspectFit, .scaleAspectFit, .scaleAspectFit])
    }

    // MARK: - The destination's answer

    @Test func offTheFeedNamesNoMediaRect() {
        SnapFeedViewController.fitsMediaOverride = false
        defer { SnapFeedViewController.fitsMediaOverride = nil }
        let feed = feed([Self.model("m", media: true, aspect: 0.75)])
        let container = feed.view!
        #expect(feed.zoomTargetMediaFrame(in: container) == nil)
        #expect(feed.zoomTargetFrame(in: container) == container.bounds)
    }

    /// Before the page has a picture of its own to measure, the model's
    /// declared shape answers — the tile's, for a feed seeded from a grid.
    @Test func onTheFeedNamesTheFittedRectOfTheDeclaredAspect() {
        SnapFeedViewController.fitsMediaOverride = true
        defer { SnapFeedViewController.fitsMediaOverride = nil }
        let feed = feed([Self.model("m", media: true, aspect: 0.75)])
        let container = feed.view!
        let expected = ZoomTransitionGeometry.fittedMediaRect(
            aspect: CGSize(width: 0.75, height: 1), in: container.bounds
        )
        let answer = feed.zoomTargetMediaFrame(in: container)
        #expect(answer != nil)
        if let answer, let expected {
            #expect(abs(answer.minY - expected.minY) < 0.001)
            #expect(abs(answer.height - expected.height) < 0.001)
            #expect(abs(answer.width - 390) < 0.001)
        }
    }

    /// A text page has no picture; its flight is not a hero at all, and it
    /// must never be handed a rect to letterbox to.
    @Test func onATextPageNamesNoMediaRect() {
        SnapFeedViewController.fitsMediaOverride = true
        defer { SnapFeedViewController.fitsMediaOverride = nil }
        let feed = feed([Self.model("t", media: false, aspect: nil)])
        #expect(feed.zoomTargetMediaFrame(in: feed.view) == nil)
    }

    /// A post whose shape nobody declared and nothing has drawn yet has no rect
    /// either — a guessed square would be a landing that snaps when the real
    /// picture arrives.
    @Test func onAnUnknownShapeNamesNoMediaRect() {
        SnapFeedViewController.fitsMediaOverride = true
        defer { SnapFeedViewController.fitsMediaOverride = nil }
        let feed = feed([Self.model("m", media: true, aspect: nil)])
        #expect(feed.zoomTargetMediaFrame(in: feed.view) == nil)
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
            viewModel: FeedViewModel(repository: FitMuteFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.seedProjection(models)
        controller.view.layoutIfNeeded()
        // On screen, or there is no active page to answer about.
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

    /// Every page cover's content mode, in page order — found by walking the
    /// view tree, since the pages are the carousel's private business.
    private static func coverModes(in carousel: MediaCarouselView) -> [UIView.ContentMode] {
        func pages(_ view: UIView) -> [UIView] {
            view.subviews.flatMap { String(describing: type(of: $0)) == "CarouselPageView" ? [$0] : pages($0) }
        }
        return pages(carousel)
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap { $0.subviews.first(where: { $0 is UIImageView }) }
            .map(\.contentMode)
    }
}
/// Vends nothing: these are about the question the feed answers, not about what
/// it loads through the repository.
private final class FitMuteFeedProvider: FeedProviding, @unchecked Sendable {
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
