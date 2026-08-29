import CoreModels
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// **What the screen actually LOOKS like, sampled from rendered pixels.**
///
/// ## Why pixels, and not another state assertion
///
/// Every suite written for this screen so far asks it questions — which post
/// owns the interface, which cell hosts a panel, whether the pager is locked —
/// and every one of them has passed while the screen was visibly wrong. That is
/// not bad luck: a defect here IS a disagreement between what the code believes
/// and what is drawn, so any test that asks the code agrees with the defect.
///
/// These render the view hierarchy and read colours out of it. A page that goes
/// black on the way out fails here and cannot fail anywhere else.
///
/// ⚠️ The device is pinned to LIGHT so the expected colours are stated rather
/// than derived: a test that computed its expectation from the same trait the
/// view used would pass whatever the view did.
@MainActor
struct SnapPageRenderSpecTests {
    // MARK: - Fixtures

    private func model(_ id: String, media: URL?) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "A", metaText: "",
            avatarURL: nil, caption: "A caption long enough to occupy the page.",
            mediaURL: media, mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: 0
        )
    }

    private func media(_ id: String) -> FeedItemDisplayModel {
        model(id, media: URL(string: "https://example.test/\(id).jpg"))
    }

    private func text(_ id: String) -> FeedItemDisplayModel { model(id, media: nil) }

    @MainActor
    private final class Panels {
        func make(_ id: PostID) -> UIViewController {
            let controller = UIViewController()
            // A real panel fills its host with the page's own ground; the
            // fixture does the same, so a page that HAS its panel renders light
            // and a page that lost it renders whatever is underneath.
            controller.view.backgroundColor = .systemBackground
            return controller
        }
    }

    private func feed(_ models: [FeedItemDisplayModel]) -> (SnapFeedViewController, UIWindow) {
        let panels = Panels()
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: QuietProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            makeCommentsPanelContent: { id in panels.make(id) }
        )
        // ⚠️ IN A WINDOW, and pinned to light. A detached view has no trait to
        // resolve `.systemBackground` against, and the screen under test reads
        // the device's style off its window — the exact path the theme defect
        // came down.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.isHidden = false
        controller.loadViewIfNeeded()
        controller.seedProjection(models)
        controller.view.layoutIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        window.layoutIfNeeded()
        return (controller, window)
    }

    private func scroll(_ feed: SnapFeedViewController, toPageFraction fraction: CGFloat) {
        guard let collection = feed.view.subviews
            .compactMap({ $0 as? UICollectionView }).first else { return }
        collection.contentOffset.y = collection.bounds.height * fraction
        collection.layoutIfNeeded()
        feed.debugRealizeVisibleCells()
        collection.layoutIfNeeded()
    }

    // MARK: - Reading the screen

    /// The rendered colour at a point, in the window's own coordinates.
    private func colour(of window: UIWindow, at point: CGPoint) -> (r: Int, g: Int, b: Int) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in
            window.layer.render(in: context.cgContext)
        }
        guard let cgImage = image.cgImage else { return (0, 0, 0) }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, 0) }
        let scale = image.scale
        context.draw(
            cgImage,
            in: CGRect(
                x: -point.x * scale, y: -(window.bounds.height - point.y) * scale,
                width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)
            )
        )
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    /// A page's ground is light when the device is: not merely "not black", but
    /// bright enough that a viewer would call it white.
    private func isLight(_ colour: (r: Int, g: Int, b: Int)) -> Bool {
        colour.r > 200 && colour.g > 200 && colour.b > 200
    }

    // MARK: - The specification

    /// A settled text page is a light page on a light device. If this fails,
    /// nothing below it means anything.
    @Test func aSettledTextPageIsLight() {
        let (feed, window) = feed([text("a"), text("b")])
        _ = feed

        let sample = colour(of: window, at: CGPoint(x: 195, y: 500))

        #expect(isLight(sample), "a text page did not render light: \(sample)")
    }

    /// ⚠️ THE INSTRUMENT'S OWN CHECK: a media page renders DARK.
    ///
    /// Without a case that must come back dark, "everything is light" is
    /// indistinguishable from a sampler that reads white whatever is on screen
    /// — and a broken instrument agrees with every specification ever written.
    @Test func aMediaPageRendersDark() {
        let (feed, window) = feed([media("a"), text("b")])
        _ = feed

        let sample = colour(of: window, at: CGPoint(x: 195, y: 500))

        #expect(isLight(sample) == false,
                "the sampler reads light on a media page — it is not reading the screen: \(sample)")
    }

    /// ⚠️ AND IT STAYS LIGHT ALL THE WAY OUT.
    ///
    /// The reported defect, stated as a picture: while a text post still has
    /// pixels in the viewport, those pixels are its page. Not the bare cell
    /// underneath it, which is black.
    @Test func aDepartingTextPageStaysLightWhileItIsOnScreen() {
        let (feed, window) = feed([text("a"), text("b")])

        scroll(feed, toPageFraction: 0.5)

        // The top half of the screen is the page being left.
        let sample = colour(of: window, at: CGPoint(x: 195, y: 200))
        #expect(isLight(sample),
                "the departing page turned dark while it was still on screen: \(sample)")
    }

    /// And the page arriving under it is a page too, not a black rectangle
    /// that fills itself in once the scroll stops.
    @Test func anArrivingTextPageIsLightBeforeItSettles() {
        let (feed, window) = feed([text("a"), text("b")])

        scroll(feed, toPageFraction: 0.5)

        // The bottom half is the page arriving.
        let sample = colour(of: window, at: CGPoint(x: 195, y: 650))
        #expect(isLight(sample),
                "the arriving page rendered dark while it was half on screen: \(sample)")
    }

    // ⚠️ NOT COVERED HERE, AND SAID SO RATHER THAN FAKED.
    //
    // A page's composer must travel with its page — it was pinned to the
    // screen's bottom edge, so two were visible at once during a scroll. The
    // observable is geometric and easy; what is missing is a panel to observe.
    // These suites stand a plain view controller in for one, and a fixture with
    // no composer would let any assertion about composers pass. Using the real
    // panel means a repository, a network and a view model inside a render
    // test, which buys a worse test than none.
    //
    // Verified on the device instead. If it regresses, it regresses silently
    // here — which is the honest cost, and the reason this note exists.

    /// ⚠️ THE GROUND BEHIND THE PAGES IS THE PAGE'S OWN.
    ///
    /// There is always a strip no page has covered for a frame or two: a cell
    /// is recycled the moment the model says it has left, while the pixels of
    /// the settle are still arriving. Black behind a light page turns that
    /// frame into a black band across the screen — one frame in a hundred and
    /// six on the recording, top-of-screen brightness 12 against 90 elsewhere,
    /// and the whole of "the post goes black on the way out".
    ///
    /// Sampled by scrolling PAST the last page, which is the one way a test can
    /// hold the gap open: what shows there is exactly what shows for that frame.
    @Test func theGroundBehindThePagesIsLightUnderALightPage() {
        let (feed, window) = feed([text("a"), text("b")])
        guard let collection = feed.view.subviews
            .compactMap({ $0 as? UICollectionView }).first else { return }

        // Settle on the last page, then open a gap below it.
        scroll(feed, toPageFraction: 1)
        feed.scrollViewDidEndDecelerating(collection)
        collection.contentOffset.y += 300
        collection.layoutIfNeeded()

        let sample = colour(of: window, at: CGPoint(x: 195, y: 700))
        #expect(isLight(sample), "the ground behind a light page is dark: \(sample)")
    }

    /// And dark under a dark one — the same rule, which is what makes it a rule
    /// rather than a preference for white.
    @Test func theGroundBehindThePagesIsDarkUnderAMediaPage() {
        let (feed, window) = feed([media("a"), media("b")])
        guard let collection = feed.view.subviews
            .compactMap({ $0 as? UICollectionView }).first else { return }

        scroll(feed, toPageFraction: 1)
        feed.scrollViewDidEndDecelerating(collection)
        collection.contentOffset.y += 300
        collection.layoutIfNeeded()

        let sample = colour(of: window, at: CGPoint(x: 195, y: 700))
        #expect(isLight(sample) == false, "the ground behind a media page is light: \(sample)")
    }

    /// The same, one page further on: the defect was reported after several
    /// changes, and a rule that only holds for the first is not the rule.
    @Test func theSecondPageChangeLooksLikeTheFirst() {
        let (feed, window) = feed([text("a"), text("b"), text("c")])
        guard let collection = feed.view.subviews
            .compactMap({ $0 as? UICollectionView }).first else { return }

        scroll(feed, toPageFraction: 1)
        feed.scrollViewDidEndDecelerating(collection)
        scroll(feed, toPageFraction: 1.5)

        #expect(isLight(colour(of: window, at: CGPoint(x: 195, y: 200))),
                "the page being left turned dark on the second change")
        #expect(isLight(colour(of: window, at: CGPoint(x: 195, y: 650))),
                "the page arriving was dark on the second change")
    }
}

/// Vends nothing: these are about what is drawn from what is already there.
private final class QuietProvider: FeedProviding, @unchecked Sendable {
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
