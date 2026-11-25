import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import LaunchArguments
import MediaCore
import PostGrid
import PostSurfaces
import ThreadKit
import UIKit

/// What the full-screen feed's toolbar asks of its screen (#2387): the page
/// in front and its model, the viewer's saved pile, the sound and the like
/// the footer offers, the author pill its leading item wears, and whether a
/// bar change may animate now.
///
/// A view controller: the toolbar is its navigation controller's, and its
/// items are the screen's `toolbarItems`.
@MainActor
protocol SnapToolbarComposerHost: UIViewController {
    var modelsByID: [PostID: FeedItemDisplayModel] { get }
    /// The settled page's model.
    var activeModel: FeedItemDisplayModel? { get }
    var unavailablePostIDs: Set<PostID> { get }
    var bookmarks: PostBookmarkStore { get }
    var viewModel: FeedViewModel { get }
    var stakes: StakeSession? { get }
    var imagePipeline: ImagePipeline { get }
    /// The pill the toolbar's leading item wears.
    var authorIdentityView: SnapAuthorIdentityView { get }
    /// On screen, and no transition or flight owns the bar's items.
    var canAnimateBarItems: Bool { get }
    /// `-snap-layout-v2` (#2407): a media page's footer is the author and
    /// repost, save and the sound being the column's (#2408).
    var layoutV2: Bool { get }
    func soundFace(for model: FeedItemDisplayModel) -> SnapSoundFace?
    func presentSoundSheet()
    func presentShareSheet(for id: PostID)
    func performBoost(on id: PostID, spend: WalletStakeSpend, from source: UIResponder?)
    func snapCell(for id: PostID) -> SnapFeedCell?
    func applyAuthorWidthBudget(bar: CGFloat?, sortOnBar: Bool?)
}

/// The full-screen feed's bottom toolbar (#2387): its one set of items, built
/// once — the author pill's item, save, repost, the post's sound and, on a
/// text page, the like — their faces for the page in front, and the bar's
/// presence across pushes and pops.
///
/// ⚠️ THE ONLY WRITER OF THE SCREEN'S `toolbarItems`. The item set is built
/// once (`configureToolbarItems`), the author's item is re-minted in its slot
/// (`reinstallAuthorItem`), and a text page's like goes in and out of the run
/// (`refreshFooterLike`). Every other change is made IN PLACE, on the item
/// that stays (bar contract, #2331).
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: every entry point runs in the caller's
/// turn, where the screen called it before — the settle (`updateBarChrome`),
/// the picture's change of owner (`updateViewportPlayback`), the appearance
/// and disappearance callbacks.
@MainActor
final class SnapToolbarComposer {
    private unowned let host: any SnapToolbarComposerHost

    init(host: any SnapToolbarComposerHost) {
        self.host = host
    }

    /// The navigation controller whose toolbar this feed is showing — held
    /// weakly across its own pop, when `navigationController` is already nil
    /// but the toolbar bookkeeping must still be settled (`viewDidDisappear`).
    private weak var toolbarHost: UINavigationController?
    /// The save star — a stock bar item (`SnapFooterToolbar`, #1679); a
    /// property because its image follows the active page's saved state.
    private(set) lazy var bookmarkItem = SnapFooterToolbar.makeSaveItem { [weak self] in
        guard let self, let model = self.host.activeModel else { return }
        self.toggleBookmark(for: model.id)
    }
    /// A text page's Share, right of the star in its platter (#2488): the
    /// active page's sheet at the moment of the tap.
    private(set) lazy var shareItem = SnapFooterToolbar.makeShareItem { [weak self] in
        guard let self, let model = self.host.activeModel else { return }
        self.host.presentShareSheet(for: model.id)
    }

    /// The one living toolbar's items (keep-and-stack): built once. The
    /// author pill's content changes inside its item (`showAuthor`), at a fixed
    /// width (`applyBarPillWidths`). The engagement no longer touches the
    /// footer — see `configureToolbarItems` for why the trailing ✕ left it.
    private(set) var defaultToolbarItems: [UIBarButtonItem] = []
    /// The toolbar's leading item: the author pill's, re-minted in its slot
    /// (`reinstallAuthorItem`).
    var authorItem = UIBarButtonItem()
    /// The post whose saved state the glyph draws — the page the bars last
    /// settled on. Nil before the first.
    private(set) var bookmarkGlyphPostID: PostID?
    /// The glyph's symbol as last drawn.
    private(set) var drawnBookmarkSymbol = AppSymbol.save.rawValue

    /// The author item's identifier: the AUTHOR's (#1791).
    ///
    /// iOS 26 treats two items with one identifier as ONE item: a fresh item
    /// under the SAME identifier swaps in a single frame, while a DIFFERENT
    /// identifier gets the bar's own replacement (the glass morphs between the
    /// two platters while the contents blur). So a new author is a different
    /// identifier — UIKit's transition — and the same author's item is
    /// re-minted only invisibly (`reinstallAuthorItem`). The follow badge is
    /// not part of it: a relation change is the badge's symbol replace (#925).
    /// No author yet (the pill before the first page) is the slot's own.
    static func authorItemIdentifier(for author: ProfileID?) -> String {
        guard let author else { return "feed.snap.author-pill" }
        return "feed.snap.author-pill." + author.rawValue
    }

    // MARK: - The author's item

    /// A fresh item wearing THE pill, under the slot's one identifier.
    func makeAuthorItem() -> UIBarButtonItem {
        BarItems.container(
            id: Self.authorItemIdentifier(for: host.authorIdentityView.shownAuthor?.authorID), view: host.authorIdentityView
        )
    }

    /// Mints the author item for the pill shown now and swaps it into the
    /// toolbar. The SAME pill re-minted keeps its identifier, so the bar swaps
    /// it in one unseen frame — the landing install. A NEW author's pill has a
    /// new identifier, and `animated` hands it to UIKit's replacement (#1791).
    ///
    /// A fresh item is a fresh custom-view wrapper, measured at hand-over — the
    /// landing install's second guard, and the cure for a wrapper whose width
    /// drifted from the pill's (memory `bar-item-wrapper-drift`), should one.
    func reinstallAuthorItem(animated: Bool = false) {
        let previousItem = authorItem
        authorItem = makeAuthorItem()
        // The toolbar's leading item (#671).
        defaultToolbarItems = defaultToolbarItems.map { $0 === previousItem ? authorItem : $0 }
        guard var items = host.toolbarItems, let index = items.firstIndex(of: previousItem) else { return }
        items[index] = authorItem
        host.setToolbarItems(items, animated: animated)
    }

    // MARK: - The items

    /// The native bottom toolbar's content, left to right: the attribution
    /// bubble, the system flexible spacer, the actions bubble (bookmark +
    /// repost in ONE capsule), a fixed gap, the more bubble. Three *isolated*
    /// glass bubbles by construction — every item is a custom view, and
    /// custom views never join a shared item background — each on the 36pt
    /// bar-bubble invariant the top bar's controls already follow.
    ///
    /// Items are installed once; the bookmark glyph follows the active page in
    /// place, and a new author is a new pill in a new item, which UIKit
    /// transitions (`showAuthor`, #1791). Every action
    /// resolves the active post at action time, so none can act on a page the
    /// user has scrolled past.
    func configureToolbarItems() {
        // REPOST takes the share's place in the capsule and SHARE moved into
        // ⋯ (#671, `moreMenuActions`). SAVE LEADS, then repost — [🔖 ⇄]
        // (#865), the order VoiceOver reads.
        //
        // ⚠️ Repost has no action yet, and is drawn anyway — the same posture the gallery card's band takes
        // for the same glyph, and for the same reason: `CreatePost` carries
        // `parent_id` on the wire and `GalleryPost.isRepost` already reads it,
        // but `PostComposer` takes no parent, so there is no client path that
        // publishes one. Pressing it does nothing today.
        let repost = SnapFooterToolbar.makeRepostItem()
        repostToolbarItem = repost
        // ⚠️ THE SOUND TAKES SHARE'S PLACE (#1999, the owner 2026-11-01):
        // Share moved to the page's column, on the sound bubble's frame, and
        // the post's sound came here — the active page's cover, turning
        // while it plays; a tap opens the sound sheet. A stock container
        // (#1679) whose CONTENT follows the page, so paging never re-lays
        // out the bar. A text page has no sound: its footer drops it.
        footerSoundButton.onTap = { [weak self] in self?.host.presentSoundSheet() }
        let sound = BarItems.container(id: SnapFooterToolbar.ID.sound, view: footerSoundButton, ownBackground: true)
        footerSoundItem = sound

        // ONE item set, for every state (#671):
        //
        //   [author pill] … [🔖 ⇄] [↪]
        //
        // The author pill leads, in the slot the audio capsule had; the sound
        // lives on the page (`SnapSoundBubbleButton`). Save and repost are
        // STOCK items side by side, so the bar puts them in one platter; the
        // separator gives Share its own (#1679). The toolbar is STATE-INVARIANT:
        // the comments exit is the nav bar's ✕, and the sort selector is the
        // nav bar's too (`setEngagedChrome`).
        defaultToolbarItems = [authorItem, footerFlexibleSpace, bookmarkItem, repost, shareSeparator, sound]
        #if DEBUG
        // `-no-toolbar`: the upper bound on what trimming the footer can buy.
        // Measured (push work, 3 runs): the floating bar's machinery costs ~45
        // ms cold and ~14 ms warm whatever is in it, against ~2 ms for one
        // platter fewer — the lever is architectural, not the item count.
        if LaunchArgument.noToolbar.isPassed() {
            defaultToolbarItems = []
        }
        #endif
        host.toolbarItems = footerToolbarItems()
    }

    /// Optimistic local toggle (no backend seam yet — see the set's comment);
    /// the glyph flips immediately, scoped to the acted-on post — the bar's
    /// star, and v2's column star (#2408).
    func toggleBookmark(for id: PostID) {
        guard !host.unavailablePostIDs.contains(id) else { return }
        MemberGates.perform(.save, from: host) { [weak self] in
            guard let self else { return }
            // The fill says it; the hand feels it, saving only (#803, #1881).
            Feedback.toggled(on: host.bookmarks.toggle(id.rawValue))
            refreshBookmarkGlyph(for: id)
        }
    }

    /// Points the bookmark glyph at `id`'s state — called on toggle, when
    /// the active page changes, and when the saved fact of the post it draws
    /// changes anywhere (`savedObservation`).
    func refreshBookmarkGlyph(for id: PostID) {
        bookmarkGlyphPostID = id
        let saved = host.bookmarks.isSaved(id.rawValue)
        drawnBookmarkSymbol = Self.bookmarkSymbol(saved: saved)
        // The label follows the state, like the glyph: "Save" and "Saved" are
        // different offers, and a reader who cannot see the fill has only this.
        bookmarkItem.accessibilityLabel = saved ? "Saved" : "Save"
        bookmarkItem.image = SnapFooterToolbar.saveImage(saved: saved)
        host.snapCell(for: id)?.chrome.actionColumn.setSaved(saved)
    }

    /// The save glyph (#1128): the star, outline at rest; filled in the
    /// save gold once saved (`SaveStar`, the one contract, #1190).
    static func bookmarkSymbol(saved: Bool) -> String {
        SaveStar.symbol(saved: saved)
    }

    // MARK: - Toolbar visibility

    /// The toolbar's push/pop choreography — UIKit's, through UIKit's API.
    ///
    /// ⚠️ NATIVE CHROME IS UIKIT'S (see `TabBarRevealPolicy`). This used to
    /// show the bar unanimated and then fade its `alpha` 0 → 1 on the
    /// transition coordinator, and the grab faded it 1 → 0 with the finger.
    /// Both are gone: `setToolbarHidden(_:animated:)` is the whole of it, and
    /// with a transition in flight UIKit animates the change alongside it, the
    /// way it animates a navigation bar's items.
    ///
    /// ⚠️ THE GEOMETRY QUESTION the unanimated show used to answer: the bottom
    /// safe area has to be final before a zoom present's `layoutIfNeeded`
    /// bakes the flight replica's insets. UIKit's animated form commits the
    /// toolbar's frame (and the safe area it implies) as a model value inside
    /// its own animation block, so it is final before the transition lays
    /// anything out — `-dock-trace` prints the safe area either side of the
    /// call to prove it on a device.
    func presentToolbar() {
        guard let nav = host.navigationController else { return }
        toolbarHost = nav

        // The stack's toolbar is shown by this screen alone, so configuring
        // the shared instance here cannot fight another owner. Transparent
        // for the same reason the navigation bar is: full-bleed media, no
        // scroll-edge darkening, items carry their own legibility.
        let appearance = UIToolbarAppearance()
        appearance.configureWithTransparentBackground()
        nav.toolbar.standardAppearance = appearance
        nav.toolbar.compactAppearance = appearance
        nav.toolbar.scrollEdgeAppearance = appearance
        nav.toolbar.tintColor = .white

        guard nav.isToolbarHidden else { return }
        #if DEBUG
        let safeBefore = host.view.safeAreaInsets.bottom
        #endif
        nav.setToolbarHidden(false, animated: host.transitionCoordinator != nil)
        #if DEBUG
        if LaunchArgument.dockTrace.isPassed() {
            host.view.layoutIfNeeded()
            print("[dock] feed toolbar shown animated=\(host.transitionCoordinator != nil)"
                + " safeB \(safeBefore) -> \(host.view.safeAreaInsets.bottom)"
                + " alpha=\(nav.toolbar.alpha)")
        }
        #endif
    }

    /// The exit leg: UIKit hides the toolbar, alongside whatever transition is
    /// carrying the feed away (the percent-driven slide scrubs it with the
    /// finger; the zoom pop runs it on the transition clock; the free-floating
    /// grab runs it over the post-release remainder, exactly like the
    /// navigation bar's own item cross-fade on that leg). A cancelled close
    /// re-appears this screen, and `presentToolbar` puts it back the same way.
    func concealToolbar() {
        guard let nav = host.navigationController, !nav.isToolbarHidden else { return }
        // Hand the bar over intact when the incoming screen is a toolbar
        // owner too (the profile's filter tray): it adopts the shared
        // instance and reconfigures it in its own viewWillAppear — hiding it
        // here would fight that presentation, the flash this rule replaces.
        if successorUsesToolbar(on: nav) { return }
        // Instant paths (tab switch) have no transition to ride.
        nav.setToolbarHidden(true, animated: host.transitionCoordinator != nil)
    }

    /// Deterministic backstop for the toolbar's hide, in the one callback
    /// that fires only for *completed* disappearances. If the hide above was
    /// undone or never ran, settle it here so the screen underneath can never
    /// inherit a visible empty toolbar. Unanimated: nothing of this screen is
    /// on display any more.
    func settleToolbarAfterDisappearance() {
        guard let nav = toolbarHost, !nav.isToolbarHidden,
              nav.topViewController !== host else { return }
        // Same handover rule as concealToolbar: a successor that shows its
        // own toolbar owns the bar now — settling it hidden would strand
        // that screen's chrome.
        if successorUsesToolbar(on: nav) { return }
        nav.setToolbarHidden(true, animated: false)
    }

    /// Whether the navigation stack's current top — the screen this feed is
    /// disappearing underneath or popping back to — presents toolbar items of
    /// its own. `topViewController` is already the successor by the time the
    /// disappearance callbacks run.
    private func successorUsesToolbar(on nav: UINavigationController) -> Bool {
        guard let top = nav.topViewController, top !== host else { return false }
        return top.toolbarItems?.isEmpty == false
    }

    // MARK: - The post actions

    /// The toolbar's post actions — save, repost, ⋯ — for the page in front:
    /// disabled on a post no one may act on (#1409), never removed, so the
    /// bar keeps its shape from page to page.
    func applyToolbarPostActions(for id: PostID) {
        let available = !host.unavailablePostIDs.contains(id)
        bookmarkItem.isEnabled = available
        shareItem.isEnabled = available
        repostToolbarItem?.isEnabled = available
        footerSoundItem?.isEnabled = available
        footerSoundButton.isUserInteractionEnabled = available
        // A text page's like (#1924): none for a post that turned unavailable.
        refreshFooterLike(for: host.modelsByID[id], animated: true)
    }

    private(set) var repostToolbarItem: UIBarButtonItem?
    /// The footer's trailing item: the active page's sound (#1999).
    private(set) var footerSoundItem: UIBarButtonItem?
    /// What it draws: the record, as the page's bubble drew it, on the bar's
    /// 36 pt bubble.
    let footerSoundButton: SnapSoundBubbleButton = {
        let button = SnapSoundBubbleButton()
        button.isHidden = false
        button.accessibilityIdentifier = SnapFooterToolbar.ID.sound
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: SnapFooterToolbar.bubbleSide),
            button.heightAnchor.constraint(equalToConstant: SnapFooterToolbar.bubbleSide),
        ])
        return button
    }()

    /// The footer's sound for `model`, in place (#1999): its cover, or the
    /// greyed note for a media post with none (#683).
    func refreshFooterSound(for model: FeedItemDisplayModel) {
        footerSoundButton.setFace(host.soundFace(for: model), pipeline: host.imagePipeline)
    }

    // MARK: - A text page's footer like (#1924)

    /// Whether a text page's like stands in this screen's footer (#1924, the
    /// owner): `[author] [♥ count] [☆ ⇄] [↪]`, and no pill floating over the
    /// composer, so a short comment list rests on it. A screen with no
    /// footer (`-no-toolbar`) keeps the pill.
    var footerCarriesTextLike: Bool { !defaultToolbarItems.isEmpty }

    /// The footer's like while a text page is active; nil on a media page,
    /// whose like is its column's pill.
    private(set) var footerLikeItem: UIBarButtonItem?
    /// What that item draws, so an unchanged face mints nothing.
    private(set) var footerLikeFace: FooterLikeFace?

    struct FooterLikeFace: Equatable {
        let id: PostID
        let count: Int64?
        let spent: Int
    }

    /// Points the footer like at `model` — minted for a text page, gone for
    /// a media one. A new count or a new face is a new item under the same
    /// identifier, set animated (R3): the bar morphs it.
    func refreshFooterLike(for model: FeedItemDisplayModel?, animated: Bool) {
        guard footerCarriesTextLike else { return }
        let face = model.flatMap { model -> FooterLikeFace? in
            guard model.mediaURL == nil, !host.unavailablePostIDs.contains(model.id) else { return nil }
            return FooterLikeFace(
                id: model.id, count: host.viewModel.visibleLikeCount(for: model), spent: host.stakes?.total(on: model.id) ?? 0
            )
        }
        guard face != footerLikeFace else { return }
        let presenceChanged = (face == nil) != (footerLikeFace == nil)
        footerLikeFace = face
        footerLikeItem = face.map { face in
            SnapFooterToolbar.makeLikeItem(count: face.count, spent: face.spent) { [weak self] in
                self?.likeFromFooter()
            }
        }
        if presenceChanged { host.applyAuthorWidthBudget(bar: nil, sortOnBar: nil) }
        host.setToolbarItems(footerToolbarItems(), animated: animated && host.canAnimateBarItems)
    }

    /// The footer as it stands. On a text page (#1924, #2488):
    /// `[author] [♥ 382] [☆ ↗]` — the like in a bubble of its own, Share
    /// beside the star with no separator so the bar puts them in one platter,
    /// repost in the share sheet (`shareSheetActions`). ⚠️ NEVER `•••` (the
    /// owner, 2026-11-18): when even the pill's face does not fit, the like
    /// joins them, `[♥ 382 ☆ ↗]` (`footerMergesLike`).
    func footerToolbarItems() -> [UIBarButtonItem] {
        var items = defaultToolbarItems
        guard let like = footerLikeItem,
              let flexible = items.firstIndex(where: { $0 === footerFlexibleSpace }) else {
            // ⚠️ v2's media page (#2408): `[author] ——— [⇄]`. Save and the
            // sound moved to the column; the repost stays, in its own bubble.
            guard host.layoutV2 else { return items }
            return items.filter { $0 !== bookmarkItem && $0 !== shareSeparator && $0 !== footerSoundItem }
        }
        items.removeAll { $0 === repostToolbarItem || $0 === footerSoundItem || $0 === shareSeparator }
        items.insert(contentsOf: footerMergesLike ? [like] : [like, footerLikeSeparator], at: flexible + 1)
        if let save = items.firstIndex(where: { $0 === bookmarkItem }) { items.insert(shareItem, at: save + 1) }
        return items
    }

    /// Whether a text page's like shares the star's platter (#2488, step 3),
    /// from the measured widths (`SnapBarPillWidths.textFooterMergesLike`).
    private(set) var footerMergesLike = false

    /// The widths decided the like's platter: set again only on a change.
    func setFooterMergesLike(_ merges: Bool) {
        guard merges != footerMergesLike else { return }
        footerMergesLike = merges
        guard footerLikeItem != nil else { return }
        host.setToolbarItems(footerToolbarItems(), animated: host.canAnimateBarItems)
    }

    /// The footer's spacer and the like's separator, kept so the like goes
    /// in its place.
    private let footerFlexibleSpace = UIBarButtonItem.flexibleSpace()
    private let footerLikeSeparator = BarItems.separator()
    /// Share's own bubble, kept so a text page's footer drops it with Share.
    private let shareSeparator = BarItems.separator()

    /// A tap on the footer's heart: the page's pill's tap, on the active
    /// text page.
    func likeFromFooter() {
        guard let id = footerLikeFace?.id else { return }
        host.performBoost(on: id, spend: .likes(WalletStore.Policy.defaultStakeAmount), from: host.snapCell(for: id))
    }
}
