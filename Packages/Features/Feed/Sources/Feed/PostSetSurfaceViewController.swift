import CoreContracts
import CoreModels
import FeedInterface
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
/// ⚠️ NO VIDEO PLAYBACK. `ForYouGridPage` takes an optional
/// `VideoPlaybackController` and this passes none. The pool is app-wide, its
/// budget is the tightest thing the hero suite measures, and a surface that is
/// one tab of a pushed screen is not where the remaining loans belong. Posts
/// render their posters here — which is also what a search result is: a thing
/// to recognise and open, not a thing to watch in place.
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
        hydrate: @escaping ([PostID]) async -> [GalleryPost]
    ) {
        page = ForYouGridPage(
            imagePipeline: imagePipeline,
            style: style == .gallery ? .grid : .list,
            videoPlayback: nil
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
