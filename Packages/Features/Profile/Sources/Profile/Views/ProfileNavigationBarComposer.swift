import CoreNavigation
import DesignSystem
import HeroPage
import LaunchArguments
import UIKit

/// What the profile's navigation bar asks of its screen (#2522, #2475): the
/// view model, whether the profile is the viewer's own (the account's tab
/// root, an editor), the selector it moves into the bar, History's Select /
/// Done and its Remove, where the header's selector slot stands, the ⋯ menu,
/// and the Edit and Settings pushes.
///
/// A view controller: the bar is its navigation item's, and a push is told
/// apart by its own `transitionCoordinator`.
@MainActor
protocol ProfileNavigationBarComposerHost: UIViewController {
    var viewModel: ProfileViewModel { get }
    var identityStubIsSelf: Bool { get }
    var hasEditor: Bool { get }
    /// The account's own profile, the Profile tab's root: it leads with the
    /// shell's bell and wears the gear.
    var isAccountRoot: Bool { get }
    var selector: HeroPageSelector { get }
    var isSelectingHistory: Bool { get }
    var historySelectBarItem: UIBarButtonItem? { get }
    var historyRemoveBarItem: UIBarButtonItem? { get }
    func isActionRowUnderBar(travelled: CGFloat) -> Bool
    func makeMoreMenu() -> UIMenu
    func pushSettings()
    func pushEditProfile()
}

/// The profile's navigation bar, out of `ProfileViewController` (#2522),
/// light since #2475 (the owner, 2026-11-28):
///
/// ```
///                      at rest                  past the threshold
/// someone else's       [‹] … [⋯]                [‹][selector] … [⋯]
/// the own profile      [🔔] … [✎][⋯ ⚙]           [🔔][selector] … [✎]
///   on History                                  [🔔][selector] … [Select]
///   selecting          [🔔][Remove (n)] … [Done][⋯ ⚙]   [🔔][Remove (n)] … [Done]
/// ```
///
/// - **No title, no soft edge, no balance, no day, no Follow** in any
///   profile's bar (#2475 §1): the header keeps the name and the @handle,
///   Follow is someone else's toolbar (`ProfileRelationToolbar`), the wallet
///   is Settings' (Wallet and Purchases), and the History day's headings
///   stay in its list.
/// - **The threshold** is the header's selector slot going under the bar
///   (`isActionRowUnderBar`, the trigger the tray used): past it the
///   selector moves into the leading group, right after the chevron or the
///   bell (#2337's arrangement), the own ⋯ and gear leave, and ✎ fills in
///   the primary — the same item, its style changed in place (#2331).
/// - **The selector's width** is #2361 / #2411's rule: it takes what the
///   other items leave (`BarSelectorBudget`), scrolls past it with the
///   selected page in view and its cut side fading, keeps its titles' size
///   (15pt, else 13pt, decided without the trailing items), never a `•••`,
///   and the same gap on both sides (#2577, `BarSelectorItem.settle`).
///
/// ⚠️ THE ONLY WRITER OF THE SCREEN'S NAVIGATION ITEMS: the leading group,
/// the trailing group, the back button's mode and the large title's.
///
/// ⚠️ ITS GROUPS ARE KEPT BY A `BarItemStore` (#2531): ✎, ⋯, the gear and
/// their separators are the trailing store's, the same instance while they
/// stay in the group, and every group is handed to the bar through its store
/// (`apply(leading:/trailing:)`), never by a `set…Items` of this file's own.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: `applyNavigationState` runs in the
/// caller's turn — `viewDidLoad` before the first layout, `viewWillAppear`
/// before the transition animates. A change mid-transition, once the bar was
/// written, waits for rest: an item set during a push lands unanimated at
/// its end (#756).
@MainActor
final class ProfileNavigationBarComposer {
    private unowned let host: any ProfileNavigationBarComposerHost

    init(host: any ProfileNavigationBarComposerHost) {
        self.host = host
    }

    static let editItemID = "profile.edit"
    static let moreItemID = "profile.more"
    static let settingsItemID = "profile.settings"
    static let selectorItemID = "profile.selector"

    /// Whether the own profile wears the settings gear, which pushes
    /// Settings (`SettingsFeatureBuilding`).
    private var hasSettingsItem = false
    /// The trailing group's own items — ✎, ⋯, the gear — kept by identifier
    /// (#2331, #2531).
    private let trailingStore = BarItemStore()
    /// The leading group's own separator before History's Remove, through
    /// its own store: a store drops what left the group it applies.
    private let leadingStore = BarItemStore()
    /// An item the SHELL owns at the head of the leading group — the
    /// notifications bell, on the tab root only (a pushed profile leads with
    /// its back button).
    private var leadingAccessoryItem: UIBarButtonItem?
    /// Whether the header's selector slot has gone under the bar (#2475):
    /// the selector is in the bar, the own ⋯ and gear gone.
    private(set) var isPastThreshold = false
    /// What the bar was last handed: a change mid-transition after the first
    /// write waits for rest.
    private var applied: AppliedKey?

    private struct AppliedKey: Equatable {
        var selectorInBar: Bool
        var leading: [ObjectIdentifier]
        var trailing: [ObjectIdentifier]
    }

    /// The own profile's settings gear, from the screen's
    /// `configureNavigationBar`.
    func configureSettingsItem() {
        hasSettingsItem = true
    }

    /// Installs (or clears) the shell's leading accessory — the bell. Safe
    /// before the view loads: `applyNavigationState` reads it every time.
    func setLeadingAccessoryItem(_ item: UIBarButtonItem?) {
        leadingAccessoryItem = item
        guard host.isViewLoaded else { return }
        applyNavigationState()
    }

    // MARK: - The items

    /// Whether the bar is the viewer's own: ✎ and ⋯ (and the gear on the
    /// tab root) in place of someone else's ⋯.
    private var isOwn: Bool {
        host.isAccountRoot || host.hasEditor || host.identityStubIsSelf || host.viewModel.isOwnProfile
    }

    /// ✎, Edit profile: quiet at rest and past the threshold alike (the
    /// owner, 2026-11-28: the primary belongs to Select and Done, History's
    /// corner word, not to ✎).
    private var editItem: UIBarButtonItem {
        trailingStore.item(Self.editItemID) {
            let item = BarItems.icon(id: Self.editItemID, image: UIImage(systemName: "pencil"), label: "Edit Profile") {
                [weak self] in self?.host.pushEditProfile()
            }
            // The page's ink, over the banner or the page.
            item.tintColor = .label
            return item
        }
    }

    /// ⋯: the profile's menu — someone else's (Unfollow first once
    /// followed, Share, Copy Link, Map, Restrict, Block, Report), or the
    /// own (Share, Copy Link, QR Code, Map, Clear History on History).
    private var moreItem: UIBarButtonItem {
        trailingStore.item(Self.moreItemID) {
            let item = BarItems.icon(
                id: Self.moreItemID, image: UIImage(systemName: "ellipsis"), label: "More actions", menu: host.makeMoreMenu()
            )
            item.tintColor = .label
            return item
        }
    }

    /// The gear, the own tab root's door to Settings.
    private var settingsItem: UIBarButtonItem? {
        guard hasSettingsItem else { return nil }
        return trailingStore.item(Self.settingsItemID) {
            // The owner's gear (#2433), tinted `.label` to read as primary
            // dark chrome over the banner.
            let settings = BarItems.icon(
                id: Self.settingsItemID, image: AppSymbol.settings.image(), label: "Settings"
            ) { [weak self] in self?.host.pushSettings() }
            settings.tintColor = .label
            return settings
        }
    }

    /// The trailing group, the first item at the bar's edge (#2475 §3, §4).
    ///
    /// - someone else's: `[⋯]` — nothing on a page for no one (#1406);
    /// - the own, at rest: `[✎][⋯ ⚙]` — ⋯ and the gear in one bubble, ✎ in
    ///   its own (Done in its place while selecting History);
    /// - the own, past the threshold: `[✎]`, `[Select]` in the primary on History,
    ///   `[Done]` while selecting (#2307).
    private func trailingItems() -> [UIBarButtonItem] {
        guard isOwn else { return host.viewModel.namesNoOne ? [] : [moreItem] }
        // The own profile gone (#1406): the gear alone, its only way out.
        if host.viewModel.namesNoOne { return [settingsItem].compactMap { $0 } }
        let lead = host.historySelectBarItem ?? editItem
        guard !isPastThreshold else { return [lead] }
        let pair = [settingsItem, moreItem].compactMap { $0 }
        let leadID = lead.identifier ?? Self.editItemID
        return pair + [trailingStore.separator(before: leadID), lead]
    }

    /// Whether the selector belongs in the bar now: past the threshold, a
    /// strip placed (more than one page), and not while selecting History —
    /// Remove stands in its place then, and the pages do not page.
    private var wantsSelectorInBar: Bool {
        isPastThreshold && host.selector.isPlaced && !host.isSelectingHistory && !host.viewModel.namesNoOne
    }

    /// The leading group: the bell on the tab root (a pushed profile's
    /// chevron is UIKit's), then the selector past the threshold, or
    /// History's Remove while selecting — each in a platter of its own.
    private func leadingItems(selectorInBar: Bool) -> [UIBarButtonItem] {
        let lead = host.isAccountRoot ? leadingAccessoryItem : nil
        if let remove = host.historyRemoveBarItem {
            let separator = leadingStore.separator(before: remove.identifier ?? "profile.history.remove")
            return lead.map { [$0, separator, remove] } ?? [remove]
        }
        if selectorInBar, let selector = host.selector.barItem { return selector.leadingGroup(after: lead) }
        return [lead].compactMap { $0 }
    }

    // MARK: - Applying

    /// The single application point for everything the navigation bar
    /// shows. Idempotent, driven from viewDidLoad (the first composition),
    /// viewWillAppear (bound before the transition animates), the threshold
    /// (`headerDidMove`), the tabs, History's select mode and a page for no
    /// one.
    func applyNavigationState(animated: Bool = false) {
        let navigationItem = host.navigationItem
        // ⚠️ THE CHEVRON KEEPS ITS SILENCE: `.minimal` keeps the back button
        // bare for the next screen (two pushed bars are budgeted against a
        // bare 44pt chevron).
        navigationItem.backButtonDisplayMode = .minimal
        // A large title has nowhere to go under an immersive banner.
        navigationItem.largeTitleDisplayMode = .never
        // No @handle in the bar, at rest or on scroll (#2475): the header
        // carries the name and the handle.
        if navigationItem.title != nil { navigationItem.title = nil }
        // ⚠️ WITHOUT THIS THE SELECTOR REPLACES THE BACK BUTTON, and UIKit
        // disables the interactive pop along with it, silently.
        navigationItem.leftItemsSupplementBackButton = true

        let selectorInBar = wantsSelectorInBar
        let trailing = trailingItems()
        let key = AppliedKey(
            selectorInBar: selectorInBar,
            leading: leadingItems(selectorInBar: false).map(ObjectIdentifier.init),
            trailing: trailing.map(ObjectIdentifier.init)
        )
        guard key != applied else {
            refitSelector()
            return
        }
        // ⚠️ A CHANGE MID-TRANSITION WAITS FOR REST once the bar has been
        // written (#756): items set during a push land unanimated at its end.
        if applied != nil, host.transitionCoordinator != nil, host.view.window != nil {
            #if DEBUG
            if LaunchArgument.profileNavbarAudit.isPassed() { print("PROFILE-NAVBAR-AUDIT deferred to rest") }
            #endif
            host.navigationController?.whenAtRest { [weak self] in
                guard let self else { return }
                applyNavigationState(animated: host.view.window != nil)
            }
            return
        }
        applied = key
        // The strip leaves the header BEFORE its item goes into the bar, and
        // the bar lets go of it BEFORE it goes back: never in two places.
        if selectorInBar { host.selector.moveIntoBar() }
        // ⚠️ A NEW TRAILING ITEM RE-FITS A STRIP ALREADY IN THE BAR (the
        // owner's device, 2026-11-28): Posts → History past the threshold
        // swaps ✎ for the wider Select, the strip states a narrower width
        // in place, and the bar must lay out again to read it — otherwise
        // it keeps ✎'s width and sweeps Select into a `•••`.
        if fitSelector(trailing: trailing) { host.navigationController?.navigationBar.setNeedsLayout() }
        #if DEBUG
        debugBarWrites.append(animated && UIView.areAnimationsEnabled)
        #endif
        leadingStore.apply(leading: leadingItems(selectorInBar: selectorInBar), to: navigationItem, animated: animated)
        trailingStore.apply(trailing: trailing, to: host, animated: animated)
        if !selectorInBar { host.selector.moveIntoHeader() }
        if selectorInBar { settleSelector(afterAnimation: animated) }
        #if DEBUG
        if LaunchArgument.profileNavbarAudit.isPassed() {
            let phase = host.transitionCoordinator != nil ? "DURING-TRANSITION" : "idle"
            print("PROFILE-NAVBAR-AUDIT rebuild leading=\(navigationItem.leftBarButtonItems?.count ?? 0) "
                + "trailing=\(trailing.count) selectorInBar=\(selectorInBar) past=\(isPastThreshold) \(phase)")
        }
        #endif
    }

    /// Recomposes the bar once no transition runs, without animation — for an
    /// item that leaves mid-transition (#800, #756).
    func applyNavigationStateAtRest() {
        let apply: @MainActor () -> Void = { [weak self] in
            UIView.performWithoutAnimation { self?.applyNavigationState() }
        }
        if let navigationController = host.navigationController { navigationController.whenAtRest(apply) } else { apply() }
    }

    /// The header moved (the screen's `heroPageHeaderDidMove`): past the
    /// threshold, or back, the bar changes — its items in place, the
    /// selector between the header and the bar (#2475).
    func headerDidMove(travelled: CGFloat) {
        let past = host.isActionRowUnderBar(travelled: travelled)
        guard past != isPastThreshold else { return }
        isPastThreshold = past
        #if DEBUG
        if LaunchArgument.profileNavbarAudit.isPassed() {
            print(String(format: "PROFILE-NAVBAR-AUDIT threshold past=%@ travelled=%.0f placed=%@ inBar=%@",
                         past ? "yes" : "no", travelled, host.selector.isPlaced ? "yes" : "no",
                         host.selector.isInBar ? "yes" : "no"))
        }
        #endif
        applyNavigationState(animated: host.view.window != nil && host.transitionCoordinator == nil)
    }

    // MARK: - The selector's width (#2361, #2411, #2577)

    /// The room the bar leaves the selector: the bell (or the back chevron)
    /// before it, the trailing group after it.
    private func selectorBudget(trailing: [UIBarButtonItem]) -> BarSelectorBudget {
        var budget = selectorTitleBudget
        budget.trailingWidths = trailing.filter { !Self.isSpace($0) }.map(BarSelectorBudget.width(of:))
        return budget
    }

    /// The room without the trailing items: what decides the titles' size,
    /// so ✎ or Select narrows the container and never shrinks a title
    /// (#2411's rule).
    private var selectorTitleBudget: BarSelectorBudget {
        let navigationBarWidth = host.navigationController?.navigationBar.bounds.width ?? 0
        let barWidth = navigationBarWidth > 1
            ? navigationBarWidth : (host.view.window?.bounds.width ?? host.view.bounds.width)
        let leading: [CGFloat]
        if host.isAccountRoot, let bell = leadingAccessoryItem {
            leading = [BarSelectorBudget.width(of: bell)]
        } else if host.navigationController.map({ $0.viewControllers.first !== host }) ?? false {
            // The back chevron, a glyph's bubble.
            leading = [BarSelectorBudget.platter]
        } else {
            leading = []
        }
        return BarSelectorBudget(barWidth: barWidth, leadingWidths: leading)
    }

    /// A separator (a fixed space) takes no room of its own.
    private static func isSpace(_ item: UIBarButtonItem) -> Bool {
        item.customView == nil && item.image == nil && item.title == nil && item.menu == nil && item.primaryAction == nil
    }

    /// True when the width the strip states moved.
    @discardableResult
    private func fitSelector(trailing: [UIBarButtonItem]) -> Bool {
        guard host.selector.isInBar, let selector = host.selector.barItem else { return false }
        return selector.fit(selectorBudget(trailing: trailing), titleBudget: selectorTitleBudget)
    }

    /// Re-fits the selector in the bar to the room it has — a page that
    /// arrived late (#742), a new bar width — and lays the bar out again
    /// when the width it states moved. The item stays the same.
    private func refitSelector() {
        guard host.selector.isInBar, let selector = host.selector.barItem,
              selector.fit(selectorBudget(trailing: host.ownTrailingBarItems), titleBudget: selectorTitleBudget)
        else { return }
        host.navigationController?.navigationBar.setNeedsLayout()
        settleSelector(afterAnimation: false)
    }

    /// Equal gaps either side of the selector, or a narrower one after a
    /// sweep, once the bar has laid it out (`BarSelectorItem.settle`, the
    /// inbox's loop).
    ///
    /// ⚠️ AFTER THE BAR'S OWN ANIMATION, when the group was written animated:
    /// measured mid-insertion, the strip had no window yet (read as a sweep,
    /// narrowed to a bubble) and the items leaving still stood beside it
    /// (a gap of −142pt "balanced" the strip to 99pt).
    private func settleSelector(afterAnimation: Bool) {
        guard host.view.window != nil, let selector = host.selector.barItem,
              let navigation = host.navigationController else { return }
        let delay: TimeInterval = afterAnimation ? Self.barAnimationAllowance : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak navigation] in
            guard let self, let navigation else { return }
            selector.settle(
                in: navigation.navigationBar,
                // ⚠️ NO GAP BALANCE HERE (#2475): on this bar the drawn gaps
                // read wrong — the strip's platter did not follow its stated
                // width — so each balance widened it again (+16, +22, +40…)
                // until the bar swept the group into a `•••`. The budget's
                // equal gaps (`interGroupGap` = `leadingGap` on iOS 27) stand.
                balances: false,
                // Select and Done are custom views (`BarItems.word`): one
                // with no window was swept.
                trailing: { [weak self] in self?.host.ownTrailingBarItems ?? [] },
                budget: { [weak self] in
                    guard let self else { return BarSelectorBudget(barWidth: 0) }
                    return selectorBudget(trailing: host.ownTrailingBarItems)
                },
                isLive: { [weak self, weak navigation] in
                    guard let self, let navigation else { return false }
                    return host.view.window != nil && host.selector.isInBar && host.selector.barItem === selector
                        && navigation.topViewController === host && !navigation.isNavigationBarHidden
                },
                rewriteLeading: { [weak self] in
                    guard let self else { return }
                    leadingStore.apply(
                        leading: leadingItems(selectorInBar: true), to: host.navigationItem, animated: false
                    )
                },
                rewriteTrailing: { [weak self] in
                    guard let self else { return }
                    // A swept group is measured again only when it is handed
                    // back: emptied, then its items, made afresh.
                    trailingStore.apply(trailing: [], to: host, animated: false)
                    let items = trailingItems()
                    trailingStore.apply(trailing: items, to: host, animated: false)
                    applied?.trailing = items.map(ObjectIdentifier.init)
                },
                trace: { moment in
                    #if DEBUG
                    guard LaunchArgument.profileNavbarAudit.isPassed() else { return }
                    print(String(format: "PROFILE-SELECTOR %@ hosted=%@ stated=%.0f trim=%.0f balance=%.0f",
                                 moment, selector.isHosted ? "yes" : "NO", selector.strip.intrinsicContentSize.width,
                                 selector.trim, selector.balance))
                    #endif
                }
            )
        }
    }

    /// How long the bar's own item animation runs (UIKit's, ~0.35 s), with
    /// a margin: the settle loop starts after it.
    static let barAnimationAllowance: TimeInterval = 0.5

    #if DEBUG
    /// Stands in for the scroll: past the threshold, or back.
    func debugSetPastThreshold(_ past: Bool) {
        isPastThreshold = past
        applyNavigationState()
    }

    /// Every write of the bar's groups, in order: whether it was animated,
    /// so UIKit could morph it (#1903).
    private(set) var debugBarWrites: [Bool] = []
    #endif
}
