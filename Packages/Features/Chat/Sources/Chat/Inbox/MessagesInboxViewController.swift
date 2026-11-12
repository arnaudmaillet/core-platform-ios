import ChatInterface
import CoreNavigation
import DesignSystem
import UIKit

/// The Messages tab's root: one navigation bar carrying the tab capsule right
/// of the bell, and a set of horizontally paged surfaces beneath it.
///
/// The container owns exactly three things — the pager, the tab capsule, and
/// the navigation bar's contents — and drives all of them from one signal, the
/// pager's fractional page position. It holds no inbox data and knows nothing
/// about how a page renders; every surface arrives as an `InboxSurface` and is
/// otherwise opaque.
///
/// **The capsule is in the bar, right of the bell, as on For You (#2337, the
/// owner 2026-11-12).** It sat in the title slot in August, in a
/// `UITabAccessory` at the foot of the screen from PR #154 (September) on; it
/// leads the bar now, `[bell][Chats | Requests | Suggestions]`, the paged tab
/// roots' one rule (`BarSelectorItem`). The foot of the screen is the tab bar
/// alone. This screen reserves no safe area of its own — the navigation bar
/// accounts for its own height and each page's list insets itself through the
/// standard safe area. Nothing floats over the content, so there is no header
/// geometry to maintain here.
///
/// **Badges are a fact about the session.** Nothing here retires one: not
/// paging between tabs, not pushing a thread, not leaving for another root tab.
/// A cold launch builds new view models and with them new watermarks, and that
/// is the only reset there is — see `InboxTabWatermark`.
///
/// **The bar belongs to the inbox, not to a page.** The bell and the selector
/// leading, the search field stacked under the bar: they belong to the inbox
/// as a whole rather than to any page, which was always the point — a page
/// publishing its own word up there would re-measure the bar on every tab
/// change. What a page contributes rides its own tab: a badge, and the menu
/// its long press offers. The shell adds an item of its own through
/// `HeaderAccessoryHosting` — the notifications bell leading — which is the
/// app's rather than the inbox's, and so pages with nothing either. No
/// balance trails it (#2336, the owner 2026-11-12): the likes balance shows
/// where likes are spent or earned, and the inbox has no heart, no spend and
/// no claim.
final class MessagesInboxViewController: UIViewController, MessagesInboxCategorySelecting,
    HeaderAccessoryHosting {
    /// The inbox's surfaces, in paging order.
    private let surfaces: [any InboxSurface]
    /// The shared glass tab capsule, in the navigation bar right of the bell.
    /// It takes titles and reports an index — the category is this container's
    /// vocabulary, not the bar's, so every call site maps one to the other
    /// through `surfaces`.
    private let categoryBar: PagedTabBar
    /// The capsule's bar item and its width rule (#2337): For You's recipe —
    /// `.navigationTitle`, `.platter`, `BarItems.container` under a stable
    /// identifier — with the room it may take, 15pt or 13pt, and a scroll
    /// past that. Never a `•••`.
    private let selector: BarSelectorItem
    /// The selector item's identifier, the same on every launch (#2337). One
    /// item for the screen's life, as For You's.
    static let selectorItemID = "messages.inbox.selector"

    /// Built in `viewDidLoad`, once the surfaces are children — reading a
    /// child's `view` before containment would load it outside its parent.
    private var pagerView: HorizontalPagerView!
    private var didSubordinatePagerToPop = false
    private var hasActivatedInitialSurface = false
    #if DEBUG
    /// Latches the launch-argument QA sequence to one run per screen.
    private var hasRunDebugSequence = false
    #endif
    /// Every tab's badge added together, for the shell's own bar item.
    ///
    /// Published from here rather than computed in the shell because this is
    /// where the parts already are: each surface reports its count as chrome,
    /// and the tab-bar badge is that same set summed. A shell that recomputed
    /// it would need the surfaces, their watermarks, and the rule for when a
    /// watermark moves — three things it has no business knowing.
    ///
    /// It therefore follows the same lifecycle for free: arrivals raise it, and
    /// leaving the screen retires every surface, which zeroes it.
    var onTotalNewCountChange: ((Int) -> Void)?

    /// The last count each surface published, so the total can be re-summed
    /// without asking every surface to re-derive its own.
    private var newCountsByCategory: [MessagesCategory: Int] = [:]

    /// Global search across every category, or `nil` in a composition without
    /// it (the surfaces still page, and no search field appears).
    ///
    /// It belongs to the container for the same reason the bar items do: a
    /// paged child has no navigation bar, so the only `navigationItem` on
    /// screen is this one. Scoping the query to a page would be the wrong
    /// answer anyway — see `InboxSearchViewModel`.
    private let searchResults: InboxSearchResultsViewController?

    init(
        surfaces: [any InboxSurface],
        searchResults: InboxSearchResultsViewController? = nil,
        initialCategory: MessagesCategory = .all
    ) {
        precondition(!surfaces.isEmpty, "The inbox needs at least one surface")
        self.surfaces = surfaces
        self.searchResults = searchResults
        categoryBar = PagedTabBar(
            titles: surfaces.map(\.category.title), style: .navigationTitle
        )
        selector = BarSelectorItem(strip: categoryBar, id: Self.selectorItemID)
        initialIndex = surfaces.firstIndex { $0.category == initialCategory } ?? 0
        super.init(nibName: nil, bundle: nil)
        // One colour for every unread mark (#1169, #2062: solid, never a
        // gradient): the tab bar's, the bell's and the rows' too.
        categoryBar.badgeTint = Palette.counter
    }

    private let initialIndex: Int
    /// A category asked for before the view existed; folded into where the
    /// pager starts rather than paged to.
    private var pendingCategory: MessagesCategory?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // ⚠️ NO TITLE. "Messages" sat here for a while (the tab bar says the
        // word already); it went on 2026-09-22 with the map tab's and For
        // You's. Nor does the bar name a section after the bell any more
        // (#1301, gone with the last headed section in #2328).
        navigationItem.largeTitleDisplayMode = .never
        // ⚠️ **AND THE CHEVRON KEEPS ITS SILENCE.** A titled root gives every
        // screen pushed from it a WORDED back button, and two pushed bars were
        // budgeted against a bare 44pt chevron: `SearchResultsViewController`
        // says in as many words that its field would then be "44pt too
        // generous", and the chat thread's identity view is capped at 240pt on
        // the same assumption — 32 margins + 44 chevron + 24 gap + 8 padding +
        // 240 = 348 fits 375, while a "Messages" label (~98pt with its platter)
        // makes it ~402 and does not. `.minimal` keeps the title for this
        // screen and the chevron bare for the next one.
        navigationItem.backButtonDisplayMode = .minimal

        view.backgroundColor = .systemBackground
        if let searchResults {
            // A picked row takes the search UI down BEFORE the thread goes up.
            searchResults.onWillOpenResult = { [weak self] in
                // Opening something IS the signal — a query that led somewhere is
                // worth offering again, and it costs the viewer nothing to say so.
                self?.searchResults?.rememberQuery(self?.searchController?.searchBar.text ?? "")
                self?.dismissSearch()
            }
            // Tapping a history row re-runs it, so the field has to show what is
            // now being searched for.
            searchResults.onReplayQuery = { [weak self] text in
                self?.searchController?.searchBar.text = text
            }
        }
        configureSearchAffordance()
        // ⚠️ Loaded NOW, not on the first tap. This controller builds a
        // compositional layout, four cell registrations and a diffable source in
        // `viewDidLoad`, and doing that as the field activates is a pause between
        // the tap and the results. Loading the view is all it takes; it stays out
        // of the hierarchy until search opens.
        searchResults?.loadViewIfNeeded()

        // ⚠️ THE CHILDREN ARE ADDED HERE, THEIR VIEWS ARE NOT LOADED. This used
        // to `loadViewIfNeeded()` every surface so each could publish its
        // chrome — the All tab's unread count, the Requests badge — before it
        // had been paged to. The chrome no longer needs a view: a surface
        // publishes it from its init, off the view model, so the header is
        // right at frame 0 and only the starting page's view is built in the
        // turn that shows this screen (charter P3). The pager makes the others
        // as a swipe or a tab reaches them.
        for surface in surfaces {
            addChild(surface)
        }
        // A route that arrived before this point decides the starting page.
        let startIndex = pendingCategory
            .flatMap { category in surfaces.firstIndex { $0.category == category } } ?? initialIndex
        pendingCategory = nil
        pagerView = HorizontalPagerView(lazyPages: surfaces.map { surface in { surface.view } }, initialIndex: startIndex)
        pagerView.pin(to: view)
        // The notifications drawer is "page −1": pulled past Chats with the
        // tabs' own gesture, from the very edge (a root has no back swipe) (#1739).
        pagerView.leadingPullTarget = DrawerPull.shared
        pagerView.reservesLeadingEdge = false
        // ⚠️ AFTER the pager, every time. `configureSearch` runs first and adds the
        // search host, so the pager lands on top of it — the bar was mounted,
        // inset for, and completely invisible behind an opaque page.

        for surface in surfaces { surface.didMove(toParent: self) }

        // ⚠️ **THE STRIP IS BACK IN THIS BAR (#2337), AND NO BAND AT THE
        // FOOT.** No `SelectorAccessory`, nothing installed on appear or
        // removed on disappear, no minimize to arm or reconcile: the strip is
        // a bar item, which UIKit keeps per navigation item, so it cannot
        // float over a pushed thread or another tab. The width arithmetic the
        // accessory made unnecessary is back with it — the bar sweeps a group
        // it cannot fit into a `•••` — and lives in `BarSelectorItem`.

        // NO `additionalSafeAreaInsets`: the pages inset under the header
        // through the standard safe area.

        // Wired like any system control: the bar carries the chosen segment as
        // its value and announces it, rather than handing back a closure.
        categoryBar.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                // The page is shown DIRECTLY (`PagedTabBar.PagerMode.instant`,
                // #1748): the lens flies there on its own and the pager's
                // report of the new page lands exactly where it is going.
                self.select(index: self.categoryBar.selectedIndex, animated: self.categoryBar.animatesPageChanges)
            },
            for: .valueChanged
        )
        // Dragging the PILL is dragging the pages. The bar reports a fractional
        // page position for every frame of the finger and the pager is scrubbed
        // to it; the pager reports back through `onProgress`, so the same loop
        // that answers a content swipe answers this too and the lens needs no
        // separate path. The release hands over a velocity and the pager lands
        // itself, which is why nothing here has to know a drag happened.
        categoryBar.onScrub = { [weak self] progress in self?.pagerView.scrub(to: progress) }
        categoryBar.onScrubEnd = { [weak self] velocity in
            self?.pagerView.settleAfterScrub(velocityInPages: velocity)
        }
        pagerView.onProgress = { [weak self] progress in
            guard let self else { return }
            categoryBar.setProgress(progress)
        }
        pagerView.onSettled = { [weak self] index in self?.didSettle(on: index) }
        // The stacked field collapses into the bar as the page in front
        // scrolls. The pager is what knows which page that is, and it is what
        // says so. No `.bottom` scroller: the tab bar never collapses here,
        // as on For You (#758) — there is no band to dock (#2337).
        pagerView.onActiveScrollViewChanged = { [weak self] scroller in
            self?.setContentScrollView(scroller, for: .top)
        }


        for surface in surfaces {
            apply(surface.chrome, from: surface)
            surface.onChromeChange = { [weak self] chrome in self?.apply(chrome, from: surface) }
        }

        categoryBar.setProgress(CGFloat(pagerView.activeIndex))
    }

    /// The bar's width is known once the screen is laid out in it: the
    /// selector re-fits to the room the bell leaves (#2337).
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refitSelector()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refitSelector()
        pagerView?.reassertActivePage()
        if let surface = activeSurface { apply(surface.chrome, from: surface) }
        // Coming BACK to the inbox — a tab switch, a popped thread — wakes the
        // page in front, which is each page's refresh. The first appearance is
        // `viewDidAppear`'s (a deep link can land on a lazy page).
        //
        // ⚠️ This is a freshness path the pull-to-refresh used to cover. All
        // already reloaded on every appearance (its own `viewWillAppear`), but
        // Requests and Suggestions only refreshed when paged to — or pulled.
        if hasActivatedInitialSurface { activeSurface?.surfaceDidBecomeActive() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A tab root always shows the bar (#769) — search mode hides it on
        // purpose.
        if !isSearching {
            ensureAppTabBarAsTabRoot(stillWanted: { [weak self] in self?.isSearching == false })
        }
        // The pager's horizontal pan yields to the stack's edge-swipe pop, so
        // a back gesture is never stolen by a page change. Wired once the view
        // is in a window — the recognizer doesn't exist before then.
        if !didSubordinatePagerToPop, let pop = navigationController?.interactivePopGestureRecognizer {
            didSubordinatePagerToPop = true
            pagerView.horizontalPan.require(toFail: pop)
        }
        // The initial page still needs waking (a deep link can land straight
        // on a lazy surface); later pages wake on settle.
        if !hasActivatedInitialSurface {
            hasActivatedInitialSurface = true
            activeSurface?.surfaceDidBecomeActive()
        }
        #if DEBUG
        // One-shot. Activating the search controller presents over this screen
        // and lands a SECOND `viewDidAppear` here when it is dismissed; without
        // the latch every step below re-arms and fires twice.
        guard !hasRunDebugSequence else { return }
        hasRunDebugSequence = true
        let arguments = ProcessInfo.processInfo.arguments

        // `-inbox-page-to <category>` animates to another tab ~2s in, through
        // the SAME path a segment tap takes (`setActivePage(animated:)`, which
        // reports fractional progress every frame). Taps can't be injected
        // headlessly, and this is the transition worth recording.
        if let index = arguments.firstIndex(of: "-inbox-page-to"),
           let name = arguments.dropFirst(index + 1).first,
           let category = MessagesCategory(rawValue: name),
           let target = surfaces.firstIndex(where: { $0.category == category }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.select(index: target, animated: true)
            }
        }
        // `-inbox-search-open`: the same, on the inbox.
        if arguments.contains("-inbox-search-open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.presentSearch()
            }
        }
        runSearchDebugSequence(arguments)

        // `-tabbar-shape-watch` samples the capsule's shape twice a second and
        // prints it. The shape's two halves fail SEPARATELY — clipping switched
        // off leaves the radius reading correct while the bar draws as a
        // rectangle — so a screenshot cannot tell you which one broke, and the
        // context menu's lift is the thing that breaks one of them.
        if arguments.contains("-tabbar-shape-watch") {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                let shape = categoryBar.debugCapsuleShape
                print(String(
                    format: "[capsule] radius=%.1f height=%.1f effect=%@ clips=%@",
                    shape.radius, shape.height,
                    shape.hasEffect ? "yes" : "NO", shape.clips ? "yes" : "NO"
                ))
            }
        }
        #endif
    }

    #if DEBUG
    /// `-inbox-search-query <text>` opens search and seeds the field, and
    /// `-inbox-search-cancel` collapses it again two seconds later.
    ///
    /// Driven through `isActive` plus the real updater rather than by poking the
    /// view model, so it exercises the same path a tap on the field takes —
    /// the presentation over the pager, the covered category bar, and the
    /// sectioned results are the whole point of the seam and all three are
    /// unreachable from a view-model call. The simulator's keyboard is not
    /// scriptable, so this is the only way to reach the results layout headlessly.
    private func runSearchDebugSequence(_ arguments: [String]) {
        guard let index = arguments.firstIndex(of: "-inbox-search-query"),
              let text = arguments.dropFirst(index + 1).first, !text.hasPrefix("-")
        else { return }
        // Drives the same path a tap on the field does: present, type, filter.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            // Requirement checks, both invisible in a screenshot: the results
            // must already be built before the first tap, and the field must be
            // focused as the crossfade lands rather than after it.
            print("[inbox-search] prewarmed=\(self.searchResults?.isViewLoaded == true)")
            self.presentSearch()
            self.searchController?.searchBar.text = text
            self.searchResults?.applyQuery(text)
            // Submitting is what a viewer does with a query worth keeping, and it
            // is the path that writes the history — so the QA sequence takes it,
            // or the history it exercises is never written.
            self.searchResults?.rememberQuery(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let results = self.searchResults else { return }
                let lists = results.view.subviews.compactMap { $0 as? UICollectionView }
                let rows = lists.first.map { list in
                    (0..<list.numberOfSections).map { list.numberOfItems(inSection: $0) }
                } ?? []
                // One literal over typed locals: Xcode 26 times out type-checking
                // a `+` chain with `==`/`??` inside its interpolations.
                let searching: Bool = self.isSearching
                let focused: Bool = self.searchController?.searchBar.searchTextField.isFirstResponder ?? false
                let onScreen: Bool = results.view.window != nil
                let typed: String = self.searchController?.searchBar.text ?? "-"
                print("[inbox-search] searching=\(searching) focused=\(focused) resultsOnScreen=\(onScreen) sections=\(rows) text=\(typed)")
            }
            guard arguments.contains("-inbox-search-cancel") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.dismissSearch()
            }
        }
    }
    #endif

    // MARK: - Search

    /// THE SYSTEM'S SEARCH (#1679, the owner 2026-10-24): a `UISearchController`,
    /// its results presented over the inbox.
    ///
    /// ⚠️ **STACKED UNDER THE BAR, NOT A BUTTON IN IT (#1901, the owner
    /// 2026-10-30).** It rested as a magnifier (`.integratedButton`) whose
    /// close kept the field at nearly its open width as it slid back, then
    /// shrank at the very end: a wide empty capsule across the bar at every
    /// close, filmed on the owner's device. A long bench ruled out the
    /// placeholder, the magnifier's place, the bar's items, the tab bar and
    /// the band; UIKit's collapse could not be tamed with public API, and the
    /// ✕ of an integrated search calls no delegate before it plays. The
    /// stacked field never collapses into a button: it rests under the bar
    /// with its placeholder, collapses into the bar as the list scrolls
    /// (`hidesSearchBarWhenScrolling`, on the page in front, see
    /// `onActiveScrollViewChanged`), and wears UIKit's own Cancel. The pull
    /// that opened search went with the magnifier: the pages' pull refreshes
    /// again (`AppRefreshControl`).
    ///
    /// Nil in a composition without results: no search field then.
    private lazy var searchController: UISearchController? = searchResults.map { results in
        let controller = UISearchController(searchResultsController: results)
        controller.searchResultsUpdater = self
        controller.delegate = self
        controller.obscuresBackgroundDuringPresentation = false
        let bar = controller.searchBar
        bar.delegate = self
        bar.placeholder = Self.searchPlaceholder
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.returnKeyType = .search
        return controller
    }

    /// What the empty field says it searches (#918). It names the two things
    /// the search actually finds — conversations and requests matched on the
    /// correspondent's name or handle, and people from the directory — and
    /// deliberately not "messages": message TEXT is not searched (only the
    /// last message of each thread is in memory; see `InboxSearchViewModel`).
    static let searchPlaceholder = "Search people and chats"

    /// What the field says, while it exists. Tests.
    var searchPlaceholderShown: String? { searchController?.searchBar.placeholder }

    /// From the search's `willPresent` to its `willDismiss`.
    private var isSearching = false

    private func configureSearchAffordance() {
        if let searchController {
            // The results cover the inbox, not the tab bar controller.
            definesPresentationContext = true
            navigationItem.searchController = searchController
            navigationItem.preferredSearchBarPlacement = .stacked
            navigationItem.hidesSearchBarWhenScrolling = true
        }
        applyRestingBar()
    }

    /// The shell's items: the notifications bell at the head of the leading
    /// group, the selector right after it. The trailing slot is the
    /// protocol's, and the shell hands nothing into it since #2336 (no
    /// balance in Messages); it reserves no room while empty, and an item
    /// that did come would be charged to the selector's room
    /// (`selectorBudget`).
    private var leadingAccessoryItem: UIBarButtonItem?
    private var trailingAccessoryItem: UIBarButtonItem?

    /// Installs (or clears) the bell.
    func setLeadingAccessoryItem(_ item: UIBarButtonItem?) {
        leadingAccessoryItem = item
        guard isViewLoaded else { return }
        applyRestingBar()
    }

    /// Installs (or replaces, or clears) a trailing item. The shell installs
    /// none (#2336): the balance left Messages.
    func setTrailingAccessoryItem(_ item: UIBarButtonItem?) {
        trailingAccessoryItem = item
        guard isViewLoaded else { return }
        applyRestingBar()
    }

    /// `[ bell ][ Chats 43 | Requests 6 | Suggestions ]———————`
    /// `[ search people and chats                       ]`
    ///
    /// What the shell hands in: the bell leading, nothing trailing (#2336: no
    /// balance in Messages). The selector follows the bell in a platter of
    /// its own (#2337), as For You's Feed | Shots does; the search is not
    /// among the items: it is stacked under the bar (`searchController`), at
    /// rest and open alike. No section is named after the bell any more
    /// (#2328).
    ///
    /// ⚠️ NEVER `searchBarPlacementBarButtonItem` IN THE NAVIGATION BAR: iOS 26
    /// throws ("only supported in UIToolbar") — iOS 27 accepts it, which is
    /// how it shipped in #1689's first push and crashed CI's iOS 26 hosts.
    private func applyRestingBar() {
        setOwnTrailingBarItems([trailingAccessoryItem].compactMap { $0 }, animated: false)
        // A back chevron (none on the tab root) would keep its place before
        // the group.
        navigationItem.leftItemsSupplementBackButton = true
        selector.fit(selectorBudget)
        applyLeadingGroup()
    }

    /// `[bell][selector]`, or the selector alone without a bell.
    private func applyLeadingGroup() {
        let leading = selector.leadingGroup(after: leadingAccessoryItem)
        // An identical group is not handed back: re-setting the same items
        // rebuilds their glass.
        guard !(navigationItem.leftBarButtonItems ?? []).elementsEqual(leading, by: ===) else { return }
        navigationItem.setLeftBarButtonItems(leading, animated: false)
    }

    /// Re-fits the selector to the room it has — a new bar width, a count
    /// that widened a segment — and, when the width it states moved, asks the
    /// bar to lay out again. The item stays the same: no group is rewritten
    /// (`BarSelectorItem`'s note on why it is never re-minted).
    private func refitSelector() {
        guard isViewLoaded, selector.fit(selectorBudget) else { return }
        navigationController?.navigationBar.setNeedsLayout()
    }

    /// The room the bar leaves the selector: the bell before it, whatever
    /// trails (nothing today, #2336). Nothing can come into the trailing
    /// corner on this screen (no editing, no batch action, no Cancel of its
    /// own — the search's Cancel is in the stacked field, under the bar).
    private var selectorBudget: BarSelectorBudget {
        let navigationBarWidth = navigationController?.navigationBar.bounds.width ?? 0
        let barWidth = navigationBarWidth > 1 ? navigationBarWidth : (view.window?.bounds.width ?? view.bounds.width)
        return BarSelectorBudget(
            barWidth: barWidth,
            leadingWidths: leadingAccessoryItem.map { [BarSelectorBudget.width(of: $0)] } ?? [],
            trailingWidths: [trailingAccessoryItem].compactMap { $0 }.map(BarSelectorBudget.width(of:))
        )
    }

    #if DEBUG
    /// The pager coming to rest on `index`, as a swipe that ended there.
    func debugSettle(on index: Int) { didSettle(on: index) }
    /// The selector in the bar (#2337). Tests.
    var debugSelector: PagedTabBar { categoryBar }
    /// The page in front. Tests.
    var debugActiveIndex: Int { pagerView?.activeIndex ?? initialIndex }
    /// The pages, in order (#2215). Tests.
    var debugCategories: [MessagesCategory] { surfaces.map(\.category) }
    #endif

    /// Opens search, focused — what `-inbox-search-query` drives.
    private func presentSearch() {
        guard let searchController, !searchController.isActive else { return }
        searchController.isActive = true
        // The field is in the bar once the activation has laid it out.
        DispatchQueue.main.async { searchController.searchBar.searchTextField.becomeFirstResponder() }
    }

    /// Closes search: the field rests under the bar again.
    private func dismissSearch() {
        searchController?.isActive = false
    }

    // MARK: - Category selection

    private var activeSurface: (any InboxSurface)? {
        let index = pagerView?.activeIndex ?? initialIndex
        return surfaces.indices.contains(index) ? surfaces[index] : surfaces.first
    }

    /// Pages to a category, from a header tap or an `AppRoute`.
    public func setCategory(_ category: MessagesCategory, animated: Bool) {
        guard let index = surfaces.firstIndex(where: { $0.category == category }) else { return }
        // A launch-time route (`-open-messages requests`, a push payload)
        // reaches this tab root BEFORE its view exists — there is no pager to
        // page yet, so the request becomes where the pager starts.
        guard isViewLoaded else {
            pendingCategory = category
            return
        }
        select(index: index, animated: animated)
    }

    private func select(index: Int, animated: Bool) {
        guard index != pagerView.activeIndex else { return }
        pagerView.setActivePage(index, animated: animated)
    }

    /// A pager settle: silent (#1881) — the tab bar's own drag ticks.
    private func didSettle(on index: Int) {
        categoryBar.setProgress(CGFloat(index))
        guard let surface = activeSurface else { return }
        // ⚠️ Paging between tabs does NOT resign anything. A badge is how the
        // header answers "what happened while I was away", and the tabs are
        // read against each other — switching to Requests to see what is there
        // and finding All's count gone is losing the comparison you switched
        // for. Only leaving the screen retires them; see `viewWillDisappear`.
        apply(surface.chrome, from: surface)
        // The shared bar follows whichever page is now in front, and the new page
        // gets the same clearance. Re-syncing here is what keeps a bar collapsed
        // on one tab from sitting half-open over another.
        surface.surfaceDidBecomeActive()
    }

    // MARK: - Chrome

    /// Applies one surface's published chrome: the count on its tab.
    ///
    /// It lands on the SEGMENT that published it, so it works whether or not
    /// that page is the one on screen. A page that wants to offer something
    /// offers it on its own tab.
    private func apply(_ chrome: InboxSurfaceChrome, from surface: any InboxSurface) {
        guard let index = surfaces.firstIndex(where: { $0.category == surface.category }) else { return }
        setBadge(chrome.badgeCount, at: index)
        newCountsByCategory[surface.category] = chrome.badgeCount
        onTotalNewCountChange?(newCountsByCategory.values.reduce(0, +))
    }

    /// Stamps a count on a segment and re-settles the navigation bar around it.
    ///
    /// ⚠️ A badge changes the capsule's WIDTH, and with it what fits: the
    /// selector is re-fitted (15pt or 13pt, its ceiling) and the bar told to
    /// lay out again when the stated width moved (`BarSelectorItem`).
    private func setBadge(_ count: Int, at index: Int) {
        categoryBar.setBadge(count, at: index)
        refitSelector()
    }

}

// MARK: - Search

extension MessagesInboxViewController: UISearchResultsUpdating, UISearchControllerDelegate, UISearchBarDelegate {
    func updateSearchResults(for searchController: UISearchController) {
        searchResults?.applyQuery(searchController.searchBar.text ?? "")
    }

    /// Searching is a mode, not a place: the tab bar is a way OUT of it that
    /// would take the query with it, and the results deserve the height. The
    /// selector goes with the bar (`hidesNavigationBarDuringPresentation`,
    /// unchanged): no band at the foot to take down any more (#2337).
    func willPresentSearchController(_ searchController: UISearchController) {
        isSearching = true
        searchResults?.applyQuery("")
        tabBarController?.setTabBarHidden(true, animated: true)
    }

    /// The results show from the first frame — recent searches before a
    /// letter is typed.
    func didPresentSearchController(_ searchController: UISearchController) {
        searchController.showsSearchResultsController = true
    }

    /// The tab bar comes back as search closes.
    func willDismissSearchController(_ searchController: UISearchController) {
        isSearching = false
        tabBarController?.setTabBarHidden(false, animated: true)
    }

    /// Submitting is the clearest signal that a query mattered.
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchResults?.rememberQuery(searchBar.text ?? "")
        searchBar.searchTextField.resignFirstResponder()
    }
}

// MARK: - Tab re-tap (#1309)

extension MessagesInboxViewController: TabReselectScrolling {
    /// The page in front back to its first row, under the header.
    func scrollToTopForTabReselect() {
        guard let list = activeSurface?.listScrollView else { return }
        Self.scrollToTop(list, animated: true)
    }

    /// A list back to its first row, under whatever it is inset by. Never
    /// downwards: a list pulled past its top is already there.
    static func scrollToTop(_ list: UIScrollView, animated: Bool) {
        let top = -list.adjustedContentInset.top
        guard list.contentOffset.y > top + 0.5 else { return }
        list.setContentOffset(CGPoint(x: list.contentOffset.x, y: top), animated: animated)
    }
}
