import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// One format page of the For You pager: a **real scrolling** collection view
/// over the shared `PostGrid` layouts.
///
/// ⚠️ THE ONE GRID FOR EVERY MEDIA TILE (epic #1269): For You's own page, and —
/// vended through `PostGridPage` — the profile's pages and media gallery
/// (#1273), the Discover gallery, search, the lists and the place page. A
/// host under a floating header hosts it (`setHostedInsets`).
/// Lets a layout built in `init` ask the page that owns it a question, without
/// either holding the other alive. See `ForYouGridPage.init`.
@MainActor
private final class WeakPageBox {
    weak var page: ForYouGridPage?
}

final class ForYouGridPage: UIView {
    /// A long press on a list card OFF its media does nothing (#1377): no
    /// lift (the configuration refuses it) — and no open on release either,
    /// which the card's tap would otherwise make of it. This hold begins
    /// there and only there, and its beginning cancels the card's touches;
    /// a control (the action row's buttons and their own hold) keeps its
    /// press.
    private lazy var offMediaHold: UILongPressGestureRecognizer = {
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(swallowHold))
        offMediaHoldGate.page = self
        hold.delegate = offMediaHoldGate
        return hold
    }()

    private let offMediaHoldGate = OffMediaHoldGate()

    /// The saved-posts pile, the app's one, shared with the post page and the
    /// profile's Saved tab — see `PostBookmarkStore`. Nil where no pile exists
    /// (a host that says so, #1273): the save control is then not drawn.
    private let bookmarks: PostBookmarkStore?

    /// The viewer asked to repost. UNSET today — there is no client path that
    /// publishes a repost yet — so no card draws the control (#801): see the
    /// note at the wiring site.
    var onRepostRequested: ((GalleryPost) -> Void)?

    /// What a card's repost control does for `post`: nil — which hides the
    /// control — while nothing handles a repost (#801).
    func repostHandler(for post: GalleryPost) -> (() -> Void)? {
        guard onRepostRequested != nil else { return nil }
        return { [weak self] in self?.onRepostRequested?(post) }
    }

    /// The page's fixed shape, chosen by its format at init.
    enum Style {
        case grid
        case list
        /// For You's Discover: the list's cards with pieces of the mosaic set
        /// between them — see `MosaicChunkPlanner` for where they go and what
        /// they hold, `DiscoverListLayout` for how they are drawn.
        ///
        /// A card and a tile on ONE page, so every question the other two
        /// styles answer once for the page ("does this autoplay", "can a hero
        /// land here", "what does a landing conceal") is answered here per
        /// POST, by whether it sits in a chunk — see `drawsAsTile`.
        case discover
    }

    /// Discover's "View all" under a chunk was pressed: show the whole mosaic.
    var onViewAllTapped: (() -> Void)?

    /// The tapped item's index into `posts`.
    var onItemTapped: ((Int) -> Void)?

    /// The same open, with the comments already engaged — see
    /// `PostGridListRowCell.onCommentsTapped`.
    ///
    /// ⚠️ FALLS BACK TO `onItemTapped` when unset, and that is not politeness.
    /// The chip is drawn by the cell on every screen this page appears on; a
    /// host that has not wired the shorter route must still get the ordinary
    /// one, or the count becomes a control that does nothing on exactly the
    /// screens nobody thought about.
    var onItemCommentsTapped: ((Int) -> Void)?

    /// What the cards' like chips stake with — nil leaves the chip a counter
    /// (a host with no wallet, a test). Shared by every row this page draws.
    ///
    /// The COMPACT cards — the mosaic's tiles (a chunk's, the gallery's) and
    /// the paired half-width cards — read it too, for their heart's colour,
    /// and never spend through it: their like is a readout
    /// (`PostCardStaking.bindReadout`).
    var staking: PostCardStaking?

    /// Whether this page's MOSAIC tiles wear their post's author and caption
    /// when they are large enough (the rule is `PostTileInfo`). For You's own
    /// surfaces set it — Discover's chunks and the Discover gallery, where the
    /// `-gallery-tile-info` experiment was validated (3 October 2026); every
    /// other grid drawn by this page (a place's, a post set's) keeps its bare
    /// tiles. Paired cards and the list's cards are untouched: they always
    /// have their words.
    var showsTileInfo = false

    /// Whether `postID`'s cell is a MOSAIC tile (not a paired card) on a page
    /// whose tiles wear their words — what the tile, its flight's copy and
    /// its close's stand-in all ask, so the three cannot disagree.
    private func tileWearsInfo(_ postID: PostID) -> Bool {
        showsTileInfo && drawsAsTile(postID) && !drawsAsPairedCard(postID)
    }

    /// What the viewer has staked on `postID` — what a compact card's heart
    /// is drawn with, and a copy of that card (a flight's, a close's
    /// stand-in) with it, so nothing changes colour in the landing frame.
    func viewerStake(on postID: PostID) -> Int {
        staking?.viewerStake(on: postID) ?? 0
    }

    /// The posts whose cards are ON SCREEN and worth warming — their first page
    /// of comments, and anything else a host wants ready before a tap.
    ///
    /// ⚠️ IT RIDES THE AUTOPLAY RECONCILE, deliberately, which is what gives it
    /// the fling gate for free. A feed that warms while the viewer is throwing
    /// it spends a request per card it will never show for longer than a
    /// glance; the same argument that stops a player being ATTACHED above
    /// `ForYouGridAutoplayDriver.maximumStartVelocity` stops the warm above
    /// it, and the two can never drift apart because they are one decision.
    var onWarmRequested: (([GalleryPost]) -> Void)?
    /// The page scrolled near its end and wants another page.
    var onNearEnd: (() -> Void)?
    /// A post's cell is about to display: its page, fetched ahead of the
    /// viewer, was shown (#970).
    var onWillDisplayPost: ((PostID) -> Void)?
    var onRefresh: (() -> Void)?
    /// Fired when a drag ends, with how far the page was pulled past its top
    /// — the pull of a page whose host draws the indicator and owns the
    /// threshold (`handPullToHost`).
    var onPullReleased: ((CGFloat) -> Void)?
    /// Where a release comes to rest while a hosted header is on screen, in
    /// the travelled space (`ScrollDetents`). Empty — every host but the
    /// profile — means free (#1273).
    var snapDetents: [CGFloat] = []
    /// Detents a release CROSSING them stops on, whatever its momentum — see
    /// `ScrollDetents.snapped(target:detents:from:catching:)`.
    var catchDetents: [CGFloat] = []
    /// A snap decided at the release with no momentum behind it, which the
    /// scroll view will not carry out on its own — see
    /// `scrollViewDidEndDragging`.
    private var pendingSnap: CGFloat?
    /// The content length the next page was last asked at from a scroll —
    /// see `askNextPageIfNearEnd`.
    private var nextPageAskedAtLength: CGFloat?
    /// A row's author was tapped — its disc, its name or its handle.
    var onAuthorTapped: ((GalleryPost) -> Void)?
    /// What a row's "..." should offer. Asked at press time, per row.
    ///
    /// The page holds no opinion about the answer: which rows exist depends on
    /// what the SCREEN can service (a reporting seam, a social graph), and this
    /// view has neither. It supplies the context and renders whatever comes
    /// back — including nothing, which hides the control.
    var authorMenuActions: ((AuthorMenuContext) -> [PostCardMenuAction])?

    /// Everything a host needs to build one row's menu — the vended page's
    /// own type (`PostGridPage`), so a host across the package line reads the
    /// same context.
    typealias AuthorMenuContext = PostGridAuthorMenuContext

    /// A post was tapped, with its stream — the vended page's tap
    /// (`PostGridPage.onPostTapped`). When set, it answers instead of
    /// `onItemTapped` / `onItemCommentsTapped`.
    var onPostTapped: ((_ post: GalleryPost, _ stream: [GalleryPost], _ comments: Bool) -> Void)?
    /// How many posts a vended page's tap hands on as the stream.
    static let vendedStreamWindow = 30

    /// Display order — the mosaic's arrangement of `rawPosts`. What the cells,
    /// the hero, and a tile tap all read.
    ///
    /// On Discover it is the stretches flattened: each run's cards, then each
    /// chunk's tiles in reading order — which is also the order a tap seeds
    /// the feed with, so paging from a tile runs through the rest of its chunk
    /// and on down the list, exactly as the viewer sees it.
    private(set) var posts: [GalleryPost] = []
    /// The order the view model handed over, kept so an append can be
    /// recognised as one before arrangement permutes it.
    private var rawPosts: [GalleryPost] = []

    /// WHICH posts are new — the pushed Following and Friends lists' "New"
    /// (2026-09-29, re-introduced after #313 dropped it: the product call is
    /// that the list the row's header pushes is divided the way the Messages
    /// inbox is). The page is TOLD this rather than deriving it, so the "New"
    /// header's count and the badge on the For You header the viewer tapped
    /// cannot be two answers to one question — see
    /// `ForYouViewModel.Snapshot.followingNew` / `.friendsUnseen`. Empty on
    /// every other page, which is therefore one plain run.
    private var newPostIDs: Set<PostID> = []

    /// Whether every section of a list wears its title, a lone one included —
    /// the pushed Following and Friends lists (2026-09-30).
    ///
    /// ⚠️ THE INBOX'S "A LONE HEADER IS A LABEL" RULE IS OFF HERE, by product
    /// call. #316 left a list that was all one section untitled, so Friends —
    /// whose posts are usually all seen — showed no header at all while
    /// Following showed two, and the same screen read as two different ones.
    /// With this on, a list with nothing new is "Recent" alone and titled, and
    /// one with nothing but new is "New" alone, counted. Off (every other list
    /// page — a place's Activity) the page is one untitled run unless it has
    /// both halves, as before.
    /// What the older section is called — "Recent" (the inbox's word), or
    /// the caller's: the place page's Popular list names its one run so.
    var earlierSectionTitle = "Recent"

    /// The section the page has scrolled into, named somewhere else — the
    /// ONE tracker for both kinds of titled page: a list's New / Recent /
    /// Popular, named in the pushed lists' bar after the back chevron
    /// (#1378), and Discover's titled groups, the profile's History by day,
    /// named after the bell (#1344) — the Messages inbox's rule (#1301).
    ///
    /// Set, a list's section headers LEAVE as they pin instead of forming
    /// their capsule (`SectionHeaderCapsuleView.hidesWhenPinned`; a group's
    /// always do), and the pinned one is told here — once per change, nil
    /// back at the top.
    var onPinnedSectionChanged: ((PostGridPinnedSection?) -> Void)? {
        didSet {
            guard style == .list, !showsSkeleton else { return schedulePinnedSectionCheck() }
            collectionView.reloadData()
            schedulePinnedSectionCheck()
        }
    }

    /// What `onPinnedSectionChanged` last said.
    private(set) var pinnedSection: PostGridPinnedSection?
    private var pinnedSectionCheckScheduled = false

    /// Re-reads which section is pinned on the next turn — after the layout
    /// has moved the pinned header there (a header's own rule waits one turn
    /// for the same reason, `SectionHeaderPillButton`), and once however many
    /// times a turn asks.
    private func schedulePinnedSectionCheck() {
        guard onPinnedSectionChanged != nil, !pinnedSectionCheckScheduled else { return }
        pinnedSectionCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pinnedSectionCheckScheduled = false
            updatePinnedSection()
        }
    }

    /// The headers' own rule asked once for the page
    /// (`SectionHeaderPillButton.pinnedSection`), on their frames as laid out
    /// now, against the pin line (`pinLine`, which a hosted page moves): a
    /// group's title on Discover, a section's on a list.
    func updatePinnedSection() {
        var next: PostGridPinnedSection?
        if isGrouped, !showsSkeleton {
            let tops = groupFirstSections.map { section -> CGFloat in
                collectionView.layoutAttributesForSupplementaryElement(
                    ofKind: PostGridListLayout.headerElementKind, at: IndexPath(item: 0, section: section)
                )?.frame.minY ?? .greatestFiniteMagnitude
            }
            next = SectionHeaderPillButton.pinnedSection(sectionTops: tops, pinLine: pinLine)
                .map { PostGridPinnedSection(index: $0, title: groupTitles[$0]) }
        } else if style == .list, !showsSkeleton, !posts.isEmpty {
            let current = sections
            let tops: [CGFloat] = current.indices.map { index in
                guard hasHeader(inSection: index), index < collectionView.numberOfSections,
                      let header = collectionView.layoutAttributesForSupplementaryElement(
                          ofKind: PostGridListLayout.headerElementKind, at: IndexPath(item: 0, section: index)
                      ) else { return .greatestFiniteMagnitude }
                return header.frame.minY
            }
            next = SectionHeaderPillButton.pinnedSection(sectionTops: tops, pinLine: pinLine).map { index in
                PostGridPinnedSection(
                    index: index,
                    title: current[index] == .earlier ? earlierSectionTitle : current[index].title,
                    count: current[index] == .new ? newRunLength : 0
                )
            }
        }
        guard next != pinnedSection else { return }
        pinnedSection = next
        onPinnedSectionChanged?(next)
    }

    /// The pin line, in content coordinates: the bar's foot.
    private var pinLine: CGFloat {
        collectionView.contentOffset.y + (pinLineInset ?? collectionView.adjustedContentInset.top)
    }

    /// The pinned section's first post on the pin line — what tapping its
    /// name in the bar means.
    func scrollToPinnedSection(animated: Bool = true) {
        guard let index = pinnedSection?.index else { return }
        scrollToSection(index, animated: animated)
    }

    /// Puts section `index` (a group's index on Discover, a list section's
    /// otherwise) with its first post on the pin line, under the bar.
    func scrollToSection(_ index: Int) {
        scrollToSection(index, animated: true)
    }

    func scrollToSection(_ index: Int, animated: Bool) {
        if isGrouped {
            guard groupFirstSections.indices.contains(index) else { return }
            scrollFirstRowToPinLine(ofSection: groupFirstSections[index], animated: animated)
        } else {
            scrollFirstRowToPinLine(ofSection: index, animated: animated)
        }
    }

    /// ⚠️ A HAND-SET OFFSET, NOT `scrollToItem(.top)` — the inbox's rule
    /// (`scrollFirstRow(ofSection:)`): the header hides as it reaches the
    /// bar, which names it instead, so `.top` would leave the post under the
    /// empty band of a header nobody sees. Clamped for a list too short to
    /// scroll.
    private func scrollFirstRowToPinLine(ofSection index: Int, animated: Bool = true) {
        guard collectionView.numberOfSections > index, collectionView.numberOfItems(inSection: index) > 0 else { return }
        collectionView.layoutIfNeeded()
        guard let row = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: index)) else { return }
        let inset = collectionView.adjustedContentInset
        let furthest = collectionView.contentSize.height + inset.bottom - collectionView.bounds.height
        let target = min(row.frame.minY - (pinLineInset ?? inset.top), furthest)
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: max(-inset.top, target)), animated: animated
        )
    }

    var titlesEverySection = false {
        didSet {
            guard titlesEverySection != oldValue, style == .list, !showsSkeleton else { return }
            collectionView.reloadData()
        }
    }

    /// How many rows lead the list as NEW — the run of arrivals `posts` is
    /// partitioned to start with. Zero on a grid, a skeleton, and a page that
    /// was told of no arrivals.
    private var newRunLength: Int {
        guard style == .list, !showsSkeleton, !newPostIDs.isEmpty else { return 0 }
        return posts.prefix { newPostIDs.contains($0.id) }.count
    }

    /// Where the "New" section ends when the list has BOTH sections, 0 when it
    /// is one section (titled or not) — the number the index mapping needs.
    ///
    /// Read off `posts` rather than stored, because `posts` is kept partitioned
    /// — the arrivals lead it.
    private var split: Int {
        sections.count == 2 ? newRunLength : 0
    }

    /// The sections a list of `total` rows whose first `lead` are new is cut
    /// into. Both halves when both have rows; otherwise the one that does —
    /// "Recent" for an empty list, so there is always one section to draw.
    ///
    /// Untitled lists keep the inbox's rule: a list that would be all one
    /// section is one plain run (`.earlier`, and `hasHeader` says no), since a
    /// lone header there is a label rather than a division.
    private static func sections(lead: Int, total: Int, titled: Bool) -> [Section] {
        if lead > 0, lead < total { return [.new, .earlier] }
        if titled, lead > 0, lead == total { return [.new] }
        return [.earlier]
    }

    /// Everything that decides how many sections there are and how many rows
    /// each holds — what an update compares before promising UIKit that the
    /// shape did not change.
    private struct SectionShape: Equatable {
        let sections: [Section]
        let split: Int
    }

    private var sectionShape: SectionShape {
        SectionShape(sections: sections, split: split)
    }

    #if DEBUG
    /// How many rows the "New" header currently covers — zero when there is
    /// no "New" section — so a test can assert the shape rather than the
    /// contents.
    var debugArrivalsRunLength: Int { sections.first == .new ? newRunLength : 0 }

    /// The section headers laid out right now, top to bottom: the title each
    /// wears and the count after it.
    func debugSectionHeaders() -> [(title: String?, count: Int)] {
        collectionView.visibleSupplementaryViews(ofKind: PostGridListLayout.headerElementKind)
            .compactMap { $0 as? SectionHeaderCapsuleView }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { header in
                (header.debugPill.title, header.debugPill.count)
            }
    }
    #endif

    /// Arrivals first, everything else after, each half keeping the order it
    /// arrived in.
    ///
    /// ⚠️ **This reorders the list, and it has to.** The display order is
    /// whatever the discovery source ranked — Trending puts the most-reacted
    /// posts on top — so the arrivals are scattered through it. A "New" header
    /// over the leading rows would then be over the wrong rows. Sections mean
    /// the list is grouped, and grouping is a reordering; the inbox's lists do
    /// exactly this. Within each half nothing moves, so the ranking still
    /// decides everything it can still decide.
    private func partitioned(_ list: [GalleryPost]) -> [GalleryPost] {
        guard style == .list, !newPostIDs.isEmpty else { return list }
        var arrivals: [GalleryPost] = []
        var earlier: [GalleryPost] = []
        for post in list {
            if newPostIDs.contains(post.id) { arrivals.append(post) } else { earlier.append(post) }
        }
        return arrivals + earlier
    }

    /// The sections this page currently has, in order.
    private var sections: [Section] {
        guard style == .list, !showsSkeleton else { return [.earlier] }
        return Self.sections(lead: newRunLength, total: posts.count, titled: titlesEverySection)
    }

    /// The two halves of a sectioned list, and the words they wear.
    ///
    /// The SAME pair the inbox uses — "New" and "Recent". A viewer moving
    /// between Messages and For You should not have to re-read a header to
    /// learn that it means what the last one meant.
    private enum Section {
        case new
        case earlier

        var title: String {
            switch self {
            case .new: "New"
            case .earlier: "Recent"
            }
        }
    }

    // MARK: Discover's stretches

    /// Discover only: the list's stretches, one collection-view SECTION each.
    /// Empty on the other styles, and while a skeleton shows.
    private(set) var segments: [DiscoverSegment] = []
    /// Where each stretch begins in `posts` — the flat index of its first post.
    private var segmentStarts: [Int] = []
    /// The posts Discover draws as mosaic tiles rather than as cards.
    private var tilePostIDs: Set<PostID> = []
    /// The posts Discover draws as HALF-WIDTH cards in pairs
    /// (`ForYouPairedVertical`).
    private var pairedPostIDs: Set<PostID> = []
    /// Keeps the chunk tilings it has generated, for the page's whole life.
    private var chunkPlanner = MosaicChunkPlanner()
    /// Whether the corpus behind this page is ALL of it — no further page is
    /// coming. What lets a chunk at the tail be decided rather than held back
    /// (see `MosaicChunkPlanner`). Told by the host before each delivery.
    private var isCorpusComplete = false
    /// The completeness the current stretches were planned under, so a
    /// delivery that changes only that is still a change worth applying.
    private var plannedCorpusComplete = false

    // MARK: Discover's titled groups (`.sections`, #1344)

    /// The groups' titles, in order — empty unless the page shows titled
    /// groups (the profile's History, by day).
    private(set) var groupTitles: [String] = []
    /// The section each group's first stretch is — where its title stands.
    private var groupFirstSections: [Int] = []
    /// Whether the page draws titled groups.
    var isGrouped: Bool { !groupTitles.isEmpty }
    /// The groups were just left — see `leaveGroups`.
    private var leftGroups = false
    /// The pin line's distance below the offset, when the scroll view's own
    /// top inset is not it — see `setPinLineInset`.
    private(set) var pinLineInset: CGFloat?

    /// No further page is coming (or one is). Read by the next `render`.
    func setCorpusComplete(_ complete: Bool) {
        isCorpusComplete = complete
    }

    /// Whether `postID` is drawn as a mosaic TILE on this page — a whole
    /// rectangle that is its media — rather than as a card of which the media
    /// is one part. Per page on the grid and the list, per post on Discover.
    ///
    /// ⚠️ A PAIRED card answers yes too (`pairedPostIDs`): it is
    /// a Following card — all picture, edge to edge, its words over it — so
    /// every question this answers (it autoplays like a brick, it hides whole
    /// for a flight, a landing leaves no hole in it, a close lands as its
    /// twin) has the tile's answer. What differs is its shape and furniture:
    /// `tileCornerRadius(for:)`, `heroAppearance`, `restingOverlay(for:)`,
    /// `makeTileStandIn`.
    func drawsAsTile(_ postID: PostID) -> Bool {
        switch style {
        case .grid: true
        case .list: false
        case .discover: tilePostIDs.contains(postID) || pairedPostIDs.contains(postID)
        }
    }

    /// The chunk `section` holds, or nil for a run of cards. Asked by the
    /// layout, which is why it is not private.
    func chunk(inSection section: Int) -> MosaicChunk? {
        guard style == .discover, !showsSkeleton, segments.indices.contains(section) else { return nil }
        return segments[section].chunk
    }

    /// Whether `section` opens a titled group, and wears its title. Asked by
    /// the layout, like `chunk(inSection:)`.
    func isTitled(inSection section: Int) -> Bool {
        guard style == .discover, !showsSkeleton else { return false }
        return groupIndex(openedBy: section) != nil
    }

    /// Whether `section` is the last stretch of a group with another after
    /// it — the section gap before the next title.
    func endsGroup(inSection section: Int) -> Bool {
        guard style == .discover, !showsSkeleton else { return false }
        return groupIndex(openedBy: section + 1) != nil
    }

    /// The group whose first stretch is `section`.
    private func groupIndex(openedBy section: Int) -> Int? {
        groupFirstSections.firstIndex(of: section)
    }

    /// Whether `section` is a block of paired half-width cards. Asked by the
    /// layout, like `chunk(inSection:)`.
    func isPairs(inSection section: Int) -> Bool {
        guard style == .discover, !showsSkeleton, segments.indices.contains(section) else { return false }
        return segments[section].isPairs
    }

    /// Whether `postID` is drawn as a half-width card of a pair — a Following
    /// card (`PostShelfMediaCardCell`), here and on the stand-in a close
    /// lands as.
    func drawsAsPairedCard(_ postID: PostID) -> Bool {
        pairedPostIDs.contains(postID)
    }

    /// The corner a post's tile-shaped cell takes: the Following card's for a
    /// paired card, the page's tile rounding otherwise. What a window closing
    /// onto it lands at, so the curve never steps in the last frame.
    func tileCornerRadius(for postID: PostID) -> CGFloat {
        drawsAsPairedCard(postID) ? PostShelfMediaCardCell.cornerRadius : tileCornerRadius
    }

    /// A paired card's words, for the flight to wear as resting furniture
    /// that fades as the card grows into the page — the Following row's own
    /// arrangement (`ForYouRowOrigins.card`). Wrapped at the card's size, and
    /// only posed after (`ForYouCardCaptionOverlay`). Nil for anything else.
    ///
    /// And a LARGE TILE's words, when the page's tiles wear them
    /// (`showsTileInfo`): the same overlay at the same size the tile drew
    /// (`PostGridTileCell.makeInfoOverlay`), so the card takes off wearing
    /// what the tile wore and lands wearing what the tile will — and nil for a
    /// tile too small to wear any, which flies its corner count as before.
    func restingOverlay(for postID: PostID) -> UIView? {
        if tileWearsInfo(postID), let post = post(for: postID),
           let size = cell(for: postID)?.bounds.size ?? slotSize(of: postID) {
            return PostGridTileCell.makeInfoOverlay(
                for: post, restingSize: size, imagePipeline: imagePipeline,
                viewerStake: viewerStake(on: postID)
            )
        }
        guard drawsAsPairedCard(postID), let post = post(for: postID) else { return nil }
        let size = cell(for: postID)?.bounds.size ?? slotSize(of: postID)
        return PostShelfMediaCardCell.makeOverlay(
            for: post, restingSize: size, imagePipeline: imagePipeline,
            viewerStake: viewerStake(on: postID)
        )
    }

    /// Adopts a planned list: the stretches, their starts, the flat order and
    /// which posts are tiles — derived from one value so they cannot disagree.
    private func adoptSegments(_ planned: [DiscoverSegment]) {
        segments = planned
        var starts: [Int] = []
        var flat: [GalleryPost] = []
        var tiles: Set<PostID> = []
        var paired: Set<PostID> = []
        for segment in planned {
            starts.append(flat.count)
            flat += segment.posts
            if segment.chunk != nil { tiles.formUnion(segment.posts.map(\.id)) }
            if segment.isPairs { paired.formUnion(segment.posts.map(\.id)) }
        }
        segmentStarts = starts
        posts = flat
        tilePostIDs = tiles
        pairedPostIDs = paired
        #if DEBUG
        logSegmentsIfAsked()
        #endif
    }

    #if DEBUG
    /// `-foryou-segments-log`: the Discover list's stretches as planned, one
    /// line per adoption — `rows(3) chunk(7) pairs(4) …`, with the flat index
    /// each starts at (what `-foryou-open N` takes).
    private func logSegmentsIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-foryou-segments-log") else { return }
        let parts = zip(segments, segmentStarts).map { segment, start -> String in
            let kind = switch segment {
            case .rows: "rows"
            case .chunk: "chunk"
            case .pairs: "pairs"
            }
            return "\(kind)(\(segment.posts.count))@\(start)"
        }
        print("[foryou-segments] \(parts.joined(separator: " "))")
    }
    #endif

    /// Where a flat index into `posts` lives in the sectioned list.
    ///
    /// Internal (not private) only for the +QA hooks.
    func indexPath(for index: Int) -> IndexPath {
        if style == .discover, !segmentStarts.isEmpty {
            // The last stretch starting at or before `index`.
            var low = 0
            var high = segmentStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if segmentStarts[mid] <= index { low = mid } else { high = mid - 1 }
            }
            return IndexPath(item: index - segmentStarts[low], section: low)
        }
        let split = split
        guard split > 0 else { return IndexPath(item: index, section: 0) }
        return index < split
            ? IndexPath(item: index, section: 0)
            : IndexPath(item: index - split, section: 1)
    }

    /// The flat index into `posts` an index path names.
    ///
    /// Internal (not private) only for the +QA hooks.
    func flatIndex(for indexPath: IndexPath) -> Int {
        if style == .discover, segmentStarts.indices.contains(indexPath.section) {
            return segmentStarts[indexPath.section] + indexPath.item
        }
        return indexPath.section == 0 ? indexPath.item : split + indexPath.item
    }

    /// Armed when the next content to arrive is a re-derived corpus rather than
    /// an extended one. Consumed by the `apply` that follows.
    private var mustReload = false

    /// The corpus this page is about to be handed was RE-DERIVED — a lens
    /// change or a re-ordering — so whatever similarity it bears to what is on
    /// screen is a coincidence, not an append. See `ForYouViewModel.onCorpusReset`.
    func invalidateIncrementalUpdates() {
        mustReload = true
    }

    /// Whether appending `count` posts leaves the section structure alone, so
    /// the append can stay an insert rather than becoming a reload.
    ///
    /// A page landing is ordinarily OLDER content, so it joins the second half
    /// and the leading run of arrivals is untouched. Two structural moves are
    /// not an append: a list that was entirely new gaining its first non-new
    /// row, and a newcomer that is itself NEW — it belongs in the first half,
    /// and an insert would put it at the foot of the second.
    private func shapeWouldHold(afterAppending added: [GalleryPost], from before: SectionShape) -> Bool {
        guard style == .list else { return true }
        guard !added.contains(where: { newPostIDs.contains($0.id) }) else { return false }
        // Older rows join the foot, so the leading run of arrivals is the same
        // run; only the total — and with it which sections exist — can move.
        let lead = newRunLength
        let after = Self.sections(lead: lead, total: posts.count + added.count, titled: titlesEverySection)
        return SectionShape(sections: after, split: after.count == 2 ? lead : 0) == before
    }

    /// Adopts a new set of arrivals. Re-groups the rows and reloads, because
    /// both which section a row is in and how many sections there are can move.
    ///
    /// Re-grouped from the order the rows ARRIVED in (`rawPosts`), not from
    /// the current grouping: a post leaving the set (a friend's story watched
    /// meanwhile) goes back to its own place in "Recent", not to the top of it.
    func setNewPosts(_ ids: Set<PostID>) {
        guard newPostIDs != ids else { return }
        newPostIDs = ids
        guard style == .list, !showsSkeleton else { return }
        posts = partitioned(rawPosts)
        collectionView.reloadData()
    }

    /// Grid pages steer each post into the block whose shape crops it least;
    /// list pages are a timeline, where order carries meaning and must not be
    /// rearranged for looks.
    ///
    /// The slot shapes come from the layout rather than from a table, because a
    /// BSP tiling generates them — see `PostGridSliceArrangement`. Before the
    /// page has been laid out there are no shapes yet and this is the identity;
    /// `onPlanInvalidated` re-runs it when geometry resolves.
    private func arrange(_ posts: [GalleryPost], startingAt index: Int) -> [GalleryPost] {
        guard style == .grid, let sliceLayout else { return posts }
        return PostGridSliceArrangement.arranged(
            posts, startingAt: index,
            slotMetrics: sliceLayout.slotMetrics(forItemCount: index + posts.count)
        )
    }

    private var sliceLayout: ChaoticSliceLayout? {
        collectionView.collectionViewLayout as? ChaoticSliceLayout
    }

    /// The rounding this page's tiles take, paired with the layout's gutter.
    /// List pages fall back to the tile default, which they never use; Discover's
    /// chunks take the feed mosaic's pairing, the gutter `DiscoverListLayout`
    /// lays them out with.
    ///
    /// ⚠️ NOT `private`, because a landing has to ask rather than restate it.
    /// The chaotic slice layout rounds its bricks more than the mosaic default
    /// does, and two reveal geometries had the default written into them: their
    /// window sprang to a 10pt corner over a 16pt brick, a step in the one
    /// channel the eye is most sensitive to, on the last frame of the close.
    var tileCornerRadius: CGFloat {
        if style == .discover { return ChaoticSliceLayout.harmonisedCornerRadius }
        return sliceLayout?.tileCornerRadius ?? PostGridTileCell.mosaicCornerRadius
    }

    /// Re-places every post against slot shapes that have just changed — a
    /// rotation, or any resize that alters the slice's aspect and therefore what
    /// shape each block is.
    ///
    /// Guarded on the two states where moving a cell would be destructive: a
    /// staged dismissal has already measured where its card is landing, and a
    /// hidden hero means a card is in the air over a tile that must not move
    /// out from under it. Reloading is also skipped when the new arrangement
    /// matches the old, which is the common case on first layout and keeps the
    /// cold start to a single reload.
    private func replanArrangement() {
        guard style == .grid, !showsSkeleton, !rawPosts.isEmpty,
              heroHiddenPostID == nil
        else { return }
        let rearranged = arrange(rawPosts, startingAt: 0)
        guard rearranged.map(\.id) != posts.map(\.id) else { return }
        posts = rearranged
        collectionView.reloadData()
        DispatchQueue.main.async { [weak self] in self?.updateAutoplay() }
    }

    private let imagePipeline: ImagePipeline
    /// Autoplay for video media, on both shapes — absent only where the host
    /// didn't supply a player pool.
    ///
    /// List pages used to be excluded outright ("a timeline row is a reading
    /// surface, not a viewing one"). They now play on the same centre-ranked
    /// terms as the mosaic. The concurrency is the whole difference between the
    /// two shapes' playback — everything below this line is shared.
    ///
    /// Internal (not private) only for the +QA hooks.
    let playback: GridVideoPlaybackCoordinator?
    /// The pool itself, held only so the audit can ask whether a surface is
    /// ADVANCING — a question the coordinator does not answer, because "playing"
    /// there means "holds a loan", not "is moving".
    private let videoPool: VideoPlaybackController?

    /// How many videos may play at once, per shape — see
    /// `ForYouGridAutoplayDriver.concurrentPlayers(for:)`.
    static func concurrentPlayers(for style: Style) -> Int {
        ForYouGridAutoplayDriver.concurrentPlayers(for: style)
    }
    private let style: Style

    /// Internal (not private) only for the +QA hooks.
    let collectionView: UICollectionView

    /// This list's lookahead (#970): its covers decoded one screen ahead and
    /// half a screen behind, their bytes on disk two and a half ahead, under
    /// one `CacheOwner` per stay on screen — every list its own, over the
    /// pipeline's shared fills. Also what decides the next page (2 screens
    /// from the end, 3 on a fling).
    private lazy var lookahead: ScrollLookahead = {
        let lookahead = ScrollLookahead(
            pipeline: imagePipeline, name: "postgrid.\(style)", kind: style == .grid ? .grid : .card
        ) { [weak self] indexPath in
            self?.lookaheadImages(at: indexPath) ?? []
        }
        lookahead.attach(to: collectionView)
        return lookahead
    }()

    /// What the item at `indexPath` shows, for the lookahead.
    private func lookaheadImages(at indexPath: IndexPath) -> [ImageRequest] {
        guard !showsSkeleton else { return [] }
        let index = flatIndex(for: indexPath)
        guard posts.indices.contains(index) else { return [] }
        return posts[index].lookaheadImages
    }

    /// The page joined or left a window: a new stay with its own owner, or
    /// the end of one, which cancels what only this list wanted.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        lookahead.setOnScreen(window != nil)
    }

    /// The scroll view the host names to the bars (`setContentScrollView`) —
    /// their scroll-edge treatment, and the tab bar's minimize on a screen
    /// that arms one (For You does not, since it lost its tabs).
    ///
    /// ⚠️ NAMED FOR ITS JOB, not opened up. Reading an offset through this is
    /// what `verticalOffset` is for; this exists because
    /// `UIViewController.setContentScrollView(_:for:)` needs the object itself
    /// and UIKit's own heuristic search does NOT find a scroll view nested in a
    /// horizontal pager — measured, see `ForYouSelectorAccessory`.
    var minimizeScrollView: UIScrollView { collectionView }
    /// The centred "nothing here" block, shared with every other surface that
    /// has to say it. Hidden unless the page is genuinely empty or failed.
    private let emptyState = EmptyStateView()
    private let refreshControl = AppRefreshControl()
    private var showsSkeleton = false
    /// The post whose cell is standing in for a flight card and must stay
    /// invisible until the card lands. See `setHeroHidden`.
    private var heroHiddenPostID: PostID?
    /// The exact cell hidden at takeoff.
    ///
    /// Held by reference because the post→cell mapping is not stable across a
    /// flight: staging swaps the active post into the departure slot, so by
    /// landing `cell(for:)` resolves the anchor to a DIFFERENT instance than the
    /// one the hide was applied to. Unhiding by lookup therefore cleared the
    /// wrong cell and left the original invisible for good — with the flag
    /// correctly nil, which is why it survived every check that looked at the
    /// flag. Weak: the collection view owns cells and may recycle this one,
    /// and a recycled cell is corrected by `cellForItemAt` anyway.
    private weak var heroHiddenCell: UICollectionViewCell?
    /// The reveal channel's equivalent, and it exists for the same reason —
    /// see `setRevealConcealed`. Weak for the same reason too: the collection
    /// view owns cells, and a recycled one is corrected at `cellForItemAt`.
    /// ⚠️ ANY CELL, not just a row. Typed to the row while only list surfaces
    /// opened windows, which quietly made every grid landing a no-op — see
    /// `setRevealConcealed`.
    private weak var revealConcealedCell: UICollectionViewCell?
    /// The post whose twin is in the air, concealed or not.
    ///
    /// Split from `heroHiddenPostID` because the two questions came apart: a
    /// dismissal wants its landing tile VISIBLE under the incoming card, but
    /// still must not let it claim a player while the card is flying that same
    /// playback.
    private var heroFlyingPostID: PostID?
    /// The inset to hand back when a flight ends; non-nil means frozen.
    private var frozenContentInset: UIEdgeInsets?
    /// The post to bring clear of the chrome once this page is out of sight.
    /// Held as an ID rather than an index path because the corpus can change
    /// while the post is open — a page can land, or a lens can re-derive the
    /// whole list — and an index would then name a different post.
    private var pendingRevealPostID: PostID?
    /// Which captions the viewer has opened out. Owned here rather than by the
    /// rows, which are recycled — see `CaptionExpansion`.
    private let captionExpansion = CaptionExpansion()
    /// The row a REVEAL is currently holding, hidden until its window lands.
    ///
    /// Its own slot, deliberately not `heroHiddenPostID`. Sharing that one was
    /// the first attempt and the frames caught it: a media flight ending
    /// anywhere on this grid calls `setHeroHidden(false, …)`, which nulls the
    /// flag for WHATEVER post it names and then sweeps every visible cell —
    /// and the sweep only knows how to un-hide a preview. So a reveal's row
    /// came back mid-grab, and the viewer held a window with a second copy of
    /// the same post sitting underneath it.
    ///
    /// Two flights, two kinds of concealment, two slots. They are OR-ed at the
    /// one place that applies them, so neither can clear the other.
    private var revealConcealedPostID: PostID?
    /// The parked clips a card window is playing, until it lands (#1294).
    let windowClips = WindowReturnClips()
    /// The autoplay decisions this page measures for — the during-scroll
    /// throttle's state and the last cover range fetched among them. See
    /// `ForYouGridAutoplayDriver`.
    private var autoplayDriver = ForYouGridAutoplayDriver()
    #if DEBUG
    /// Internal (not private) only for the +QA hooks.
    var hasScheduledDiagnostics = false
    #endif

    /// List pages show a column of placeholder cards; the grid shows two full
    /// slices — a scrolling page has a whole viewport to fill, and a slice is
    /// only a little over one screenful.
    private var skeletonCount: Int {
        style == .grid ? (sliceLayout?.cellsPerSlice ?? ChaoticSliceEngine.defaultCellsPerSlice) * 2 : 6
    }

    init(
        imagePipeline: ImagePipeline, style: Style, videoPlayback: VideoPlaybackController? = nil,
        bookmarks: PostBookmarkStore? = .shared
    ) {
        self.imagePipeline = imagePipeline
        self.bookmarks = bookmarks
        videoPool = videoPlayback
        chunkPlanner.chunksLeavePairableMedia = !ForYouPairedVertical.chunksTakeVerticals
        #if DEBUG
        CarouselPlaybackAudit.capturePoolTrace()
        #endif
        playback = videoPlayback.map {
            GridVideoPlaybackCoordinator(pool: $0, maxConcurrent: Self.concurrentPlayers(for: style))
        }
        self.style = style
        // `headerHost` breaks the chicken-and-egg: the layout needs to ask the
        // page which sections are titled, and the page does not exist until
        // after `super.init`. The box is filled in below, and the layout only
        // ever asks during a layout pass — long after that.
        let headerHost = WeakPageBox()
        let layout: UICollectionViewLayout = switch style {
        case .grid:
            ChaoticSliceLayout()
        case .list:
            PostGridListLayout.layout(hasHeader: { [headerHost] index in
                headerHost.page?.hasHeader(inSection: index) ?? false
            })
        case .discover:
            // Same box, other questions: which sections are chunks, and which
            // are blocks of paired cards.
            DiscoverListLayout.layout(
                chunk: { [headerHost] section in
                    headerHost.page?.chunk(inSection: section)
                },
                isPairs: { [headerHost] section in
                    headerHost.page?.isPairs(inSection: section) ?? false
                },
                isTitled: { [headerHost] section in
                    headerHost.page?.isTitled(inSection: section) ?? false
                },
                endsGroup: { [headerHost] section in
                    headerHost.page?.endsGroup(inSection: section) ?? false
                },
                // A titled group is a day of what the viewer looked at, not a
                // corpus to browse: no chunk offers "View all" there.
                showsViewAll: { [headerHost] in
                    !(headerHost.page?.isGrouped ?? false)
                }
            )
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        headerHost.page = self

        sliceLayout?.onPlanInvalidated = { [weak self] in self?.replanArrangement() }
        pagingSpinner.alpha = 0
        pagingSpinner.hidesWhenStopped = false
        collectionView.addSubview(pagingSpinner)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        // No indicators: the header floats over these pages, so a vertical bar
        // runs the whole viewport and crosses the chrome instead of stopping
        // under it. Same reason as the profile's pages.
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        // No effect under the bar: the rows run up under the pills untouched — see
        // `prefersClearTopEdge`.
        collectionView.prefersClearTopEdge()
        collectionView.register(PostGridTileCell.self, forCellWithReuseIdentifier: PostGridTileCell.reuseID)
        collectionView.register(PostGridListRowCell.self, forCellWithReuseIdentifier: PostGridListRowCell.reuseID)
        collectionView.register(
            PostShelfMediaCardCell.self, forCellWithReuseIdentifier: PostShelfMediaCardCell.reuseID
        )
        collectionView.register(
            PostGridSkeletonTileCell.self, forCellWithReuseIdentifier: PostGridSkeletonTileCell.reuseID
        )
        collectionView.register(
            PostGridSkeletonListCell.self, forCellWithReuseIdentifier: PostGridSkeletonListCell.reuseID
        )
        collectionView.register(
            SectionHeaderCapsuleView.self,
            forSupplementaryViewOfKind: PostGridListLayout.headerElementKind,
            withReuseIdentifier: Self.sectionHeaderReuseID
        )
        collectionView.register(
            DiscoverViewAllFooterView.self,
            forSupplementaryViewOfKind: DiscoverListLayout.viewAllElementKind,
            withReuseIdentifier: DiscoverViewAllFooterView.reuseID
        )
        collectionView.register(
            LeadHostView.self,
            forSupplementaryViewOfKind: DiscoverListLayout.leadElementKind,
            withReuseIdentifier: LeadHostView.reuseID
        )
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.addGestureRecognizer(offMediaHold)
        refreshControl.addAction(UIAction { [weak self] _ in self?.onRefresh?() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl
        collectionView.pin(to: self)

        // Centred in the page, and pinned to the page rather than to the
        // collection view: a scroll view's centre moves with its content
        // insets, so an empty state hung inside one drifts down as chrome is
        // added above it. The page's own bounds do not move.
        //
        // Not user-interactive, so a pull-to-refresh started on top of the
        // message still reaches the scroll view underneath — the empty state is
        // exactly where someone reaches to pull.
        emptyState.isUserInteractionEnabled = false
        emptyState.isHidden = true
        emptyState.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The content inset the pager's owner needs to clear with its tray — the
    /// page scrolls under it, so the last row must be reachable above it.
    var additionalBottomInset: CGFloat {
        get { trayInset }
        set {
            trayInset = newValue
            applyBottomInset()
        }
    }

    /// The tray's clearance and the paging footer's, kept apart because they
    /// change independently and both land on the same inset.
    private var trayInset: CGFloat = 0
    private var footerInset: CGFloat = 0

    private func applyBottomInset() {
        // A hero flight pins the inset so its landing measurement stays valid —
        // see `beginHeroFreeze`. Writing to it here would unpick that, so the
        // value is held and applied when the flight thaws.
        guard frozenContentInset == nil else { return }
        var bottom = trayInset + footerInset + hostedBottomInset
        if hostedTopInset != nil {
            // Hosted pages must be ABLE to travel the header's full distance
            // whatever they hold — a short tab with nowhere to put the viewer
            // is what makes the header snap back on a tab switch (the same
            // rule, for the same reason, as the profile grid's
            // `setMinimumScrollTravel`). The room is empty space below the
            // last row.
            let needed = offeredTravel
                + collectionView.bounds.height
                - collectionView.contentSize.height
                - collectionView.contentInset.top
            bottom = max(bottom, needed)
        }
        // Value-guarded: this runs per scroll tick in hosted mode, and an
        // unconditional write mid-drag disturbs the pan.
        guard abs(collectionView.contentInset.bottom - bottom) > 0.5 else { return }
        collectionView.contentInset.bottom = bottom
        collectionView.verticalScrollIndicatorInsets.bottom =
            trayInset + footerInset + hostedBottomInset
    }

    // MARK: - The leading header (Discover only)

    /// What leads Discover's list — For You's Friends and Following rows.
    /// Held weakly: the host owns it and hands it to whichever reusable view
    /// the layout realizes for it (`LeadHostView`), so its state — a row's
    /// scroll position, a card's player — survives the header being recycled.
    private weak var leadView: UIView?
    private var leadHeight: CGFloat = 0

    /// Puts `view` above the list at `height`; nil or zero removes it. Only
    /// Discover has a lead: the other styles' layouts have no slot for one.
    func setLead(_ view: UIView?, height: CGFloat) {
        guard style == .discover,
              let layout = collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout
        else { return }
        leadView = view
        let height = view == nil ? 0 : height
        // Re-host into a realized header at once: a view can have one parent,
        // and the one it had may have been recycled.
        for case let host as LeadHostView in collectionView.visibleSupplementaryViews(
            ofKind: DiscoverListLayout.leadElementKind
        ) {
            host.host(view)
        }
        guard abs(height - leadHeight) > 0.5 else { return }
        // ⚠️ A LIST AT ITS TOP STAYS AT ITS TOP. A new configuration keeps the
        // content offset while the content above the first stretch grows, so
        // the rows arriving on a list already laid out slid in UNDER the
        // navigation bar and the screen opened scrolled past them — filmed.
        let top = -collectionView.adjustedContentInset.top
        let wasAtTop = collectionView.contentOffset.y <= top + 1
        leadHeight = height
        DiscoverListLayout.setLeadHeight(height, on: layout)
        guard wasAtTop else { return }
        collectionView.layoutIfNeeded()
        collectionView.contentOffset.y = -collectionView.adjustedContentInset.top
    }

    /// The reconcile ran — every scroll tick (throttled), every visibility
    /// change. What lets a lead with players of its own keep time with the
    /// list: a row scrolling out of the band must stop as the list's tiles do.
    var onAutoplayReconcile: ((_ allowingStarts: Bool) -> Void)?

    /// Players a lead is holding from the SAME pool right now — asked right
    /// after `onAutoplayReconcile`, so it is the lead's answer to this very
    /// reconcile. The list plays at most what the pool's budget
    /// (`VideoPlaybackController.capacity`) leaves it, never more than its own
    /// style's number.
    ///
    /// ⚠️ ONE BUDGET FOR TWO COORDINATORS. For You's Following row plays every
    /// card on screen (up to three) and the list under it plays five: eight
    /// decoders against a budget of six, and a seventh clip does not stutter
    /// politely, it starves one of the six. The row is claimed first — it is
    /// the part of the screen the viewer is reading when it is up — and the
    /// list's farthest candidates give way.
    var playerReserve: (() -> Int)?

    // MARK: - Hosted collapsible header (the Place Profile's mechanics)

    /// The page's distance from its content top, every scroll tick — what a
    /// floating header rides. Fired for every page; a pager gates on the
    /// active one.
    var onVerticalScroll: ((CGFloat) -> Void)?

    /// Puts the list back at its top unless the viewer is moving it — a
    /// page whose first posts landed after it was laid out (a place opened
    /// from a link, #985) opened scrolled past its header.
    func restAtTop() {
        guard !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating else { return }
        collectionView.layoutIfNeeded()
        collectionView.contentOffset.y = -collectionView.adjustedContentInset.top
    }

    /// Where this page is scrolled to, measured from the top of its CONTENT
    /// rather than from its own origin: hosted pages rest at `-inset`, and
    /// reporting travel keeps every caller out of that arithmetic.
    var verticalOffset: CGFloat {
        collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    }

    /// Non-nil once hosted — the height of the header floating above.
    private var hostedTopInset: CGFloat?
    private var hostedBottomInset: CGFloat = 0
    private var minimumScrollTravel: CGFloat = 0

    /// Puts the page under a floating header: `top` is the header's height
    /// (content starts below it, scrolls under it), `bottom` the chrome at the
    /// screen's foot. Switches inset management to manual (`.never`) — the
    /// host's safe areas are the header's business now, and UIKit adding its
    /// own on top double-counted the bar region.
    func setHostedInsets(top: CGFloat, bottom: CGFloat) {
        guard hostedTopInset != top || hostedBottomInset != bottom else { return }
        let travelled = verticalOffset
        hostedTopInset = top
        hostedBottomInset = bottom
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.top = top
        collectionView.verticalScrollIndicatorInsets.top = top
        // Changing the inset moves the content under a stationary offset, so
        // the offset is restated to keep the page where it was.
        collectionView.contentOffset.y = travelled - top
        hostStatusUnderHeader()
        applyBottomInset()
        positionHostedStatus()
    }

    // MARK: - The status under a hosted header (#1273)

    /// The empty/failed state's centre, while hosted — see `positionHostedStatus`.
    private var hostedStatusCentre: NSLayoutConstraint?

    /// Moves the status from filling the page to riding under the header:
    /// pinned to the page, the block centred on a page taller than the room
    /// left under the header, behind it on a short screen.
    private func hostStatusUnderHeader() {
        guard hostedStatusCentre == nil else { return }
        emptyState.removeFromSuperview()
        addSubview(emptyState)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        let centre = emptyState.centerYAnchor.constraint(equalTo: topAnchor)
        hostedStatusCentre = centre
        NSLayoutConstraint.activate([
            centre,
            emptyState.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// Puts the status where the first row would be: centred in the room
    /// between the header and the chrome at the foot, riding the offset
    /// (`HostedStatusPlacement`, the profile's rule).
    private func positionHostedStatus() {
        guard let hostedTopInset, let hostedStatusCentre, !emptyState.isHidden else { return }
        let centre = HostedStatusPlacement.centreY(
            visibleTop: hostedTopInset, visibleBottom: bounds.height - hostedBottomInset,
            blockHeight: hostedStatusHeight
        )
        hostedStatusCentre.constant = centre - verticalOffset
    }

    /// The status block's own height, measured once per state and width — it
    /// is read on every frame a hosted page moves.
    private var hostedStatusHeight: CGFloat {
        let key = HostedStatusKey(width: bounds.width, revision: statusRevision,
                                  contentSize: traitCollection.preferredContentSizeCategory)
        if let cached = hostedStatusHeightCache, cached.key == key { return cached.height }
        let height = emptyState.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        hostedStatusHeightCache = (key, height)
        return height
    }

    private struct HostedStatusKey: Equatable {
        let width: CGFloat
        let revision: Int
        let contentSize: UIContentSizeCategory
    }

    private var hostedStatusHeightCache: (key: HostedStatusKey, height: CGFloat)?
    /// Bumped by every status shown, so the measured height follows it.
    private var statusRevision = 0

    /// The travel a hosted page offers: the header's whole run with rows to
    /// show; with only its status, none — there is nothing to scroll to — or
    /// just what brings a block taller than the room under the header into
    /// view (a small phone). The profile's rule (the owner, 2026-10-15).
    private var offeredTravel: CGFloat {
        guard let hostedTopInset, !emptyState.isHidden else { return minimumScrollTravel }
        let roomBottom = bounds.height - hostedBottomInset
        return max(0, hostedTopInset + hostedStatusHeight - roomBottom)
    }

    /// Shows a status in place of the posts — a host's own words (a private
    /// profile, a tab's empty copy) as well as the page's.
    func showStatus(
        symbolName: String?, title: String, subtitle: String? = nil,
        actionTitle: String? = nil, action: (() -> Void)? = nil
    ) {
        statusRevision += 1
        emptyState.configure(
            symbolName: symbolName, title: title, subtitle: subtitle,
            actionTitle: actionTitle, actionHandler: action
        )
        emptyState.isHidden = false
        leaveGroups()
        apply([], skeleton: false)
        settleHostedStatus()
    }

    /// An empty page offers no travel: one that became empty while scrolled
    /// comes back to the top, its status centred under the header.
    private func settleHostedStatus() {
        guard hostedTopInset != nil else { return }
        applyBottomInset()
        if !emptyState.isHidden, verticalOffset > offeredTravel + 0.5 {
            setVerticalOffset(offeredTravel)
        }
        positionHostedStatus()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The status is placed from this view's height, which is zero until
        // a layout pass gives it one.
        positionHostedStatus()
    }

    /// How far this page must be able to scroll, whatever it holds — see the
    /// note in `applyBottomInset`.
    func setMinimumScrollTravel(_ travel: CGFloat) {
        guard minimumScrollTravel != travel else { return }
        minimumScrollTravel = travel
        applyBottomInset()
    }

    /// Drops the stock `UIRefreshControl`: the host reads the pull from
    /// `onPullReleased` and draws its own indicator.
    ///
    /// ⚠️ **FOR A PAGE UNDER A FLOATING HEADER.** The stock control positions
    /// itself against the content top, which is under the header there — its
    /// spinner turns behind the banner — and on the place page a real drag
    /// stretched the banner without ever tripping it, while the same drag
    /// tripped For You's. The profile retired it for the same layout
    /// (`HeroPullToRefreshView`). `onRefresh` stays: it is also the failed
    /// state's "Try Again".
    func handPullToHost() {
        collectionView.refreshControl = nil
    }

    /// Scrolls to a travel offset, clamped to what the content can hold.
    /// What keeps a floating header still across a tab switch: the page
    /// arriving is put level with the page leaving BEFORE it shows.
    ///
    /// `animated` is for the ONE case a viewer asked for the journey: a host
    /// re-tapping the tab already showing (the profile, #1273). Every other
    /// caller keeps a page in step with something else, where an animation is
    /// a page arriving late.
    func setVerticalOffset(_ offset: CGFloat) {
        setVerticalOffset(offset, animated: false)
    }

    func setVerticalOffset(_ offset: CGFloat, animated: Bool) {
        // Make room BEFORE asking the page to travel: on a tab switch the
        // page may not have laid out since its content arrived, and it would
        // clamp against a range that has not been extended yet.
        collectionView.layoutIfNeeded()
        applyBottomInset()
        let inset = collectionView.adjustedContentInset.top
        let travel = collectionView.contentSize.height
            + inset
            + collectionView.contentInset.bottom
            - collectionView.bounds.height
        let target = offset < 0 ? offset : min(offset, max(0, travel))
        guard abs(verticalOffset - target) > 0.5 else { return }
        let point = CGPoint(x: 0, y: target - inset)
        if animated {
            collectionView.setContentOffset(point, animated: true)
        } else {
            collectionView.contentOffset = point
        }
    }

    // MARK: - Paging footer

    /// The band reserved below the content while the next page is in flight.
    ///
    /// The tray's own clearance cannot serve here: it is exactly the height the
    /// tray floats over, so anything parked in it sits *behind* the tray at full
    /// scroll. The footer adds its own space above that.
    private static let footerHeight: CGFloat = 56

    private let pagingSpinner = AppLoaderView(size: .medium)
    private var isPaging = false

    /// Shows or hides the next-page spinner beneath the last tile.
    ///
    /// **Why this cannot jump the scroll.** Reserving the band happens when
    /// pagination fires, which is two screens (three on a fling) before the
    /// end (`LookaheadPaging`) —
    /// growing the bottom inset never moves `contentOffset`, so there is nothing
    /// to see. Releasing it happens once the page has landed and added a whole
    /// slice of content, by which point the viewer is far from the bottom and
    /// the offset cannot be clamped by 56pt. The animation covers the one case
    /// left: a page that lands empty, where the release can nudge a viewer
    /// sitting at the very end.
    /// ⚠️ EVERY STYLE, and the `style == .grid` this replaces was a hole.
    ///
    /// The timeline is the surface where the wait is actually visible: its rows
    /// are a screen tall, so the viewer reaches the end of a page in a few
    /// flicks, and until the next one landed the list simply stopped with no
    /// sign that anything was coming. A grid hid that behind three columns of
    /// tiles. Same footer, same band, same rule — the spinner is the answer to
    /// "is there more", and both shapes owe it.
    func setPaging(_ paging: Bool) {
        guard isPaging != paging else { return }
        isPaging = paging
        if paging {
            pagingSpinner.startAnimating()
            positionPagingFooter()
        }
        footerInset = paging ? Self.footerHeight : 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) {
            self.applyBottomInset()
            self.pagingSpinner.alpha = paging ? 1 : 0
        } completion: { _ in
            if !self.isPaging { self.pagingSpinner.stopAnimating() }
        }
    }

    /// Parks the spinner just under the content, in the scroll view's own
    /// coordinates, so it travels with the last row instead of floating over it.
    private func positionPagingFooter() {
        guard isPaging else { return }
        let contentHeight = collectionView.collectionViewLayout.collectionViewContentSize.height
        pagingSpinner.center = CGPoint(
            x: collectionView.bounds.width / 2,
            y: contentHeight + Self.footerHeight / 2
        )
    }

    func endRefreshing() {
        refreshControl.endRefreshing()
    }

    // MARK: - Autoplay

    /// The part of this page the viewer can see — what autoplay measures a
    /// tile against. At least half of a tile's media must be inside it (see
    /// `GridPlaybackVisibility.minimumVisibleFraction`): a brick creeping in at
    /// the edge is not something the viewer is looking at, and starting it
    /// there spends a pool slot the centre of the screen wants.
    ///
    /// ⚠️ NOT `bounds.inset(by: adjustedContentInset)` WHEN HOSTED. On For You
    /// both insets are floating bars, so the inset is the cover. Under the
    /// place page's header neither is: the top is the header's whole height as
    /// reserved range (content starts there, nothing hides behind it), and the
    /// bottom is inflated by `applyBottomInset` so the page can always travel
    /// that height. Measured at the landing, `bounds=-479…395 inset=t479/b369`:
    /// a 26pt band. Every Discover tile read as under half visible
    /// (`frac=0.11/0.20/0.00`), so the reconcile that runs as the page appears
    /// stopped the tile the dismissal had just landed on, its card timed out
    /// on `frames=0`, and nothing on the grid ever played. The host's cover
    /// (`setChromeOcclusion`) is what the departure reveal already trusts;
    /// autoplay now reads the same number, as the profile gallery's
    /// `visibleBand` does.
    private var autoplayViewport: CGRect {
        GridPlaybackVisibility.viewport(
            bounds: collectionView.bounds,
            contentInset: collectionView.adjustedContentInset,
            hostOcclusion: hostChromeOcclusion
        )
    }

    /// Reconciles autoplay against what is on screen now. Cheap and idempotent;
    /// call it whenever the visible set or the surface's visibility can have
    /// changed.
    ///
    /// `allowingStarts: false` still stops tiles that left, but starts nothing
    /// new — the mid-fling case, where anything started is gone before its first
    /// frame.
    func updateAutoplay(allowingStarts: Bool = true) {
        requestWarm(allowingStarts)
        onAutoplayReconcile?(allowingStarts)
        guard let playback else { return }
        if let playerReserve, let videoPool {
            playback.maxConcurrent = ForYouGridAutoplayDriver.playerBudget(
                for: style, poolCapacity: videoPool.capacity, reserve: playerReserve()
            )
        }
        let viewport = autoplayViewport
        // The measuring stays here, in its old order — the cover gate applies
        // a cached cover as it answers, so it runs for exactly the items it
        // always ran for. The viewport and the ranking are the driver's.
        let tiles = collectionView.indexPathsForVisibleItems.compactMap {
            indexPath -> ForYouGridAutoplayDriver.Tile? in
            guard !showsSkeleton, posts.indices.contains(flatIndex(for: indexPath)) else { return nil }
            let post = posts[flatIndex(for: indexPath)]
            guard post.id != heroFlyingPostID, // its twin is in the air
                  let cell = collectionView.cellForItem(at: indexPath) as? any GridPlaybackCell,
                  let held = playableURL(for: post, in: cell),
                  hasCover(for: post, in: cell)
            else { return nil }
            // Held versus ADVANCING — see `ForYouGridAutoplayDriver.isAdvancing`.
            let advancing = (cell as? PostGridListRowCell).map {
                ForYouGridAutoplayDriver.isAdvancing(
                    showsCarousel: $0.showsCarousel, currentPageVideoURL: $0.currentPageVideoURL, held: held
                )
            } ?? true
            return .init(
                id: post.id, url: held, cell: cell,
                mediaFrame: cell.convert(cell.videoMediaRect, to: collectionView),
                isPaused: !advancing
            )
        }
        let candidates = ForYouGridAutoplayDriver.candidates(from: tiles, in: viewport)
        playback.update(candidates: candidates, allowingStarts: allowingStarts)
        #if DEBUG
        logRejectedCandidates(chosen: Set(candidates.map(\.id)))
        auditCarouselPlayback()
        #endif
    }

    #if DEBUG
    /// ⚠️ THE DENOMINATOR THE RANKING LOG NEVER HAD.
    ///
    /// `[grid-rank]` reports what was CHOSEN, and an empty ranking reads
    /// exactly like a page of photographs — which is how "no video row on this
    /// page plays at all" stayed invisible while the log looked clean. Each
    /// rejection below is a different reason a row can hold a clip and still
    /// never reach the coordinator, and each is a different bug when it is the
    /// wrong answer.
    private func logRejectedCandidates(chosen: Set<PostID>) {
        guard ProcessInfo.processInfo.arguments.contains("-grid-playback-log"),
              !showsSkeleton
        else { return }
        let viewport = autoplayViewport
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            let index = flatIndex(for: indexPath)
            guard posts.indices.contains(index) else { continue }
            let post = posts[index]
            guard !chosen.contains(post.id),
                  let cell = collectionView.cellForItem(at: indexPath) as? any GridPlaybackCell
            else { continue }
            let row = cell as? PostGridListRowCell
            let held = playableURL(for: post, in: cell)
            // A row with no clip anywhere is the ordinary case and says
            // nothing; everything else is worth a line.
            guard held != nil || post.kind == .video || post.isCollection else { continue }
            let frame = cell.convert(cell.videoMediaRect, to: collectionView)
            let fraction = GridPlaybackVisibility.visibleFraction(of: frame, in: viewport)
            print("[grid-reject] \(post.id.rawValue) kind=\(post.kind)"
                + " collection=\(post.isCollection ? "Y" : "N")"
                + " carousel=\(row.map { $0.showsCarousel ? "Y" : "N" } ?? "-")"
                + " page=\(row?.currentPageVideoURL?.lastPathComponent ?? "nil")"
                + " held=\(held?.lastPathComponent ?? "nil")"
                + " cover=\(hasCover(for: post, in: cell) ? "Y" : "N")"
                + " flying=\(post.id == heroFlyingPostID ? "Y" : "N")"
                // The rects the fraction came from, and the content inset it
                // is NOT taken from on a hosted page — a wrong band is
                // otherwise indistinguishable from a tile genuinely off screen.
                + String(format: " frac=%.2f media=%.0f…%.0f viewport=%.0f…%.0f"
                         + " bounds=%.0f…%.0f inset=t%.0f/b%.0f",
                         fraction, frame.minY, frame.maxY, viewport.minY, viewport.maxY,
                         collectionView.bounds.minY, collectionView.bounds.maxY,
                         collectionView.adjustedContentInset.top,
                         collectionView.adjustedContentInset.bottom))
        }
    }

    /// Asks every visible collection row the audit's four questions.
    ///
    /// Run after the reconcile rather than inside it: what matters is the state
    /// the VIEWER is left in once everything has had its say, not the state any
    /// one participant believes it produced.
    /// Whether this page is the one the viewer is looking at.
    ///
    /// ⚠️ The audit's scope, and it needs one. A grid covered by an open post
    /// legitimately holds surfaces that are not hosted and not drawing — the
    /// post has them. Judging the card there reported the handoff working as a
    /// fault, six times in a run.
    private var isAudited = true

    private func auditCarouselPlayback() {
        guard CarouselPlaybackAudit.isEnabled, isAudited, let playback else { return }
        // ⚠️ A HEARTBEAT, unconditionally.
        //
        // Three times this session a run was read as clean when it had produced
        // NOTHING: a console that stopped delivering, a stale file from an
        // earlier build, and a guard that silenced the only writer. A file that
        // is always written and always carries its check count cannot be
        // mistaken for a passing run — an empty one is now impossible rather
        // than indistinguishable.
        CarouselPlaybackAudit.report("card")
        for indexPath in collectionView.indexPathsForVisibleItems {
            let index = flatIndex(for: indexPath)
            guard posts.indices.contains(index),
                  let row = collectionView.cellForItem(at: indexPath) as? PostGridListRowCell
            else { continue }
            let post = posts[index]
            guard post.isCollection else { continue }
            CarouselPlaybackAudit.check(
                surface: "card", subject: post.id.rawValue,
                page: row.currentMediaPage ?? -1,
                playing: playback.isPlaying(post.id),
                clip: row.currentPageVideoURL != nil,
                hosted: row.isRenderingCurrentMedia,
                drawable: row.isSurfaceDrawable
            )
            CarouselPlaybackAudit.checkStillPage(
                surface: "card", subject: post.id.rawValue,
                page: row.currentMediaPage ?? -1,
                drawsVideo: row.drawsVideoOnAStillPage
            )
            // Frozen: on the clip's page, drawing, and not moving.
            CarouselPlaybackAudit.checkAdvancing(
                surface: "card", subject: post.id.rawValue,
                page: row.currentMediaPage ?? -1,
                watching: row.currentPageVideoURL != nil && row.isSurfaceDrawable
                    && playback.isPlaying(post.id),
                advancing: row.playbackSurface.map { videoPool?.isAdvancing(in: $0) ?? true }
                    ?? true,
                hasPlayer: row.playbackSurface.map { videoPool?.hasPlayer(in: $0) ?? true } ?? false
            )
            // ⚠️ Is the coordinator even talking about THIS cell? A collection
            // view recycles, and a loan is held against the instance it was
            // given to.
            if playback.isPlaying(post.id),
               let loaned = playback.loanedCell(post.id), loaned !== row {
                CarouselPlaybackAudit.trace("cell mismatch \(post.id.rawValue)")
            }
        }
    }
    #endif

    /// Brings the last-tapped post clear of the chrome, now that nobody is
    /// looking at this page.
    ///
    /// Called when the post has finished covering the grid. Unanimated because
    /// there is no one to animate for, and because the dismissal that follows
    /// reads the cell's rect when it starts — this has to be settled by then,
    /// not still moving.
    func applyPendingReveal() {
        guard let id = pendingRevealPostID else { return }
        pendingRevealPostID = nil
        #if DEBUG
        debugLastRevealedPostID = id
        #endif
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        // ⚠️ THE INSET IS THE COVER ONLY WHERE THE INSET IS CHROME.
        //
        // `ScrollIntoView` defaults the cover to the content inset, which is
        // correct on a page whose insets exist BECAUSE of chrome — For You,
        // where the top inset IS the navigation bar. The bottom is short even
        // there: the tab bar FLOATS, drawing over the grid without insetting
        // it, and `ForYouViewController` measured the gap years ago in its own
        // words — "bar at y 791 height 83, while the grid reserves 34" — so a
        // tile whose foot is within those 49pt was "revealed" while still
        // behind the bar. That is what `footChromeCover` repairs.
        //
        // ⚠️ AND ON A HOSTED PAGE THE TOP IS NOT CHROME AT ALL. A host with a
        // header that scrolls away insets this page by the header's WHOLE
        // height as scrollable range — reserved room the content travels into,
        // not something covering it. Handed over as a cover it collapsed the
        // visible band to a sliver: on the place page, 874 - 628 - 83 = 163pt
        // against cards 310-549pt tall, so every card read as "taller than the
        // gap", every reveal took the align-to-the-top branch, and the list
        // parked whatever was tapped at screen y 640 — off the bottom of the
        // screen. Filmed three times: a card left cut off, a card already whole
        // dragged to the top, a card cut off at the head dragged to the top.
        //
        // So a host whose insets are LAYOUT must say what actually covers this
        // page — the profile, the place page; `nil` keeps For You on the inset.
        //
        // It matters more here than anywhere: this page deliberately does not
        // scroll at the LANDING (see `ForYouGridZoomSource`), so where the
        // departure reveal leaves a tile is where the card comes back to.
        var cover = hostChromeOcclusion ?? collectionView.adjustedContentInset
        cover.bottom = max(cover.bottom, footChromeCover)
        // The tab-bar hide that precedes the push invalidates the layout, and
        // this reads attributes out of it — `revealPost` forces the pass for
        // exactly this reason and this path never did.
        collectionView.layoutIfNeeded()
        ScrollIntoView.revealImmediately(
            collectionView.layoutAttributesForItem(at: indexPath(for: index))?.frame,
            in: collectionView,
            occlusion: cover
        )
    }

    /// What covers this page's FOOT and its content inset does not — the
    /// floating tab bar, measured by the host because only it can see the bar.
    /// Zero means "the inset is the whole story", which is the honest default
    /// for a page with nothing floating over it.
    var footChromeCover: CGFloat = 0

    /// What COVERS this page, told by the host — for a host whose content
    /// insets are LAYOUT rather than chrome.
    ///
    /// `nil` means "the insets are the whole story", which is the honest
    /// answer for a page inset by its own navigation bar, and keeps For You on
    /// the path it has always taken. A hosted page under a header that scrolls
    /// away must say otherwise; see the note in `applyPendingReveal`.
    private var hostChromeOcclusion: UIEdgeInsets?

    func setChromeOcclusion(_ occlusion: UIEdgeInsets?) {
        hostChromeOcclusion = occlusion
    }

    /// Brings `postID`'s tile into the unobstructed viewport NOW, layout
    /// settled — the cluster gallery's landing rule. Unlike the For You
    /// dismissal (which anchors on the departure tile and never scrolls —
    /// see `ForYouGridZoomSource`), a cluster gallery has never been seen
    /// when the first dismissal stages, so there is no viewer context to
    /// preserve and the grid is free to travel to the landing post's own
    /// tile.
    /// Brings the landing row fully into sight — and ONLY if it is not already.
    ///
    /// ⚠️ IT USED TO CENTRE, and centring is the wrong question for a landing.
    /// A card the viewer can already see whole was dragged to the middle of the
    /// band anyway, so closing a post moved the list under them for no reason
    /// they could name. What a landing owes them is that the card they are
    /// returning to is not half under the chrome — nothing more. So this moves
    /// as little as it can, in whichever direction is short, and not at all
    /// when there is nothing to fix.
    ///
    /// `occlusion` is what COVERS the list — the header band above and the tab
    /// bar below — as distinct from the content inset, which is this page's
    /// scrollable RANGE and is mostly reserved layout. `ScrollIntoView` keeps
    /// the two apart for exactly this reason; the caller measures the cover
    /// because only the host knows where its chrome currently is.
    ///
    /// ⚠️ AND THE COVER IS WHY CENTRING WAS TRIED FIRST. This centred once, for
    /// a filmed reason worth keeping: a post tucked under the bottom chrome
    /// came up until it "just cleared" and the window closed onto a row pinned
    /// to the bottom edge — as far from where the viewer was looking as it
    /// could be while still being on screen. That reading was right about the
    /// symptom and wrong about the cause. The row looked pinned because the
    /// cover was UNDER-MEASURED: the tab bar floats, and `safeAreaInsets.bottom`
    /// reports 34 where the bar is 83, so "just clear" left it half behind the
    /// bar. Measured properly, the minimum move clears the real bar with the
    /// helper's own padding, and the answer to a card that is already whole on
    /// screen is to leave it alone.
    func revealPost(_ postID: PostID, clearing occlusion: UIEdgeInsets = .zero) {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        collectionView.layoutIfNeeded()
        ScrollIntoView.revealImmediately(
            collectionView.layoutAttributesForItem(at: indexPath(for: index))?.frame,
            in: collectionView,
            occlusion: occlusion
        )
    }

    /// Whether a post autoplays ON THIS PAGE — the one autoplay rule that
    /// differs by shape, so the difference lives in exactly one place.
    ///
    /// `autoplaysInGrid` excludes SQUARE video, and that is a mosaic judgement:
    /// a square brick competing for one of six slots in a dense wall is not
    /// worth the slot. A row's preview is a fixed landscape box that
    /// aspect-fills whatever it is handed, so a square source is no different
    /// there to any other, and applying the grid's rule would leave those rows
    /// permanently still for a reason that never applied to them.
    ///
    /// Asked per POST (`drawsAsTile`), because Discover draws both: a chunk's
    /// tiles follow the mosaic's rule and its cards the timeline's.
    private func autoplays(_ post: GalleryPost) -> Bool {
        drawsAsTile(post.id) ? post.autoplaysInGrid : post.hasPlayableVideo
    }

    /// The stream this cell should be playing right now, or nil for none.
    ///
    /// ⚠️ A COLLECTION answers from its current page, and the post cannot answer
    /// for it.
    ///
    /// `GalleryPost.videoURL` is page one's, for ever. Nothing in `post.v1` says
    /// a carousel's attachments agree about their type, so a post whose first
    /// page is a photograph is a `.photo` post that still has a clip on page
    /// two — `autoplays(post)` would refuse it, and `post.videoURL` would be nil
    /// even if it did not. Both questions move to the page.
    ///
    /// A row showing a still page answers nil, which is what stops the clip the
    /// viewer just scrolled away from.
    private func playableURL(for post: GalleryPost, in cell: any GridPlaybackCell) -> URL? {
        if let row = cell as? PostGridListRowCell, post.isCollection {
            // RETAINED, not current: the row keeps its player while the viewer
            // is on a still page of the same collection. Whether it advances is
            // decided separately, at the call site.
            return row.retainedVideoURL
        }
        guard autoplays(post) else { return nil }
        return post.videoURL
    }

    /// Whether a tile has something to show behind its video surface.
    ///
    /// A video surface covers the tile's cover image, and until the first frame
    /// decodes it has nothing of its own to draw — so a tile that starts
    /// playing before its cover has arrived is simply black, and a hero flight
    /// departing from it flies black. Measured on a cold `-rich-media` grid,
    /// every tile reported `cover=NIL` at play start.
    ///
    /// Gating here rather than in the renderer because this is not a rendering
    /// problem: there is no frame AND no poster, and no amount of sequencing
    /// invents one. Playback simply waits for the tile to have a face.
    ///
    /// A post with no `thumbnailURL` is admitted rather than blocked. Nothing
    /// is coming for it, so waiting would mean never playing — and its first
    /// decoded frame is the only face it will ever have.
    private func hasCover(for post: GalleryPost, in cell: any GridPlaybackCell) -> Bool {
        guard let thumbnail = post.thumbnailURL else { return true }
        // The cell's own image first: it may hold a cover the pipeline has
        // since evicted from its cache.
        if cell.renderedCover != nil { return true }
        // Cached but not yet applied — `configure` asked the cache before the
        // prefetch landed, and the cell's own load has not come back. Apply it
        // now rather than merely reporting it: a gate that passed on a cover
        // the tile is not actually showing would let playback start against a
        // blank face, which is what it exists to prevent.
        guard let cached = imagePipeline.cachedImage(for: thumbnail) else { return false }
        cell.applyCover(cached)
        return true
    }

    /// Tab left, feed presented over the grid, app backgrounded. `keeping`
    /// exempts the post whose player a hero flight is still carrying.
    /// Opens the handoff scope for a tapped tile. Replaces the old
    /// "stop everything except this one" call: the scope also makes the post
    /// invisible to `reconcile`, so nothing can restart or stop it mid-flight.
    ///
    /// `parkingReturn`: also park a player on the tile's own clip for a close
    /// from another post (#923) — only for an opener whose close asks for it
    /// (`returnFlightSurface`).
    func beginPlaybackHandoff(of postID: PostID, parkingReturn: Bool = false) {
        playback?.beginHandoff(postID, parkingReturn: parkingReturn)
    }

    /// The tile's own clip, resumed from where it was parked at the tap — the
    /// arriving picture of a close from another post (#923). Nil when nothing
    /// is parked, and the close lands on the tile's still.
    ///
    /// ⚠️ A ROW THAT PAGED ON IS NOT SHOWING THAT CLIP (#1332). The row
    /// follows the post's carousel, and keeps that page when the viewer
    /// swipes on to another post; the clip was parked on the page that played
    /// at the tap. Filmed: page 1 a clip, closed from another post with the
    /// row on page 2 — the card faded page 1's clip in over page 2's picture,
    /// and the landing handed it to the row. Such a close lands on the row's
    /// still, the page it shows (`SnapFeedHeroOrigin.currentCover`).
    func returnFlightSurface(for postID: PostID) -> VideoRenderView? {
        if let row = cell(for: postID) as? PostGridListRowCell, row.currentMediaPage != nil,
           row.currentPageVideoURL != playback?.returnURL(for: postID) {
            return nil
        }
        return playback?.makeReturnSurface(for: postID)
    }

    /// A close that resumed the return player was abandoned.
    func pauseReturnPlayback(for postID: PostID) {
        playback?.pauseReturnPlayback(of: postID)
    }

    /// Whether `postID`'s tile has a return player parked right now.
    func hasReturnPlayback(for postID: PostID) -> Bool {
        playback?.hasReturnPlayback(for: postID) ?? false
    }

    /// A close from another post landing on `postID`'s tile, for an opener
    /// that flies through `ExternalHeroZoomSource` (#951): the tile, out of
    /// concealment, takes the return player `view` draws. The For You list's
    /// own landing goes through `adoptLivePlayback`.
    @discardableResult
    func landReturnPlayback(_ view: UIView, for postID: PostID) -> Bool {
        guard let view = view as? VideoRenderView, let playback,
              let tile = cell(for: postID) as? any GridPlaybackCell
        else { return false }
        Self.applyHeroConcealment(false, to: tile as? UICollectionViewCell)
        return playback.landReturnPlayback(view, for: postID, cell: tile)
    }

    /// The same landing's hold: the tile's clip once it took the return
    /// player, its still otherwise.
    func isReturnLandingReady(for postID: PostID) -> Bool {
        guard let playback else { return true }
        return playback.isReturnLandingReady(
            for: postID,
            cell: cell(for: postID) as? any GridPlaybackCell,
            hasThumbnail: post(for: postID)?.thumbnailURL != nil
        )
    }

    /// Points the handoff scope at the post a dismissal is actually landing on.
    /// See `GridVideoPlaybackCoordinator.retargetHandoff`.
    func retargetPlaybackHandoff(to postID: PostID) {
        playback?.retargetHandoff(postID)
    }

    /// Closes the scope and reconciles once — the single act that restores the
    /// grid's full complement of players after a dismissal.
    func endPlaybackHandoff() {
        playback?.endHandoff()
        // The claim ends with the round trip: the post is back to being one
        // tile among others, and holding the claim would pin a player to
        // whatever the viewer opened last, for ever.
        playback?.focus(nil)
        updateAutoplay()
        #if DEBUG
        logVisibility("return-complete")
        #endif
    }

    func setAutoplayActive(_ active: Bool, keeping kept: PostID? = nil) {
        #if DEBUG
        isAudited = active
        #endif
        // Covered but alive (a feed or a pushed screen over it): the
        // lookahead drops to the minimum windows, P2 at most (#970).
        lookahead.setHidden(!active)
        playback?.setSurfaceVisible(active, keeping: kept)
        if active {
            updateAutoplay()
            #if DEBUG
            schedulePlaybackDiagnosticsIfNeeded()
            #endif
        }
    }

    #if DEBUG
    /// The realized cell drawing `postID`, if any.
    func debugCell(for postID: PostID) -> UICollectionViewCell? { cell(for: postID) }

    /// Whether the inset is pinned (`beginHeroFreeze`) rather than tracking
    /// the safe area.
    var debugIsInsetPinned: Bool { frozenContentInset != nil }

    /// The three numbers that decide where a cell is on screen, for tracing a
    /// landing that missed. A rect alone cannot say WHY it moved; these can.
    var debugInsetState: String {
        String(
            format: "offset=%.1f adjInset=(t%.1f b%.1f) frozen=%@ h=%.1f",
            collectionView.contentOffset.y,
            collectionView.adjustedContentInset.top,
            collectionView.adjustedContentInset.bottom,
            frozenContentInset == nil ? "N" : "Y",
            collectionView.bounds.height
        )
    }

    /// The posts on screen that COULD play, with the same centre distance the
    /// ranking uses — the independent check on what the coordinator chose.
    var debugVisibleVideoRanking: [(id: String, distance: Int)] {
        let viewport = autoplayViewport
        let centreY = viewport.midY
        return collectionView.indexPathsForVisibleItems.compactMap {
            indexPath -> (id: String, distance: Int)? in
            let index = flatIndex(for: indexPath)
            guard posts.indices.contains(index) else { return nil }
            let post = posts[index]
            guard autoplays(post),
                  let cell = collectionView.cellForItem(at: indexPath) as? any GridPlaybackCell
            else { return nil }
            let box = cell.convert(cell.videoMediaRect, to: collectionView)
            return (post.id.rawValue, Int(abs(box.midY - centreY)))
        }
        .sorted { $0.distance < $1.distance }
    }

    #endif

    // MARK: - Hero handoff

    /// Mirrors a playing tile's player onto the flight card and then parks it.
    ///
    /// Order is the whole point, and it is why both steps live here rather than
    /// at the call site. Mirroring first attaches the card's layer while the
    /// tile still owns the player, so the card renders live from frame 0 and,
    /// being the most recently attached layer, is the one that displays.
    /// Parking second releases the tile without interrupting the player, so the
    /// destination can adopt it — same item, same playhead — when the flight
    /// lands.
    ///
    /// Parking first, which is what this used to do, left nothing to mirror:
    /// the card flew a static cover for the whole 420ms zoom while the player
    /// sat parked, and the live frame only reappeared after landing.
    func donateLivePlayback(of postID: PostID) -> VideoRenderView? {
        playback?.donateLiveSurface(of: postID)
    }

    /// The N-surface alternative to `donateLivePlayback`: a NEW surface showing
    /// the same live playback, with the tile keeping its own.
    ///
    /// Nothing is donated, nothing is parked, and the tile is hidden rather
    /// than stopped — so if the flight is abandoned there is nothing to put
    /// back. Returns nil when the tile is not playing, which is the same
    /// contract the donate path had.
    func liveFlightSurface(for postID: PostID) -> VideoRenderView? {
        // ⚠️ The CURRENT PAGE's stream where there is one. `post.videoURL` is
        // page one's for ever, so a collection opened from a clip on page three
        // asked for the wrong asset — and a collection whose head is a
        // photograph asked for nil and never flew live at all.
        let row = cell(for: postID) as? PostGridListRowCell
        guard let playback,
              let index = posts.firstIndex(where: { $0.id == postID }),
              let url = row?.currentPageVideoURL ?? posts[index].videoURL
        else { return nil }
        // Nothing to join. Ask for the player rather than reporting its
        // absence: this call is repeated every frame of the flight (see
        // `ZoomLiveMediaRetry`), so a start kicked here is picked up by the
        // next ask — which is the difference between a hero that shows video
        // 100ms in and one that shows a poster all the way home.
        // The shared rule (`tileFlightSurface`, #1269); a row is demanded, a
        // tile keeps today's answer.
        let made = playback.tileFlightSurface(for: postID, url: url, cell: row)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
            print(String(format: "[zoom-live] %.3f producer GRID liveFlightSurface -> %@",
                         CACurrentMediaTime(), made == nil ? "NIL (tile not playing)" : "surface"))
        }
        #endif
        return made
    }

    /// The LANDING row's own moving picture, for the card's rising operand.
    ///
    /// The mirror of `liveFlightSurface`, which serves the DEPARTURE on a
    /// present — and deliberately not the same call: that one resolves by URL,
    /// which this leg must not do. See
    /// `GridVideoPlaybackCoordinator.makeLandingSurface`.
    func landingFlightSurface(for postID: PostID) -> VideoRenderView? {
        if let made = playback?.makeLandingSurface(for: postID) { return made }
        // Nothing to join yet. Ask for the player rather than reporting its
        // absence — the same move `liveFlightSurface` makes for the departure,
        // and for the same reason: this call is repeated every frame of the
        // flight, so a start kicked here is picked up by the next ask. Without
        // it a row that had scrolled out of the autoplay window could only ever
        // land as a thumbnail.
        //
        // The CURRENT PAGE's stream where there is one: a collection whose head
        // is a photograph has a nil `videoURL` and would otherwise never be
        // asked for at all.
        let row = cell(for: postID) as? PostGridListRowCell
        guard let playback, let index = posts.firstIndex(where: { $0.id == postID }),
              let url = row?.currentPageVideoURL ?? posts[index].videoURL,
              let row
        else { return nil }
        playback.demandFlightPlayback(of: postID, url: url, in: row)
        return nil
    }

    /// Forces the landing cell through a layout pass while the card still
    /// covers it.
    ///
    /// The surface can report a decoded frame while the CELL around it has a
    /// pending layout — the render view was just inserted or unhidden, and its
    /// frame resolves on the next pass. Unmounting the card into that gap
    /// shows the cell mid-composition for a frame. Doing the pass under the
    /// card costs nothing visible.
    func finalizeLandingLayout(for postID: PostID) {
        guard let index = posts.firstIndex(where: { $0.id == postID }),
              let cell = collectionView.cellForItem(at: indexPath(for: index))
        else { return }
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
    }

    /// Whether the tile a dismissal is landing on has something to show yet.
    ///
    /// The card is held over the landing until this is true, so "ready" has to
    /// mean *the viewer would see content*, not merely *playback is running*.
    /// Three cases, and the first two are why a swapped-in post could flash:
    ///
    /// - The tile has TAKEN a surface. A dismissal hands its live surface to any
    ///   post carrying a stream, but the old gate only waited when the post also
    ///   passed `autoplaysInGrid` — which excludes square clips. So a square
    ///   video adopted a surface, the gate said ready, the card let go, and the
    ///   surface's first frame had not arrived: one empty tile.
    /// - A still tile is ready when it has a cover. Nothing waited on that at
    ///   all, so landing on a post whose thumbnail was not already cached — the
    ///   normal case for one swapped in from further down the feed — showed the
    ///   tile's background colour until the load returned.
    /// - Nothing realized, or nothing to load: there is no gap to cover.
    ///
    /// `ZoomAnimator.holdCard`'s ceiling bounds all of this, so a cover that
    /// never arrives is a brief pause rather than a stuck card.
    ///
    /// `expectingVideo: false` is a landing that was handed no clip — a close
    /// from another post whose return player was evicted (#923). Only the
    /// still can be waited on then; asking for a clip would hold the card for
    /// the hold's whole ceiling.
    func isLandingPlaybackReady(for postID: PostID, expectingVideo: Bool = true) -> Bool {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return true }
        let post = posts[index]
        let cell = collectionView.cellForItem(
            at: indexPath(for: index)
        ) as? any GridPlaybackCell
        // ⚠️ THE CURRENT PAGE'S STREAM, not page one's. `GalleryPost.videoURL`
        // is `pages.first?.videoURL` for ever, so a collection resting on a clip
        // whose HEAD is a photograph answered nil here and fell through to the
        // still gate below — which reports ready on a COVER while the row has no
        // moving picture at all. That is worse than having no gate: the hold is
        // released by the very thing it exists to hold across.
        let pageVideoURL = (cell as? PostGridListRowCell)?.currentPageVideoURL ?? post.videoURL
        guard let playback else {
            guard let cell, post.thumbnailURL != nil else { return true }
            return cell.renderedCover != nil
        }
        // The shared rule (`isTileLandingReady`, #1269).
        return playback.isTileLandingReady(
            for: postID,
            expectsVideo: expectingVideo && pageVideoURL != nil
                && (autoplays(post) || cell?.loadedVideoRenderView != nil),
            cell: cell, hasThumbnail: post.thumbnailURL != nil
        )
    }




    /// The clip a landing on `index` shows: the carousel's CURRENT page when
    /// the row is a carousel, the post's clip otherwise.
    ///
    /// ⚠️ The flight and its staging already resolved it this way; the two
    /// landings keyed by `posts[index].videoURL`, which is page 0. Landing on a
    /// later clip page, the transfer was refused (a still flash, the page's
    /// player orphaned) or took a prewarmed page-0 player.
    private func landingVideoURL(at index: Int) -> URL? {
        let row = collectionView.cellForItem(at: indexPath(for: index)) as? PostGridListRowCell
        return row?.currentPageVideoURL ?? posts[index].videoURL
    }

    /// Installs the flight card's live surface on the landing tile, so it is
    /// rendering before the card is removed. Answers whether the tile took a
    /// playback.
    @discardableResult
    func adoptLivePlayback(_ view: VideoRenderView, for postID: PostID) -> Bool {
        guard let playback,
              let index = posts.firstIndex(where: { $0.id == postID }),
              let url = landingVideoURL(at: index),
              let cell = collectionView.cellForItem(
                  at: indexPath(for: index)
              ) as? any GridPlaybackCell
        else { return false }
        // Same rule as the present leg: the surface must land in a VISIBLE
        // hierarchy or the layer stops rendering. The cell is still standing in
        // for the flight card at this point, so reveal it first — the card is
        // on top and covers the swap.
        //
        // Through `applyHeroConcealment` rather than `isHidden`, because the
        // two shapes conceal differently: a tile hides whole, a row fades only
        // its preview. Setting `isHidden` on a row would reveal nothing (it was
        // never hidden) and leave the preview — and the surface inside it — at
        // alpha 0, so the video would land invisible.
        Self.applyHeroConcealment(false, to: cell as? UICollectionViewCell)
        // The shared rule (`adoptTileLanding`, #1269).
        return playback.adoptTileLanding(view, for: postID, url: url, cell: cell)
    }

    /// The destination never adopted the parked player — a cancelled flight, or
    /// a plain push. Retires it rather than leaving it decoding unseen.
    ///
    /// Kept for the plain-push fallback, where no handoff scope was opened.
    func discardPlaybackHandoff() {
        playback?.discardHandoff()
    }

    // MARK: - Hero geometry

    // What the zoom transition needs to fly a post's media: where it is, what
    // it looks like, and the ability to hide it while its twin is in the air.
    // All of it is asked of the *page* rather than of a cell, because cells are
    // recycled — the page resolves an id to whatever cell is showing it now, or
    // reports that none is.

    /// Everything a flight needs from a realized cell, resolved together so the
    /// rect, the cover and the style cannot describe different objects.
    struct Hero {
        let frame: CGRect
        let cover: UIImage?
        let style: PostGridFlightCard.Style
    }

    /// The post's flyable media in `space`, or nil when there is nothing to
    /// fly: no realized cell (scrolled out), or a text-only row, which has no
    /// media surface at all. The caller pushes plainly in that case.
    func hero(for postID: PostID, in space: UICoordinateSpace) -> Hero? {
        guard let cell = cell(for: postID), let appearance = heroAppearance(for: postID) else {
            return nil
        }
        let rect: CGRect = switch cell {
        // A brick IS its media, edge to edge; a row is a card of which the
        // media is one part, so fly that part. A TEXT row has no media and no
        // hero — see `heroAppearance`.
        case let tile as PostGridTileCell: tile.bounds
        // A paired (Following) card is its picture, edge to edge, too.
        case let card as PostShelfMediaCardCell: card.bounds
        case let row as PostGridListRowCell: row.mediaHeroRect ?? .zero
        default: .zero
        }
        guard rect != .zero else { return nil }
        return Hero(frame: cell.convert(rect, to: space), cover: appearance.cover, style: appearance.style)
    }

    /// What the flight card should *look* like, without needing a coordinate
    /// space — the card is built before anyone knows the container, and asking
    /// for a frame there would mean inventing one.
    func heroAppearance(for postID: PostID) -> (cover: UIImage?, style: PostGridFlightCard.Style)? {
        switch cell(for: postID) {
        case let tile as PostGridTileCell:
            (cover: tile.renderedCover, style: .tile)
        // A paired card flies as the Following row's cards do: a list
        // media flight, on the card's own corner (`ForYouRowOrigins.card`).
        case let card as PostShelfMediaCardCell:
            (cover: card.renderedCover, style: .listMedia)
        case let row as PostGridListRowCell:
            // A TEXT row answers nil, and that is the whole of its transition
            // policy: no hero, so `openFeed` pushes it natively.
            //
            // It used to fly its whole card, and the attempt is worth one line
            // of warning. A media hero works because the media is the same
            // object at both ends. A text page is its COMMENTS, which a row
            // card has none of, so the card had to impersonate them — first by
            // photographing the page, then by fading the real one in behind a
            // growing card. Each version fixed the previous one's artifact and
            // introduced its own: a skeleton in the still, a blank card, wrong
            // safe area, two captions, a caption floating outside the card. A
            // native push has none of them and is what the platform does.
            row.mediaHeroRect == nil
                ? nil
                : (cover: row.renderedCover, style: .listMedia)
        default:
            nil
        }
    }

    /// **THE TEXT REVEAL**. The whole card of a TEXT row, in
    /// `space` — the rect a clip-window reveal opens from and closes onto.
    ///
    /// Deliberately NOT `hero(for:in:)`'s rect, and the difference is the
    /// point. A media row flies its PREVIEW, because the preview is the one
    /// object that exists at both ends; a text row has no such object, so what
    /// opens is the card itself — caption, metrics and all. The card fills the
    /// cell (`PostGridListRowCell` pins it to `contentView`), so the cell's
    /// own bounds are the card's.
    ///
    /// Answers nil for anything that is not a realized text row: a media row,
    /// a tile, or a post scrolled out of the viewport. The reveal then falls
    /// back to a centred window, exactly as a hero falls back to a centred
    /// collapse.
    func textRowFrame(for postID: PostID, in space: UICoordinateSpace) -> CGRect? {
        guard let row = cell(for: postID) as? PostGridListRowCell,
              row.mediaHeroRect == nil
        else { return nil }
        // ⚠️ THE GUARD ABOVE IS A POLICY, not arithmetic: a row WITH media has
        // a hero, so it flies rather than opening as a window.
        // The WHOLE card. Departing from below the author band was the first
        // attempt and the frames killed it: a window that stops short of the
        // card's top leaves the band outside the transition, so the card gains
        // it in one frame at the landing. The offset is carried instead — see
        // `PostGridListRowCell.revealCaptionTop`.
        return row.convert(row.bounds, to: space)
    }

    /// Moves a row's carousel to `page`, so the card follows the post opened
    /// from it. A no-op for a row that is not realized — a card that scrolled
    /// away has no carousel to move, and will be configured fresh when it
    /// comes back.
    func setMediaPage(_ page: Int, for id: PostID) {
        (cell(for: id) as? PostGridListRowCell)?.setMediaPage(page, animated: false)
    }

    /// Which page of a row's carousel is showing, or nil for a row that has
    /// none — or one the collection view has not realized, which is the honest
    /// answer rather than a guess of zero.
    func currentMediaPage(atIndex index: Int) -> Int? {
        guard posts.indices.contains(index) else { return nil }
        let row = collectionView.cellForItem(at: indexPath(for: index)) as? PostGridListRowCell
        return row?.currentMediaPage
    }

    /// Where the page stops matching the row, in the row's own space — the
    /// reveal's cut line. `nil` when the row is not realized.
    /// The card a dismissal carries home, drawn at the ROW's own width so its
    /// caption wraps and truncates exactly as the row's does — or, for a post
    /// this page draws as a TILE, the tile.
    ///
    /// ⚠️ A TILE IS NOT A ROW, and this used to draw one for it. On Discover a
    /// chunk's tile opens with a flight; page onto a text post and the close
    /// is the card-shaped window (`installTextReveal`, `presenting: false`),
    /// whose stand-in came from here — a whole post card, author band, caption
    /// and actions, squeezed into the tile's rect. Filmed as "the whole post
    /// interface squashed" in a window that should have held the tile's
    /// picture. The tile's own twin (`PostGridTileStandInView`) is what the
    /// window lands as now, the rows' #314 arrangement for a brick.
    func makeDismissStandIn(for postID: PostID) -> UIView? {
        // With its live count (#896): the stand-in draws the number the tile
        // it hands over to draws, a like made in the feed it opened included.
        guard let post = post(for: postID) else { return nil }
        if drawsAsTile(postID) { return makeTileStandIn(for: post) }
        // The realized row's width when there is one, the list's own otherwise:
        // a row scrolled out still has to produce a card, and the width is a
        // property of the LIST rather than of any particular cell.
        let width = cell(for: postID)?.bounds.width ?? collectionView.bounds.width
        guard width > 0 else { return nil }
        return RevealDismissCardView(
            post: post,
            width: width,
            imagePipeline: imagePipeline,
            // The viewer may have opened this caption out before opening the
            // post. The expansion belongs to the SURFACE, not to the cell, so
            // it is here to be asked for — and a stand-in that does not ask
            // flies a truncated card home, "Show more" and all, onto a row that
            // is showing the whole thing.
            captionExpanded: captionExpansion.isExpanded(postID),
            showsAuthorMenu: showsAuthorMenu(for: post),
            // ⚠️ What the row wires — see `configure`: the bookmark always,
            // the repost only once something handles it (#801). The saved
            // state is read from the same store the row reads, so a post saved
            // a moment ago flies home filled in.
            actions: .init(
                repost: onRepostRequested != nil, bookmark: bookmarks != nil,
                saved: bookmarks?.isSaved(postID.rawValue) ?? false,
                // The like stakes on every row `staking` binds, and its heart
                // is red once the viewer has — the stand-in reads the same
                // wallet, or the heart changes colour in the landing frame.
                stake: staking?.viewerStake(on: postID)
            ),
            // The row's own date when there is a row — see
            // `PostGridListRowCell.renderedAgeText`.
            ageText: (cell(for: postID) as? PostGridListRowCell)?.renderedAgeText,
            // The ROW's own height when it is realized — see the profile's
            // twin, and `RevealDismissCardView.init`.
            height: cell(for: postID)?.bounds.height
        )
    }

    /// The window's stand-in for `postID`, wearing the tile's parked clip
    /// when there is one (#1294): a close from a text page plays the tile
    /// home rather than carrying a still of it.
    func makeWindowStandIn(for postID: PostID) -> UIView? {
        dressWithReturnClip(makeDismissStandIn(for: postID), for: postID)
    }

    /// `standIn` playing `postID`'s parked clip — a tile's or a paired card's;
    /// a row's card has no picture to play it in.
    func dressWithReturnClip(_ standIn: UIView?, for postID: PostID) -> UIView? {
        guard drawsAsTile(postID) || drawsAsPairedCard(postID) else { return standIn }
        return windowClips.dress(standIn, for: postID) { returnFlightSurface(for: postID) }
    }

    /// A card window's close is over: one that sprang back pauses the clip
    /// its stand-in was playing, for the next close (#1294).
    func windowCloseDidEnd(_ committed: Bool, for postID: PostID) {
        guard !committed else { return }
        windowClips.abandon(postID) { pauseReturnPlayback(for: postID) }
    }

    /// `sizingUnrealizedFromLayout` is for a tile landing in its OWN slot, where
    /// the layout's rect is the one the close measures too; a swap into
    /// another post's slot keeps the rule above and refuses a guessed size.
    private func makeTileStandIn(
        for post: GalleryPost, slotOf occupantID: PostID, sizingUnrealizedFromLayout: Bool
    ) -> UIView? {
        let laidOut = sizingUnrealizedFromLayout ? slotSize(of: occupantID) : nil
        guard let size = cell(for: occupantID)?.bounds.size ?? laidOut,
              size.width > 0, size.height > 0
        else { return nil }
        // A paired slot is a Following card: its twin is that card as it
        // rests — the picture the cell is showing and the words over it — the
        // Following row's own stand-in (`ForYouRowOrigins.cardReveal`).
        if drawsAsPairedCard(occupantID) {
            let cover = (cell(for: occupantID) as? PostShelfMediaCardCell)?.renderedCover
                ?? post.thumbnailURL.flatMap { imagePipeline.cachedImage(for: $0) }
            return PostShelfMediaCardCell.makeStandIn(
                for: post, cover: cover, size: size, imagePipeline: imagePipeline,
                // The heart, as the card in the slot will draw it.
                viewerStake: viewerStake(on: post.id)
            )
        }
        return PostGridTileStandInView(
            post: post,
            size: size,
            // The PAGE's rounding, not the cell default: this grid's gutter and
            // curve are one decision — see `tileCornerRadius`.
            cornerRadius: tileCornerRadius,
            imagePipeline: imagePipeline,
            viewerStake: viewerStake(on: post.id),
            // The slot's words, as the tile in it wears them — wrapped at the
            // slot's size, posed as the window travels.
            showsInfo: tileWearsInfo(occupantID)
        )
    }

    /// A tile's OWN twin — `post` in its own slot. See `makeDismissStandIn`.
    func makeTileStandIn(for post: GalleryPost) -> UIView? {
        makeTileStandIn(for: post, slotOf: post.id, sizingUnrealizedFromLayout: true)
    }

    /// The size the layout gives `postID`'s slot, for a slot with no realized
    /// cell to measure — a close whose tile scrolled out under the open post
    /// still lands as that tile rather than as nothing (and nothing, for a
    /// window, is the live page squeezed into the tile's rect).
    private func slotSize(of postID: PostID) -> CGSize? {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return nil }
        return collectionView.layoutAttributesForItem(at: indexPath(for: index))?.size
    }

    /// The window a TILE's post opens (a text tile) and closes (any tile, once
    /// the feed has paged onto words) through — for a host that opens its
    /// tiles through `presentSnapFeedHero` (`RowCardCloseLanding`).
    ///
    /// ⚠️ OFFERED FOR MEDIA TILES TOO, the rows' rule (`ForYouRowOrigins`):
    /// `hasHero` decides the opening, and this decides whether a close that
    /// has nothing left to fly has anywhere to go. Without it a tile opened by
    /// a flight and paged onto a text post had neither grab — both refuse a
    /// `.card` page — and a chevron that cut.
    ///
    /// Marker-shaped, for the place page's reason: the feed is a pager, so the
    /// tile and the page are the same post only until the first swipe. The
    /// tile's own twin is the stand-in at both ends, in the tile's own shape
    /// and ground; nothing is aligned (a tile has no caption to align to).
    /// `willStageDismissal` is the host's: bring the tile back and pin the
    /// inset before the landing is measured.
    func tileWindow(
        for post: GalleryPost,
        willStageDismissal: @escaping () -> Void,
        dismissalDidEnd: @escaping (Bool) -> Void
    ) -> TextRevealOrigin? {
        guard drawsAsTile(post.id), rowFrame(for: post.id, in: self) != nil else { return nil }
        let anchor = post.id
        return TextRevealOrigin(
            rowFrame: { [weak self] space in self?.rowFrame(for: anchor, in: space) },
            captionEnd: nil,
            depthView: { [weak self] in self },
            // Playing the tile's parked clip when it has one (#1294).
            makeDismissStandIn: { [weak self] _ in
                self?.dressWithReturnClip(self?.makeTileStandIn(for: post), for: anchor)
            },
            makePresentStandIn: { [weak self] in self?.makeTileStandIn(for: post) },
            alignsPageToSource: false,
            pageFit: .covering,
            cornerRadius: tileCornerRadius(for: anchor),
            fill: PostGridTileCell.fillColor(for: post),
            setConcealed: { [weak self] concealed in
                self?.setRevealConcealed(concealed, for: anchor)
            },
            willStageDismissal: { _ in willStageDismissal() },
            dismissalDidEnd: { [weak self] committed in
                self?.windowCloseDidEnd(committed, for: anchor)
                dismissalDidEnd(committed)
            }
        )
    }

    /// Whether the row for `post` draws a "...", asked of the same provider the
    /// row asks. The stand-in has to match it or the control pops in or out in
    /// the last frame — see `RevealDismissCardView`.
    private func showsAuthorMenu(for post: GalleryPost) -> Bool {
        guard let authorID = post.authorID, let authorMenuActions else { return false }
        // The anchor only ever places a popover, and nothing is being presented
        // here: this asks the provider what it WOULD offer.
        let context = AuthorMenuContext(post: post, authorID: authorID, anchor: UIView())
        return !authorMenuActions(context).isEmpty
    }

    /// The row's author band, for the destination to borrow during a flight.
    /// The realized ROW's own reading when there is one — its date included,
    /// which is a function of the clock and must match what the card says —
    /// and the post's otherwise, so it answers for a row that has scrolled
    /// out as readily as for one on screen.
    func textRowAuthorBand(for postID: PostID) -> PostAuthorBandView.Model? {
        if let model = (cell(for: postID) as? PostGridListRowCell)?.authorBandModel { return model }
        return posts.first { $0.id == postID }.map { PostAuthorBandView.Model(post: $0) }
    }

    /// The pipeline this page draws with, so a borrowed band can load the same
    /// avatar from the same cache rather than fetching its own copy.
    var bandImagePipeline: ImagePipeline { imagePipeline }

    /// How far below the row's top its caption begins — the band's height plus
    /// its gap, or zero. See `PostGridListRowCell.revealCaptionTop`.
    func textRowCaptionTop(for postID: PostID) -> CGFloat {
        (cell(for: postID) as? PostGridListRowCell)?.revealCaptionTop ?? 0
    }

    func textRowCaptionEnd(for postID: PostID) -> CGFloat? {
        (cell(for: postID) as? PostGridListRowCell)?.revealCut
    }

    /// Which posts the viewer currently cannot see, whatever is hiding them.
    ///
    /// Answered from the CELLS rather than from the concealment flags, because
    /// the two came apart — a flag naming one post while another row was the
    /// invisible one is the whole of two separate defects. A caller asking
    /// "what is on screen" must not be told what the bookkeeping believes.
    ///
    /// The index mapping lives here because the sections do: a caller walking
    /// the collection view itself would have to re-derive Discover's stretches
    /// or the lists' arrivals split.
    func concealedPosts() -> Set<PostID> {
        var hidden: Set<PostID> = []
        for cell in collectionView.visibleCells {
            guard let path = collectionView.indexPath(for: cell) else { continue }
            let index = flatIndex(for: path)
            guard posts.indices.contains(index) else { continue }
            let card = cell.contentView.subviews.first
            if cell.isHidden || cell.alpha == 0 || card?.alpha == 0
                || (cell as? PostGridListRowCell)?.isHeroMediaConcealed == true {
                hidden.insert(posts[index].id)
            }
        }
        return hidden
    }

    /// Whether a landing conceals the row's MEDIA while the card flies to it.
    ///
    /// True on a timeline, where concealing takes the preview and leaves the
    /// card standing; false on a grid, where a tile IS its media and concealing
    /// it would leave a hole in the mosaic for the length of the flight.
    var landingConcealsMedia: Bool { style == .list }

    /// The same question for ONE landing — what the flight actually asks,
    /// because Discover answers it both ways: a card's preview is concealed,
    /// a chunk's tile is not (a hole in a chunk is as much a hole as one in
    /// the mosaic).
    func landingConcealsMedia(for postID: PostID) -> Bool {
        !drawsAsTile(postID)
    }

    /// The post's whole cell, whatever kind of cell it is.
    ///
    /// ⚠️ THE ANSWER OF LAST RESORT FOR A CLOSE, and it exists because the two
    /// specific ones REFUSE each other's rows on purpose: `hero(for:)` answers
    /// nil for a text row (it has no media to fly) and `textRowFrame(for:)`
    /// answers nil for a media row (it has a hero, so it flies instead). Each
    /// refusal is right on its own, and between them a close whose anchor
    /// turned out to be the other kind has NOTHING — so it collapsed into the
    /// middle of the screen, which is what "the transition window returns to
    /// the centre" looks like.
    ///
    /// Landing on the right card in the wrong shape is a small infelicity;
    /// landing nowhere is a broken transition. This is the floor under both.
    func rowFrame(for postID: PostID, in space: UICoordinateSpace) -> CGRect? {
        guard let cell = cell(for: postID) else { return nil }
        return cell.convert(cell.bounds, to: space)
    }

    /// Whether a realized cell for the post is currently within the viewport —
    /// the hero falls back to a centered collapse when it isn't.
    func isPostVisible(_ postID: PostID) -> Bool {
        guard let cell = cell(for: postID) else { return false }
        return collectionView.bounds.intersects(cell.frame)
    }

    /// Pins the content inset the grid is currently laid out with, so nothing
    /// can move the cells for the duration of a flight.
    ///
    /// **This is what makes a single landing measurement valid.** A pop animates
    /// the safe area — the navigation bar's height interpolates as the pop
    /// scrubs — and this collection view adds that safe area to its own inset,
    /// which drags `contentOffset` along with it. Measured: `adjustedContentInset
    /// .top` crept 102 → 106 across one drag and settled at 116, while the cell's
    /// frame *within the content* never moved at all. The card was therefore
    /// aimed at a tile that was still travelling, and landed ~21pt high.
    ///
    /// Freezing converts the inset from "safe area plus mine" to a constant
    /// equal to whatever it resolved to at freeze time, so the cells hold still
    /// through the whole transition and one rect is the truth. The caller freezes
    /// only after forcing a layout with the tab bar restored, so the value
    /// captured is the RESTING one — the same inset the grid will still have
    /// when the pop finishes, which is why thawing cannot move anything either.
    /// The OFFSET is preserved across the switch, and that is not belt and
    /// braces — it is the difference between freezing the grid and scrolling
    /// it.
    ///
    /// `contentInsetAdjustmentBehavior = .never` lands one assignment before
    /// `contentInset = resolved`, and in that instant the adjusted inset
    /// collapses to whatever `contentInset` still holds (zero, for this grid).
    /// UIKit re-clamps `contentOffset` against it immediately, so a grid
    /// resting at the TOP — where `offset.y == -adjustedInset.top` — is
    /// yanked to 0 and every cell moves up by the whole top inset. Measured
    /// on this screen: `offset=-116 → offset=0`, which put a landing rect
    /// 116pt above the row it departed from.
    ///
    /// It only shows when the grid is scrolled to its very top, because that
    /// is the only place where the offset is pinned to the inset it is about
    /// to lose — which is why a freeze that has been correct for every
    /// mid-scroll flight still had this in it.
    func beginHeroFreeze() {
        guard frozenContentInset == nil else { return }
        let offset = collectionView.contentOffset
        frozenContentInset = collectionView.contentInset
        let resolved = collectionView.adjustedContentInset
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = resolved
        collectionView.contentOffset = offset
    }

    /// Opens a post from a PUSHED screen with this page's inset pinned — from
    /// the tap until the host is back on screen and thaws it (its
    /// `viewDidAppear`).
    ///
    /// ⚠️ PINNED FOR THE WHOLE VISIT, not only for the close. A pushed list
    /// adds the safe area to its inset, and while a post covers it that safe
    /// area is not the list's: the view leaves the window, and the pop settles
    /// the chrome only after a close has ended. Each change drags
    /// `contentOffset` along (see `beginHeroFreeze`), so a list that tracked
    /// them came back from a post shifted. For You's
    /// own page is pinned by its flight source for the same reason.
    ///
    /// A push that did not happen — the stack refused it — hands the inset
    /// straight back.
    func openHoldingStill(from host: UIViewController, _ open: () -> Void) {
        pinForPushedClose()
        open()
        if host.navigationController?.topViewController === host,
           host.navigationController?.transitionCoordinator == nil {
            endHeroFreeze()
        }
    }

    /// The pin a pushed screen asks for at the tap and again as a close
    /// stages — `beginHeroFreeze`, unless `-list-jump-unpinned` asks for the
    /// old behaviour (DEBUG: the control run that shows the jump this pin
    /// removes, read with `-list-jump-trace`).
    func pinForPushedClose() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-list-jump-unpinned") { return }
        #endif
        beginHeroFreeze()
    }

    /// Symmetrical with the freeze, and for the same reason: the two
    /// assignments below each re-clamp `contentOffset` against an inset that
    /// is momentarily wrong, so the offset is carried across by hand rather
    /// than left to survive them.
    func endHeroFreeze() {
        guard let frozenContentInset else { return }
        let offset = collectionView.contentOffset
        let pinnedTop = collectionView.adjustedContentInset.top
        self.frozenContentInset = nil
        // A hosted page manages its insets manually for its whole life — the
        // pre-freeze behaviour to restore is `.never` there, not the default.
        collectionView.contentInsetAdjustmentBehavior =
            hostedTopInset == nil ? .automatic : .never
        collectionView.contentInset = frozenContentInset
        collectionView.contentOffset = offset
        // The footer may have opened or closed while the inset was pinned, and
        // those writes were dropped. Re-apply now that it is ours again.
        applyBottomInset()
        // ⚠️ A THAW ONTO A DIFFERENT INSET IS SETTLED HERE, OR THE NEXT UPDATE
        // MOVES THE ROWS. The collection view re-bases its offset on the inset
        // it recorded at its last UPDATE (`_restoreOrAdjustContentOffset
        // IfNecessaryWithInsets:`, from a later `layoutSubviews` →
        // `_updateVisibleCellsNow:`) and keeps `offset + top inset` constant
        // across the difference. The pinned and resting insets differ whenever
        // the chrome moved while the list was covered — under #323's large
        // titles (since removed) it was pinned t168 (expanded, at the tap),
        // resting t116 (the departure reveal had scrolled the list to 204), so
        // about a second after a grab's return the rows slid 52pt up (204 →
        // 256), after the viewer had them back. Measured with
        // `-list-jump-trace` and a KVO stack, 2026-09-30. Without a large title
        // the two usually agree and this is a no-op; when they do not, an
        // empty update records the resting inset, and the offset the viewer
        // sees is restated over whatever it re-based to.
        if abs(collectionView.adjustedContentInset.top - pinnedTop) > 0.5 {
            UIView.performWithoutAnimation {
                collectionView.performBatchUpdates(nil)
                collectionView.layoutIfNeeded()
            }
            collectionView.contentOffset = offset
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-list-jump-trace") {
            print("[list-jump] thaw from offset=\(offset.y) pinnedTop=\(pinnedTop) → \(debugInsetState)")
        }
        #endif
    }

    /// Puts a post the list no longer holds INTO it, at the departure slot.
    ///
    /// Whole-table, unconditionally: an insert changes the count of whichever
    /// section it lands in, and `split` — the leading run of arrivals — can
    /// change with it, so there is no targeted update that can honestly
    /// describe this. The cost is the same one the swap pays when the run
    /// moves, and it is paid under a screen the post being dismissed is
    /// covering.
    private func insertPost(_ post: GalleryPost, at slot: Int) -> Bool {
        posts.insert(post, at: slot)
        UIView.performWithoutAnimation {
            collectionView.reloadData()
            // The caller reads the landing rect from a realized cell the moment
            // this returns; `reloadData` alone leaves `cellForItem` answering
            // nil and the flight collapses to the middle of the screen.
            collectionView.layoutIfNeeded()
            if let cell = collectionView.cellForItem(at: indexPath(for: slot)) {
                cell.isHidden = false
                cell.alpha = 1
                cell.layoutIfNeeded()
            }
        }
        warmLandingCover(of: post)
        return true
    }

    /// The cover a close is about to land on, loaded now at the visible
    /// priority: the tile is on screen the moment the flight ends, which is
    /// no lookahead's guess. Shared with the cell's own load (one fill).
    private func warmLandingCover(of post: GalleryPost) {
        guard let url = post.thumbnailURL, !imagePipeline.isDecoded(url) else { return }
        let pipeline = imagePipeline
        Task { _ = try? await pipeline.image(for: url) }
    }

    /// Hides the real cell while its twin is flying.
    /// Hides the real cell while its twin is flying, and keeps it hidden.
    ///
    /// The flag lives on the PAGE, keyed by post, and is re-applied at every
    /// dequeue — it is not enough to set `isHidden` on the cell that happens to
    /// be realized now. Two things break that: a `reloadData` (a page landing
    /// mid-flight) hands back a fresh, VISIBLE cell, so the tile reappears
    /// under the card and the viewer sees it twice; and a recycled cell carries
    /// the stale `isHidden` to whatever index it is next used for, leaving an
    /// invisible tile somewhere else in the grid.
    #if DEBUG
    /// `-foryou-visibility-log`: the state of the grid's visibility invariant at
    /// a named moment.
    ///
    /// Written to answer one question the simulator would not: when a tile has
    /// vanished on device, is it HIDDEN or is it ABSENT? Those point at opposite
    /// halves of the system — a leaked hero hide against a data/arrangement
    /// fault — and no screenshot distinguishes them.
    ///
    /// `hero` should be nil whenever no flight is in the air; a non-nil value
    /// here is a leaked hide, and every future dequeue of that post will hide
    /// its cell. `hidden` should be empty for the same reason. `posts` and
    /// `items` must agree, or the data source and the collection view have
    /// diverged and cells are missing rather than invisible.
    func logVisibility(_ moment: String) {
        guard ProcessInfo.processInfo.arguments.contains("-foryou-visibility-log"),
              style == .grid
        else { return }
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        let invisible = visible.compactMap { path -> String? in
            guard let cell = collectionView.cellForItem(at: path) else { return nil }
            guard cell.isHidden || cell.alpha == 0 else { return nil }
            let id = posts.indices.contains(path.item) ? posts[path.item].id.rawValue : "?"
            return "\(path.item):\(id)\(cell.isHidden ? "/hidden" : "")\(cell.alpha == 0 ? "/alpha0" : "")"
        }
        let blank = visible.compactMap { path -> String? in
            guard let cell = collectionView.cellForItem(at: path) as? any GridPlaybackCell,
                  posts.indices.contains(path.item) else { return nil }
            let post = posts[path.item]
            guard post.thumbnailURL != nil, cell.renderedCover == nil,
                  cell.loadedVideoRenderView?.isReadyForDisplay != true
            else { return nil }
            return "\(path.item):\(post.id.rawValue)"
        }
        let items = collectionView.numberOfSections > 0
            ? collectionView.numberOfItems(inSection: 0) : 0
        let ids = Set(posts.map(\.id))
        print("[vis] \(moment) hero=\(heroHiddenPostID?.rawValue ?? "nil")"
            + " posts=\(posts.count) items=\(items) uniqueIDs=\(ids.count)"
            + " visible=\(visible.count) invisible=\(invisible.isEmpty ? "none" : invisible.joined(separator: ","))"
            + " blank=\(blank.isEmpty ? "none" : blank.joined(separator: ","))"
            + (posts.count == items && ids.count == posts.count ? "" : "  <<< DATA SOURCE DIVERGED"))
    }
    #endif

    /// `conceals` is false for a DISMISSAL. The card is flying home TO this
    /// tile, so hiding it opens a hole in the grid for the whole flight and the
    /// tile pops in at the end. Left visible, the card simply lands on top of
    /// content that was already there. A presentation still conceals: there the
    /// card is flying AWAY from the tile, and two copies of the same post would
    /// be on screen at once.
    /// CONCEAL EXACTLY WHAT THE FLIGHT REPRODUCES.
    ///
    /// A tile IS its media edge to edge, so the whole cell goes. A row is a
    /// card of which the media is one part, and `hero(for:in:)` flies that
    /// part — so hiding the whole row removed the caption, author line and
    /// metrics that nothing in the air was standing in for. They were absent
    /// for the length of the flight and snapped back on its last frame, which
    /// is the reported "the rest of the post pops in at the end".
    ///
    /// One function so the two paths that conceal — this and `cellForItemAt`,
    /// which re-applies on every dequeue — cannot drift apart. They already
    /// had to agree; now they agree by construction.
    /// Internal, not private, so the routing itself is testable: the defect
    /// was not in either cell, it was in one call site treating a row like a
    /// tile.
    /// `carry` says what the transition is taking away — see
    /// `PostGridListRowCell.HeroCarry`. Defaults to the flight's answer, so the
    /// hero channel reads exactly as it did; the reveal channel says `.card`.
    static func applyHeroConcealment(
        _ concealed: Bool,
        to cell: UICollectionViewCell?,
        carrying carry: PostGridListRowCell.HeroCarry = .media
    ) {
        switch cell {
        // A row keeps everything the flight is not carrying — and which part
        // that is depends on the row, so the row is asked. It used to be
        // assumed: only media rows flew, so the preview was hard-coded here.
        // A text row flies too now, and what it carries away is the whole card.
        case let row as PostGridListRowCell:
            row.isHidden = false
            row.setHeroConcealed(concealed, carrying: carry)
        case let other?:
            other.isHidden = concealed
        case nil:
            break
        }
    }

    /// Hides the row a reveal's window was taken from, for the flight's length.
    /// See `revealConcealedPostID` for why this does not go through
    /// `setHeroHidden`.
    /// Reveals whatever row a reveal is currently hiding, whoever hid it.
    ///
    /// A belt for the one path that can strand a concealment: a card-shaped
    /// close CANCELLED leaves the row hidden under the page it sprang back to —
    /// correct, since the page is covering it — and the viewer may then leave
    /// by another route entirely (paging to a post that flies, and tapping
    /// back). Nothing in that second transition knows a row is waiting to be
    /// put back.
    func clearRevealConcealment() {
        guard let postID = revealConcealedPostID else { return }
        setRevealConcealed(false, for: postID)
    }

    /// Puts back whatever a FLIGHT hid, whoever ended up finishing the close.
    ///
    /// ⚠️ THE HIDE AND THE UNHIDE CAN BELONG TO DIFFERENT DRIVERS, and that is
    /// the whole reason this exists. The push hides the tapped row's media so
    /// the card flies alone, and the flight's own return puts it back — but the
    /// feed is a PAGER: page onto a text post and the close is the card
    /// driver's, so the flight never runs a return leg and never unhides
    /// anything. The row came back with its caption and a blank where its
    /// photograph had been, for the rest of the session.
    ///
    /// Reported after several round trips, because it accumulates: one row per
    /// visit that ended on another kind of post. The sweep inside
    /// `setHeroHidden(false:)` is what collects the ones neither reference
    /// still names.
    func clearHeroConcealment() {
        // ⚠️ NO GUARD ON THE FLAGS, and the first version of this had one.
        //
        // The flags are what a leak may well NOT have. The post→cell mapping is
        // not stable across a flight — staging swaps the landed post into the
        // departure slot — so an unhide by lookup can clear the wrong instance
        // and nil the flags while the cell that was actually hidden stays at
        // alpha 0. A guard would skip the sweep in exactly that case, and the
        // sweep costs one pass over the visible cells.
        //
        // (What actually fixed the reported leak was WHERE this is called from
        // — `viewDidAppear` rather than a driver's callback. The guard was
        // dropped alongside it and the two were never measured apart; this is
        // the cheaper of the two shapes to be wrong about.)
        setHeroHidden(false, for: heroHiddenPostID ?? heroFlyingPostID ?? PostID(""))
    }

    func setRevealConcealed(_ concealed: Bool, for postID: PostID) {
        revealConcealedPostID = concealed ? postID : nil
        // ⚠️ WHATEVER KIND OF CELL IT IS. This resolved `as? PostGridListRowCell`
        // and did nothing at all for anything else — so on the Discover GRID,
        // whose cells are tiles, the landing was never hidden: the window
        // closed onto a tile that was visible underneath it the whole way, two
        // copies of the same post. Filmed. The hero channel beside this one has
        // always switched on the cell (`applyHeroConcealment`); this one was
        // written when only list surfaces opened windows and never caught up.
        let target = cell(for: postID)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-text-reveal-log") {
            // Whether the cell it names is REALIZED, because a concealment
            // applied to nothing looks exactly like one that was never asked
            // for — and the cell it must hide is the one a dismissal is landing
            // on.
            print("[text-reveal] conceal=\(concealed) post=\(postID.rawValue)"
                + " cell=\(target.map { String(describing: type(of: $0)) } ?? "MISSING")")
        }
        #endif
        // ⚠️ THE WHOLE CARD, because that is what a window carries.
        //
        // This shares its machinery with the hero's channel, and the hero takes
        // only the picture out of a media row. Sharing the DEFAULT as well meant
        // a window landing on a media row hid that row's picture and left its
        // author line, caption and metrics drawn underneath the window that was
        // already drawing them — the same card twice. It only shows on a close
        // whose two ends differ in kind, which is why it outlived the fix that
        // made this switch on the cell at all.
        Self.applyHeroConcealment(concealed, to: target, carrying: .card)
        // ⚠️ THE INSTANCE, NOT JUST THE ID — the hero channel has kept one of
        // these since the day a lookup cleared the wrong cell, and this channel
        // never got the same treatment.
        //
        // The post→cell mapping is not stable across a close (a refresh can
        // re-render the page under it), so by the time the concealment is lifted
        // `cell(for:)` can resolve the id to a different instance, or to none at
        // all. A live capture of a reported session shows the precondition
        // happening five times in one minute — `row=MISSING`, once of them on a
        // `conceal=true`.
        //
        // ⚠️ DEFENSIVE BY ANALOGY, NOT MEASURED. Every route to it reachable
        // from a test recycles the cell on the way, and reuse now clears both
        // channels, so nothing here fails without this guard. It is kept
        // because the sibling channel earned the same one the hard way and the
        // cost is a weak reference — but it has not been shown to fix anything,
        // and this note is what stops the next reader assuming it did.
        if concealed {
            revealConcealedCell = target
        } else {
            Self.applyHeroConcealment(false, to: revealConcealedCell)
            revealConcealedCell = nil
            // A committed window close is landing (the reveal shows the row
            // again only then): the tile takes the clip its window was
            // playing (#1294).
            windowClips.land(
                postID, over: (cell(for: postID) as? UICollectionViewCell)?.contentView,
                land: { landReturnPlayback($0, for: postID) },
                isReady: { [weak self] in self?.isReturnLandingReady(for: postID) ?? true }
            )
        }
    }

    func setHeroHidden(_ hidden: Bool, for postID: PostID, conceals: Bool = true) {
        heroFlyingPostID = hidden ? postID : nil
        heroHiddenPostID = (hidden && conceals) ? postID : nil
        // Apply to whatever is on screen right now; `cellForItemAt` covers
        // everything realized from here on.
        let resolved = cell(for: postID)
        Self.applyHeroConcealment(hidden, to: resolved)
        if hidden {
            heroHiddenCell = resolved
        } else {
            // The instance that was actually hidden, which a lookup may no
            // longer reach.
            Self.applyHeroConcealment(false, to: heroHiddenCell)
            heroHiddenCell = nil
            // And a sweep, because a flight can end without either reference
            // naming the hidden cell — an interrupted transition, or a swap
            // that moved the post twice. No flight is in the air once the flag
            // is nil, so nothing on screen may legitimately be invisible.
            for visible in collectionView.visibleCells {
                if visible.isHidden { visible.isHidden = false }
                // Skip a row a REVEAL is holding: this broom is for a media
                // flight's leftovers, and sweeping the other flight's row back
                // into view mid-grab is exactly what it must not do.
                if let row = visible as? PostGridListRowCell,
                   revealConcealedPostID == nil || cell(for: revealConcealedPostID!) !== row {
                    row.setHeroConcealed(false)
                }
            }
        }
        // Unhiding is the end of a flight. The tile is excluded from
        // candidates while its twin is in the air (or it would adopt the
        // player mid-flight and blank the card), so this is the first moment
        // it may claim the player the destination parked for it.
        if !hidden {
            updateAutoplay()
            #if DEBUG
            logVisibility("unhide")
            #endif
        }
    }

    /// The post behind an id, for a flight card that must configure itself
    /// from the model rather than from a cell that may not be realized.
    /// With its live like count (#896): what the flight, the close's
    /// stand-in and a seeded feed draw is what the bound card draws.
    func post(for postID: PostID) -> GalleryPost? {
        posts.first { $0.id == postID }.map { staking?.liveCopy(of: $0) ?? $0 }
    }

    /// The posts `new` adds to `old`, or nil when this is not an addition.
    ///
    /// Membership, not order. The old rule demanded that `new` be exactly `old`
    /// plus a suffix, so a page landing failed it whenever the discovery source
    /// had re-ranked the corpus in the meantime — which Trending does on every
    /// page. `apply` then took the reload branch and re-permuted EVERY slot,
    /// and the grid visibly reshuffled under the viewer: tiles they were looking
    /// at jumped elsewhere, reading as tiles vanishing.
    ///
    /// So a re-rank that only ADDS is treated as an addition. The upstream
    /// ordering is honoured for the newcomers and ignored for posts already
    /// placed, which is what the layout's immutable slices promise anyway — a
    /// slot's contents do not move once the viewer has seen them. A genuine
    /// removal or replacement still falls through to the reload.
    static func addedPosts(from old: [GalleryPost], to new: [GalleryPost]) -> [GalleryPost]? {
        guard !old.isEmpty, new.count > old.count else { return nil }
        let existing = Set(old.map(\.id))
        // Everything already on screen must still be there. A post that
        // disappeared is a removal, which an insert cannot express.
        guard existing.isSubset(of: Set(new.map(\.id))) else { return nil }
        let added = new.filter { !existing.contains($0.id) }
        // And the arithmetic has to close: same membership plus the newcomers,
        // or something was duplicated and the counts would drift.
        guard added.count == new.count - old.count else { return nil }
        return added
    }

    private func cell(for postID: PostID) -> UICollectionViewCell? {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return nil }
        return collectionView.cellForItem(at: indexPath(for: index))
    }

    func render(_ state: ForYouViewModel.PageState) {
        // The sections or the new run's count may have moved under the bar.
        defer { schedulePinnedSectionCheck() }
        switch state {
        case .loading:
            emptyState.isHidden = true
            // A refresh keeps the existing rows under the spinner rather than
            // blanking to skeletons — the content is still valid until the
            // new page lands.
            //
            // ⚠️ Discover hands back the CORPUS, not `posts`: its display
            // order has the chunks' media pulled forward, and re-planning that
            // as if it were the ranking would lay out a different list under a
            // spinner that promised to change nothing.
            // Titled groups are planned from their groups, which a refresh
            // under the spinner does not change.
            guard !(isGrouped && !posts.isEmpty) else { break }
            apply(style == .discover ? rawPosts : posts,
                  skeleton: !refreshControl.isRefreshing && posts.isEmpty)
        case .content(let posts):
            emptyState.isHidden = true
            leaveGroups()
            apply(posts, skeleton: false)
        case .empty(let empty):
            showStatus(
                symbolName: style == .grid ? "photo.on.rectangle.angled" : "tray",
                title: empty.title,
                subtitle: empty.subtitle
            )
        case .failed(let message):
            // A failure gets the one thing an empty page does not: something to
            // press. Pull-to-refresh is already here, but a page with no rows
            // is a page with nothing to pull, so the retry has to be visible.
            showStatus(
                symbolName: "exclamationmark.triangle",
                title: message,
                actionTitle: "Try Again",
                action: { [weak self] in self?.onRefresh?() }
            )
        }
        lookahead.setNeedsPlan()
    }

    private func apply(_ incoming: [GalleryPost], skeleton: Bool) {
        // Consumed here whatever happens next: it describes THIS delivery, and
        // leaving it armed would force the next genuine page landing to reload.
        // Groups just left redraw whatever arrives: the same posts, untitled,
        // are still a different list.
        let leftGroups = leftGroups
        self.leftGroups = false
        let mustReload = mustReload || leftGroups
        self.mustReload = false
        // On Discover the corpus's COMPLETENESS is an input too: the last page
        // can land with nothing new in it and still decide the tail's chunk.
        let completenessMoved = style == .discover && plannedCorpusComplete != isCorpusComplete
        guard rawPosts != incoming || showsSkeleton != skeleton || completenessMoved || leftGroups
        else { return }
        // ⚠️ **SETTLE ANY PENDING RELOAD AGAINST THE OLD MODEL FIRST.** A batch
        // insert below takes its "before" counts from the collection view — and
        // a `reloadData` still pending (the slice layout's first-geometry
        // re-plan, `replanArrangement`, posts one a turn after `prepare`) makes
        // it re-ask the data source instead, AFTER the model below has already
        // grown: "before 27, after 27, insert 14" and an
        // NSInternalInconsistencyException. Measured on the simulator: a
        // second page landing in the same turn as that re-plan crashed For You
        // at launch. A layout pass here consumes the reload while the counts
        // are still the old ones; with nothing pending it costs nothing.
        collectionView.layoutIfNeeded()
        if !mustReload, !completenessMoved, applyCountsOnly(incoming, skeleton: skeleton) { return }
        // Hydration retires the skeleton with a cross-dissolve, the same
        // in-place hand-off the profile gallery uses.
        let dissolving = showsSkeleton && !skeleton && !incoming.isEmpty && window != nil
        // A page landing is a pure APPEND, and `reloadData` would recycle every
        // realized cell to express it. That is what made a drag stop and restart
        // all four playing tiles inside 60ms — the players were fine, the cells
        // under them were destroyed and rebuilt. Inserting only the new items
        // leaves existing cells (and their playback) untouched.
        //
        // Measured against the RAW list, not the arranged one: arrangement is a
        // permutation, so an append upstream is still an append downstream, and
        // comparing raw keeps that fact simple to establish.
        // A data change ends any flight this page still thinks is in the air.
        // The flag is written in exactly one place and cleared only by the
        // matching unhide, so a flight that never delivered one would hide its
        // post's cell on every future dequeue — for the life of the page.
        if !posts.contains(where: { $0.id == heroHiddenPostID }) { heroHiddenPostID = nil }
        if style == .discover {
            applyDiscover(incoming, skeleton: skeleton, dissolving: dissolving, mustReload: mustReload)
            return
        }
        let added = Self.addedPosts(from: rawPosts, to: incoming)
        rawPosts = incoming
        showsSkeleton = skeleton
        // ⚠️ An append can change the SECTIONING, not just the item count: a
        // corpus that was entirely new is one unlabelled run, and the first
        // older page landing under it splits the list in two. Inserting items
        // into a collection view whose section count changed in the same pass
        // is the classic inconsistency exception, so that case takes the
        // reload path below instead.
        let shapeBefore = sectionShape
        if let added, !added.isEmpty, !showsSkeleton, !skeleton, !dissolving, !mustReload,
           shapeWouldHold(afterAppending: added, from: shapeBefore) {
            // Arrange only the newcomers, against the absolute slots they will
            // occupy. Placement depends solely on the absolute index, so the
            // items already on screen cannot move — which is what keeps this an
            // insert rather than a reload.
            //
            // Indexed off `posts`, not off `incoming`: the two are no longer the
            // same order once a swap or a re-rank has happened, and the rows
            // being inserted are this page's, not upstream's.
            let start = posts.count
            posts += arrange(added, startingAt: start)
            collectionView.performBatchUpdates {
                collectionView.insertItems(
                    at: (start..<posts.count).map { indexPath(for: $0) }
                )
            }
            DispatchQueue.main.async { [weak self] in self?.updateAutoplay() }
            return
        }
        posts = partitioned(arrange(incoming, startingAt: 0))
        reloadAll(dissolving: dissolving)
    }

    /// Whether `new` is `old` with other counters — the one change a cell can
    /// take without being re-dressed or re-measured.
    static func differOnlyInCounts(_ old: GalleryPost, _ new: GalleryPost) -> Bool {
        var recounted = new
        recounted.reactionCount = old.reactionCount
        recounted.commentCount = old.commentCount
        return recounted == old
    }

    /// ⚠️ THE SAME POSTS IN THE SAME ORDER, NEW COUNTS — a refresh landing —
    /// re-dress nothing (the profile's rule, #1273). A reload rebuilt every
    /// visible cell and its media, playing tiles handed back and restarted,
    /// for a number. A count is a capsule's text: written straight onto the
    /// cells on screen; anything else changed, or off screen, is
    /// reconfigured. False — the caller goes on — for any other change.
    private func applyCountsOnly(_ incoming: [GalleryPost], skeleton: Bool) -> Bool {
        guard !showsSkeleton, !skeleton, !rawPosts.isEmpty, rawPosts.count == incoming.count,
              zip(rawPosts, incoming).allSatisfy({ $0.id == $1.id && Self.differOnlyInCounts($0, $1) })
        else { return false }
        let fresh = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let before = posts
        rawPosts = incoming
        if style == .discover {
            adoptSegments(segments.map { $0.mappingPosts { fresh[$0.id] ?? $0 } })
        } else {
            posts = posts.map { fresh[$0.id] ?? $0 }
        }
        let changed = posts.indices.filter { posts[$0] != before[$0] }
        let visible = Set(collectionView.indexPathsForVisibleItems)
        var reconfigured: [IndexPath] = []
        for index in changed {
            let path = indexPath(for: index)
            switch visible.contains(path) ? collectionView.cellForItem(at: path) : nil {
            case let row as PostGridListRowCell: row.updateCounts(from: posts[index])
            case let tile as PostGridTileCell: tile.updateCounts(from: posts[index])
            default: reconfigured.append(path)
            }
        }
        if !reconfigured.isEmpty { collectionView.reconfigureItems(at: reconfigured) }
        #if DEBUG
        debugRecountedItems += changed.count - reconfigured.count
        debugReconfiguredItems += reconfigured.count
        #endif
        return true
    }

    #if DEBUG
    /// Cells a counts-only refresh wrote straight onto, and cells it had to
    /// reconfigure — see `applyCountsOnly`.
    private(set) var debugRecountedItems = 0
    private(set) var debugReconfiguredItems = 0
    /// Whole-list reloads — what a counts-only change or an append must not be.
    private(set) var debugReloadCount = 0
    /// The post the last `applyPendingReveal` brought clear of the chrome.
    private(set) var debugLastRevealedPostID: PostID?

    /// That post's tile, in window space — a host's QA hook measures it
    /// against its own chrome (the profile's `-profile-verify-reveal`).
    func debugRevealedTileInWindow() -> CGRect? {
        guard let id = debugLastRevealedPostID,
              let index = posts.firstIndex(where: { $0.id == id }),
              let window,
              let attributes = collectionView.layoutAttributesForItem(at: indexPath(for: index))
        else { return nil }
        return collectionView.convert(attributes.frame, to: window)
    }
    var debugShowsSkeleton: Bool { showsSkeleton }
    /// The status block's frame while it shows, nil otherwise.
    var debugStatusFrame: CGRect? { emptyState.isHidden ? nil : emptyState.frame }
    /// The travel a hosted page offers now — see `offeredTravel`.
    var debugOfferedTravel: CGFloat { offeredTravel }
    #endif

    /// Discover's delivery: the stretches are re-planned over the whole corpus
    /// (the planner is cheap once its tilings are cached), and the difference
    /// is expressed as an INSERT whenever it is one — a page landing grows the
    /// last run of cards and appends stretches after it, and must leave every
    /// realized cell, and its playback, alone. See `MosaicChunkPlanner` for why
    /// a landing can only ever extend the list.
    private func applyDiscover(
        _ incoming: [GalleryPost], skeleton: Bool, dissolving: Bool, mustReload: Bool
    ) {
        let before = segments
        let postsBefore = posts
        let wasSkeleton = showsSkeleton
        rawPosts = incoming
        showsSkeleton = skeleton
        plannedCorpusComplete = isCorpusComplete
        let planned = skeleton ? [] : chunkPlanner.segments(for: incoming, isComplete: isCorpusComplete)
        let change = MosaicChunkPlanner.change(from: before, to: planned)
        adoptSegments(planned)
        if !wasSkeleton, !skeleton, !dissolving, !mustReload,
           case .extended(let grown, let appended) = change {
            let last = before.count - 1
            collectionView.performBatchUpdates {
                if !grown.isEmpty {
                    collectionView.insertItems(at: grown.map { IndexPath(item: $0, section: last) })
                }
                if !appended.isEmpty {
                    collectionView.insertSections(IndexSet(integersIn: appended))
                }
            }
            DispatchQueue.main.async { [weak self] in self?.updateAutoplay() }
            return
        }
        // The same posts in the same places: nothing to redraw. (A post whose
        // counters moved is NOT this case — `posts` compares whole models.)
        if change == .identical, wasSkeleton == skeleton, !mustReload, postsBefore == posts { return }
        reloadAll(dissolving: dissolving)
    }

    /// Discover's titled groups (`.sections`): each group planned as a list
    /// of its own — its chunks numbered on from the group before, so the
    /// shapes vary down the page — and the lists drawn one after another,
    /// each group's title over its first stretch.
    ///
    /// Always complete: a host that groups its posts holds all of them (the
    /// History is on the device). So a change is a reload, never an insert —
    /// except new counters on the same posts, written onto the cells.
    func applyGroups(_ groups: [PostGridPageSection]) {
        defer { lookahead.setNeedsPlan() }
        guard style == .discover else { return apply(groups.flatMap(\.posts), skeleton: false) }
        emptyState.isHidden = true
        let shown = groups.filter { !$0.posts.isEmpty }
        guard !shown.isEmpty else {
            leaveGroups()
            return apply([], skeleton: false)
        }
        var ordinal = 0
        var planned: [DiscoverSegment] = []
        var firsts: [Int] = []
        for group in shown {
            firsts.append(planned.count)
            planned += chunkPlanner.segments(for: group.posts, isComplete: true, ordinal: &ordinal)
        }
        let titles = shown.map(\.title)
        let sameShape = !showsSkeleton && titles == groupTitles && firsts == groupFirstSections
            && MosaicChunkPlanner.change(from: segments, to: planned) == .identical
        let postsBefore = posts
        let dissolving = showsSkeleton && window != nil
        // Settled against the old model first — `apply`'s rule.
        collectionView.layoutIfNeeded()
        rawPosts = shown.flatMap(\.posts)
        showsSkeleton = false
        plannedCorpusComplete = true
        leftGroups = false
        mustReload = false
        groupTitles = titles
        groupFirstSections = firsts
        adoptSegments(planned)
        if !posts.contains(where: { $0.id == heroHiddenPostID }) { heroHiddenPostID = nil }
        if sameShape {
            guard posts != postsBefore else { return }
            let visible = collectionView.indexPathsForVisibleItems.filter {
                posts[flatIndex(for: $0)] != postsBefore[flatIndex(for: $0)]
            }
            if !visible.isEmpty { collectionView.reconfigureItems(at: visible) }
            return
        }
        collectionView.collectionViewLayout.invalidateLayout()
        reloadAll(dissolving: dissolving)
        DispatchQueue.main.async { [weak self] in self?.updatePinnedSection() }
    }

    /// Back to one untitled list: the next delivery is planned whole.
    private func leaveGroups() {
        guard isGrouped else { return }
        groupTitles = []
        groupFirstSections = []
        leftGroups = true
        updatePinnedSection()
    }

    func setPinLineInset(_ inset: CGFloat?) {
        guard pinLineInset != inset else { return }
        pinLineInset = inset
        for case let header as SectionHeaderCapsuleView in collectionView.visibleSupplementaryViews(
            ofKind: PostGridListLayout.headerElementKind
        ) {
            header.pinLineInset = inset
        }
        updatePinnedSection()
    }

    /// The whole-table path every style ends on when a delivery is not an
    /// append.
    private func reloadAll(dissolving: Bool) {
        #if DEBUG
        debugReloadCount += 1
        #endif
        // The covers are the lookahead's (#970): it plans once the reload has
        // laid out the new items (`render`'s `setNeedsPlan`), the visible ones
        // and the screen ahead decoded — the first load included, the moment
        // the grid is coldest and the fetch has the most latency to hide.
        if dissolving {
            UIView.transition(
                with: collectionView, duration: 0.35,
                options: [.transitionCrossDissolve, .allowUserInteraction, .curveEaseInOut],
                animations: { self.collectionView.reloadData() }
            )
        } else {
            collectionView.reloadData()
        }
        // New content means a new visible set. Reconcile after the reload has
        // realized its cells, or every candidate lookup returns nil.
        DispatchQueue.main.async { [weak self] in self?.updateAutoplay() }
    }
}

// MARK: - Data source / delegate

extension ForYouGridPage: UICollectionViewDataSource, UICollectionViewDelegate {
    /// Whether a section carries a pill: both halves of a divided list, and a
    /// lone section only on a list that titles every section
    /// (`titlesEverySection`). Asked by the LAYOUT, which is why it is not
    /// private.
    func hasHeader(inSection index: Int) -> Bool {
        guard style == .list, !showsSkeleton, !posts.isEmpty,
              sections.indices.contains(index) else { return false }
        return sections.count == 2 || titlesEverySection
    }

    /// What one post is drawn as. The page's `Style` answers it for the grid
    /// and the list; Discover answers it per post.
    private enum CellShape {
        case card
        case tile
        /// Discover's paired vertical media: a Following card.
        case pairedCard
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        guard !showsSkeleton else { return 1 }
        // One section per stretch — and one empty one for an empty list, the
        // shape the other styles have when there is nothing to show.
        if style == .discover { return max(1, segments.count) }
        return sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard !showsSkeleton else { return skeletonCount }
        if style == .discover {
            return segments.indices.contains(section) ? segments[section].posts.count : 0
        }
        let split = split
        guard split > 0 else { return posts.count }
        return section == 0 ? split : posts.count - split
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        if kind == DiscoverListLayout.leadElementKind {
            let host = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: LeadHostView.reuseID, for: indexPath
            ) as! LeadHostView
            host.host(leadView)
            return host
        }
        if kind == DiscoverListLayout.viewAllElementKind {
            let footer = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: DiscoverViewAllFooterView.reuseID,
                for: indexPath
            ) as! DiscoverViewAllFooterView
            footer.onTap = { [weak self] in self?.onViewAllTapped?() }
            return footer
        }
        // The Messages inbox's own header (`SectionHeaderPillButton`, here in
        // its collection-view host): a large title in the flow that becomes a
        // Liquid Glass capsule once it pins under the bar.
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: Self.sectionHeaderReuseID,
            for: indexPath
        ) as! SectionHeaderCapsuleView
        header.pinLineInset = pinLineInset
        // A titled group's header: the title in the flow, which leaves as it
        // reaches the bar — the host names the group there (#1344, the
        // inbox's #1301).
        if style == .discover, let group = groupIndex(openedBy: indexPath.section) {
            header.hidesWhenPinned = true
            header.setTitle(groupTitles[group])
            header.onTap = { [weak self] in self?.scrollToSection(group) }
            return header
        }
        let section = sections.indices.contains(indexPath.section) ? sections[indexPath.section] : .earlier
        // "New 8": the header says how much is new, so the viewer knows the
        // size of the run before scrolling it — the number the For You header
        // they came from carries, written the same way, on the section it
        // describes. The separation between sections is the layout's bottom
        // inset on the one above; the header stands its line
        // `Spacing.sectionTitle` over the first row, as every title does.
        header.setTitle(section == .earlier ? earlierSectionTitle : section.title,
                        count: section == .new ? newRunLength : 0)
        // Named in the bar instead, the header leaves as it pins (#1378).
        header.hidesWhenPinned = onPinnedSectionChanged != nil
        // Tapping a header means "show me this part" — the same gesture the
        // inbox's pills answer.
        header.onTap = { [weak self] in self?.scrollToListSection(indexPath.section) }
        return header
    }

    private static let sectionHeaderReuseID = "ForYouGridPage.sectionHeader"

    /// Puts a section's first row directly under its header.
    ///
    /// A no-op for a list too short to scroll: `scrollToItem` cannot invent
    /// content, so a two-section list that already fits stays where it is.
    private func scrollToListSection(_ index: Int) {
        // Named in the bar, its header hides once pinned: the row goes on
        // the pin line, not under an empty header box.
        if onPinnedSectionChanged != nil {
            scrollFirstRowToPinLine(ofSection: index)
            return
        }
        guard collectionView.numberOfSections > index,
              collectionView.numberOfItems(inSection: index) > 0
        else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: 0, section: index), at: .top, animated: true
        )
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if showsSkeleton {
            switch style {
            // Discover waits as cards: most of what it shows is cards, and a
            // chunk's shape is not known until its posts are.
            case .list, .discover:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: PostGridSkeletonListCell.reuseID, for: indexPath
                ) as! PostGridSkeletonListCell
                cell.configure(variant: indexPath.item)
                return cell
            case .grid:
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: PostGridSkeletonTileCell.reuseID, for: indexPath
                ) as! PostGridSkeletonTileCell
                // The shimmer has to be the shape content will hydrate into, or
                // the cross-dissolve changes silhouette as it lands.
                cell.cornerRadius = tileCornerRadius
                return cell
            }
        }
        let post = posts[flatIndex(for: indexPath)]
        // Set on EVERY dequeue, both ways: the flight's stand-in stays hidden
        // across reloads, and a recycled cell can never carry a stale hide to
        // another tile.
        // Either flight hides it, and neither knows about the other.
        let isFlying = post.id == heroHiddenPostID || post.id == revealConcealedPostID
        // Asked per post, because Discover draws both — see `drawsAsTile`.
        let shape: CellShape = drawsAsPairedCard(post.id)
            ? .pairedCard
            : (drawsAsTile(post.id) ? .tile : .card)
        switch shape {
        case .pairedCard:
            // The Following row's card, at half the list's width — the
            // picture, the author and two lines over its foot. Played and
            // concealed like a tile (`drawsAsTile`).
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PostShelfMediaCardCell.reuseID, for: indexPath
            ) as! PostShelfMediaCardCell
            cell.configure(with: post, imagePipeline: imagePipeline)
            // The heart closing the author line reads the viewer's stake.
            staking?.bindReadout(cell, to: post.id)
            // Autoplay is gated on the cover, as for a tile.
            cell.onCoverLoaded = { [weak self] in self?.updateAutoplay() }
            cell.isHidden = isFlying
            return cell
        case .card:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PostGridListRowCell.reuseID, for: indexPath
            ) as! PostGridListRowCell
            cell.configure(
                with: post,
                imagePipeline: imagePipeline,
                captionExpanded: captionExpansion.isExpanded(post.id)
            )
            // Captured by POST, never by index path: the row that asked can
            // have moved by the time the answer is applied, and an index path
            // held across a reload names a different post.
            cell.onRevealFullCaption = { [weak self] in
                guard let self else { return }
                captionExpansion.expand(post.id, in: collectionView)
            }
            // Same reason as the tile below: autoplay is gated on the cover, so
            // a cover arriving is the only event that can re-open the gate for
            // a row that came up faceless while the timeline sat still.
            cell.onCoverLoaded = { [weak self] in self?.updateAutoplay() }
            // A COLLECTION row's media is a scroll view, and a scroll view in
            // the content path swallows the collection view's own selection —
            // so a tap on the photograph has to arrive by its own route or the
            // card simply stops opening. Straight into the SAME handler a tap
            // anywhere else on the row lands in.
            // Save, on the row. The pile is the SAME one the post page and the
            // profile's Saved tab read — a second store here would let a card
            // and the post it opens disagree about whether a post is saved.
            //
            // The control never toggles itself: `isBookmarked` is set from the
            // store's answer, before and after, so a store that refused would
            // leave the glyph telling the truth.
            // ⚠️ REPOST HAS NO ACTION YET, so it is NOT DRAWN (#801).
            //
            // The band hides a button whose handler is nil — visibility tracks
            // the answer. This used to set a closure anyway, forwarding to
            // `onRepostRequested`, which nothing sets: the chip drew, pressed
            // with its wash, and did nothing, so it looked as if it worked.
            // `repostHandler(for:)` is nil until a handler exists.
            //
            // What it needs is a real mutation, not a handler: `CreatePost`
            // carries `parent_id` on the wire and `GalleryPost.isRepost` already
            // reads it (the profile's Posts/Reposts split), but `PostComposer`
            // takes no parent, so there is no client path that publishes one.
            cell.onRepostTapped = repostHandler(for: post)
            // The like chip stakes — see `PostCardStaking`.
            staking?.bind(cell, to: post.id)
            if let bookmarks {
                cell.isBookmarked = bookmarks.isSaved(post.id.rawValue)
                cell.onBookmarkTapped = { [weak cell] in
                    guard let cell else { return }
                    MemberGates.perform(.save, from: cell) { [weak cell] in
                        _ = bookmarks.toggle(post.id.rawValue)
                        // The fill says it; the hand feels it (#803).
                        Feedback.toggled()
                        cell?.isBookmarked = bookmarks.isSaved(post.id.rawValue)
                    }
                }
            } else {
                cell.onBookmarkTapped = nil
            }
            cell.onMediaTapped = { [weak self, weak cell] in
                guard let self, let cell,
                      let path = self.collectionView.indexPath(for: cell) else { return }
                self.collectionView(self.collectionView, didSelectItemAt: path)
            }
            // The comment count opens the same post at its thread. Resolved
            // through the CELL's index path rather than through this closure's
            // captured one: rows are recycled and the list re-renders under
            // them, so the index that was true at configure time is not
            // necessarily true when the finger arrives.
            cell.onCommentsTapped = { [weak self, weak cell] in
                guard let self, let cell,
                      let path = self.collectionView.indexPath(for: cell) else { return }
                self.open(at: path, showingComments: true)
            }
            // ⚠️ Paging a MIXED collection changes what should be playing, and
            // nothing else would ask.
            //
            // Autoplay is reconciled when the visible SET changes — a scroll, a
            // surface appearing. A carousel moving inside a stationary row
            // changes neither, so a clip on page two would keep playing behind
            // page three, and a clip on page three would never start.
            cell.onMediaPageChanged = { [weak self] _ in
                self?.updateAutoplay()
            }
            // Hold to pause, the same gesture the post screen carries. Captured
            // by POST rather than by cell for the reason the handlers below
            // state: the row that received the touch can have been recycled by
            // the time the finger lifts, and the clip that must resume is the
            // one belonging to the post, not to whatever the cell shows now.
            cell.onMediaHoldChanged = { [weak self] held in
                self?.playback?.setHeld(held, for: post.id)
            }
            // The band's identity and its "...", if the post carries an author.
            // Captured by AUTHOR and by POST for the same reason the caption's
            // handler is captured by post: the row that asked can have moved by
            // the time the answer is applied.
            if let authorID = post.authorID {
                cell.onAuthorTapped = { [weak self] in self?.onAuthorTapped?(post) }
                cell.authorMenuActions = { [weak self, weak cell] in
                    guard let self, let cell else { return [] }
                    return authorMenuActions?(
                        AuthorMenuContext(
                            post: post, authorID: authorID, anchor: cell.authorMenuAnchor
                        )
                    ) ?? []
                }
            }
            Self.applyHeroConcealment(isFlying, to: cell)
            return cell
        case .tile:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PostGridTileCell.reuseID, for: indexPath
            ) as! PostGridTileCell
            cell.cornerRadius = tileCornerRadius
            // A large tile wears its author and caption start when the page
            // asks (`showsTileInfo`); the cell picks how much by its size.
            cell.configure(with: post, imagePipeline: imagePipeline, showsInfo: showsTileInfo)
            #if DEBUG
            // `-gallery-tile-info-log`: which tile wears what — the flat
            // index `-foryou-open` / `-foryou-gallery-open` take, to film a
            // worded tile's flight.
            if showsTileInfo, ProcessInfo.processInfo.arguments.contains("-gallery-tile-info-log") {
                let size = cell.bounds.size
                print("[tile-info] index=\(flatIndex(for: indexPath)) id=\(post.id.rawValue)"
                    + " size=\(Int(size.width))x\(Int(size.height)) variant=\(PostTileInfo.variant(for: size))")
            }
            #endif
            // The count's heart reads the viewer's stake (red once staked) —
            // the corner's or, on a worded tile, the author line's.
            staking?.bindReadout(cell, to: post.id)
            // Autoplay is gated on the cover, so the arrival of a cover is a
            // reason to re-run the gate. Without this a tile whose cover lands
            // while the grid is stationary fails the gate once and is never
            // asked again.
            cell.onCoverLoaded = { [weak self] in self?.updateAutoplay() }
            cell.isHidden = isFlying
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !showsSkeleton, posts.indices.contains(flatIndex(for: indexPath)) else { return }
        collectionView.deselectItem(at: indexPath, animated: false)
        // The flight leaves from where the cell IS. Nothing moves first:
        // the grid stays visible behind the expanding card, so any offset
        // change here — animated or not — is a jump under the viewer's thumb
        // at the exact moment they are watching that spot.
        //
        // The reveal is remembered and applied once the post has covered the
        // grid (`applyPendingReveal`), where it costs nothing to look at and
        // is finished long before the dismissal flies home to it.
        open(at: indexPath, showingComments: false)
    }

    /// Both ways into a post, so the flight is staged identically either way —
    /// the reveal is remembered here, and forgetting it on one route is how a
    /// dismissal lands on the wrong row.
    private func open(at indexPath: IndexPath, showingComments: Bool) {
        let index = flatIndex(for: indexPath)
        guard posts.indices.contains(index) else { return }
        pendingRevealPostID = posts[index].id
        // ⚠️ CLAIM THE POOL BEFORE THE FLIGHT IS STAGED.
        //
        // A hero can only fly what is already playing: the card asks this page
        // for a live surface while the flight is being built, and the answer is
        // nil for a tile that holds no player. Until the tap is known this tile
        // competed on distance like any other, so the one that MUST be playing
        // could be the one that was not — the flight then carried the thumbnail.
        //
        // Claimed and reconciled in the same breath, so the grant is at least
        // in flight by the time the card asks. It cannot always be finished —
        // a cold tile has to resolve a URL first — which is why the flight
        // keeps asking (see `ZoomFlight`'s live-media retry).
        playback?.focus(posts[index].id)
        updateAutoplay()
        // ⚠️ A TEXT POST'S COMMENTS ARE ITS PAGE. Its comment chip presses
        // like any other (the card has one affordance), and lands where the
        // card itself lands — by the text reveal, never the media flight the
        // comments route would pick for a post with no media to fly.
        if let onPostTapped {
            let stream = Array(posts[index...].prefix(Self.vendedStreamWindow))
            onPostTapped(posts[index], stream, showingComments && posts[index].kind != .text)
            return
        }
        if showingComments, posts[index].kind != .text, let openComments = onItemCommentsTapped {
            openComments(index)
        } else {
            onItemTapped?(index)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        positionPagingFooter()
        schedulePinnedSectionCheck()
        if hostedTopInset != nil {
            // Content can land without a layout pass reaching the host —
            // re-derive the travel room here (value-guarded, so this is a
            // comparison per tick, not a write) and report for the header.
            applyBottomInset()
            positionHostedStatus()
            onVerticalScroll?(verticalOffset)
        }
        // Autoplay reconciles DURING the scroll, so a brick starts playing as
        // it slides into view rather than after the scroll has stopped.
        // Throttled rather than run per callback: `scrollViewDidScroll` fires
        // at the display refresh rate, and reconciling at 120 Hz spends more
        // time diffing than the work is worth.
        throttledAutoplayReconcile(scrollView)
        lookahead.scrollViewDidScroll()

        // ⚠️ MEASURED IN SCREENS, not in points, because a row is not a tile:
        // a fixed 800pt was barely ONE card of runway on the timeline, and a
        // flick outran it. Two screens of lead, three on a fling, is the same
        // lead on every shape (`LookaheadPaging`, #970). One page in flight is
        // the view model's.
        askNextPageIfNearEnd(force: false)
    }

    /// Asks for the next page within the lookahead's lead. From a scroll,
    /// ONCE PER CONTENT LENGTH (the profile's rule, #1273): a view model that
    /// resumes a paging that failed would otherwise be asked again at the
    /// display's rate, and a failure retried at once, over and over. A cell
    /// coming on screen (`force`) asks as it always did — which is also what
    /// asks for a first page too short to scroll.
    private func askNextPageIfNearEnd(force: Bool) {
        guard !showsSkeleton, !posts.isEmpty, lookahead.wantsNextPage else { return }
        let length = collectionView.contentSize.height
        guard force || nextPageAskedAtLength != length else { return }
        nextPageAskedAtLength = length
        onNearEnd?()
    }

    /// Asks the host to warm what is on screen. Silent during a fling, and
    /// silent while the page is showing skeletons — there is nothing on screen
    /// then but the shape of what is coming.
    private func requestWarm(_ allowing: Bool) {
        guard allowing, !showsSkeleton, onWarmRequested != nil else { return }
        // At most the driver's `warmWindow` — see the ⚠️ there.
        let visible = ForYouGridAutoplayDriver.warmIndices(
            visibleFlatIndices: collectionView.indexPathsForVisibleItems.sorted().map(flatIndex(for:)),
            postCount: posts.count
        ).map { posts[$0] }
        guard !visible.isEmpty else { return }
        onWarmRequested?(visible)
    }

    /// The cadence and the fling gate are the driver's
    /// (`scrollReconcileInterval`, `maximumStartVelocity`).
    private func throttledAutoplayReconcile(_ scrollView: UIScrollView) {
        guard playback != nil, !showsSkeleton else { return }
        guard let allowingStarts = autoplayDriver.scrollTick(
            offset: scrollView.contentOffset.y, at: CACurrentMediaTime()
        ) else { return }
        updateAutoplay(allowingStarts: allowingStarts)
    }

    /// A fling that ends without deceleration still needs a final reconcile:
    /// the throttled pass may have been velocity-gated right up to the stop.
    /// ⚠️ THE SNAP IS WRITTEN INTO THE TARGET, not applied after the fact
    /// (the profile's, #1273). Moving the offset once deceleration has
    /// finished is a second motion the viewer sees start; rewriting where the
    /// deceleration is heading folds the snap into the one motion already
    /// under way.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        pendingSnap = nil
        guard !snapDetents.isEmpty else { return }
        let inset = scrollView.adjustedContentInset.top
        let target = targetContentOffset.pointee.y + inset
        guard let snapped = ScrollDetents.snapped(
            target: target, detents: snapDetents, from: verticalOffset, catching: catchDetents
        ), abs(snapped - target) > 0.5 else { return }
        targetContentOffset.pointee.y = snapped - inset
        // With no momentum the scroll view stops where the finger left it and
        // ignores the target, so the snap has to be driven by hand.
        if abs(velocity.y) < 0.01 { pendingSnap = snapped - inset }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateAutoplay()
            lookahead.scrollViewDidEndScrolling()
        }
        onPullReleased?(max(0, -verticalOffset))
        if !decelerate, let pendingSnap {
            self.pendingSnap = nil
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: pendingSnap), animated: true)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateAutoplay()
        lookahead.scrollViewDidEndScrolling()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateAutoplay()
        lookahead.scrollViewDidEndScrolling()
    }

    // MARK: - The native preview (#1318)

    /// ⚠️ EVERY TILE OF EVERY GRID LIFTS ITS POST (the owner, 2026-10-17):
    /// the long press For You's shelves had, here once for every surface this
    /// page serves — For You's lists, the profile's pages, the place page.
    /// The menu is built from what every host already hands the page (its
    /// author tap and its author menu), so no host has anything new to wire;
    /// a clip plays inside the lift (`ForYouPostPreviewViewController`).
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !showsSkeleton, let indexPath = indexPaths.first else { return nil }
        let index = flatIndex(for: indexPath)
        guard posts.indices.contains(index) else { return nil }
        // ⚠️ A LIST CARD'S PREVIEW BELONGS TO ITS MEDIA (#1377, the owner
        // 2026-10-18): only a press that starts on the media (a carousel's
        // page on screen) lifts it; the header, the caption, the action row
        // and a text-only card lift nothing. A grid tile IS its media.
        if let row = collectionView.cellForItem(at: indexPath) as? PostGridListRowCell {
            guard let media = row.mediaHeroRect,
                  media.contains(collectionView.convert(point, to: row)) else { return nil }
        }
        let post = posts[index]
        let width = max(0, bounds.width - LeadRowMetrics.sideMargin * 2)
        let pipeline = imagePipeline
        let pool = videoPool
        return UIContextMenuConfiguration(
            identifier: post.id.rawValue as NSString,
            previewProvider: {
                ForYouPostPreviewViewController(
                    post: post, imagePipeline: pipeline, width: width, videoPlayback: pool
                )
            },
            actionProvider: { [weak self] _ in self?.tileMenu(for: post, at: indexPath) }
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        highlightPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        tilePreview(at: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        tilePreview(at: indexPath)
    }

    /// Tapping the lift opens the post — the tap's own open, through the same
    /// flight. `.dismiss` first, then ours, one turn past the completion: the
    /// flight leaves FROM the tile, so UIKit must have put it back (the
    /// shelf's rule, `PostShelfSection`).
    func collectionView(
        _ collectionView: UICollectionView,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let raw = configuration.identifier as? String else { return }
        animator.preferredCommitStyle = .dismiss
        animator.addCompletion { [weak self] in
            DispatchQueue.main.async { self?.openPost(rawID: raw) }
        }
    }

    /// Open, the author's profile, then the host's author rows (Unfollow,
    /// Report — none on the viewer's own posts, which the host decides).
    func tileMenu(for post: GalleryPost, at indexPath: IndexPath) -> UIMenu {
        let id = post.id.rawValue
        var children: [UIMenuElement] = [RowGeometry.openAction { [weak self] in self?.openPost(rawID: id) }]
        if let onAuthorTapped, post.authorID != nil {
            children.append(UIAction(title: "View Profile", image: UIImage(systemName: "person.crop.circle")) { _ in
                onAuthorTapped(post)
            })
        }
        if let authorID = post.authorID, let authorMenuActions {
            let anchor: UIView = collectionView.cellForItem(at: indexPath) ?? self
            let rows = authorMenuActions(AuthorMenuContext(post: post, authorID: authorID, anchor: anchor))
            if let menu = PostCardMenu.menu(for: rows) {
                children.append(UIMenu(options: .displayInline, children: menu.children))
            }
        }
        return UIMenu(children: children)
    }

    /// Opens the post with this id, wherever it now sits.
    private func openPost(rawID: String) {
        guard let index = posts.firstIndex(where: { $0.id.rawValue == rawID }) else { return }
        open(at: indexPath(for: index), showingComments: false)
    }

    @objc private func swallowHold() {}

    /// Whether a long press at `point` (in the collection view) lands on a
    /// list card off its media and off any control.
    func swallowsHold(at point: CGPoint) -> Bool {
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let row = collectionView.cellForItem(at: indexPath) as? PostGridListRowCell else { return false }
        let local = collectionView.convert(point, to: row)
        if let media = row.mediaHeroRect, media.contains(local) { return false }
        var view = row.hitTest(local, with: nil)
        while let current = view, current !== row {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    /// The tile the lift is made of, on its own rounded shape — on a list
    /// card, its MEDIA alone (a carousel's page on screen), on the media's
    /// own corners: the card's header, text and actions never take part in
    /// the morph, and stay in place while it is up (#1377).
    func tilePreview(at indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: indexPath), cell.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let card = cell.contentView
        // The media's OWN view, not the card clipped to it: UIKit hides the
        // targeted view while the lift is up, and the card's header, text
        // and actions must stay where they are.
        if let row = cell as? PostGridListRowCell {
            guard let media = row.mediaPreviewView else { return nil }
            parameters.visiblePath = UIBezierPath(
                roundedRect: media.bounds, cornerRadius: PostGridListRowCell.mediaCornerRadius
            )
            return UITargetedPreview(view: media, parameters: parameters)
        }
        let radius = max(card.layer.cornerRadius, cell.layer.cornerRadius)
        parameters.visiblePath = UIBezierPath(roundedRect: card.bounds, cornerRadius: radius)
        return UITargetedPreview(view: card, parameters: parameters)
    }

    func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath
    ) {
        askNextPageIfNearEnd(force: true)
        guard !showsSkeleton, let onWillDisplayPost else { return }
        let index = flatIndex(for: indexPath)
        guard posts.indices.contains(index) else { return }
        onWillDisplayPost(posts[index].id)
    }

    /// A recycled cell hands its player back immediately rather than waiting
    /// for the next reconcile, so it can never render the previous post.
    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        // Rows as well as tiles: a cell that left the viewport must give its
        // player back whatever the scroll is doing, or the pool starves.
        guard let playable = cell as? any GridPlaybackCell else { return }
        playback?.stop(cell: playable)
    }
}

/// The reusable view the layout realizes for Discover's leading header. It
/// owns nothing: it HOSTS the page's lead view, which outlives it — see
/// `ForYouGridPage.setLead`.
private final class LeadHostView: UICollectionReusableView {
    static let reuseID = "ForYouLeadHostView"

    func host(_ view: UIView?) {
        for stale in subviews where stale !== view { stale.removeFromSuperview() }
        guard let view else { return }
        if view.superview !== self {
            view.removeFromSuperview()
            addSubview(view)
        }
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
}

/// `ForYouGridPage.offMediaHold`'s gate — its own object: a view's
/// `gestureRecognizerShouldBegin` is UIView's.
@MainActor
private final class OffMediaHoldGate: NSObject, UIGestureRecognizerDelegate {
    weak var page: ForYouGridPage?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let page else { return false }
        return page.swallowsHold(at: gestureRecognizer.location(in: page.collectionView))
    }
}
