import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import LaunchArguments
import MediaCore
import MediaUI
import PostGrid
import PostSurfaces
import ThreadKit
import UIKit

/// What the full-screen feed's author pill asks of its screen (#2387): the
/// arriving page and the theme it lends the bars, the follow graph, the
/// flight, the toolbar that hosts the pill, and what stands beside the pills
/// on both bars — the arithmetic of their widths reads it.
///
/// A view controller: the follow gate and its toasts are presented from it,
/// and the bars it measures are its own.
@MainActor
protocol SnapAuthorBarHost: UIViewController {
    var arrivalModel: FeedItemDisplayModel? { get }
    var modelsByID: [PostID: FeedItemDisplayModel] { get }
    var viewModel: FeedViewModel { get }
    var imagePipeline: ImagePipeline { get }
    var followStore: SnapAuthorFollowStore { get }
    var flight: SnapFlightPhase { get }
    /// On screen, and no transition or flight owns the bar's items.
    var canAnimateBarItems: Bool { get }
    /// The bars are being handed back to the screen underneath.
    var isHandingChromeBack: Bool { get }
    /// The toolbar the pill's item stands in, its only writer.
    var toolbarComposer: SnapToolbarComposer { get }
    var defaultToolbarItems: [UIBarButtonItem] { get }
    var commentsContentVC: UIViewController? { get }
    var backItem: UIBarButtonItem? { get }
    var engagedChromeOnBar: Bool { get }
    var engagedChromeHasMedia: Bool { get }
    var isCommentSortAvailable: Bool { get }
    var commentTabs: CommentTabsSelector { get }
    var walletBadge: WalletBadgeButton { get }
    var walletBadgeItem: UIBarButtonItem? { get }
    func isTextPage(_ id: PostID?) -> Bool
    func applyChromeTheme(hasMedia: Bool)
    /// The navigation bar's trailing run as the bars stand.
    func engagedTrailingItems() -> [UIBarButtonItem]
    func applyTrailingNavItems(_ items: [UIBarButtonItem], animated: Bool)
    #if DEBUG
    func debugProbeBarItemWidth(_ pill: UIView, slot: String)
    #endif
}

/// The full-screen feed's author pill (#2387): the pill the toolbar's leading
/// item wears, a fresh one per author (#1791), its install once the screen
/// has landed, the follow its "+" makes and the badges bound to the author,
/// and the fixed widths both bars' pills are given — the author's and the
/// comments' day under the header (#757), which the same arithmetic sizes.
///
/// The pill's ITEM is the toolbar's (`SnapToolbarComposer`): this draws the
/// pill and asks the composer to re-mint the item, which it alone writes.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: every entry point runs in the caller's
/// turn, where the screen called it before — the picture's change of owner
/// and the settle (`showAuthor`), the appearance (`installAuthorPillAfterLanding`),
/// every layout pass (`applyBarPillWidths`). What waits — the landing
/// install, an author held by a transition, the day's placement — waits on
/// its own, as it did.
@MainActor
final class SnapAuthorBar {
    /// File-private, not private: `BarAuthorBadge` asks whether the pill is
    /// in a window.
    fileprivate unowned let host: any SnapAuthorBarHost

    init(host: any SnapAuthorBarHost) {
        self.host = host
    }

    /// The author identity, hosted as the trailing bar item's custom view —
    /// at a FIXED width read off the bar (`applyBarPillWidths`), so its glass
    /// is the same size on every page and a long name truncates inside it.
    ///
    /// A FRESH PILL IN A FRESH ITEM PER AUTHOR (#1791, the owner 2026-10-27),
    /// under a per-author `identifier` (`authorItemIdentifier(for:)`), so iOS
    /// 26/27 runs its own item replacement — the glass morphing between the
    /// two platters. This reverses #627's one-item-per-slot with a hand-made
    /// scroll blur (`BarPillScrub`, deleted): the owner now prefers UIKit's
    /// transition. The same author keeps the pill and the item, and changes
    /// in place (`showAuthor`).
    private(set) var authorIdentityView = SnapAuthorIdentityView()

    // MARK: - Author pill

    /// Wires a pill for this screen: its taps, the theme hook, the width the
    /// bar leaves it and the ground it floats over — everything the screen
    /// told the pill before, so a fresh pill for a new author (#1791) is the
    /// same pill to the bar.
    func wireAuthorIdentityView(_ pill: SnapAuthorIdentityView) {
        // ⚠️ THE BAR'S THEME, THE MOMENT ITS GLASS EXISTS (#1325). Every
        // opening themed at appearance, and again alongside the push — but
        // UIKit hosts the toolbar's items (and creates the glass container
        // `toolbarGlassHost` themes) on ITS schedule, which on a shelf card's
        // flight came after both: the bottom bar flew in light over a media
        // post for its first frames (filmed by the owner) while a grid tile's
        // did not. Themed when the pill joins the window, whatever the path.
        pill.onDidMoveToWindow = { [weak self] in
            guard let self, let model = self.host.arrivalModel, !self.host.isHandingChromeBack else { return }
            self.host.applyChromeTheme(hasMedia: model.mediaURL != nil)
        }
        // ⚠️ THE PILL OPENS THE PROFILE CARD (#1524), not the profile: the
        // viewer's own pill still pushes theirs.
        pill.onAuthorTapped = { [weak self] id in
            guard let self else { return }
            host.viewModel.didTapAuthorPill(id, isViewer: host.followStore.relation(for: id) == .viewer)
        }
        // A hold pushes the profile itself (#1669), as the leftward swipe
        // does; the tap keeps the card.
        pill.onAuthorLongPressed = { [weak self] id in self?.host.viewModel.didTapAuthor(id) }
        // The "+" follows, in place (`followAuthor`). The followed and friends
        // marks take no tap of their own — a tap on them is a tap on the pill,
        // which opens the profile — so there is no unfollow here: that is the
        // profile's Following button, one tap away.
        pill.onFollowTapped = { [weak self] id in self?.followAuthor(id) }
        #if DEBUG
        pill.onContentSettled = { [weak self, weak pill] in
            guard let self, let pill else { return }
            self.host.debugProbeBarItemWidth(pill, slot: "author")
        }
        #endif
        pill.setWidthBudget(authorWidthBudget)
        pill.setOverMedia(authorOverMedia)
    }

    /// The width the toolbar leaves the pill (`applyBarPillWidths`) and the
    /// ground it floats over (`updateBarChrome`): kept, so a fresh pill
    /// (#1791) is told them too.
    private var authorWidthBudget: CGFloat?
    var authorOverMedia = true

    /// Puts `model`'s author in the bar (#1791).
    ///
    /// - A NEW AUTHOR is a fresh pill in a fresh item under the author's
    ///   identifier, handed to the toolbar animated: UIKit's own item
    ///   replacement. The pill is drawn — face, name AND follow badge (#925) —
    ///   before it is handed over, so the new author and their relation land
    ///   in that one swap.
    /// - The SAME AUTHOR (paging between their posts, or better data for
    ///   them) changes in place, with no transition: the pill's meta line is
    ///   the handle alone, so usually nothing moves at all; a badge change is
    ///   its symbol replace alone.
    /// - ⚠️ NEVER DURING A PRESENTATION'S TRANSITION (`canAnimateBarItems`):
    ///   that transition owns the bar, and an item swap started under it lands
    ///   in its first frames. The author waits (`pendingAuthor`) and swaps
    ///   once, natively, when the screen has landed. Off screen there is
    ///   nothing to see: the swap is made at once.
    ///
    /// Called when the playback owner changes (`updateViewportPlayback`), so
    /// the pill and the picture change owner on the same frame, and at every
    /// settle (`updateBarChrome`) — a no-op there after a scroll.
    ///
    /// Internal, not private, so the item contract is testable without a
    /// populated feed.
    func showAuthor(_ model: FeedItemDisplayModel) {
        let badge = host.followStore.badge(for: model.authorID)
        // The bar's pill follows this author's answers from now on (#1972);
        // drawn below with the pill's own swap rules.
        defer { authorBadges.bind(barAuthorBadge, to: model.authorID) }
        let shown = authorIdentityView.shownAuthor?.authorID
        guard let shown, shown != model.authorID else {
            pendingAuthor = nil
            authorIdentityView.setAuthor(model, pipeline: host.imagePipeline, animated: false)
            authorIdentityView.setFollowBadge(badge, animated: host.canAnimateBarItems)
            return
        }
        guard host.view.window == nil || host.canAnimateBarItems else {
            pendingAuthor = model
            showPendingAuthorAfterTransition()
            return
        }
        pendingAuthor = nil
        let pill = SnapAuthorIdentityView(arrives: true)
        wireAuthorIdentityView(pill)
        pill.setFollowBadge(badge)
        pill.setAuthor(model, pipeline: host.imagePipeline, animated: false)
        authorIdentityView = pill
        host.toolbarComposer.reinstallAuthorItem(animated: host.view.window != nil)
    }

    /// An author that arrived while a transition owned the bar — swapped in
    /// once it has landed (`showAuthor`).
    private var pendingAuthor: FeedItemDisplayModel?

    /// Shows `pendingAuthor` once the presentation's transition is over — a
    /// flight's landing calls it too (`installAuthorPillAfterLanding`).
    private func showPendingAuthorAfterTransition() {
        guard let coordinator = host.transitionCoordinator else { return }
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            // One turn later: out of the transition's completion.
            DispatchQueue.main.async { self?.showPendingAuthor() }
        }
    }

    func showPendingAuthor() {
        guard let model = pendingAuthor else { return }
        showAuthor(model)
    }

    /// Set by an appearance, spent once the screen has LANDED: the pill that
    /// rode the presentation in is re-installed in a fresh item.
    ///
    /// ⚠️ THE SQUARE PLATE. A post opened by a flight showed the pill's initials
    /// plate as a rounded SQUARE (filmed on a device; reproduced on the iPhone
    /// 18 Pro simulator with an author who has no picture — with a picture the
    /// plate is covered within 0.15s, which is why quick screenshots missed
    /// it). The item had first materialised inside the push's bar transition,
    /// and there the plate's system-fill background was drawn with the bar's
    /// own corner, ignoring the view's radius and its oval mask; re-installing
    /// the item (opening and closing the comments) drew a disc.
    ///
    /// The cause is fixed at the plate (`MonogramAvatarView.drawPlate`: an oval
    /// path, no fill background). This install is the second guard, and costs
    /// one item swap per appearance: every entry path ends the way the
    /// comments round trip did, with an item installed on a settled screen.
    /// Same pill, same identifier — the swap is not animated and not seen.
    var authorPillAwaitsLandingInstall = false

    func installAuthorPillAfterLanding() {
        guard authorPillAwaitsLandingInstall, !host.flight.isAwaitingAnyFlight else { return }
        #if DEBUG
        if LaunchArgument.pillNoLandingInstall.isPassed() { return }
        #endif
        authorPillAwaitsLandingInstall = false
        // One turn later: out of the transition's completion and whatever
        // animation context it closes in.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.host.view.window != nil else { return }
            self.host.toolbarComposer.reinstallAuthorItem()
            // A follow relation that arrived during the flight was left for
            // this moment (`drawBarAuthorBadge`): its symbol replaces
            // the badge's now.
            self.authorBadges.reapply(self.barAuthorBadge)
            // An author the flight kept waiting swaps in now, natively (#1791).
            self.showPendingAuthor()
        }
    }

    // MARK: - Follow

    /// Every pill that shows an author — the bar's and a text page's caption
    /// row — bound to it in one place (#1972).
    private(set) lazy var authorBadges = AuthorBadgeBinding(store: host.followStore)

    /// The bar's pill, as the binding sees it: whichever pill is shown now.
    private lazy var barAuthorBadge = BarAuthorBadge(owner: self)

    /// Re-draws the bar pill's badge — its symbol replaced, nothing else
    /// (#925). During a presentation the landing install is armed and draws
    /// it again — the badge changes once the screen has landed, where it can
    /// be seen to change.
    fileprivate func drawBarAuthorBadge(_ badge: PersonPill.Badge) {
        // Bound to the author being shown — one a transition keeps waiting
        // (`pendingAuthor`) is drawn when its pill swaps in.
        guard authorIdentityView.shownAuthor?.authorID == authorBadges.author(of: barAuthorBadge),
              authorIdentityView.followBadge != badge else { return }
        if authorPillAwaitsLandingInstall, host.flight.isAwaitingAnyFlight || host.transitionCoordinator != nil { return }
        authorIdentityView.setFollowBadge(badge, animated: host.canAnimateBarItems)
    }

    /// The pill's "+": follows the author, OPTIMISTICALLY — the profile's
    /// Follow button's rule (`ProfileViewModel.toggleFollow`). The "+" turns
    /// at once into the followed mark — the FRIENDS mark for someone who
    /// already follows the viewer — through the badge's symbol replace, and comes
    /// back if the graph refuses (`SnapAuthorFollowStore.follow`).
    ///
    /// Internal for tests.
    func followAuthor(_ author: ProfileID) {
        MemberGates.perform(.follow(handle: nil), from: host) { [weak self] in
            self?.commitFollow(author)
        }
    }

    private func commitFollow(_ author: ProfileID) {
        // Named now, while the pill shows them: by the time the graph answers
        // the viewer may have swiped to someone else.
        let name = authorIdentityView.shownAuthor.flatMap { $0.authorID == author ? Self.followName(of: $0) : nil }
        let followed = host.followStore.follow(author) { [weak self] in
            guard let self else { return }
            // The "+" comes back — and says why (#802): a mark that undoes
            // itself without a word reads as a glitch, or is missed entirely.
            #if DEBUG
            self.debugFollowFailureToastsShown += 1
            #endif
            Feedback.failure(name.map { "Couldn't follow \($0)" } ?? "Couldn't follow", from: self.host)
        }
        // Turned on at the optimistic flip (#1885), not when the graph answers.
        if followed { Haptics.play(.toggleOn) }
    }

    /// How a follow failure names the author: their `@handle` from the
    /// model, otherwise their display name.
    static func followName(of model: FeedItemDisplayModel) -> String {
        model.authorHandle.map { "@" + $0 } ?? model.authorName
    }

    /// A TEXT page's author face — its caption's row (#2300) — bound as the
    /// bar's pill is: one more face of `authorBadges`, redrawn
    /// on every answer for its author and on a viewer change, a page built
    /// ahead included; the "+" is `followAuthor`'s; the face's tap is the
    /// card and its hold the profile, the author pill's routes (#2145).
    ///
    /// A media page's caption row is never bound: the bar's pill wears the
    /// mark.
    func bindCaptionAuthor(of content: UIViewController?, for id: PostID) {
        guard let detail = content as? PostDetailViewController else { return }
        let author = host.isTextPage(id) ? host.modelsByID[id]?.authorID : nil
        detail.bindCaptionAuthor = { [weak self] cell in
            guard let self else { return }
            authorBadges.bind(cell, to: author)
            guard let author else { return }
            cell.onAvatarTap = { [weak self] in
                guard let self else { return }
                host.viewModel.didTapAuthorPill(author, isViewer: host.followStore.relation(for: author) == .viewer)
            }
            cell.onAvatarHold = { [weak self] in self?.host.viewModel.didTapAuthor(author) }
            cell.onAuthorFollowTap = { [weak self] in self?.followAuthor(author) }
        }
    }

    // MARK: - The pills' widths

    /// Gives both pills their FIXED widths for the bars as they stand — see
    /// `SnapBarPillWidths` for the arithmetic and why nothing a post says is
    /// in it.
    ///
    /// The system does not negotiate here: the instant a run does not fit it
    /// hides the whole item behind a `•••` menu, and the author vanishes
    /// rather than shrinking. So the fitting is arithmetic done up front, off
    /// the bars and the items beside the pills, and what gives way gives way
    /// in the order that costs the reader least:
    ///
    ///   1. inside the pill, the display NAME truncates first
    ///      (`SnapAuthorIdentityView`'s compression priorities — the handle
    ///      outranks the name), then the handle
    ///   2. the SORT PILL drops its word and keeps its glyph when the word
    ///      would leave the author narrower than `comfortableAuthor`
    ///
    /// Idempotent, and cheap enough for every layout pass: an unchanged width
    /// writes nothing. Called wherever the bars' geometry can move — a layout
    /// pass of this screen (rotation, the first real width), the sort joining
    /// or leaving (`setEngagedChrome`, `setCommentTabsAvailable`), the wallet
    /// badge growing a digit — and never from a page change.
    func applyBarPillWidths() {
        // The first width that is real: the bar's, else its navigation
        // controller's (already on screen when this screen's view loads for a
        // push), else this screen's own.
        let bar = [
            host.navigationController?.navigationBar.bounds.width,
            host.navigationController?.view.bounds.width,
            host.view.bounds.width,
        ].compactMap { $0 }.first { $0 > 0 } ?? 0
        guard bar > 0 else { return }
        // ⚠️ Not `toolbar.bounds`: the iOS 26 toolbar answers the screen, laid
        // out or not. The feed is full-screen, so its own width is the bar's.
        let toolbar = host.view.bounds.width > 0 ? host.view.bounds.width : bar
        // The sort is on the bar only while a thread that offers it holds the
        // engaged chrome — a withdrawn sort (`CommentSortPolicy`) takes
        // nothing: no pill, no padding, no spacer beside the arrow.
        let sortOnBar = host.engagedChromeOnBar && host.isCommentSortAvailable
        let widths = SnapBarPillWidths.resolve(
            toolbarWidth: toolbar,
            // The footer's glyph items grow with the text size (#1679).
            toolbarIcon: SnapBarPillWidths.toolbarIcon(for: host.traitCollection),
            // …and so does a text post's like beside them (#1924).
            toolbarLike: host.defaultToolbarItems.isEmpty ? nil : SnapFooterToolbar.likeBubbleWidth(for: host.traitCollection)
        )
        barPillWidths = widths
        // ⚠️ THE DAY GIVES WAY FIRST (#757): it takes what the run leaves —
        // bar margins, the back arrow and the sort on the left, the ✕ and the
        // points on the right — and truncates in it.
        if let pill = commentsDayItem?.customView as? SnapBarDayPill {
            let padding: CGFloat = 18
            let gap = Spacing.sm
            var used: CGFloat = 16 * 2 + padding
            if host.backItem != nil { used += 44 + padding }
            if sortOnBar { used += gap + padding + host.commentTabs.width }
            if host.engagedChromeOnBar, host.engagedChromeHasMedia { used += 44 + padding + gap }
            if host.walletBadgeItem != nil {
                used += host.walletBadge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + padding + gap
            }
            pill.setMaxWidth(bar - used - gap)
        }
        // The toolbar's leading slot (#671): the room the audio capsule had —
        // the CAP, since #925: the pill takes its own width under it.
        applyAuthorWidthBudget(bar: bar, sortOnBar: sortOnBar)
    }

    /// The pill's room: the footer's, less the like's on a text post (#1924),
    /// so the run never folds.
    func applyAuthorWidthBudget(bar: CGFloat? = nil, sortOnBar: Bool? = nil) {
        guard let widths = barPillWidths else { return }
        authorWidthBudget = host.toolbarComposer.footerLikeItem == nil ? widths.toolbarAuthor : widths.toolbarAuthorBesideLike
        authorIdentityView.setWidthBudget(authorWidthBudget)
    }

    /// The widths `applyBarPillWidths` last gave the pills.
    private var barPillWidths: SnapBarPillWidths?

    // MARK: - The day under the header (#757)

    /// The engaged thread's day: the last chip gone under the header, none
    /// before one has. ⚠️ ONE ITEM PER DAY, EACH UNDER ITS OWN IDENTIFIER, as
    /// a conversation's (#755): a new identifier gets the native Liquid Glass
    /// morph. Placed once per turn and never mid-transition (#756).
    private(set) var commentsDay: Date?
    private(set) var commentsDayItem: UIBarButtonItem?
    private var trailingPlacementScheduled = false

    /// The engaged panel's day, as it changes. Internal for tests.
    func setCommentsDay(_ day: Date?) {
        guard day != commentsDay else { return }
        commentsDay = day
        commentsDayItem = day.map(makeCommentsDayItem)
        applyBarPillWidths()
        scheduleTrailingPlacement()
    }

    private func makeCommentsDayItem(_ day: Date) -> UIBarButtonItem {
        let pill = SnapBarDayPill(title: DayTitleFormatter.title(for: day))
        pill.addAction(UIAction { [weak self] _ in
            (self?.host.commentsContentVC as? PostDetailViewController)?.scrollToDay(day)
        }, for: .primaryActionTriggered)
        return BarItems.container(id: "snap.comments.day.\(Int(day.timeIntervalSince1970))", view: pill)
    }

    /// Hears the day off the panel that holds the engagement.
    ///
    /// ⚠️ ONLY THE CURRENT PAGE'S PANEL DRIVES THE BAR, at the mount too. A
    /// preview mounts while the page being left still owns the engagement,
    /// and reading ITS day there cleared the pill mid-swipe; a cancelled
    /// swipe never brought it back. A preview is heard at its promotion
    /// instead (`syncCommentsDay`).
    func observeCommentsDay(of detail: PostDetailViewController?) {
        detail?.onDayUnderHeaderChange = { [weak self, weak detail] day in
            guard let self, let detail, self.host.commentsContentVC === detail else { return }
            self.setCommentsDay(day)
        }
        guard let detail, host.commentsContentVC === detail else { return }
        setCommentsDay(detail.dayUnderHeader)
    }

    /// Reads the day off the panel that holds the engagement, whichever
    /// route made it the one: a promotion, a settle, a cancelled swipe.
    func syncCommentsDay() {
        setCommentsDay((host.commentsContentVC as? PostDetailViewController)?.dayUnderHeader)
    }

    private func scheduleTrailingPlacement() {
        guard host.view.window != nil else {
            return host.applyTrailingNavItems(host.engagedTrailingItems(), animated: false)
        }
        guard !trailingPlacementScheduled else { return }
        trailingPlacementScheduled = true
        // The next turn: scrolls and layouts reach here inside diffable
        // applies' `performWithoutAnimation` (#756).
        DispatchQueue.main.async { [weak self] in self?.placeTrailingAfterTransition() }
    }

    /// Not during a push: items set then land unanimated at its end (#756).
    private func placeTrailingAfterTransition() {
        if let coordinator = host.transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { [weak self] _ in
               DispatchQueue.main.async { self?.placeTrailingAfterTransition() }
           }) {
            return
        }
        trailingPlacementScheduled = false
        host.applyTrailingNavItems(host.engagedTrailingItems(), animated: true)
    }

    #if DEBUG
    /// Refused-follow toasts shown (#1979): their ARRIVAL, which a test
    /// cannot miss, where the toast itself is gone after a few seconds — a
    /// starved runner looked for it too late.
    private(set) var debugFollowFailureToastsShown = 0
    #endif
}

/// The bar's author pill as the author binding draws it (#1972): whichever
/// pill is shown now, through the bar's own rules (`drawBarAuthorBadge`).
@MainActor
private final class BarAuthorBadge: AuthorBadgeDrawing {
    private weak var owner: SnapAuthorBar?

    init(owner: SnapAuthorBar) {
        self.owner = owner
    }

    func drawAuthorBadge(_ badge: PersonPill.Badge, animated: Bool) {
        owner?.drawBarAuthorBadge(badge)
    }

    var drawsAuthorBadgeOnScreen: Bool { owner?.host.view.window != nil }
}
