import CoreModels
import EmoteKit
import MediaCore
import MediaPlayback
import PostSurfaces
import UIKit

/// What the full-screen feed's warm planner asks of its screen (#2514): the
/// pages and their models, the comment streams, the picture pipeline, whether
/// the feed is watched, and the text pages' interfaces kept warm.
@MainActor
protocol SnapWarmPlannerHost: AnyObject {
    var orderedIDs: [PostID] { get }
    var modelsByID: [PostID: FeedItemDisplayModel] { get }
    var viewModel: FeedViewModel { get }
    var imagePipeline: ImagePipeline { get }
    var isOnScreen: Bool { get }
    var soundPlayback: SnapSoundPlayback { get }
    /// The text pages' interfaces kept warm (`SnapCommentsCoordinator`).
    var restingWarm: SnapWarmSlots<PostID, UIViewController> { get }
    func isPageReady(_ index: Int) -> Bool
    func prewarmRestingComments(for id: PostID)
    func lifecycleCell(at index: Int) -> SnapCellLifecycle?
}

/// The full-screen feed's warm planner (#2514): what is made ready around the
/// page the viewer settled on — the comment streams, the players and the
/// video lookahead, the pictures, the neighbouring text pages' interfaces and
/// the next captions' emotes — and what is let go while the feed is not
/// watched.
///
/// WHICH pages is `SnapWarmWindow`'s (pure, tested on its own); the
/// lookaheads are MediaPlayback's and MediaCore's (`VideoLookahead`,
/// `ImageLookahead`, `VerticalLookaheadPlan`). This decides when to ask them,
/// and for what.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: every entry point runs in the caller's
/// turn, where the screen called it before — the settle
/// (`warmSettledWindow`), UIKit's prefetch, a visibility change.
@MainActor
final class SnapWarmPlanner {
    private unowned let host: any SnapWarmPlannerHost
    private let videoPlayback: VideoPlaybackController?
    /// The next captions' emotes, warmed at each settle (#1504).
    private let emotePrefetch = EmotePrefetch()

    init(host: any SnapWarmPlannerHost, videoPlayback: VideoPlaybackController?) {
        self.host = host
        self.videoPlayback = videoPlayback
    }

    /// Follows the feed's visibility, at each change (`refreshVisibility`).
    func followVisibility(isWatched: Bool) {
        // Off screen, nothing is planned ahead: the warmed and kept players go
        // back and every head preload is cancelled. The next activation plans
        // again (`warmSettledWindow`).
        if !isWatched {
            videoLookahead?.stop()
            emotePrefetch.cancelAll()
            // The stay's pictures too: what only this feed wanted is cancelled.
            imageLookahead?.revoke()
            imageLookahead = nil
        } else if let pending = pendingImagePlan {
            // Shown: the plan a settle made off screen starts this stay.
            applyImagePlan(pending)
        }
    }

    /// Everything a page needs that is NOT its player or its pictures: the
    /// comment stream to fetch. The pictures are the settle's image lookahead
    /// (`warmImages`, #970).
    ///
    /// Cheap, and what a viewer notices missing — a page that snaps in and
    /// then fills itself in reads as a stutter even when no frame was dropped.
    func warmContent(at items: [Int]) {
        let ids = items.compactMap { host.orderedIDs.indices.contains($0) ? host.orderedIDs[$0] : nil }
        // Loaded before the page scrolls in, so its band enters the viewport
        // already streaming (subtitles still wait for settle — their gate is
        // activation, not content).
        for id in ids where host.modelsByID[id] != nil {
            host.viewModel.ensureCommentStreams(for: id)
        }
    }

    /// The players, kept to the immediate neighbours — see `SnapWarmWindow`.
    ///
    /// Deliberately a narrower window than the content's: a player holds a
    /// decoder and the platform caps how many can render at once, so this is
    /// the one warm that has to stay stingy.
    func warmPlayers(at items: [Int]) {
        // Data saver on cellular: upcoming videos aren't loaded ahead (#409).
        guard MediaPlaybackPolicy.preloads else { return }
        for item in items where host.orderedIDs.indices.contains(item) {
            guard let model = host.modelsByID[host.orderedIDs[item]],
                  model.mediaKind == .video, let url = model.mediaURL else { continue }
            videoPlayback?.preroll(url)
        }
    }

    /// The video around the settled page (#895): with the byte cache, the
    /// lookahead warms +1's player, preloads the head ranges of +2 and +3 to
    /// disk once the playing clip has buffered enough, and keeps −1's player
    /// (`VideoLookahead`). A pool without a byte cache (tests) only prerolls
    /// the neighbours, as before.
    private func warmVideo(around active: Int, speculative: [String: VideoLookahead.SpeculativeRequest] = [:]) {
        guard let videoLookahead else {
            warmPlayers(at: SnapWarmWindow.players(around: active, count: host.orderedIDs.count))
            return
        }
        guard host.orderedIDs.indices.contains(active) else { return }
        let window = SnapWarmWindow.videoLookahead(around: active, count: host.orderedIDs.count)
        videoLookahead.update(
            page: host.orderedIDs[active].rawValue,
            playing: lookaheadItem(at: active),
            ahead: window.ahead.map(lookaheadItem(at:)),
            behind: window.behind.flatMap(lookaheadItem(at:)),
            // Data saver on cellular: nothing loads ahead of the viewer (#409).
            allowsPreload: MediaPlaybackPolicy.preloads,
            // +2/+3's pictures, to disk: under the video's page owner and
            // gate, cancelled with its head ranges on a swipe (#970).
            speculative: speculative
        )
    }

    /// The pictures around the settled page (#970, `VerticalLookaheadPlan`):
    /// the page, −1, +1 and +2 decoded at screen size under this stay's owner
    /// (P1); +3 returned as a speculative request for the video lookahead to
    /// start once the playing clip has buffered enough, bytes to disk only
    /// (P2). Depth follows the coordinator's policy. A text page has no
    /// picture to fetch: it is data only.
    ///
    /// The owner is made on the feed's first visibility, never by a settle
    /// that lands off screen (data arriving under a covering screen): that
    /// plan waits in `pendingImagePlan` and is applied when the feed shows.
    ///
    /// ⚠️ THE POSTER IS THE PICTURE of a video page: it falls back on it
    /// whenever it is not decoding — before its first frame and after its
    /// last — so an uncached poster is a black page until an async hop lands
    /// it (measured ~350ms of black on arrival, ~150ms with it warmed).
    private func warmImages(around active: Int) -> [String: VideoLookahead.SpeculativeRequest] {
        let depth = host.imagePipeline.prefetchPolicy.videoPreloadDepth
        let reach = (active - 1)...(active + max(depth, 1))
        let pages: [[ImageRequest]] = host.orderedIDs.indices.map { reach.contains($0) ? lookaheadImages(at: $0) : [] }
        let plan = VerticalLookaheadPlan.images(around: active, pages: pages, depth: depth)
        applyImagePlan(plan.display)
        let pipeline = host.imagePipeline
        var speculative: [String: VideoLookahead.SpeculativeRequest] = [:]
        for request in plan.preload {
            speculative["image:\(request.url.absoluteString)"] = { owner in
                pipeline.prefetch(request.url, size: request.size, window: .preload, owner: owner)
            }
        }
        return speculative
    }

    /// What a page's cell asks the pipeline for: a photo page's photo, a
    /// video page's poster, and the author's face; nothing for a text page.
    private func lookaheadImages(at index: Int) -> [ImageRequest] {
        guard host.orderedIDs.indices.contains(index), let model = host.modelsByID[host.orderedIDs[index]] else { return [] }
        let picture: URL? = model.mediaKind == .video ? model.thumbnailURL : model.mediaURL
        guard let picture else { return [] }
        return [picture, model.avatarURL].compactMap(\.self).map { ImageRequest(url: $0) }
    }

    /// The decoded pictures' lookahead for this stay on screen; dropped (its
    /// owner revoked) when the feed leaves it.
    private var imageLookahead: ImageLookahead?
    /// The last plan made while the feed was off screen, for its next stay.
    private var pendingImagePlan: [ImageRequest]?

    /// Decodes `display` under this stay's owner, made here on first
    /// visibility; off screen, the plan only waits for the next stay.
    private func applyImagePlan(_ display: [ImageRequest]) {
        guard host.isOnScreen && host.soundPlayback.isForeground else {
            pendingImagePlan = display
            return
        }
        pendingImagePlan = nil
        let lookahead = imageLookahead ?? ImageLookahead(pipeline: host.imagePipeline, name: "snap-feed.images")
        imageLookahead = lookahead
        lookahead.update(display: display, preload: [])
    }

    /// A single-video page's clip, under the post it plays for — the scope
    /// its cell plays it with. Galleries warm their own pages.
    private func lookaheadItem(at index: Int) -> VideoLookaheadItem? {
        guard host.orderedIDs.indices.contains(index), let model = host.modelsByID[host.orderedIDs[index]],
              model.mediaKind == .video, let url = model.mediaURL else { return nil }
        return VideoLookaheadItem(url: url, scope: host.orderedIDs[index].rawValue)
    }

    /// The vertical feed's video lookahead; nil when the pool has no byte cache.
    private lazy var videoLookahead: VideoLookahead? = videoPlayback?.makeLookahead(name: "snap-feed")

    /// ⚠️ A DEFINED WINDOW AROUND THE PAGE THE VIEWER SETTLED ON.
    ///
    /// `UICollectionViewDataSourcePrefetching` is UIKit's guess, made from
    /// scroll velocity: it warms nothing at all while the pager is at rest, and
    /// what it warms during a fling is whatever its heuristic reached. A feed
    /// whose whole promise is that the next page is INSTANT cannot be built on
    /// a guess — after every settle the window is stated outright, so the pages
    /// either side are ready whether the viewer arrived by flick, by tap, or by
    /// sitting still for a minute first.
    ///
    /// Kept alongside the prefetch callback rather than replacing it: UIKit's
    /// guess is genuinely good DURING a fast scroll, where it runs ahead of the
    /// settles. The two overlap, and both are idempotent.
    func warmSettledWindow(around active: Int) {
        let count = host.orderedIDs.count
        let content = SnapWarmWindow.content(around: active, count: count)
        warmContent(at: content)
        warmVideo(around: active, speculative: warmImages(around: active))
        // ⚠️ AND THE NEIGHBOURING TEXT PAGES' INTERFACE, the one page whose
        // content is a whole view controller rather than an image: the page
        // immediately ahead AND the one behind, now that the feed pages back
        // (#2059). Two view controllers' memory, no more — the pages past
        // them are a guess, and what left the window is let go first.
        // The page being landed on stays in the window: its warm is mounted
        // after this. A page whose panel is anywhere already — warm, preview,
        // or the page just left still holding it — is never built twice.
        let window = [active - 1, active, active + 1].filter { host.orderedIDs.indices.contains($0) }
        host.restingWarm.keep(only: Set(window.map { host.orderedIDs[$0] }))
        for index in [active + 1, active - 1] where host.orderedIDs.indices.contains(index) && !host.isPageReady(index) {
            host.prewarmRestingComments(for: host.orderedIDs[index])
        }
        warmCaptionEmotes(around: active)
        #if DEBUG
        // What the settle actually warmed. The window itself is pure and tested
        // on its own; this is how a test reaches the WIRING — that the settle
        // asks at all, and asks about the page it settled on.
        debugLastWarmedWindow = content
        #endif
    }

    #if DEBUG
    private(set) var debugLastWarmedWindow: [Int] = []
    #endif

    /// ⚠️ THE NEXT CAPTIONS' EMOTES, BEFORE THEY ARRIVE (#1504): the two pages
    /// ahead of the settled one and the one behind it (#2059), warmed at the
    /// bucket the caption on screen
    /// draws at, so a caption swiped in installs its emotes at once — no
    /// skeleton. What leaves the window is let go.
    private func warmCaptionEmotes(around active: Int) {
        guard let side = (host.lifecycleCell(at: active) as? SnapFeedCell)?.captionEmotePixelSide else { return }
        // And the one behind: the feed pages back (#2059).
        let window = [active - 1, active + 1, active + 2]
        let captions = window.compactMap { index -> String? in
            guard host.orderedIDs.indices.contains(index) else { return nil }
            return host.modelsByID[host.orderedIDs[index]]?.caption
        }
        emotePrefetch.warm(captions, pixelSide: side)
    }
}
