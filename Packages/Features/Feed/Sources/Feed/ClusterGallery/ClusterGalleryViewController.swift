import CoreModels
import CoreNavigation
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The place gallery that sits BENEATH a semantic-cluster feed (Case B of the
/// cluster-gallery milestone): tapping a City/Country/Region cluster on the
/// map lands on the snap feed with this screen already on the stack under it,
/// and a downward grab on the feed morphs the active post into its tile here.
///
/// It is an ordinary navigation citizen on purpose — plain title ("Paris •
/// City Cluster"), tab bar visible, native edge-pop back to the map — because
/// every special behaviour of the flow lives in the TRANSITIONS, not in the
/// screen: the two-VC stack insertion is the map's, the vertical morph is the
/// zoom stack's, and this type only has to host a grid and answer the
/// `ZoomTransitionSource` questions about it.
///
/// Hosts a `ForYouGridPage` rather than its own collection view: the grid,
/// its skeletons, its hero geometry, its playback pooling and its freeze
/// mechanics are exactly the For You page's, and a second implementation
/// would drift. The page renders this screen's corpus — the cluster's
/// members, hydrated once and ranked by `DiscoverySource.trending`
/// (client-side, over the members only — there is still no ranking RPC, see
/// `dev/BACKEND_GAPS.md` §14/§18).
final class ClusterGalleryViewController: UIViewController {
    private let page: ForYouGridPage
    private let postIDs: [PostID]
    private let loadPosts: () async throws -> [GalleryPost]
    /// Opens a tapped tile's post over this gallery — wired by the builder to
    /// `presentSnapFeedHero`, so a gallery-opened post gets the full hero
    /// pair (flight up, grab back to this very tile) with no new machinery.
    private let openPost: (UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void

    /// The post the OVERLYING feed is currently showing — the landing anchor
    /// for a dismissal into this gallery. Injected (weakly, by the builder)
    /// so this screen never has to know what a feed is.
    var activePostID: (() -> PostID?)?

    /// The header's follow-this-place toggle, when the caller's subject has a
    /// followable identity (`ClusterGalleryFollowing`); nil hides the button.
    private let following: ClusterGalleryFollowing?
    private let followButton = UIButton(configuration: .plain())

    /// The tile a dismissal is currently flying to. Starts at the cluster's
    /// representative (the feed's first post) and re-points to whatever the
    /// feed settled on when a dismissal stages.
    private var anchorID: PostID
    private var loadTask: Task<Void, Never>?

    /// How many posts seed a feed opened from a gallery tile — the same
    /// window (and the same reason) as For You's.
    private static let seedWindow = 40

    init(
        postIDs: [PostID],
        imagePipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?,
        following: ClusterGalleryFollowing? = nil,
        loadPosts: @escaping () async throws -> [GalleryPost],
        openPost: @escaping (UIViewController, SnapFeedHeroOrigin, [PostID]) -> Void
    ) {
        self.postIDs = postIDs
        self.following = following
        self.loadPosts = loadPosts
        self.openPost = openPost
        self.anchorID = postIDs.first ?? PostID("")
        self.page = ForYouGridPage(
            imagePipeline: imagePipeline, style: .grid, videoPlayback: videoPlayback
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        page.render(.loading)
        page.onItemTapped = { [weak self] index in self?.openTile(at: index) }
        configureFollowButton()
    }

    /// The header's trailing item: heart + "Follow" flipping to filled heart
    /// + "Following". A custom view rather than a plain `UIBarButtonItem`
    /// because the design pairs the icon WITH a label, and a bar item shows
    /// one or the other.
    private func configureFollowButton() {
        guard let following else { return }
        var configuration = UIButton.Configuration.plain()
        configuration.imagePadding = 4
        configuration.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        followButton.configuration = configuration
        // The bar squeezes a custom view before it truncates the TITLE; let
        // the long nav title give way instead — "Following" must never wrap
        // into "Follow-ing".
        followButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        followButton.titleLabel?.numberOfLines = 1
        followButton.addAction(UIAction { [weak self] _ in
            guard let self, let following = self.following else { return }
            self.renderFollowState(following.toggle())
        }, for: .primaryActionTriggered)
        renderFollowState(following.isFollowing())
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: followButton)
    }

    /// One place decides both states' looks, so they can't drift: outline
    /// heart + tinted "Follow" against filled heart + neutral "Following"
    /// (the resting state whispers; the call to action doesn't).
    private func renderFollowState(_ isFollowing: Bool) {
        guard var configuration = followButton.configuration else { return }
        configuration.image = UIImage(systemName: isFollowing ? "heart.fill" : "heart")
        var title = AttributedString(isFollowing ? "Following" : "Follow")
        title.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .semibold
        )
        configuration.attributedTitle = title
        configuration.baseForegroundColor = isFollowing ? .secondaryLabel : .tintColor
        followButton.configuration = configuration
        followButton.accessibilityLabel = isFollowing ? "Unfollow this place" : "Follow this place"
    }

    /// Starts the one hydration this screen ever does. Called by the builder
    /// at CREATION, not on first appearance: the gallery spends its early
    /// life invisible beneath the feed (the two-VC insertion never even loads
    /// a mid-stack view), and the first thing anyone sees of it is the
    /// landing of a dismissal — which must find tiles, not a skeleton.
    /// Idempotent; re-entry is a no-op.
    func beginLoading() {
        guard loadTask == nil else { return }
        loadViewIfNeeded()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let posts = Self.ranked(try await loadPosts())
                guard !Task.isCancelled else { return }
                page.render(posts.isEmpty
                    ? .empty(.init(title: "No posts here yet"))
                    : .content(posts))
            } catch {
                guard !Task.isCancelled else { return }
                // The members were already open in the feed above, so a failed
                // hydration here is almost certainly transient — say so
                // plainly rather than rendering a dead end.
                page.render(.failed(message: "Couldn't load this place's posts."))
            }
        }
    }

    /// The gallery's default order: POPULARITY descending — the place
    /// profile leads with what the place is known for, not what happened
    /// last. `DiscoverySource.trending`'s rule verbatim (reactions, then
    /// recency, then id, so ties are stable), applied HERE rather than in
    /// the builder so the screen owns its own ordering contract. Client-side
    /// because no ranking RPC exists (`dev/BACKEND_GAPS.md` §14/§18); it
    /// matches the map above by construction — the cluster's pin wears its
    /// most-liked member's face, which is this grid's first tile.
    static func ranked(_ posts: [GalleryPost]) -> [GalleryPost] {
        DiscoverySource.trending.ordering(posts)
    }

    /// What the grid currently shows, in its rendered order — for the tests
    /// that pin the popularity ranking without reaching into the page.
    var renderedPosts: [GalleryPost] { page.posts }

    private func openTile(at index: Int) {
        let posts = page.posts
        guard posts.indices.contains(index) else { return }
        let tapped = posts[index]
        let stream = Array(posts[index...].prefix(Self.seedWindow))
        let hero = page.hero(for: tapped.id, in: view)
        let appearance = page.heroAppearance(for: tapped.id)
        let origin = SnapFeedHeroOrigin(
            post: tapped,
            stream: stream,
            hasHero: hero != nil,
            cover: appearance?.cover,
            style: .tile,
            frame: { [weak page] space in page?.hero(for: tapped.id, in: space)?.frame },
            isOnScreen: { [weak page] in page?.isPostVisible(tapped.id) ?? false },
            setConcealed: { [weak page] concealed in
                page?.setHeroHidden(concealed, for: tapped.id)
            },
            depthView: { [weak page] in page }
        )
        openPost(self, origin, stream.map(\.id))
    }
}

// MARK: - The landing side of the cluster feed's vertical grab

extension ClusterGalleryViewController: ZoomTransitionSource {
    /// The grid recedes; the navigation title stays grounded.
    var zoomPresenterDepthView: UIView? { page }

    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect {
        guard let hero = page.hero(for: anchorID, in: container) else {
            return ZoomTransitionGeometry.centeredFallback(in: container.bounds, side: 96)
        }
        return hero.frame
    }

    var zoomSourceIsOnScreen: Bool {
        page.isPostVisible(anchorID)
    }

    func makeZoomFlightCard() -> any ZoomFlightCard {
        let appearance = page.heroAppearance(for: anchorID)
        return PostGridFlightCard(
            post: page.post(for: anchorID) ?? Self.placeholder(id: anchorID),
            cover: appearance?.cover,
            style: appearance?.style ?? .tile
        )
    }

    func setZoomSourceHidden(_ hidden: Bool) {
        page.setHeroHidden(hidden, for: anchorID)
        if !hidden {
            page.endHeroFreeze()
        }
    }

    /// Re-anchor on the post the feed settled on and BRING ITS TILE INTO
    /// VIEW. The opposite scrolling rule from `ForYouGridZoomSource` (which
    /// pins the departure tile and adopts the post into it), and
    /// deliberately: this grid has never been seen when the first dismissal
    /// stages — the viewer arrived from a map pin, not from a tile — so
    /// there is no departure context to preserve and the honest landing is
    /// the post's own place in the ranking.
    func zoomSourceWillStageDismissal() {
        page.beginHeroFreeze()
        if let active = activePostID?(), page.post(for: active) != nil {
            anchorID = active
        }
        page.revealPost(anchorID)
        // Visible for the whole return: the card is landing ON this tile.
        page.setHeroHidden(true, for: anchorID, conceals: false)
    }

    var zoomLandingMediaIsReady: Bool {
        page.isLandingPlaybackReady(for: anchorID)
    }

    func zoomFinalizeLanding() {
        page.finalizeLandingLayout(for: anchorID)
    }

    func zoomAdoptLiveMediaView(_ view: UIView) {
        guard let view = view as? VideoRenderView else { return }
        page.adoptLivePlayback(view, for: anchorID)
    }

    /// A landing post the grid does not hold (hydration raced the grab, or
    /// the feed paged past the members somehow) still needs a card to fly —
    /// a plain dark square, which is what a missing cover renders as anyway.
    private static func placeholder(id: PostID) -> GalleryPost {
        GalleryPost(
            id: id, kind: .photo, isRepost: false, thumbnailURL: nil,
            caption: "", publishedAtMS: 0
        )
    }
}
