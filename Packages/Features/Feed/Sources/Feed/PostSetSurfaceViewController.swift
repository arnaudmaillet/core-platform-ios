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

    var onOpenPost: ((PostID) -> Void)?

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
        page.onItemTapped = { [weak self] index in
            guard let self, self.page.posts.indices.contains(index) else { return }
            self.onOpenPost?(self.page.posts[index].id)
        }
    }

    func show(_ state: PostSetSurfaceState) {
        loadViewIfNeeded()
        switch state {
        case .loading:
            shownIDs = []
            page.render(.loading)

        case .posts(let ids):
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
