import CoreContracts
import CoreModels
import FeedInterface
import MediaPlayback
import PostGrid
import MediaCore
import UIKit

/// A `ForYouGridPage` over an arbitrary set of post ids, vended across the
/// feature seam.
///
/// # Why this is thin
///
/// Everything it does already existed. `ForYouGridPage` is the component both
/// For You tabs are — one type, two styles — and `PlaceProfileViewController`
/// already drives it over a fixed id set with `render(.content(posts))` and no
/// `ForYouViewModel` anywhere. The hydration is the same one the place profile
/// runs: a fixed-set provider through `ForYouRepository`, then one batched
/// counter read, so every member is a cache hit against what the feed already
/// holds.
///
/// ⚠️ IT PLAYS, AND IT DID NOT. `ForYouGridPage` takes an optional
/// `VideoPlaybackController`, and this passed `nil` on the argument that the
/// player pool is app-wide, that its budget is the tightest thing the hero
/// suite measures, and that one tab of a pushed screen is not where the
/// remaining loans belong.
///
/// That was the wrong trade to make quietly. These pages ARE For You's tabs:
/// a viewer scrolling search results reads the same rows they read on the feed,
/// and clips that stay frozen there make the surface look broken rather than
/// frugal. The pool is handed over now, and the page's own autoplay reconcile —
/// the same one For You runs, with the same fling gate and the same visibility
/// rules — decides what plays.
///
/// ⚠️ WHAT THIS COSTS IS REAL AND IS NOT PAID HERE. The pool is shared, and
/// `HeroSoak`'s `players<=6` is already red on develop for reasons that predate
/// this screen (the profile gallery holds loans for a tab nobody opened). Two
/// more grids that can borrow makes a tight budget tighter. The honest position
/// is that the surface should behave like the feed and the pool accounting is a
/// separate, already-open problem — not that this screen should be the one to
/// go without.
@MainActor
final class PostSetSurfaceViewController: UIViewController, PostSetSurface {
    var viewController: UIViewController { self }

    private let page: ForYouGridPage
    private let hydrate: ([PostID]) async -> [GalleryPost]
    private var loadTask: Task<Void, Never>?
    /// The ids currently on screen, so an identical re-show is not a re-fetch.
    private var shownIDs: [PostID] = []

    /// Opens a post WITH a flight. Supplied by the builder, which owns the
    /// snap feed and the transition — the same closure the place profile is
    /// handed, and for the same reason: this file describes a departure, and
    /// something else knows how to fly from one.
    var openPost: ((UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void)?

    /// How many posts follow the tapped one into the feed. The place profile's
    /// number, because this is the same kind of doorway: enough to page
    /// through without a fetch, not so many that the seed costs more than the
    /// open saves.
    private static let seedWindow = 12

    init(
        style: PostSetSurfaceStyle,
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?,
        hydrate: @escaping ([PostID]) async -> [GalleryPost]
    ) {
        page = ForYouGridPage(
            imagePipeline: imagePipeline,
            style: style == .gallery ? .grid : .list,
            videoPlayback: videoPlayback
        )
        self.hydrate = hydrate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        page.onItemTapped = { [weak self] index in self?.openTile(at: index) }
    }

    /// The departure, described for the flight machinery.
    ///
    /// ⚠️ THIS IS `PlaceProfileViewController.openTile` WITH THE PLACE TAKEN
    /// OUT, deliberately and almost line for line. That screen is the other
    /// host of these two pages over a fixed set of posts, and every awkward
    /// answer in here was measured there: the card's style is ASKED of the page
    /// rather than assumed to be a tile (a list row's cover is a wide row, not
    /// a square), and the card takes off PLAYING by joining the row's own
    /// surface, because a row under the finger that tapped it is already a
    /// moving picture and carrying the still turns it into a photograph for the
    /// length of the opening.
    ///
    /// ⚠️ THE HANDOFF OPENS BEFORE THE FLIGHT, not after. It stops the page's
    /// own reconcile from starting or stopping the tapped post's player while
    /// that player is in the air — the grid is about to be covered, and its
    /// slots are what the feed needs.
    ///
    /// What is deliberately NOT copied is the place profile's text-post window
    /// and its `tileDeparture` bookkeeping. The window is a caption growing
    /// into a page; it would transfer, since these are the same rows, but it is
    /// a second flight family and this change is about the first one arriving
    /// at all. A text row keeps the plain push here — the honest floor, and
    /// written down so it reads as a choice rather than an omission.
    private func openTile(at index: Int) {
        let posts = page.posts
        guard posts.indices.contains(index), let openPost else { return }
        let tapped = posts[index]
        let stream = Array(posts[index...].prefix(Self.seedWindow))
        let hero = page.hero(for: tapped.id, in: view)
        let appearance = page.heroAppearance(for: tapped.id)

        page.beginPlaybackHandoff(of: tapped.id)

        let origin = SnapFeedHeroOrigin(
            post: tapped,
            stream: stream,
            hasHero: hero != nil,
            cover: appearance?.cover,
            style: appearance?.style == .listMedia ? .listMedia : .tile,
            frame: { [weak page] space in page?.hero(for: tapped.id, in: space)?.frame },
            isOnScreen: { [weak page] in page?.isPostVisible(tapped.id) ?? false },
            setConcealed: { [weak page] concealed in
                page?.setHeroHidden(concealed, for: tapped.id)
            },
            donateLiveMedia: { [weak page] in page?.liveFlightSurface(for: tapped.id) },
            opensComments: false,
            depthView: { [weak page] in page },
            textReveal: nil
        )
        openPost(self, origin, stream.map(\.id))
    }

    #if DEBUG
    /// `-search-open-post <index>` taps a tile, which is the only way to reach
    /// the flight offline — the simulator injects no touches. It goes through
    /// `openTile` rather than the opener directly, because everything worth
    /// checking (the handoff, the hero rect, the card's style) is decided in
    /// there.
    private func openTileForQAIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-search-open-post"),
              position + 1 < arguments.count,
              let index = Int(arguments[position + 1]),
              !didOpenForQA
        else { return }
        didOpenForQA = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.openTile(at: index)
        }
    }

    /// ⚠️ ONCE. `show` is called on every republication and BOTH post tabs get
    /// it, so an unguarded hook would stage a flight per call and per tab.
    private var didOpenForQA = false
    #endif

    /// ⚠️ THE PAGE PLAYS NOTHING UNTIL IT IS TOLD IT IS VISIBLE, and handing it
    /// the pool is not that. `ForYouGridPage` gates its whole autoplay
    /// reconcile behind `setAutoplayActive` — measured before this existed: the
    /// grids had the pool, sat on screen, and every clip was a still, because
    /// nothing had ever said they were being looked at. For You drives the same
    /// call from its own appearance and from its pager's settle, and only for
    /// the page at the active index.
    func setPlaybackActive(_ active: Bool) {
        loadViewIfNeeded()
        isPlaybackActive = active
        page.setAutoplayActive(active)
    }

    /// ⚠️ REMEMBERED, BECAUSE VISIBILITY ARRIVES BEFORE THE CONTENT DOES.
    /// The screen appears, says "you are the visible tab", and at that moment
    /// this page has no posts — the answer is still being hydrated. Measured:
    ///
    ///     [autoplay-probe] active=true posts=0 videos=0
    ///
    /// `setAutoplayActive(true)` on an empty page reconciles nothing and is
    /// never asked again, so every clip stayed a still on a screen that had
    /// been told twice over that it was visible. The flag is kept and
    /// re-asserted the moment there is something to reconcile.
    private var isPlaybackActive = false

    func show(_ state: PostSetSurfaceState) {
        loadViewIfNeeded()
        switch state {
        case .loading:
            shownIDs = []
            page.render(.loading)

        case .posts(let ids):
            #if DEBUG
            openTileForQAIfRequested()
            #endif
            // ⚠️ AN IDENTICAL SET IS NOT A RELOAD. Both post tabs are shown the
            // same answer, and the screen re-publishes whenever anything about
            // it changes — without this, one search would hydrate the same ids
            // four times over.
            guard ids != shownIDs else { return }
            shownIDs = ids
            guard !ids.isEmpty else {
                page.render(.content([]))
                return
            }
            page.render(.loading)
            loadTask?.cancel()
            loadTask = Task { [weak self] in
                guard let self else { return }
                let posts = await self.hydrate(ids)
                guard !Task.isCancelled, self.shownIDs == ids else { return }
                // ⚠️ RE-ORDERED BACK INTO THE ANSWER'S ORDER. The hydration
                // reads a timeline, which returns what it returns; the ranking
                // the viewer picked lives in the id list, and handing the page
                // the provider's order would quietly replace their sort.
                let byID = Dictionary(posts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.page.render(.content(ids.compactMap { byID[$0] }))
                // ⚠️ RE-ASSERTED AFTER THE RENDER. See `isPlaybackActive`.
                // ⚠️ AFTER A LAYOUT PASS, not just after the snapshot. The
                // page's autoplay reconcile asks the collection view which
                // cells are VISIBLE, and a snapshot applied this turn has none
                // until the next pass. Measured, straight after the apply:
                //
                //     straightAfterSnapshot visible=0
                //     afterLayoutIfNeeded   visible=2
                //
                // So `setAutoplayActive(true)` here would walk an empty list
                // over a page holding 71 posts, 23 of them video. The layout
                // and the hop are what turn a correct call into an effective
                // one.
                guard self.isPlaybackActive else { return }
                self.page.layoutIfNeeded()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isPlaybackActive else { return }
                    self.page.setAutoplayActive(true)
                }
            }

        case .empty(let message):
            shownIDs = []
            loadTask?.cancel()
            page.render(.content([]))
            _ = message

        case .failed(let message):
            shownIDs = []
            loadTask?.cancel()
            page.render(.failed(message: message))
        }
    }
}
