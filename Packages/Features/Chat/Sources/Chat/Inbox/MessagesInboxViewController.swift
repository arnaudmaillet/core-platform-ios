import ChatInterface
import CoreNavigation
import DesignSystem
import UIKit

/// The Messages tab's root: one navigation bar carrying the tab capsule as its
/// title, and a set of horizontally paged surfaces beneath it.
///
/// The container owns exactly three things — the pager, the tab capsule, and
/// the navigation bar's contents — and drives all of them from one signal, the
/// pager's fractional page position. It holds no inbox data and knows nothing
/// about how a page renders; every surface arrives as an `InboxSurface` and is
/// otherwise opaque.
///
/// **The capsule WAS the title, and is not any more.** It sat in
/// `navigationItem.titleView`; it is in a `UITabAccessory` at the foot of the
/// screen now, and the title slot carries the word "Messages". Either way this
/// screen reserves no safe area of its own — the navigation bar accounts for
/// its own height, UIKit accounts for the accessory's, and each page's list
/// insets itself through the standard safe area. Nothing floats over the
/// content, so there is no header geometry to maintain here.
///
/// **Badges are a fact about the session.** Nothing here retires one: not
/// paging between tabs, not pushing a thread, not leaving for another root tab.
/// A cold launch builds new view models and with them new watermarks, and that
/// is the only reset there is — see `InboxTabWatermark`.
///
/// **The bar is written once and never again.** The tab's name in the centre
/// and the search magnifier trailing — the selector moved to the accessory and
/// compose went with the leading group. Both belong to the inbox as a whole
/// rather than to any page, which was always the point: a page publishing its
/// own word up there would re-measure the bar on every tab change. What a page
/// contributes rides its own tab: a badge, and the menu its long press offers.
/// The one exception is search, which takes the title slot for its field —
/// a `titleView` outranks a `title`, so the name hides and returns by itself.
/// The shell adds two items of its own through `HeaderAccessoryHosting` — the
/// notifications bell leading and the balance beside the magnifier — which
/// are the app's rather than the inbox's, and so page with nothing either.
final class MessagesInboxViewController: UIViewController, MessagesInboxCategorySelecting,
    HeaderAccessoryHosting {
    /// The inbox's surfaces, in paging order.
    private let surfaces: [any InboxSurface]
    /// The shared glass tab capsule, hosted in the navigation bar's title slot.
    /// It takes titles and reports an index — the category is this container's
    /// vocabulary, not the bar's, so every call site maps one to the other
    /// through `surfaces`.
    private let categoryBar: PagedTabBar
    private let selectionFeedback = HapticSelection()

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
    /// it (the surfaces still page, and no magnifier appears).
    ///
    /// It belongs to the container for the same reason the bar items do: a
    /// paged child has no navigation bar, so the only `navigationItem` on
    /// screen is this one. Scoping the query to a page would be the wrong
    /// answer anyway — see `InboxSearchViewModel`.
    private let searchResults: InboxSearchResultsViewController?

    /// Pull-down-to-search, following whichever page is in front: pulling any
    /// page past a line and letting go opens search — see `InboxPullToSearch`.
    /// It replaced the pages' pull-to-refresh, and goes through
    /// `presentSearch`, the magnifier's own path, so the two entrances cannot
    /// drift apart. Exists only in a composition WITH search: a pull that
    /// armed and then did nothing would be a lie.
    private lazy var pullToSearch: InboxPullToSearch? = searchResults == nil ? nil : InboxPullToSearch()

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
        initialIndex = surfaces.firstIndex { $0.category == initialCategory } ?? 0
        super.init(nibName: nil, bundle: nil)
        // One colour for the solid unread marks (#1169): the tab bar's and
        // the bell's too. The rows' avatars wear the icon's gradient.
        categoryBar.badgeTint = Palette.counter
        // The selector's badges wear the conversation avatars' gradient (#1190).
        categoryBar.badgeGradient = Palette.accentGradient
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
        // You's. The section the list has scrolled into ("New", "Recent") is
        // named in the bar, after the bell (#1301; first tried in #179 and
        // reverted in #181, when it had the leading group to itself).
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
        // `viewDidLoad`, and doing that inside the field's expansion is the pause between the
        // magnifier and the field. Loading the view is all it takes; it stays out
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
        // ⚠️ AFTER the pager, every time. `configureSearch` runs first and adds the
        // search host, so the pager lands on top of it — the bar was mounted,
        // inset for, and completely invisible behind an opaque page.

        for surface in surfaces { surface.didMove(toParent: self) }

        configurePullToSearch()

        // ⚠️ **The selector has the leading group to ITSELF; compose rides
        // trailing beside the magnifier.**
        //
        // Two leading items collapse on a narrow bar and one survives — the same
        // rule the profile hit, where moving its switcher trailing is what finally
        // hosted its selector. Measured here: with compose leading, 402pt hosts and
        // 375pt collapses the whole group into a `•••`; with compose trailing, both
        // host. Width is not the trigger, so a narrower selector does not help.
        // ⚠️ **THE STRIP IS NOT IN THIS BAR ANY MORE.** It lives at the foot of
        // the screen in a `UITabAccessory`, above the tab bar. Everything above
        // — the compose-item ordering, the width ceiling, the "install after
        // the search affordance" rule — was arithmetic against a navigation
        // bar that sweeps a group it cannot fit into a `•••`. An accessory has
        // no item groups and no overflow control, so the whole calculation is
        // gone rather than restated.
        selectorAccessory = SelectorAccessory(strip: categoryBar)

        // NO `additionalSafeAreaInsets`: the pages inset under the header
        // through the standard safe area, and UIKit owns the band at the foot.

        // Wired like any system control: the bar carries the chosen segment as
        // its value and announces it, rather than handing back a closure.
        categoryBar.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                // ONE animation drives both. The pager scrolls to the target
                // and reports fractional progress every frame; the lens
                // interpolates off that, so page and lens cannot disagree and
                // there is nothing to keep in sync. The bar runs no animation
                // of its own — a second one on the same frame would fight this.
                self.select(index: self.categoryBar.selectedIndex, animated: true)
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
            // Mid-page the two pages share the screen and neither list is
            // "the" list; a pull only counts on a settled page.
            isBetweenPages = abs(progress - progress.rounded()) > 0.01
            updatePullToSearchAvailability()
        }
        pagerView.onSettled = { [weak self] index in self?.didSettle(on: index) }
        // The band's minimize rides whichever page is in front. The pager is
        // what knows, and it is what says so — see `onActiveScrollViewChanged`.
        pagerView.onActiveScrollViewChanged = { [weak self] scroller in
            self?.setContentScrollView(scroller, for: .bottom)
            // The pull follows the same list the band's minimize does, for the
            // same reason: only the pager knows which page is in front.
            self?.pullToSearch?.attach(to: scroller)
        }


        for surface in surfaces {
            apply(surface.chrome, from: surface)
            surface.onChromeChange = { [weak self] chrome in self?.apply(chrome, from: surface) }
            // Only the page in front names its section; the others are read
            // again when they come in front (`didSettle`).
            surface.onPinnedSectionChange = { [weak self, weak surface] pinned in
                guard let self, let surface, surface === activeSurface else { return }
                applyPinnedSection(pinned)
            }
        }

        categoryBar.setProgress(CGFloat(pagerView.activeIndex))
    }

    /// Fires at the START of a pop — including the interactive one, before any
    /// frame is drawn — so what the transition reveals is already in agreement:
    /// the page shown and the lens over it.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // ⚠️ ABOVE ANY OTHER GUARD, and covering a push as well as a tab
        // switch: the accessory is shell-lifetime state, and this is the only
        // moment that reliably precedes something else owning the band.
        selectorAccessory?.remove(from: tabBarController, alongside: transitionCoordinator)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // ⚠️ **AS EARLY AS THE TRANSITION ALLOWS, AND `viewDidAppear` IS NOT
        // EARLY.** Measured on a tab switch, headless: `viewWillAppear` at
        // +36ms, `viewDidAppear` at +947ms — nine hundred milliseconds of empty
        // band under a screen already fully on display. The call below is
        // idempotent with the one in `viewDidAppear`, which stays as the
        // backstop for the paths the policy declines (a scrub that has not
        // committed, a flight that owns the chrome).
        installBottomChromeWhenAppearing(hasActiveFlight: false,
                                         handsOver: tabBarController?.bottomAccessory != nil) { [weak self] in
            guard let self else { return }
            selectorAccessory?.install(into: tabBarController, owner: self, minimizesOnScroll: true,
                                       alongside: transitionCoordinator)
        }

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
        // ⚠️ THE MINIMIZE NEEDS A SCROLLER NAMED, or arming it does nothing
        // here and gives every other tab a collapsing bar for free.
        selectorAccessory?.install(into: tabBarController, owner: self, minimizesOnScroll: true,
                                   alongside: transitionCoordinator)
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
        runPullToSearchDemo(arguments)
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
    /// view model, so it exercises the same path a tap on the magnifier takes —
    /// the presentation over the pager, the covered category bar, and the
    /// sectioned results are the whole point of the seam and all three are
    /// unreachable from a view-model call. The simulator's keyboard is not
    /// scriptable, so this is the only way to reach the results layout headlessly.
    private func runSearchDebugSequence(_ arguments: [String]) {
        guard let index = arguments.firstIndex(of: "-inbox-search-query"),
              let text = arguments.dropFirst(index + 1).first, !text.hasPrefix("-")
        else { return }
        // Drives the same path the magnifier does: present, type, filter.
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
                print("[inbox-search] searching=\(self.isSearching) "
                    + "focused=\(self.searchController?.searchBar.searchTextField.isFirstResponder == true) "
                    + "resultsOnScreen=\(results.view.window != nil) "
                    + "sections=\(rows) text=\(self.searchController?.searchBar.text ?? "-")")
            }
            guard arguments.contains("-inbox-search-cancel") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.dismissSearch()
            }
        }
    }
    #endif

    // MARK: - Search

    /// THE SYSTEM'S SEARCH (#1679, the owner 2026-10-24): a `UISearchController`
    /// whose bar rests as the magnifier and expands into the field in place —
    /// UIKit's own animation, its own Close — with the results presented over
    /// the inbox. It replaced a `UISearchTextField` swapped into the title slot
    /// under a hand-made cross-dissolve of the whole bar (R3).
    ///
    /// Nil in a composition without results: no magnifier then.
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

    /// The magnifier: the search bar's OWN item, placed by this screen so the
    /// balance stands inboard of it — a tap expands the field out of it.
    private var searchItem: UIBarButtonItem? {
        searchController == nil ? nil : navigationItem.searchBarPlacementBarButtonItem
    }

    /// What the empty field says it searches (#918). It names the two things
    /// the search actually finds — conversations and requests matched on the
    /// correspondent's name or handle, and people from the directory — and
    /// deliberately not "messages": message TEXT is not searched (only the
    /// last message of each thread is in memory; see `InboxSearchViewModel`).
    static let searchPlaceholder = "Search people and chats"

    /// What the field says, while it exists. Tests.
    var searchPlaceholderShown: String? { searchController?.searchBar.placeholder }

    /// The selector's item, kept so the bar can be put back exactly as it was.
    /// ⚠️ INSTALLED ON APPEAR, REMOVED ON DISAPPEAR, and that bracket is the
    /// whole reason it is safe. `bottomAccessory` is a property of the TAB BAR
    /// CONTROLLER with no per-tab scope: a band left up floats over whatever is
    /// pushed on top of this screen and over whichever tab is chosen next.
    private var selectorAccessory: SelectorAccessory?
    /// From the search's `willPresent` to its `willDismiss`.
    private var isSearching = false

    private func configureSearchAffordance() {
        if let searchController {
            // The results cover the inbox, not the tab bar controller.
            definesPresentationContext = true
            navigationItem.searchController = searchController
            navigationItem.preferredSearchBarPlacement = .integratedButton
            navigationItem.hidesSearchBarWhenScrolling = false
        }
        applyRestingBar()
    }

    /// The shell's items: the notifications bell at the head of the leading
    /// group, the balance inboard of the magnifier.
    private var leadingAccessoryItem: UIBarButtonItem?
    private var trailingAccessoryItem: UIBarButtonItem?

    /// Installs (or clears) the bell.
    func setLeadingAccessoryItem(_ item: UIBarButtonItem?) {
        leadingAccessoryItem = item
        guard isViewLoaded else { return }
        applyRestingBar()
    }

    /// Installs (or replaces, or clears) the balance.
    func setTrailingAccessoryItem(_ item: UIBarButtonItem?) {
        trailingAccessoryItem = item
        guard isViewLoaded else { return }
        applyRestingBar()
    }

    /// `[ bell ][ New · 8 ]——————————[ coins ][ search ]`
    ///
    /// The magnifier plus whatever the shell hands in: the bell leading, the
    /// balance inboard of the magnifier (`[0]` is the screen edge, so search
    /// keeps the corner — the Maps and For You arrangement) — and, after the
    /// bell, the section the page in front has scrolled into
    /// (`applyPinnedSection`, #1301). Written once: search no longer takes
    /// the bar over — the field grows out of the magnifier by itself.
    private func applyRestingBar() {
        setOwnTrailingBarItems([searchItem, trailingAccessoryItem].compactMap { $0 }, animated: false)
        // The leading group is the contract's: the bell, then the section.
        sectionBinding.leadingPrefix = [leadingAccessoryItem].compactMap { $0 }
        sectionBinding.placeNow()
    }

    // MARK: - The pinned section (#1301)

    /// Its name after the bell — the conversation's day item, exactly (#750,
    /// #755; the owner, 2026-10-17): a system-titled glass bubble in the bar's
    /// own type, interactive, one item per section and count so "New · 4"
    /// becoming "Recent · 18" is UIKit's Liquid Glass morph. Minted, placed
    /// once per turn and held past a push by the contract
    /// (`PinnedSectionBarBinding`, #1573); the bell is its `leadingPrefix`.
    ///
    /// ⚠️ ONLY THE LEADING GROUP. Toasts own the trailing one while they show
    /// (`NavigationBarToasts`, #1066); rewriting the whole resting bar on every
    /// change would put the magnifier back over a toast.
    private lazy var sectionBinding: PinnedSectionBarBinding = {
        let binding = PinnedSectionBarBinding(
            viewController: self, placement: .leading, scope: "inbox", countNoun: "unread"
        )
        // What tapping the header's pill did: that section's first row under
        // the bar.
        binding.onSelect = { [weak self] _ in self?.activeSurface?.scrollToPinnedSection() }
        return binding
    }()

    /// Names `section` after the bell, or takes the name away.
    private func applyPinnedSection(_ section: InboxPinnedSection?) {
        // The page in front scrolls to its own section on a tap, so the
        // index is the section's place in the inbox's two.
        sectionBinding.show(pinned: section.map { pinned in
            (pinned.section == .new ? 0 : 1, .init(id: pinned.title, title: pinned.title, count: pinned.count))
        })
    }

    #if DEBUG
    /// The bar's section item while it is shown — what a test reads.
    var debugSectionItem: UIBarButtonItem? {
        guard let sectionItem = sectionBinding.item,
              navigationItem.leftBarButtonItems?.contains(where: { $0 === sectionItem }) == true
        else { return nil }
        return sectionItem
    }

    /// What a tap on the section item does. Tests.
    func debugTapSectionItem() { activeSurface?.scrollToPinnedSection() }
    #endif

    /// Opens search — the magnifier's tap, a pull — focused.
    private func presentSearch() {
        guard let searchController, !searchController.isActive else { return }
        searchController.isActive = true
        // The field is in the bar once the activation has laid it out.
        DispatchQueue.main.async { searchController.searchBar.searchTextField.becomeFirstResponder() }
    }

    /// Closes search: the field folds back into the magnifier.
    private func dismissSearch() {
        searchController?.isActive = false
    }

    // MARK: - Pull to search

    /// Whether the pager is between two pages right now.
    private var isBetweenPages = false

    /// Places the capsule and points the gesture at `presentSearch`.
    ///
    /// The capsule is the CONTAINER's view, laid over the pager just under the
    /// bar: every page's pull reveals the same one, and it stays put while a
    /// page change slides the lists beneath it. It is added AFTER the pager so
    /// it draws above the lists; search results, added later still, cover it.
    private func configurePullToSearch() {
        guard let pullToSearch else { return }
        let indicator = pullToSearch.indicator
        indicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicator.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        ])
        // The magnifier's own path — the field out of the magnifier, the
        // hidden tab bar, the focus — so a pull and a tap cannot open two
        // different searches.
        pullToSearch.onTrigger = { [weak self] in self?.presentSearch() }
    }

    private func updatePullToSearchAvailability() {
        pullToSearch?.isEnabled = !isSearching && !isBetweenPages
    }

    #if DEBUG
    /// `-messages-pull-demo [short|peek|hold|sweep]` drives the pull the way a
    /// finger would — the active list's offset, frame by frame, with the
    /// gesture marked as tracking — and then lets go, through the same release
    /// path a lifted finger takes. The simulator injects no pans, so this is
    /// the only headless way to see the capsule arrive, arm and open search.
    ///
    /// - default: pulls past the line and releases → search must open.
    /// - `short`: stops short of the line and releases → nothing must open.
    /// - `peek`: stops short of the line and STAYS there (for a screenshot of
    ///   the in-between capsule, its meter part-filled); nothing is released.
    /// - `hold`: pulls past the line and STAYS there (for a screenshot of the
    ///   armed capsule); nothing is released.
    /// - `sweep`: slowly past the line, back above it (past the hysteresis),
    ///   past it again, then releases → search must open. For a screen
    ///   recording of the arming AND the disarming motion, both directions.
    ///
    /// Waits for a settled, on-screen, populated list rather than a clock, and
    /// prints `[qa] GAVE UP` if that never comes.
    private func runPullToSearchDemo(_ arguments: [String]) {
        guard let index = arguments.firstIndex(of: "-messages-pull-demo") else { return }
        let mode = arguments.dropFirst(index + 1).first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "full"
        let label = "-messages-pull-demo \(mode)"
        QAWait.until(label, { [weak self] in
            guard let self, let pull = pullToSearch, let list = pull.debugScrollView else { return self == nil }
            return view.window != nil && !isSearching && !isBetweenPages
                && transitionCoordinator == nil && !list.isHidden && list.window != nil
                && list.contentSize.height > 0
        }) { [weak self] in
            guard let self, let pull = pullToSearch else { return }
            if let list = pull.debugScrollView {
                print("[pull-search] before: offsetY=\(Int(list.contentOffset.y)) "
                    + "restY=\(Int(-list.adjustedContentInset.top))")
            }
            let line = InboxPullToSearch.threshold
            let short = mode == "short" || mode == "peek"
            let target = short ? line * 0.6 : line + 24
            // Each leg reports what the capsule shows once it lands, so a run
            // is judged on the arming state, not on a screenshot alone.
            let report: @MainActor (String) -> Void = { [weak self] leg in
                guard let pull = self?.pullToSearch else { return }
                print("[pull-search] \(leg): pulled=\(Int(pull.pullDistance)) armed=\(pull.isArmed) "
                    + "ring=\(String(format: "%.2f", pull.indicator.debugRingProgress)) "
                    + "label=\(pull.indicator.debugLabelText ?? "-")")
            }
            // `sweep` goes out, back and out again before the common release;
            // every other mode goes straight out.
            let legs: [(name: String, distance: CGFloat, duration: TimeInterval)] = mode == "sweep"
                ? [("out", line + 24, 1.2), ("back", line * 0.55, 1.2), ("again", line + 24, 1.2)]
                : [("pulled", target, 0.6)]
            @MainActor func run(_ index: Int, then finish: @escaping @MainActor () -> Void) {
                guard index < legs.count, let pull = pullToSearch else { return finish() }
                let leg = legs[index]
                pull.debugPull(to: leg.distance, duration: leg.duration) {
                    report(leg.name)
                    run(index + 1, then: finish)
                }
            }
            run(0) { [weak self] in
                guard let self, let pull = pullToSearch else { return }
                guard mode != "hold", mode != "peek" else { return }
                pull.debugRelease()
                if mode == "short" {
                    // Nothing may open — an absence, which no wait can detect,
                    // so the verdict is read once the bounce-back is over.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        let list = self?.pullToSearch?.debugScrollView
                        // The list must also be back at REST, not left hanging
                        // where the pull let go of it.
                        print("[pull-search] short pull: searching=\(self?.isSearching == true) "
                            + "offsetY=\(list.map { Int($0.contentOffset.y) } ?? 0) "
                            + "restY=\(list.map { Int(-$0.adjustedContentInset.top) } ?? 0)")
                    }
                } else {
                    QAWait.until("\(label): search opening", timeout: 3, { [weak self] in
                        self?.isSearching ?? true
                    }) { [weak self] in
                        print("[pull-search] searching=\(self?.isSearching == true)")
                    }
                }
            }
        }
    }
    #endif

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

    private func didSettle(on index: Int) {
        selectionFeedback.selectionChanged()
        categoryBar.setProgress(CGFloat(index))
        guard let surface = activeSurface else { return }
        // ⚠️ Paging between tabs does NOT resign anything. A badge is how the
        // header answers "what happened while I was away", and the tabs are
        // read against each other — switching to Requests to see what is there
        // and finding All's count gone is losing the comparison you switched
        // for. Only leaving the screen retires them; see `viewWillDisappear`.
        apply(surface.chrome, from: surface)
        // The bar names the section of the page now in front, or none.
        applyPinnedSection(surface.pinnedSection)
        // The shared bar follows whichever page is now in front, and the new page
        // gets the same clearance. Re-syncing here is what keeps a bar collapsed
        // on one tab from sitting half-open over another.
        surface.surfaceDidBecomeActive()
    }

    // MARK: - Chrome

    /// Applies one surface's published chrome: the count on its tab.
    ///
    /// It lands on the SEGMENT that published it, so it works whether or not
    /// that page is the one on screen — and it does not touch the navigation
    /// bar. The bar is written once, in `viewDidLoad`, and never again: its two
    /// glyphs belong to the inbox rather than to any page, which is what keeps
    /// the capsule between them one width instead of four. A page that wants to
    /// offer something offers it on its own tab.
    private func apply(_ chrome: InboxSurfaceChrome, from surface: any InboxSurface) {
        guard let index = surfaces.firstIndex(where: { $0.category == surface.category }) else { return }
        setBadge(chrome.badgeCount, at: index)
        newCountsByCategory[surface.category] = chrome.badgeCount
        onTotalNewCountChange?(newCountsByCategory.values.reduce(0, +))
    }

    /// Stamps a count on a segment and re-settles the navigation bar around it.
    ///
    /// ⚠️ A badge changes the capsule's WIDTH, and a navigation bar caches the
    /// size of its title view — the capsule's own `invalidateIntrinsicContentSize`
    /// is not enough, and frame and content drift apart the moment a count
    /// appears or clears (`ForYouViewController.applyBadges` documents the
    /// measured symptom). This has no equivalent in the floating arrangement
    /// this screen used to wear, where the bar's width was the screen's and
    /// nothing had to be told about it.
    private func setBadge(_ count: Int, at index: Int) {
        categoryBar.setBadge(count, at: index)
        // ⚠️ TOLD, NOT FORCED. The paragraph above records what the forcing was
        // for — a navigation bar caches its title view's size, so a badge that
        // changed the capsule's width left the frame and the content
        // disagreeing. An accessory sizes by constraint.
        selectorAccessory?.contentWidthDidChange()
    }

}

// MARK: - Search

extension MessagesInboxViewController: UISearchResultsUpdating, UISearchControllerDelegate, UISearchBarDelegate {
    func updateSearchResults(for searchController: UISearchController) {
        searchResults?.applyQuery(searchController.searchBar.text ?? "")
    }

    /// Searching is a mode, not a place: the tab bar is a way OUT of it that
    /// would take the query with it, and the results deserve the height.
    ///
    /// ⚠️ **AND THE ACCESSORY GOES WITH IT — IT DOES NOT FOLLOW ON ITS OWN.**
    /// The tab bar is hidden here with no transition of this screen, so
    /// `viewWillDisappear` never runs and the bracket that takes the band down
    /// never fires: left up, UIKit re-lays it out at the foot of the tab bar
    /// controller's view — over the results (`.regular`'s documented
    /// behaviour).
    func willPresentSearchController(_ searchController: UISearchController) {
        isSearching = true
        updatePullToSearchAvailability()
        searchResults?.applyQuery("")
        selectorAccessory?.remove(from: tabBarController)
        tabBarController?.setTabBarHidden(true, animated: true)
    }

    /// The results show from the first frame — recent searches before a
    /// letter is typed.
    func didPresentSearchController(_ searchController: UISearchController) {
        searchController.showsSearchResultsController = true
    }

    /// The band comes back with the bar it left with. `minimizesOnScroll` is
    /// re-armed for the same reason it is armed on appearing.
    func willDismissSearchController(_ searchController: UISearchController) {
        isSearching = false
        updatePullToSearchAvailability()
        tabBarController?.setTabBarHidden(false, animated: true)
        selectorAccessory?.install(into: tabBarController, owner: self, minimizesOnScroll: true)
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
