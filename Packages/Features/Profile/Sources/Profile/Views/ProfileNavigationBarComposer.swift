import CoreNavigation
import DesignSystem
import LaunchArguments
import PostGrid
import UIKit

/// What the profile's navigation bar asks of its screen (#2522): the view
/// model and the relation the header shows, whether the profile is the
/// viewer's own (the origin's word, an editor, the tab root), the header
/// whose Follow the bar's Follow taps, the bar's @handle title, History's
/// Select / Done, the pager a day's tap scrolls, where the header's tray
/// stands, and the Settings push.
///
/// A view controller: the bar is its navigation item's, the section
/// contract is bound to it, and a push is told apart by its own
/// `transitionCoordinator`.
@MainActor
protocol ProfileNavigationBarComposerHost: UIViewController {
    var viewModel: ProfileViewModel { get }
    var followButtonState: ProfileViewModel.FollowButton { get }
    var identityStubIsSelf: Bool { get }
    var hasEditor: Bool { get }
    var dayLeads: Bool { get }
    var headerView: ProfileHeaderView { get }
    var barTitle: ProfileBarTitle { get }
    var historySelectBarItem: UIBarButtonItem? { get }
    var shownHistoryBarItem: UIBarButtonItem? { get }
    var galleryPager: ProfileGalleryPagerView { get }
    func isActionRowUnderBar(travelled: CGFloat) -> Bool
    func pushSettings()
}

/// The profile's navigation bar, out of `ProfileViewController` (#2522):
/// the own profile's gear (History's Select or Done in its place), Follow or
/// Requested in the corner once the header's tray has scrolled away, the
/// shell's bell and balance, History's day, and the rules for writing them
/// at rest or mid-push.
///
/// ⚠️ THE ONLY WRITER OF THE SCREEN'S NAVIGATION ITEMS: the leading group,
/// the trailing group (directly, or through the section contract), the back
/// button's mode and the large title's. The @handle title is
/// `ProfileBarTitle`'s, which this composer asks to draw.
///
/// ⚠️ MADE ONCE, NEVER REBUILT (the bar contract, R3, #2331): the three
/// spaces and the day's binding keep their instances, and every
/// identical-group guard compares them by reference.
///
/// ⚠️ ITS GROUPS ARE KEPT BY A `BarItemStore` (#2531): Follow, Requested and
/// the gear are the trailing store's, the same instance while they stay in
/// the group, and every group is handed to the bar through its store
/// (`apply(leading:/trailing:)`), never by a `set…Items` of this file's own.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: `applyNavigationState` runs in the
/// caller's turn — `viewDidLoad` before the first layout, `viewWillAppear`
/// before the transition animates, and inside the screen's
/// `alongsideTransition` while one runs.
@MainActor
final class ProfileNavigationBarComposer {
    private unowned let host: any ProfileNavigationBarComposerHost

    init(host: any ProfileNavigationBarComposerHost) {
        self.host = host
    }

    /// Whether the own profile wears the settings gear, which pushes
    /// Settings (`SettingsFeatureBuilding`). The item is the trailing
    /// store's (`settingsItem`).
    private var hasSettingsItem = false
    /// The trailing group's own items — Follow, Requested, the gear — kept by
    /// identifier (#2331, #2531): the same instance while it stays in the
    /// group, dropped when it leaves. The group goes to the bar through it.
    private let trailingStore = BarItemStore()
    /// The leading group — the shell's bell — handed to the bar through its
    /// own store (#2531): a store drops what left the group it applies, so
    /// each group has one.
    private let leadingStore = BarItemStore()
    /// Keeps the corner item — Follow or Requested (#2248) — and the shell's
    /// balance two bubbles: iOS 26 groups adjacent bar items into one platter
    /// (the feed's note on `setEngagedChrome`). One space for both, since
    /// only one of them stands at a time, and none with the corner empty.
    /// Kept: the trailing run is compared by reference (the bar's
    /// identical-group guard), so a fresh item is a rebuild.
    private let cornerSpacer = UIBarButtonItem.fixedSpace(Spacing.sm)
    /// Keeps History's Select / Done — standing in the gear's place (#2307)
    /// — its own bubble, apart from the balance.
    private let historySelectSpacer = UIBarButtonItem.fixedSpace(Spacing.sm)
    /// An item the SHELL owns at the head of the leading group — the
    /// notifications bell, on the tab root only (a pushed profile leads with
    /// its back button). Kept as state for the same reason as the trailing
    /// one: the leading run is rewritten in `applyNavigationState`.
    private var leadingAccessoryItem: UIBarButtonItem?
    /// An item the SHELL owns, standing inboard of this screen's own — the
    /// viewer's point balance today, the same badge the Explore header and the
    /// post screen wear.
    ///
    /// Injected rather than built here, and that is the design: three screens
    /// show one number, so one object owns the wallet, the claim countdown and
    /// the sheet, and each screen promises only to keep the item in its
    /// trailing run. Kept as state because that run is REBUILT — see
    /// `applyNavigationState`.
    private var trailingAccessoryItem: UIBarButtonItem?
    /// Whether the header's action tray has scrolled under the bar: the bar
    /// then carries the profile's Follow (or Requested) in its corner — at
    /// exactly the point the identity pill used to come in (#1451, #2248),
    /// so the page never shows two Follows at once. On the viewer's own
    /// profile, History's Select takes the gear's place then (#2307).
    private(set) var isTrayScrolledAway = false
    /// Keeps History's day in its own bubble, inboard of the trailing group.
    private let sectionSpacer = UIBarButtonItem.fixedSpace(Spacing.sm)
    /// The bar's Follow, in the corner where the bell stands once the
    /// profile is followed (#2248, the owner 2026-11-10) — replacing the
    /// identity pill whose "+" was the bar's only Follow (#1451).
    /// Requested, on a private profile the viewer asked to follow: its own
    /// item under its own identifier, so the bar morphs Follow into it
    /// (#1679, R3). A tap withdraws the request, as the tray's does.
    ///
    /// **A stock titled item (`BarItems.title`) — deliberately not a
    /// custom-view item, and not a `UIButton` of any kind.** Two independent
    /// reasons, and both have bitten this screen:
    ///
    /// 1. *Rendering.* The iOS 26 bar wraps every item in its own Liquid Glass
    ///    capsule. A glass-configured button hosted as a custom view stacks a
    ///    second material inside that capsule — a visible double-background
    ///    bleed. Handing UIKit a title and letting it draw the chrome is the
    ///    only way to get exactly one capsule.
    /// 2. *Transitions.* A custom view is opaque to the bar's push/pop
    ///    choreography: UIKit can cross-fade and slide items it owns, but a
    ///    hosted view is just a subview it has to carry, which is what makes
    ///    custom bar items snap while native ones interpolate.
    ///
    /// Kept by the trailing store while it stays in the group: the trailing
    /// run is compared by reference (the bar's identical-group guard), so a
    /// fresh item would be a rebuild.
    private func relationshipBarItem(requested: Bool) -> UIBarButtonItem {
        trailingStore.item(requested ? Self.requestedItemID : Self.followItemID) {
            makeRelationshipBarItem(requested: requested)
        }
    }

    // MARK: - Follow in the corner (#2248)

    static let followItemID = "profile.follow"
    static let requestedItemID = "profile.follow-requested"

    /// The item the bar's corner wears for the relation, or nil: Follow or
    /// Requested only once the tray has scrolled away (the owner,
    /// 2026-11-10), where the identity pill came in before (#1451) — so the
    /// page never shows the tray's Follow and the bar's at once.
    ///
    /// | Relation        | Corner      |
    /// |-----------------|-------------|
    /// | not followed    | Follow      |
    /// | requested       | Requested   |
    /// | followed        | nothing     |
    /// | blocked, nobody, the viewer's own, not read yet | nothing |
    ///
    /// ⚠️ NEVER THE BELL (#2302, the owner 2026-11-11): once followed, the
    /// header's Follow becomes the bell, and the corner stays empty, scrolled
    /// or not. A follow from the bar's Follow takes it out, animated
    /// (`updateActionBarItem`).
    ///
    /// A guest reads as not followed, so Follow — behind the member gate,
    /// as the tray's Follow is (`headerView.onFollowTapped`).
    private var cornerItem: UIBarButtonItem? {
        guard showsRelationshipItem else { return nil }
        switch host.followButtonState {
        case .follow: return relationshipBarItem(requested: false)
        case .requested: return relationshipBarItem(requested: true)
        default: return nil
        }
    }

    /// Whether Follow / Requested may stand in the corner now: someone
    /// else's profile, read, not blocked, its tray out of sight.
    private var showsRelationshipItem: Bool {
        guard isTrayScrolledAway, !host.viewModel.namesNoOne, !host.viewModel.isBlocked else { return false }
        guard !host.viewModel.isOwnProfile, !host.identityStubIsSelf, !host.hasEditor else { return false }
        return host.followButtonState == .follow || host.followButtonState == .requested
    }

    /// Whether the bar wears Follow or Requested right now.
    private var isShowingRelationshipItem: Bool {
        host.ownTrailingBarItems.contains { Self.isRelationshipItem($0) }
    }

    /// Whether `item` is Follow or Requested: by identifier, the store's
    /// key — only this composer makes an item under either.
    private static func isRelationshipItem(_ item: UIBarButtonItem?) -> Bool {
        item?.identifier == followItemID || item?.identifier == requestedItemID
    }

    /// Follow, or Requested: a titled native item (the bar contract, #1679)
    /// whose tap is the tray's own — `headerView.onFollowTapped`: the member
    /// gate for a guest, the optimistic flip, its haptic, a request on a
    /// private profile and its withdrawal on Requested. One path, so the bar
    /// and the tray can never disagree on what a tap did.
    ///
    /// Follow wears the bar's `.prominent` style, in the brand's primary;
    /// Requested stays plain (#2268, the owner 2026-11-10 — the colour only
    /// while it reads "Follow").
    private func makeRelationshipBarItem(requested: Bool) -> UIBarButtonItem {
        let item = BarItems.title(
            id: requested ? Self.requestedItemID : Self.followItemID,
            title: requested ? "Requested" : "Follow",
            prominent: !requested
        ) { [weak self] in self?.host.headerView.onFollowTapped?() }
        if requested { item.accessibilityHint = "Withdraws your follow request." }
        return item
    }

    /// The own profile's settings gear, from the screen's
    /// `configureNavigationBar`.
    func configureSettingsItem() {
        hasSettingsItem = true
    }

    static let settingsItemID = "profile.settings"

    /// The gear, kept by the trailing store while it stays in the group.
    private var settingsItem: UIBarButtonItem? {
        guard hasSettingsItem else { return nil }
        return trailingStore.item(Self.settingsItemID) {
            // Settings gear — the viewer's account entry point. A plain
            // trailing item (no leading item, so it never disturbs the
            // edge-swipe pop), tinted `.label` to read as primary dark chrome
            // over the banner.
            let settings = BarItems.icon(
                id: Self.settingsItemID, image: UIImage(systemName: "gearshape"), label: "Settings"
            ) { [weak self] in self?.host.pushSettings() }
            settings.tintColor = .label
            return settings
        }
    }

    /// Installs (or clears) the shell's trailing accessory. Safe before the
    /// view loads: the run is composed in `applyNavigationState`, which reads
    /// this every time it runs.
    func setTrailingAccessoryItem(_ item: UIBarButtonItem?) {
        trailingAccessoryItem = item
        guard host.isViewLoaded else { return }
        applyNavigationState()
    }

    /// Installs (or clears) the shell's leading accessory — the bell. Safe
    /// before the view loads: `applyNavigationState` reads it every time.
    func setLeadingAccessoryItem(_ item: UIBarButtonItem?) {
        leadingAccessoryItem = item
        guard host.isViewLoaded else { return }
        applyNavigationState()
    }

    // MARK: - History's day in the bar (#1344)

    /// The leading group: the tab root's bell. A pushed profile leads with
    /// its back button and its @handle, a native title (#2248) — the
    /// identity pill that came in beside the chevron is gone (#1590's
    /// leading placement with it).
    private var leadingItems: [UIBarButtonItem] {
        [leadingAccessoryItem].compactMap { $0 }
    }

    /// History's day in the bar (#1344): the app's one section contract
    /// (#1573) — it mints the item (one per day, each with its own
    /// identifier, so UIKit morphs between them), places it, and never
    /// mid-push. A tap: the day's first post under the bar.
    ///
    /// - Someone else's profile: innermost of the TRAILING group (#1590) —
    ///   the leading side is the chevron and the @handle (#2248) — through
    ///   `setOwnTrailingBarItems`.
    /// - The viewer's own (`dayLeads`): LEADING, after the bell (the owner,
    ///   2026-10-23, #1642) — the Messages inbox's arrangement. The leading
    ///   group is then the contract's to write.
    private lazy var sectionBinding: PinnedSectionBarBinding = {
        let binding = PinnedSectionBarBinding(
            viewController: host, placement: host.dayLeads ? .leading : .trailing, scope: "profile.history",
            separator: host.dayLeads ? nil : sectionSpacer
        )
        binding.onSelect = { [weak self] index in self?.host.galleryPager.scrollActivePageToSection(index) }
        return binding
    }()

    /// The day the page in front has scrolled into, as last published.
    private var pinnedSection: PostGridPinnedSection?

    /// Names `section` innermost of the trailing group, or takes the name
    /// away. No day over a page for no one (#1406): its gallery is gone.
    func applyPinnedSection(_ section: PostGridPinnedSection?) {
        pinnedSection = section
        let shown = host.viewModel.namesNoOne ? nil : section
        sectionBinding.show(pinned: shown.map { ($0.index, .init(id: $0.title, title: $0.title, count: $0.count)) })
    }

    /// The single application point for everything the navigation bar shows —
    /// the @handle as a leading title on a pushed profile (#2248), the shell's
    /// items, the bell or Follow in the corner. Idempotent, driven from three
    /// places: viewDidLoad (initial composition), viewWillAppear (synchronous
    /// pre-transition bind), and the async data callbacks (via
    /// `alongsideTransition`).
    func applyNavigationState(animated: Bool = false) {
        // ⚠️ **AND THE CHEVRON KEEPS ITS SILENCE.** A titled root gives every
        // screen pushed from it a WORDED back button, and two pushed bars were
        // budgeted against a bare 44pt chevron: `SearchResultsViewController`
        // says in as many words that its field would then be "44pt too
        // generous", and the chat thread's identity view is capped at 240pt on
        // the same assumption — 32 margins + 44 chevron + 24 gap + 8 padding +
        // 240 = 348 fits 375, while a "Messages" label (~98pt with its platter)
        // makes it ~402 and does not. `.minimal` keeps the title for this
        // screen and the chevron bare for the next one.
        host.navigationItem.backButtonDisplayMode = .minimal
        // ⚠️ **`.never`, OR THE TITLE IS NOT DRAWN AT ALL.** With the mode left
        // `.automatic` the bar rendered three platters and NO title label —
        // read straight off `-header-bar-tree`, which is how this was told from
        // a width problem: the string was set (`navItem=Demo Viewer`) and
        // simply had no label anywhere in the bar. For You and Messages both
        // state `.never` for their own reasons; this screen needs it because a
        // large title has nowhere to go under an immersive banner.
        host.navigationItem.largeTitleDisplayMode = .never

        // No content-source filter on any profile (#772): its sources are
        // pages at the foot, your own as anyone else's (#696).
        //   tab root  [bell][day] … [coins][gear | Select | Done]
        //             (History only: Select once the tray has scrolled away,
        //             Done while selecting, wherever the scroll — #2307)
        //   pushed    [‹ @handle] … [day][coins][Follow | Requested | bell]
        //             (Follow / Requested once the tray has scrolled away,
        //             the bell whenever followed, the day on History — #2248)
        // Written only when it changed — the same "say nothing" rule as the
        // trailing run below, for the same torn-capsule reason.
        let leading = leadingItems
        if host.dayLeads {
            // The contract writes the group, the day after the bell (#1642):
            // at once, as below, and only if it changed.
            sectionBinding.leadingPrefix = leading
            sectionBinding.placeNow()
        } else {
            // Through the store, which writes only if the group changed.
            leadingStore.apply(leading: leading, to: host.navigationItem, animated: false)
        }
        // ⚠️ **WITHOUT THIS THE ITEM REPLACES THE BACK BUTTON**, and UIKit
        // disables the interactive pop along with it, silently. Harmless on the
        // tab root, which has no back button to supplement.
        host.navigationItem.leftItemsSupplementBackButton = true

        host.barTitle.applyBarTitle()
        updateActionBarItem(host.followButtonState, animated: animated)
    }

    /// Recomposes the bar once no transition runs, without animation — for an
    /// item that leaves mid-transition (#800, #756).
    func applyNavigationStateAtRest() {
        let apply: @MainActor () -> Void = { [weak self] in
            UIView.performWithoutAnimation { self?.applyNavigationState() }
        }
        if let navigationController = host.navigationController { navigationController.whenAtRest(apply) } else { apply() }
    }

    /// Composes the trailing group per the current state: the own profile's
    /// gear (History's Select or Done in its place, #2307), the corner item
    /// (`cornerItem` — Follow / Requested once the tray has scrolled away,
    /// #2248; never the bell, #2302), the shell's balance, and
    /// History's day. Nothing relational until the relationship is known.
    /// Native items only (the bar contract, #1679): iOS 26 wraps each in the
    /// bar's own Liquid Glass capsule, and a glass-configured custom button
    /// would stack a second material on top of it.
    private func updateActionBarItem(_ state: ProfileViewModel.FollowButton, animated: Bool = false) {
        // Edit is no longer a bar item — it lives in the header tray beside the
        // avatar (see `ProfileHeaderView.configureAction`), so own-profile keeps
        // only its account overflow menu here.
        // `.hidden` yields no item at all. It used to install a bare custom
        // view as a placeholder pill, which was both unreachable — every path
        // into `followButtonState` sets a concrete state, the view model never
        // assigns `.hidden`, and the audit only ever logs `follow`/`following`
        // — and the one thing in this slot that UIKit could not animate across
        // a transition. An absent item is the honest native answer for "no
        // relationship applies".
        // Follow / the bell lives in the header's tray beside Message — see
        // `ProfileHeaderView.configureAction`. The bar takes Follow (or
        // Requested) over only once that tray has scrolled out of sight
        // (#2248), and never the bell (#2302): once followed, the corner is
        // empty. `state` still arrives, because a rebuild is keyed on it and
        // the guard below decides whether anything actually changed.
        _ = state
        // The switcher sits in the LEADING slot, opposite the gear.
        //
        // Safe here and only here: the item exists solely on the canonical own
        // profile, which is a tab ROOT — so there is no back button to displace
        // and no interactive pop for a leading item to interfere with. A pushed
        // profile never has one (see `ProfileFeatureBuilding.onLogout`).
        //
        // Written through the same "say nothing unless it changed" guard as the
        // trailing items: handing UIKit the identical item mid-transition is
        // what tears a capsule down and rebuilds it empty.
        // ⚠️ **The switcher rides TRAILING, beside the gear, and the leading
        // group belongs to the docked selector alone.**
        //
        // Measured, docked own profile: with the switcher in the leading group
        // BOTH leading platters came out 0x44 at the same x while the trailing
        // gear sat at 46x44 — and with the switcher absent, the selector hosted
        // correctly. Neither its empty menu (seeded with a placeholder child) nor
        // the group being rewritten (single write, `isHidden` for visibility)
        // accounted for it; two leading items are fine elsewhere, since For You
        // carries a compose glyph beside its selector.
        //
        // So the chrome moved rather than the selector: this screen's actions all
        // live at the trailing end now, which is also the layout every other
        // surface wears — leading is the selector, trailing is what you can do.
        // ⚠️ THE LEADING GROUP IS NOBODY'S NOW, and the guard that used to
        // claim it for the docked selector had to be DELETED rather than left
        // to evaluate: with no selector item it reduced to
        // `leftBarButtonItems = []` on every appearance and every follow-state
        // change — a silent eraser of any leading item an owner installs, which
        // `configureNavigationBar` explicitly contemplates.

        // Relationship action for other users; the gear for own profile (where
        // `action` is nil).
        var items: [UIBarButtonItem] = []
        // A page for no one (#800, #1406) acts on no one: no relationship,
        // no balance. A pushed one keeps only its back button;
        // the viewer's own tab root keeps the gear and the switcher, its only
        // way to settings and to another profile.
        let namesNoOne = host.viewModel.namesNoOne
        // The own profile's corner: the gear — or, on History once the tray
        // has scrolled away, Select in its place, and Done while selecting
        // wherever the scroll is (#2307, the owner 2026-11-11). Each its own
        // item under its own identifier, so UIKit morphs the gear into Select
        // and back (R3), on the trigger the handle and the blur use (#2268).
        let historyItem = host.historySelectBarItem
        if let historyItem {
            items.append(historyItem)
        } else if let settingsItem {
            items.append(settingsItem)
        }
        // The corner, someone else's profile only: `[0]`, as the gear is on
        // your own. Follow or Requested, once the tray has scrolled away
        // (#2248, where the identity pill came in before, #1451) —
        // `[coins][Follow]`, then `[coins]` once followed: the bell is the
        // header's now (#2302). Each its own item under its own identifier,
        // so UIKit morphs one into the other (R3).
        let corner = namesNoOne ? nil : cornerItem
        if let corner { items.append(corner) }
        // The shell's accessory next: the gear keeps the corner and the
        // balance sits inboard — the Explore header's arrangement ([coins]
        // [search]). On a pushed profile, which has neither the gear nor the
        // switcher, the balance is the corner. Fixed spaces keep each its own
        // bubble — adjacent items share one glass capsule.
        // ⚠️ THE BALANCE IS NEVER REPLACED (#2307): History's Select / Done
        // took its place until then (#2188); it stands in the gear's now, and
        // the balance keeps its own on every tab.
        if let trailingAccessoryItem, !namesNoOne {
            if corner != nil {
                items.append(cornerSpacer)
            } else if historyItem != nil {
                items.append(historySelectSpacer)
            }
            items.append(trailingAccessoryItem)
        }
        // History's day, innermost (#1590), is the section contract's
        // (`sectionBinding`): it composes the group, the day after these. No
        // day over a page for no one (#1406): its gallery is gone.
        if namesNoOne, sectionBinding.item != nil { sectionBinding.show(pinned: nil) }
        // The load-bearing guard. A pop's `viewWillAppear` resolves to exactly
        // the item set already on the bar, and handing that same set back is
        // what used to tear the capsule down and rebuild it mid-transition.
        // Nothing changed, so nothing is said.
        let group = sectionBinding.placedTrailing(items)
        guard !host.ownTrailingBarItems.elementsEqual(group, by: ===) else {
            if !host.dayLeads { sectionBinding.trailingItems = items }
            return
        }
        // ⚠️ THE CORNER CHANGING waits for rest, then comes in animated
        // (#2248): Follow added mid-push would pop in unanimated at the end
        // (#756) — and so would Follow taken away.
        let cornerArrives = corner.map { item in !host.ownTrailingBarItems.contains { $0 === item } } ?? false
        let relationshipLeaves = isShowingRelationshipItem && !Self.isRelationshipItem(corner)
        // So does the own profile's corner changing hands (#2307) — Done
        // leaving as the screen does (`viewWillDisappear`), Select or the gear
        // coming back: a write mid-push lands unanimated at its end (#756).
        // On this screen's own coordinator, one turn after its completion; a
        // coordinator already past its animations takes the write now.
        let historySlotChanges = host.dayLeads && host.shownHistoryBarItem !== historyItem
        if historySlotChanges, let coordinator = host.transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { [weak self] _ in
               DispatchQueue.main.async { [weak self] in
                   guard let self else { return }
                   updateActionBarItem(host.followButtonState, animated: host.view.window != nil)
               }
           }) {
            return
        }
        if cornerArrives || relationshipLeaves, host.transitionCoordinator != nil {
            host.navigationController?.whenAtRest { [weak self] in
                guard let self else { return }
                updateActionBarItem(host.followButtonState, animated: host.view.window != nil)
            }
            return
        }
        // ⚠️ Items leaving a page for no one wait for rest: one removed
        // mid-push pops unanimated at its end (#756) — whichever call got
        // here first (a late relationship, the shell re-sending its balance).
        if namesNoOne, host.transitionCoordinator != nil {
            applyNavigationStateAtRest()
            return
        }
        #if DEBUG
        // Dev convenience: `-profile-navbar-audit` prints every *actual* bar
        // rebuild with the transition state it happened in. A rebuild logged
        // during a pop is the bug this guard exists to prevent, so the audit
        // is the regression test a recording can't be.
        if LaunchArgument.profileNavbarAudit.isPassed() {
            let phase = host.transitionCoordinator != nil ? "DURING-TRANSITION" : "idle"
            // `custom=` is the audit's other job: it counts items in this slot
            // that are HOSTED VIEWS rather than ones UIKit draws itself — the
            // shape that cannot interpolate across a bar transition.
            //
            // ⚠️ The floor is no longer zero. The shell's accessory (the wallet
            // badge) is a hosted view by necessity: a bar item cannot carry a
            // count beside a glyph. What the audit is still for is this
            // screen's OWN items — the follow capsule above all, which was
            // converted off a custom view for exactly this reason — so read it
            // as "one, and only the injected one".
            let custom = group.count(where: { $0.customView != nil })
            print("PROFILE-NAVBAR-AUDIT rebuild items=\(group.count) custom=\(custom) "
                + "state=\(host.followButtonState) \(phase)")
        }
        #endif
        // Written now, so they ride a push they arrive in; the contract
        // composes the group with the day and writes it.
        #if DEBUG
        debugBarWrites.append(animated && UIView.areAnimationsEnabled)
        #endif
        if host.dayLeads {
            // The day is leading here (#1642): the trailing group is all ours.
            trailingStore.apply(trailing: items, to: host, animated: animated)
        } else {
            // The contract keeps our items around the day it places on its
            // own; the group, the day after them, goes through the store.
            sectionBinding.trailingItems = items
            trailingStore.apply(trailing: group, to: host, animated: animated)
        }
    }

    /// The header moved (the screen's `heroPageHeaderDidMove`).
    ///
    /// Once the tray has scrolled under the bar, the bar's corner carries the
    /// profile's Follow or Requested (#2248) — and gives it back to the tray
    /// on the way down. On the viewer's own History, the gear becomes Select
    /// on the same frame (#2307).
    ///
    /// The bar's @handle follows the header's @handle line, step by step
    /// (#2334): a slow scroll brings it slowly, and a stop half way leaves
    /// it half way.
    func headerDidMove(travelled: CGFloat) {
        let passageChanged = host.barTitle.headerDidMove(travelled: travelled)
        let trayGone = host.isActionRowUnderBar(travelled: travelled)
        guard trayGone != isTrayScrolledAway else {
            // Only the title moves: no item, no blur.
            if passageChanged { host.barTitle.applyBarTitle() }
            return
        }
        isTrayScrolledAway = trayGone
        // The corner item and the blur on the same frame (#2268); the
        // handle, already whole by now, stays so.
        updateActionBarItem(host.followButtonState, animated: host.view.window != nil && host.transitionCoordinator == nil)
        host.barTitle.applyBarTitle()
    }

    #if DEBUG
    func debugSetTrayScrolledAway(_ away: Bool) {
        isTrayScrolledAway = away
        updateActionBarItem(host.followButtonState)
        host.barTitle.applyBarTitle()
    }
    /// The bar's Follow or Requested, if it shows one (#2248).
    var debugBarRelationshipItem: UIBarButtonItem? {
        host.ownTrailingBarItems.first { Self.isRelationshipItem($0) }
    }
    /// Every write of the bar's trailing group, in order: whether it was
    /// animated, so UIKit could morph it (#1903). A test reads how Follow
    /// left.
    private(set) var debugBarWrites: [Bool] = []
    /// The bar's day item while it is shown — what a test reads.
    var debugSectionItem: UIBarButtonItem? {
        let shown = host.ownTrailingBarItems + (host.navigationItem.leftBarButtonItems ?? [])
        guard let item = sectionBinding.item, shown.contains(where: { $0 === item }) else { return nil }
        return item
    }
    /// What a tap on the day item does. Tests.
    func debugTapSectionItem() {
        if let index = pinnedSection?.index { host.galleryPager.scrollActivePageToSection(index) }
    }
    #endif
}
