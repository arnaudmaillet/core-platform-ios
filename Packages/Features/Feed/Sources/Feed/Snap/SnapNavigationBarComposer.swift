import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import PostSurfaces
import ThreadKit
import UIKit

/// What the full-screen feed's navigation bar asks of its screen (#2514): the
/// back item, the open comments' panel and its tabs, the author pill and the
/// toolbar that wears it, the wallet's badge, its sheet and its render, and
/// the boost anchors a wallet change redraws.
///
/// A view controller: the bar is its navigation item's, and its trailing run
/// goes through the toasts' door (`setOwnTrailingBarItems`).
@MainActor
protocol SnapNavigationBarComposerHost: UIViewController {
    var backItem: UIBarButtonItem? { get }
    var commentsContentVC: UIViewController? { get }
    var commentTabs: CommentTabsSelector { get }
    var authorBar: SnapAuthorBar { get }
    var authorIdentityView: SnapAuthorIdentityView { get }
    var toolbarComposer: SnapToolbarComposer { get }
    var walletBadge: WalletBadgeButton { get }
    var makeWalletSheet: (@MainActor () -> UIViewController)? { get }
    func presentWalletSheet()
    func refreshWalletBadge()
}

/// The full-screen feed's navigation bar (#2514): its appearance, the leading
/// run (the back arrow, and the comments' sort beside it), the trailing run
/// (the balance, and the comments' day), the engaged chrome's switch between
/// the two states, and the sort's availability.
///
/// ⚠️ THE ONLY WRITER OF THE SCREEN'S NAVIGATION ITEMS, as
/// `SnapToolbarComposer` is of its `toolbarItems`: the leading run through
/// `applyLeadingNavItem`, the trailing one through `applyTrailingNavItems`,
/// both SET with the bar's own animation, never assigned.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: every entry point runs in the caller's
/// turn, where the screen called it before — `viewDidLoad`
/// (`configureNavigationItem`), the appearance, the engagement's switch
/// (`setEngagedChrome`), a panel's comment count.
@MainActor
final class SnapNavigationBarComposer {
    private unowned let host: any SnapNavigationBarComposerHost
    /// The viewer's point balance; nil keeps the bar without a badge.
    private let wallet: (any WalletStaking)?
    /// Whether the bar wears the balance: not for a guest (#1146).
    private let showsBalance: Bool

    init(host: any SnapNavigationBarComposerHost, wallet: (any WalletStaking)?, showsBalance: Bool) {
        self.host = host
        self.wallet = wallet
        self.showsBalance = showsBalance
    }

    /// The nav bar's two trailing items, held so comment mode can add the
    /// sort selector beside the author pill and take it away again.
    private var sortItem = UIBarButtonItem()
    private(set) var walletBadgeItem: UIBarButtonItem?
    /// The wallet's changes, heard for this controller's lifetime.
    private var walletObservation: StoreObservation?

    /// Puts the screen chrome into (or out of) comment mode, both bars at
    /// once — they are one state, and splitting them across call sites is
    /// how a half-engaged bar happens.
    ///
    ///   resting          NAV [‹ back] … [🪙 solde] [author pill]
    ///   comments (media) NAV [✕]      … [🪙 solde] [Popular | Recent] [author pill]
    ///   comments (text)  NAV [‹ back] … [🪙 solde] [Popular | Recent] [author pill]
    ///   TOOLBAR          [♫ attribution] … [🔖 ⬆︎] [⋯]   — in every state
    ///
    /// (The wallet badge appears only when a wallet is injected; a
    /// nil-wallet feed keeps the historical runs without it.)
    ///
    /// `hasMedia` no longer changes the bar: it picked the leading slot for
    /// the first comments space's ✕, gone with it (#2087) — a media post's
    /// comments are a sheet with a bar of its own.
    ///
    /// Internal, not private, so the bar contracts are unit-testable without
    /// driving a whole engagement — which needs a live cell, a hosted child,
    /// and a spring to settle.
    func setEngagedChrome(_ engaged: Bool, hasMedia: Bool, animated: Bool) {
        engagedChromeOnBar = engaged
        engagedChromeHasMedia = hasMedia
        // The bar pills' widths for the bars as they stand
        // (`applyBarPillWidths`), in this same turn, under the bar's own item
        // animation.
        host.authorBar.applyBarPillWidths()

        // ⚠️ READ RIGHT TO LEFT: `rightBarButtonItems[0]` is the one nearest
        // the screen edge. The author pill is the toolbar's (#671), so this
        // run holds the ✕ while a media post's thread is open — the way back
        // to the picture — and the balance. A TEXT post's comments ARE the
        // page: there is nothing to close.
        //
        // SET, don't ASSIGN (`applyTrailingNavItems`): the animated setter is
        // the one that hands the change to the bar's own item animator. The
        // fixed space keeps two pills apart — iOS 26 groups ADJACENT bar
        // items into one shared glass platter.
        applyTrailingNavItems(engagedTrailingItems(), animated: animated)

        applyLeadingNavItem(engaged: engaged, hasMedia: hasMedia, animated: animated)
    }

    /// The trailing run as the bars stand, right to left: the ✕ while a media
    /// post's thread is open, the points, and — engaged under Recent, once a
    /// day chip has gone under the header — the day (#757).
    func engagedTrailingItems() -> [UIBarButtonItem] {
        guard engagedChromeOnBar else { return restingTrailingItems() }
        // The comments' ✕ is the LEADING button now (#1192), not a trailing
        // item.
        var items: [UIBarButtonItem] = []
        // The fixed spaces keep the pills apart: iOS 26 groups ADJACENT bar
        // items into one shared glass platter.
        for item in [walletBadgeItem, host.authorBar.commentsDayItem].compactMap({ $0 }) {
            items += items.isEmpty ? [item] : [.fixedSpace(Spacing.sm), item]
        }
        return items
    }

    /// The resting run's items: the author pill alone (no wallet), or the
    /// pill with the badge to its left, spacer-separated so iOS 26 never
    /// fuses them into one platter.
    private func restingTrailingItems() -> [UIBarButtonItem] {
        // The pill is the toolbar's (#671): the nav bar holds the points alone.
        return walletBadgeItem.map { [$0] } ?? []
    }

    /// The leading slot's two faces:
    ///
    ///   media comments open → ✕ (collapse to the media layout)
    ///   anything else       → the back arrow, if there is one
    ///
    /// TEXT POSTS KEEP THE BACK ARROW. Their engagement is the page's
    /// permanent resting state, so a ✕ would promise a media layout that
    /// does not exist — the same asymmetry that used to live in the
    /// toolbar's trailing slot, now expressed in the slot where it reads as
    /// a navigation choice instead of an action.
    ///
    /// A tab-root feed has no back arrow at rest, and gains a ✕ all the
    /// same: the two answer different questions (leave the screen vs. leave
    /// the layout), and only the second is always available.
    ///
    /// SET, don't ASSIGN — same reason as the trailing items: the animated
    /// form hands the change to the bar's own item animator, so the ✕ morphs
    /// into the arrow's place instead of popping over it.
    /// ⚠️ THE ARROW STAYS, in every state.
    ///
    /// The comments exit used to take this slot on a media post, on the reading
    /// that it means the same kind of thing one level in — leave what is open.
    /// It cost the screen its way OUT while the layout was open: the arrow was
    /// gone, so leaving the post meant closing the comments first and then
    /// going back, two gestures for one intention. The exit lives at the other
    /// end now, in the TRAILING nav slot the author pill holds at rest — so the
    /// two ways out of a post are one at each end of the same bar, and neither
    /// costs the other.
    ///
    /// ⚠️ SUPERSEDED (#1192, the owner 2026-10-15): while a MEDIA post's
    /// comments are open, the ✕ item TAKES the arrow's place at the edge, and
    /// the trailing ✕ is gone. Two items swapped through the animated setter,
    /// so UIKit draws the change as it does every other bar change (#1197:
    /// a symbol replace inside one button was not the bar's own transition).
    func applyLeadingNavItem(engaged: Bool, hasMedia: Bool, animated: Bool) {
        // ⚠️ LEFT TO RIGHT here, unlike the trailing run: `leftBarButtonItems[0]`
        // is the one nearest the screen edge. So this reads [‹ back] [Popular | Recent],
        // the sort just inboard of the arrow, with the fixed space that keeps
        // them two pills rather than one shared platter.
        //
        // The sort belongs at this end: it is a control over the thread, and
        // this is the end that carries what the screen is DOING. The trailing
        // end carries who the post is by.
        var items = [host.backItem].compactMap { $0 }
        if engaged, isCommentSortAvailable {
            items += items.isEmpty ? [sortItem] : [leadingSortSpacer, sortItem]
        }
        // ⚠️ THE SPACES ARE KEPT TOO (#2331): fresh ones made every run look
        // changed, and the bar was handed the same items again.
        guard host.navigationItem.leftBarButtonItems ?? [] != items else { return }
        host.navigationItem.setLeftBarButtonItems(items, animated: animated)
    }

    /// The leading run's space, kept as its items are (#2331).
    private let leadingSortSpacer = UIBarButtonItem.fixedSpace(Spacing.sm)

    /// Whether the engaged thread is long enough to be worth sorting — see
    /// `CommentSortPolicy`. Until it is, the sort is not in the bar at all, and
    /// the author pill has its width.
    private(set) var isCommentSortAvailable = false

    /// Whether the bar is WEARING the engaged chrome, which is not the same as
    /// an engagement holding the slot: a text page mounts its engagement while
    /// it is still being scrolled in, and a closing thread keeps its slot until
    /// the animation's teardown — the bar is resting in both. A count arriving
    /// then is kept for the next engaged chrome, not drawn onto a resting bar.
    var engagedChromeOnBar = false
    private(set) var engagedChromeHasMedia = false

    /// Offers or withdraws the sort. Fed by the ENGAGED panel's comment count,
    /// so a thread that reaches the threshold while it is open — the viewer's
    /// own tenth comment — brings the sort in through the bar's own animation.
    /// Internal for tests, which have no panel to count.
    func setCommentTabsAvailable(_ available: Bool, animated: Bool = false) {
        guard available != isCommentSortAvailable else { return }
        isCommentSortAvailable = available
        guard engagedChromeOnBar else { return }
        // The widths first: the sort's word is decided before it is handed over.
        host.authorBar.applyBarPillWidths()
        applyLeadingNavItem(engaged: true, hasMedia: engagedChromeHasMedia, animated: animated)
    }

    /// Reads the answer off the panel about to own the engagement — BEFORE the
    /// engaged chrome is built, so the bar comes up right the first time.
    func syncCommentSortAvailability() {
        isCommentSortAvailable = (host.commentsContentVC as? PostDetailViewController)?.showsPopular ?? false
    }

    /// The count, as it changes, from a panel that holds the engagement. A
    /// panel that does not (a warm, a preview) is heard at its promotion
    /// instead, through `syncCommentSortAvailability`.
    func observeCommentCount(of detail: PostDetailViewController?) {
        detail?.onCommentCountChange = { [weak self, weak detail] _ in
            guard let self, let detail, self.host.commentsContentVC === detail else { return }
            self.setCommentTabsAvailable(detail.showsPopular, animated: true)
        }
    }

    func applyTrailingNavItems(_ items: [UIBarButtonItem], animated: Bool) {
        // The screen's own items, through the toasts' door (#1420, #1679).
        guard host.ownTrailingBarItems != items else { return }
        host.setOwnTrailingBarItems(items, animated: animated)
    }

    func configureNavigationItem() {
        // Fully transparent bar over the full-bleed media, identical for every
        // bar state so no scroll-edge transition ever fires. Set per-item (not
        // on the bar) so pushed screens keep their normal bars with zero
        // restore choreography.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        host.navigationItem.standardAppearance = appearance
        host.navigationItem.scrollEdgeAppearance = appearance
        host.navigationItem.compactAppearance = appearance

        // The author identity rides the toolbar's leading item (#671), not
        // the centered titleView: a pill per author, in an item under the
        // author's identifier, so a new author is UIKit's item replacement
        // (`showAuthor`, #1791). The feed's chrome stays identical on every
        // entry path (menu push and pin flight), so nothing else may install
        // items, here or from outside.
        host.authorBar.wireAuthorIdentityView(host.authorIdentityView)
        // No badge until the graph has answered for an author.
        host.authorIdentityView.setFollowBadge(.none)
        host.toolbarComposer.authorItem = host.toolbarComposer.makeAuthorItem()
        sortItem = BarItems.container(id: "feed.snap.commentTabs", view: host.commentTabs.tabBar)
        if wallet != nil {
            // Tappable exactly when a sheet is wired: the badge opens the
            // same claim sheet the map's does, from any post. Without one
            // it stays display-only and must not swallow taps meant for
            // the page.
            host.walletBadge.isUserInteractionEnabled = host.makeWalletSheet != nil
            if host.makeWalletSheet != nil {
                host.walletBadge.addAction(
                    UIAction { [weak self] _ in self?.host.presentWalletSheet() },
                    for: .primaryActionTriggered
                )
            }
            if showsBalance { walletBadgeItem = BarItems.container(id: BarItems.SharedID.walletBalance, view: host.walletBadge) }
            // A grown count needs a re-measured wrapper, and the wrapper
            // belongs to the ITEM: re-adding the same item hands the bar
            // the same wrapper with the same frozen size (measured in-sim).
            // A FRESH item is the only thing the bar measures anew.
            host.walletBadge.onFittedWidthChange = { [weak self] in
                guard let self, let old = self.walletBadgeItem,
                      case var items = self.host.ownTrailingBarItems,
                      let index = items.firstIndex(of: old) else { return }
                let fresh = BarItems.container(id: BarItems.SharedID.walletBalance, view: self.host.walletBadge)
                self.walletBadgeItem = fresh
                items[index] = fresh
                // The badge is the run's PRIORITY member: when it grows,
                // the author's width shrinks by the same points — before the
                // run is handed over, or it overflows into a `•••` on narrow
                // bars. One of the few things that moves the pill's width.
                self.host.authorBar.applyBarPillWidths()
                self.host.setOwnTrailingBarItems(items, animated: false)
            }
            host.refreshWalletBadge()
            // The badge re-renders on every store change — a rail spend, a
            // comments-bar spend, or a claim taken on the map while this
            // screen sits in the stack below. The like controls are the
            // screen's stakes' to redraw (#2532).
            walletObservation = wallet?.changes.observeOnMain { [weak self] in
                self?.host.refreshWalletBadge()
            }
        }
        // Both pills' widths BEFORE their items are handed over: the bar reads
        // a custom view's size at hand-over (memory `bar-item-wrapper-drift`).
        host.authorBar.applyBarPillWidths()
        host.setOwnTrailingBarItems(restingTrailingItems(), animated: false)


        // Keep `title` (it feeds pushed screens' back labels) but suppress its
        // centered rendering — the bar's center stays empty by design.
        host.navigationItem.titleView = UIView()
    }
}
