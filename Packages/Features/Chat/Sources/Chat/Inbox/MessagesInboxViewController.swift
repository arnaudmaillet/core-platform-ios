import ChatInterface
import CoreNavigation
import UIKit

/// The Messages tab's root: a fixed navigation bar over a glass category
/// header over a set of horizontally paged surfaces.
///
/// The container owns exactly three things — the pager, the header, and the
/// navigation bar's contents — and drives all of them from one signal, the
/// pager's fractional page position. It holds no inbox data and knows nothing
/// about how a page renders; every surface arrives as an `InboxSurface` and is
/// otherwise opaque.
///
/// Layout: the pager fills the whole view and the header floats above it, with
/// `additionalSafeAreaInsets.top` reserving the header's height. Each page's
/// list therefore insets itself below the header through the standard safe
/// area — content scrolls *under* the glass rather than starting after it, and
/// no page needs a single line of header-aware layout code.
final class MessagesInboxViewController: UIViewController, MessagesInboxCategorySelecting {
    /// The inbox's surfaces, in paging order.
    private let surfaces: [any InboxSurface]
    private let categoryBar: InboxCategoryBar
    private let selectionFeedback = UISelectionFeedbackGenerator()

    /// Built in `viewDidLoad`, once the surfaces are children — reading a
    /// child's `view` before containment would load it outside its parent.
    private var pagerView: InboxPagerView!
    private var didSubordinatePagerToPop = false
    private var hasActivatedInitialSurface = false
    #if DEBUG
    /// Latches the launch-argument QA sequence to one run per screen.
    private var hasRunDebugSequence = false
    #endif
    /// Whose chrome the navigation bar is currently showing.
    ///
    /// This tracks the pager's DOMINANT page — the one a drag is more than
    /// half way onto — rather than the settled page. Bar items therefore hand
    /// over mid-drag, at the same moment the header's lens passes the halfway
    /// mark, instead of snapping into place after the page lands.
    private var barOwner: MessagesCategory?

    private lazy var categoryBarTop = categoryBar.topAnchor.constraint(equalTo: view.topAnchor)

    /// Compose belongs to the inbox, not to a page: it starts a new message
    /// regardless of which surface is showing, and rides the same route seam
    /// as row selection so the contact-selection flow lands resolver-side.
    private lazy var composeItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "square.and.pencil"),
            primaryAction: UIAction { [weak self] _ in self?.onCompose?() }
        )
        item.accessibilityLabel = "New Message"
        return item
    }()

    /// Wired by the feature builder to the router, so this view controller
    /// never navigates.
    var onCompose: (() -> Void)?

    /// Global search across every category, or `nil` in a composition without
    /// it (the surfaces still page, and no magnifier appears).
    ///
    /// It belongs to the container for the same reason the bar items do: a
    /// paged child has no navigation bar, so the only `navigationItem` on
    /// screen is this one. Scoping the query to a page would be the wrong
    /// answer anyway — see `InboxSearchViewModel`.
    private let searchResults: InboxSearchResultsViewController?
    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: searchResults)
        controller.searchResultsUpdater = searchResults
        return controller
    }()

    init(
        surfaces: [any InboxSurface],
        searchResults: InboxSearchResultsViewController? = nil,
        initialCategory: MessagesCategory = .all
    ) {
        precondition(!surfaces.isEmpty, "The inbox needs at least one surface")
        self.surfaces = surfaces
        self.searchResults = searchResults
        categoryBar = InboxCategoryBar(categories: surfaces.map(\.category))
        initialIndex = surfaces.firstIndex { $0.category == initialCategory } ?? 0
        super.init(nibName: nil, bundle: nil)
    }

    private let initialIndex: Int
    /// A category asked for before the view existed; folded into where the
    /// pager starts rather than paged to.
    private var pendingCategory: MessagesCategory?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Messages"
        view.backgroundColor = .systemBackground
        configureSearch()

        // Loaded up front, not lazily: a surface has to be able to publish its
        // chrome — the All tab's unread count, the Requests badge — before it
        // has ever been paged to, or the header would start out blank.
        for surface in surfaces {
            addChild(surface)
            surface.loadViewIfNeeded()
        }
        // A route that arrived before this point decides the starting page.
        let startIndex = pendingCategory
            .flatMap { category in surfaces.firstIndex { $0.category == category } } ?? initialIndex
        pendingCategory = nil
        pagerView = InboxPagerView(pages: surfaces.map(\.view), initialIndex: startIndex)
        pagerView.pin(to: view)
        for surface in surfaces { surface.didMove(toParent: self) }

        // The header's height is reserved as safe area, so every page's list
        // insets under it automatically.
        additionalSafeAreaInsets.top = InboxCategoryBar.height
        view.addSubview(categoryBar)
        categoryBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            categoryBarTop,
            categoryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            categoryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            categoryBar.heightAnchor.constraint(equalToConstant: InboxCategoryBar.height)
        ])

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
        // Dragging the header IS dragging the pages. The bar reports a
        // fractional page position and the pager is scrubbed to it, so the same
        // `onProgress` loop that answers a content swipe answers this too — the
        // lens and the bar items need no separate path.
        categoryBar.onScrub = { [weak self] progress in self?.pagerView.scrub(to: progress) }
        categoryBar.onScrubEnd = { [weak self] velocity in
            self?.pagerView.settleAfterScrub(velocityInPages: velocity)
        }
        pagerView.onProgress = { [weak self] progress in
            self?.categoryBar.setProgress(progress)
            self?.updateBarOwner(forProgress: progress)
        }
        pagerView.onSettled = { [weak self] index in self?.didSettle(on: index) }

        barOwner = surfaces[pagerView.activeIndex].category
        for surface in surfaces {
            apply(surface.chrome, from: surface)
            surface.onChromeChange = { [weak self] chrome in self?.apply(chrome, from: surface) }
        }

        categoryBar.setProgress(CGFloat(pagerView.activeIndex))
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // `view.safeAreaInsets.top` already contains the header height added
        // above; removing it again lands the bar exactly on the navigation
        // bar's bottom edge, whatever chrome is present.
        categoryBarTop.constant = view.safeAreaInsets.top - additionalSafeAreaInsets.top
    }

    /// Fires at the START of a pop — including the interactive one, before any
    /// frame is drawn — so everything the transition reveals is already in
    /// agreement: the page shown, the lens over it, and the bar items above.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Claim ownership BEFORE re-asserting: that republishes progress, and
        // an owner change there would crossfade the bar in the middle of the
        // pop — motion the transition is already providing.
        barOwner = activeSurface?.category
        pagerView?.reassertActivePage()
        if let surface = activeSurface { apply(surface.chrome, from: surface) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        runSearchDebugSequence(arguments)

        // `-inbox-edit` puts the active surface into multi-selection editing ~2s
        // in, through the surface's own `setEditing` — the same path its Edit
        // item takes. Bar items can't be tapped headlessly, and this is the one
        // state where the container has to WITHDRAW the magnifier rather than
        // just redraw around it.
        if arguments.contains("-inbox-edit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.activeSurface?.setEditing(true, animated: true)
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
        // Anchored a beat after appearance: activating a search controller while
        // the tab's own first layout is still settling fights the presentation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let results = self.searchResults else { return }
            self.searchController.isActive = true
            self.searchController.searchBar.text = text
            results.updateSearchResults(for: self.searchController)

            guard arguments.contains("-inbox-search-cancel") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.searchController.isActive = false
            }
        }
    }
    #endif

    // MARK: - Search

    /// Global search, collapsed to a magnifier in the bar's trailing slot until
    /// tapped — `.integratedButton`, which is UIKit's own name for exactly that
    /// behaviour.
    ///
    /// The placement is chosen for this screen specifically. A `.stacked` field
    /// would be the obvious pick on a plain list root, but its collapse is driven
    /// by the navigation controller's tracked scroll view — and the first one
    /// UIKit finds here is the PAGER's, whose vertical offset never moves. The
    /// field would sit permanently expanded, costing ~52pt on top of the 54pt
    /// the glass header already reserves. `.integratedButton` has no relationship
    /// to any scroll view, so the pager is simply irrelevant to it, and it costs
    /// nothing at rest.
    private func configureSearch() {
        guard let searchResults else { return }
        searchController.searchBar.placeholder = "Search"
        searchController.searchBar.autocapitalizationType = .none
        searchController.searchBar.autocorrectionType = .no
        searchController.searchBar.returnKeyType = .search
        // Stated rather than inherited: clearing through the system glyph routes
        // back out via `updateSearchResults`, so an emptied field returns to the
        // prompt by the same path typing narrowed it.
        searchController.searchBar.searchTextField.clearButtonMode = .whileEditing
        // The bar stays put while the field is active — under `.integratedButton`
        // the field expands INSIDE it, so hiding the bar would take the field
        // being typed into with it.
        searchController.hidesNavigationBarDuringPresentation = false
        // Left to UIKit deliberately: touching `showsCancelButton` flips this to
        // NO and hands us the job of showing and hiding it. Under
        // `.integratedButton` the affordance renders as an ✕ glyph rather than
        // the word "Cancel"; that is the native look, not a missing button.
        searchController.automaticallyShowsCancelButton = true
        // The empty-query state is the system's dim over the inbox — the native
        // "search is open, type something" affordance, and a better answer than
        // any placeholder screen of ours.
        searchController.obscuresBackgroundDuringPresentation = true

        // A picked row must bring the search UI down BEFORE the thread goes up.
        // The results controller is *presented* over this one, so a push landing
        // while it is still up would arrive underneath it — the thread would be
        // on the stack and invisible.
        searchResults.onWillOpenResult = { [weak self] in self?.searchController.isActive = false }

        // Presented in THIS view controller's context, which is what puts the
        // results over the pager and the floating category bar both, rather than
        // over the window. Nothing has to hide the header: it is simply covered,
        // and with it every suggestion that the query has a tab-shaped scope.
        definesPresentationContext = true
        setSearchAvailable(true)
    }

    /// Shows or withholds the magnifier. Idempotent; re-run on every chrome change.
    ///
    /// Withheld while a surface is editing. That surface publishes two batch
    /// actions into the trailing slot, and a magnifier beside them makes three
    /// items plus a title — which truncates on a 402pt bar, the same crowding
    /// `InboxSurfaceChrome.title` was shaped around. Editing is also a mode about
    /// the rows in front of you, so a global search is the wrong offer to make.
    private func setSearchAvailable(_ available: Bool) {
        guard searchResults != nil else { return }
        guard available else {
            guard navigationItem.searchController != nil else { return }
            searchController.isActive = false
            navigationItem.searchController = nil
            return
        }
        guard navigationItem.searchController == nil else { return }
        navigationItem.searchController = searchController
        navigationItem.preferredSearchBarPlacement = .integratedButton
        // No toolbar hand-off: `UINavigationController` transfers a screen's
        // toolbar items at transition *completion*, so letting UIKit relocate the
        // field there drops it into place after a push has already finished.
        navigationItem.searchBarPlacementAllowsToolbarIntegration = false
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

    private func didSettle(on index: Int) {
        selectionFeedback.selectionChanged()
        categoryBar.setProgress(CGFloat(index))
        if let surface = activeSurface {
            apply(surface.chrome, from: surface)
            surface.surfaceDidBecomeActive()
        }
    }

    // MARK: - Chrome

    /// Hands the navigation bar over to whichever page the drag is now more
    /// than half onto, crossfading as it goes.
    ///
    /// Driven by the pager's fractional position rather than its settle, so
    /// "Edit" and "Clear All" trade places at the same moment the header's
    /// lens crosses between their segments — and dragging back and forth
    /// crossfades back and forth with it, instead of holding the old items and
    /// snapping once the page lands.
    private func updateBarOwner(forProgress progress: CGFloat) {
        let index = Int(progress.rounded())
        guard surfaces.indices.contains(index) else { return }
        let surface = surfaces[index]
        guard surface.category != barOwner else { return }
        barOwner = surface.category
        applyChrome(surface.chrome, animated: true)
    }

    /// Applies one surface's published chrome. Badges land whoever sent them;
    /// bar items belong to whichever surface currently owns the bar.
    ///
    /// Not animated: this is the in-place path — a badge count arriving, or
    /// the selection counter ticking while editing. Animating those would
    /// crossfade the whole bar on every row tap.
    private func apply(_ chrome: InboxSurfaceChrome, from surface: any InboxSurface) {
        categoryBar.setBadge(chrome.badgeCount, for: surface.category)
        guard surface.category == barOwner else { return }
        applyChrome(chrome, animated: false)
    }

    private func applyChrome(_ chrome: InboxSurfaceChrome, animated: Bool) {
        let write = {
            self.title = chrome.title ?? "Messages"
            self.navigationItem.leftBarButtonItem = chrome.leadingBarItem
            self.navigationItem.rightBarButtonItems = chrome.trailingBarItems.isEmpty
                ? [self.composeItem]
                : chrome.trailingBarItems
            // Inside the crossfade with everything else in the bar: the
            // magnifier arriving or leaving is the same kind of change as
            // Edit becoming Cancel, and animating it separately would put two
            // animations on one bar in one frame.
            self.setSearchAvailable(!chrome.locksPaging)
        }
        // Editing freezes paging: a half-made selection has no good outcome if
        // the page slides away under it, and the batch actions on screen
        // belong to the surface being edited. Outside the crossfade — it is
        // state, not appearance.
        pagerView?.isPagingEnabled = !chrome.locksPaging
        categoryBar.isUserInteractionEnabled = !chrome.locksPaging

        // The bar is crossfaded as a whole rather than each item's alpha being
        // driven: a `UIBarButtonItem` has no alpha, and wrapping items in
        // custom views to get one would forfeit the system's Liquid Glass
        // capsules — the same double-material trap `GlassSegmentRow`
        // documents. `.allowUserInteraction` keeps the swipe under the
        // viewer's control while the fade runs.
        guard animated, view.window != nil, let bar = navigationController?.navigationBar else {
            write()
            return
        }
        UIView.transition(
            with: bar,
            duration: 0.22,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
            animations: write
        )
    }
}
