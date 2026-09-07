import CoreModels
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// **THE SPECIFICATION FOR "IT IS COMING": a page whose media has not arrived
/// says so.**
///
/// Reported from the feed: paging onto a post shows its thumbnail — a poster
/// for a clip, nothing at all for a photograph — and then stays that way for as
/// long as the network takes, with nothing on screen to say anything is
/// happening. A still frame that is waiting and a still frame that has arrived
/// look identical, which is the whole complaint.
///
/// So the rule, from the reader's side:
///
/// * while a page's media area has no real picture, a spinner sits over it;
/// * the moment the picture lands, the spinner goes;
/// * a page with no media at all never shows one;
/// * and a picture that was already in hand never flashes one — the wait has to
///   be long enough to be worth announcing.
///
/// ⚠️ These are about the page, not about the pipeline. They name no fetch, no
/// decode and no player: an implementation that satisfies them by any means is
/// acceptable.
@MainActor
struct SnapMediaLoaderSpecTests {
    // MARK: - Fixtures

    private static let container = CGRect(x: 0, y: 0, width: 390, height: 844)

    private func model(
        _ id: String, kind: MediaKind, media: URL?, thumbnail: URL? = nil
    ) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("p"), authorName: "Ava",
            metaText: "@ava · 3m", avatarURL: nil, caption: "caption",
            mediaURL: media, mediaKind: kind, thumbnailURL: thumbnail,
            audioText: nil, likeCount: 0, timestampText: "now"
        )
    }

    /// A page whose media is genuinely outstanding: the pipeline is asked and
    /// never answers, which is what a slow network looks like from here.
    private func cell(_ model: FeedItemDisplayModel) -> SnapFeedCell {
        let cell = SnapFeedCell(frame: Self.container)
        cell.configure(
            with: model,
            pipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil
        )
        cell.layoutIfNeeded()
        return cell
    }

    private func photo(_ id: String = "post-photo") -> FeedItemDisplayModel {
        model(id, kind: .image, media: URL(string: "https://example.test/\(id).jpg"))
    }

    private func clip(_ id: String = "post-clip") -> FeedItemDisplayModel {
        model(
            id, kind: .video, media: URL(string: "https://example.test/\(id).mp4"),
            thumbnail: URL(string: "https://example.test/\(id)-poster.jpg")
        )
    }

    private func text(_ id: String = "post-text") -> FeedItemDisplayModel {
        model(id, kind: .image, media: nil)
    }

    /// A post of several pictures, none of which the pipeline will ever answer
    /// for — so every page is genuinely outstanding.
    private func collection(_ pages: Int, id: String = "post-gallery") -> SnapFeedCell {
        let cell = SnapFeedCell(frame: Self.container)
        let extra = (1..<pages).map { index in
            GalleryPost.MediaPage(
                thumbnailURL: URL(string: "https://example.test/\(id)-\(index).jpg"),
                videoURL: nil
            )
        }
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID(id), authorID: ProfileID("p"), authorName: "Ava",
                metaText: "@ava · 3m", avatarURL: nil, caption: "caption",
                mediaURL: URL(string: "https://example.test/\(id)-0.jpg"),
                mediaKind: .image, thumbnailURL: nil, audioText: nil,
                likeCount: 0, timestampText: "now", extraMedia: extra
            ),
            pipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil
        )
        cell.layoutIfNeeded()
        return cell
    }

    // MARK: - The surface the page is actually showing

    /// **A PAGE THAT ADOPTS A SURFACE MID-FLIGHT STOPS WAITING.**
    ///
    /// Reported from the map: on the first open of a media post the spinner
    /// sometimes never goes away, over video that is playing perfectly.
    ///
    /// The mechanism is a signal wired to the wrong object. A hero flight
    /// carries the live player, so the page defers its own playback and its own
    /// surface sits at zero frames while the grace runs out — spinner up. Then
    /// the landing hands over the flight's surface, which has been rendering
    /// the whole time. `restoreRenderView` re-points `renderView` at that
    /// object and detaches the one the page installed its "there is a picture
    /// now" closure on, so the page's only way down is wired to a view that
    /// will never speak again, while the view the viewer is watching announces
    /// to nobody.
    ///
    /// Measured before the fix: 19 cold opens, 11 stuck. Widening the grace to
    /// 3s made 5 of 5 clean — which is not a fix, but it is the proof that the
    /// answer is available at the landing and simply never asked for.
    ///
    /// Two claims, and they fail separately, so they are tested separately.
    @Test func adoptingALiveSurfaceEndsTheWait() {
        let cell = cell(clip())
        cell.debugElapseMediaLoaderGrace()
        #expect(cell.debugIsShowingMediaLoader, "the premise: nothing has arrived yet")

        // What a landing hands over: a surface already drawing, whose
        // announcement is in the past.
        let adopted = VideoRenderView()
        adopted.debugSimulateFirstFrame()

        cell.adoptLiveRenderView(adopted)

        #expect(!cell.debugIsShowingMediaLoader,
                "the page is showing a picture, so it must stop saying it is not")
    }

    /// ⚠️ AND THE SIGNAL MOVES WITH THE SURFACE, for the frame that has not
    /// arrived yet.
    ///
    /// Re-asking at the landing fixes the surface that arrives already
    /// rendering. A surface that arrives EMPTY — flushed by a renderer change
    /// on the way over — still has to be able to speak when its first frame
    /// lands, and it can only do that if the page's closure followed it. Three
    /// places re-point this surface (a landing, a reclaimed donation, a
    /// carousel page turn), so the closure belongs to the card rather than to
    /// whichever object happened to be there at bind.
    @Test func thePictureSignalFollowsTheSurface() {
        let cell = cell(clip())
        let original = cell.debugRenderView
        #expect(original.onPictureAvailabilityChange != nil, "the premise: the page is listening")

        let adopted = VideoRenderView()
        cell.adoptLiveRenderView(adopted)

        #expect(adopted.onPictureAvailabilityChange != nil,
                "the surface the page is showing has to be the one it listens to")
        #expect(original.onPictureAvailabilityChange == nil,
                "and the one it replaced must not still be holding the page's only edge")
    }

    // MARK: - Whose wait it is

    /// ⚠️ THE WAIT BELONGS TO A MEDIA, NOT TO THE POST.
    ///
    /// Reported from the feed: the spinner behaved as though it were the page's
    /// rather than the picture's. Centred on the card, it stayed put while the
    /// pictures moved under it — so swiping off a page that was still loading
    /// left its announcement hanging over the picture that had already arrived,
    /// saying the opposite of the truth on both pages at once.
    ///
    /// The stopped mark and the play/pause glyph already ride their page. This
    /// is the same rule, and the claim is the same shape: each page owns its
    /// own, and turning to another takes the first one's down.
    @Test func theWaitRidesItsOwnPage() {
        let cell = collection(3)
        cell.debugElapseMediaLoaderGrace()

        let first = cell.debugLoaderView(onPage: 0)
        #expect(first != nil, "the premise: page one is waiting")
        #expect(cell.debugLoaderView(onPage: 1) == nil,
                "and the page next door is not announcing anything")

        cell.debugShowPage(1)
        cell.debugElapseMediaLoaderGrace()

        let second = cell.debugLoaderView(onPage: 1)
        #expect(second != nil)
        // ⚠️ NOT THE SAME VIEW. One spinner moved from page to page would be
        // the card's again, wearing a different address.
        #expect(second !== first)
        #expect(cell.debugLoaderView(onPage: 0) == nil,
                "the page left behind stopped announcing a wait nobody decides for")
    }

    // MARK: - When it shows

    /// ⚠️ NOT AT ONCE. A page whose picture is already in hand — a cache hit,
    /// the common case — must not flash a spinner on its way to being ready.
    /// The wait has to outlast the grace before it is worth announcing.
    @Test func nothingIsAnnouncedForTheFirstMoment() {
        let cell = cell(photo())

        #expect(cell.debugIsShowingMediaLoader == false)
    }

    /// ⚠️ AND THEN IT DOES. Past the grace, with nothing to show, the page says
    /// it is waiting.
    @Test func aPageStillWaitingPastTheGraceAnnouncesIt() {
        let cell = cell(photo())

        cell.debugElapseMediaLoaderGrace()

        #expect(cell.debugIsShowingMediaLoader,
                "a page with no picture and no spinner is indistinguishable from a loaded one")
    }

    /// THE REPORTED CASE, exactly: a clip showing its poster. There IS a
    /// picture on screen — but it is not the post's media, and the viewer is
    /// waiting for something.
    @Test func aClipShowingOnlyItsPosterAnnouncesTheWait() {
        let cell = cell(clip())

        cell.debugElapseMediaLoaderGrace()

        #expect(cell.debugIsShowingMediaLoader)
    }

    /// A page with NO media has nothing to wait for, ever.
    @Test func aTextPageNeverAnnouncesAnything() {
        let cell = cell(text())

        cell.debugElapseMediaLoaderGrace()

        #expect(cell.debugIsShowingMediaLoader == false)
    }

    // MARK: - When it goes

    /// The moment the picture lands, the spinner goes — not at the next settle,
    /// not on the next layout pass.
    @Test func theSpinnerGoesWhenThePictureLands() {
        let cell = cell(photo())
        cell.debugElapseMediaLoaderGrace()
        #expect(cell.debugIsShowingMediaLoader, "the premise: it was waiting")

        cell.debugDeliverMedia()

        #expect(cell.debugIsShowingMediaLoader == false)
    }

    /// A recycled cell carries nothing over. A spinner inherited from the post
    /// before it would sit over a page that is not waiting for anything.
    @Test func aRecycledCellCarriesNoSpinner() {
        let cell = cell(photo())
        cell.debugElapseMediaLoaderGrace()

        cell.prepareForReuse()

        #expect(cell.debugIsShowingMediaLoader == false)
    }

    /// And re-binding to a post whose picture is in hand does not re-arm it.
    @Test func abindingToAReadyPageDoesNotAnnounceAWait() {
        let cell = cell(photo("post-a"))
        cell.debugElapseMediaLoaderGrace()
        cell.debugDeliverMedia()

        cell.debugElapseMediaLoaderGrace()

        #expect(cell.debugIsShowingMediaLoader == false)
    }

    // MARK: - What is drawn

    /// ⚠️ RENDERED, not asked.
    ///
    /// Every earlier defect on this screen was a disagreement between what the
    /// code believed and what was drawn, so the state above is not enough: the
    /// media area is rendered into a bitmap with the spinner up and again
    /// without it, and the two must DIFFER. A view that reports itself visible
    /// and paints nothing fails here and nowhere else.
    @Test func theSpinnerIsActuallyDrawnOverTheMedia() throws {
        let window = UIWindow(frame: Self.container)
        window.overrideUserInterfaceStyle = .dark
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()

        let cell = SnapFeedCell(frame: Self.container)
        host.view.addSubview(cell)
        cell.configure(
            with: photo(),
            pipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil
        )
        host.view.layoutIfNeeded()

        let quiet = try #require(Self.render(window))
        cell.debugElapseMediaLoaderGrace()
        host.view.layoutIfNeeded()
        let waiting = try #require(Self.render(window))

        #expect(quiet != waiting, "the page renders identically with and without the spinner")
    }

    /// The instrument's own check: two renders of the SAME state agree. Without
    /// it, "the two differ" could as easily mean the renderer is noisy.
    @Test func twoRendersOfOneStateAgree() throws {
        let window = UIWindow(frame: Self.container)
        window.overrideUserInterfaceStyle = .dark
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        let cell = SnapFeedCell(frame: Self.container)
        host.view.addSubview(cell)
        cell.configure(
            with: photo(),
            pipeline: ImagePipeline(fetcher: SilentFetcher()),
            videoPlayback: nil
        )
        host.view.layoutIfNeeded()

        let first = try #require(Self.render(window))
        let second = try #require(Self.render(window))

        #expect(first == second)
    }

    /// The media area only — the chrome around it moves for its own reasons and
    /// would make every comparison differ.
    ///
    /// ⚠️ NO TRANSLATION OF ITS OWN. `UIGraphicsImageRenderer(bounds:)` already
    /// offsets the context by the bounds' origin, so translating again samples
    /// a region 120x320pt away from the one asked for — which came back
    /// uniformly black, and made the spinner "invisible" in a test that was
    /// photographing the wrong part of the screen.
    private static func render(_ window: UIWindow) -> Data? {
        let area = CGRect(x: 120, y: 320, width: 150, height: 150)
        let renderer = UIGraphicsImageRenderer(bounds: area)
        let image = renderer.image { context in
            window.layer.render(in: context.cgContext)
        }
        return image.pngData()
    }
}

/// Asked, and never answers — a page whose media is genuinely outstanding.
private struct SilentFetcher: ImageFetching {
    func fetchImageData(for url: URL) async throws -> Data {
        try await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
        return Data()
    }
}
