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
/// **The capsule is the title.** It is `navigationItem.titleView`, the same
/// arrangement `ForYouViewController` uses, so this screen reserves no safe
/// area of its own: the navigation bar's height already accounts for it, and
/// each page's list insets itself through the standard safe area. Nothing
/// floats over the content, so there is no header geometry to maintain here.
///
/// **Badges are a fact about the session.** Nothing here retires one: not
/// paging between tabs, not pushing a thread, not leaving for another root tab.
/// A cold launch builds new view models and with them new watermarks, and that
/// is the only reset there is — see `InboxTabWatermark`.
///
/// **The bar is written once and never again.** Leading is Compose, trailing is
/// the search magnifier, and both belong to the inbox as a whole rather than to
/// any page — which is the whole point: a title view gets what the side items
/// leave it, so a page publishing its own word there would re-measure the
/// capsule on every tab change. What a page contributes rides its own tab: a
/// badge, and the menu its long press offers.
final class MessagesInboxViewController: UIViewController, MessagesInboxCategorySelecting {
    /// The inbox's surfaces, in paging order.
    private let surfaces: [any InboxSurface]
    /// The shared glass tab capsule, hosted in the navigation bar's title slot.
    /// It takes titles and reports an index — the category is this container's
    /// vocabulary, not the bar's, so every call site maps one to the other
    /// through `surfaces`.
    private let categoryBar: PagedTabBar
    private let selectionFeedback = UISelectionFeedbackGenerator()

    /// Built in `viewDidLoad`, once the surfaces are children — reading a
    /// child's `view` before containment would load it outside its parent.
    private var pagerView: HorizontalPagerView!
    private var didSubordinatePagerToPop = false
    private var hasActivatedInitialSurface = false
    #if DEBUG
    /// Latches the launch-argument QA sequence to one run per screen.
    private var hasRunDebugSequence = false
    #endif
    /// Compose belongs to the inbox, not to a page: it starts a new message
    /// regardless of which surface is showing, and rides the same route seam
    /// as row selection so the contact-selection flow lands resolver-side.
    ///
    /// It holds the leading slot permanently — no page can displace it.
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
        categoryBar = PagedTabBar(
            titles: surfaces.map(\.category.title), style: .navigationTitle
        )
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
        // No title string: the capsule occupies the slot one would have taken.
        // The tab's own name still reads "Messages" — that lives on the `UITab`,
        // not here.
        navigationItem.title = nil
        navigationItem.largeTitleDisplayMode = .never
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
        pagerView = HorizontalPagerView(pages: surfaces.map(\.view), initialIndex: startIndex)
        pagerView.pin(to: view)
        // ⚠️ AFTER the pager, every time. `configureSearch` runs first and adds the
        // search host, so the pager lands on top of it — the bar was mounted,
        // inset for, and completely invisible behind an opaque page.
        view.bringSubviewToFront(dockedHeader)
        for surface in surfaces { surface.didMove(toParent: self) }

        // The bar's contents, stated once. Nothing else writes them.
        //
        navigationItem.leftBarButtonItem = composeItem
        // ⚠️ ORDER: the selector comes SECOND, because `leftBarButtonItem`
        // (singular) replaces the whole leading group — installing before this
        // line dropped the selector off the bar entirely.
        //
        // This surface is the widest of the four: three long titles measure 280pt,
        // and beside the compose glyph and the integrated search button there is
        // not that much room. `LeadingSelectorHost` caps the width and the bar
        // scrolls the remainder, so no title is shortened. Before the cap existed
        // UIKit silently declined to host it and the capsule was simply absent.
        // 120, not the default 170: this bar carries a compose glyph and the
        // integrated search button and nothing else, and at 170 the ceiling clipped
        // the final letter of "Suggestions" off a capsule that fits at 280pt.
        navigationItem.installLeadingSelector(categoryBar, roomForOtherItems: 120)

        // NO `additionalSafeAreaInsets.top`, and no constraints for the capsule:
        // it lives INSIDE the navigation bar, whose height already covers it.
        // Every page's list insets under the header through the standard safe
        // area, with nothing of ours to keep in step with it.

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
        pagerView.onProgress = { [weak self] progress in self?.categoryBar.setProgress(progress) }
        pagerView.onSettled = { [weak self] index in self?.didSettle(on: index) }

        for surface in surfaces {
            apply(surface.chrome, from: surface)
            surface.onChromeChange = { [weak self] chrome in self?.apply(chrome, from: surface) }
        }

        categoryBar.setProgress(CGFloat(pagerView.activeIndex))
    }

    /// Fires at the START of a pop — including the interactive one, before any
    /// frame is drawn — so what the transition reveals is already in agreement:
    /// the page shown and the lens over it.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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
        #if DEBUG
        if let position = ProcessInfo.processInfo.arguments.firstIndex(of: "-inbox-scroll"),
           position + 1 < ProcessInfo.processInfo.arguments.count,
           let points = Double(ProcessInfo.processInfo.arguments[position + 1]),
           !hasActivatedInitialSurface {
            runSearchCollapseDemo(points: CGFloat(points))
        }
        #endif
        if !hasActivatedInitialSurface {
            hasActivatedInitialSurface = true
            if let surface = activeSurface { mountSearchBar(in: surface) }
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

        // `-inbox-compose` fires the leading item's action ~2s in, through the
        // same closure the button invokes. Compose moved from the trailing slot
        // to the leading one when the tabs took the title, and a bar item that
        // renders in its new place but no longer reaches the router looks
        // identical in a screenshot.
        if arguments.contains("-inbox-compose") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.onCompose?()
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
            guard let self else { return }
            // Drives the SAME path a tap takes now: focusing the field docks it and
            // mounts the results as a child. `isActive` belonged to the controller's
            // own presentation, which this architecture no longer uses — setting it
            // here would present results over the very bar it docked.
            self.searchBar.becomeFirstResponder()
            self.dockSearch()
            self.searchBar.text = text
            self.updateResults()
            print("[inbox-search] query applied text=\(self.searchBar.text ?? "-")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let results = self.searchResults else { return }
                let lists = results.view.subviews.compactMap { $0 as? UICollectionView }
                let rows = lists.first.map { list in
                    (0..<list.numberOfSections).map { list.numberOfItems(inSection: $0) }
                } ?? []
                print("[inbox-search] results sections=\(rows) text=\(self.searchBar.text ?? "-")")
            }

            guard arguments.contains("-inbox-search-cancel") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.undockSearch()
            }
        }
    }
    #endif

    // MARK: - Search

    /// Global search, as a magnifier in the bar's trailing slot that expands in
    /// place when tapped — `.integratedButton`, UIKit's own name for that.
    ///
    /// **It is the trailing item, on every tab, and it never changes size.**
    /// That is the point: a glyph measures the same whatever page is showing,
    /// so the title slot the tab capsule lives in is one number instead of four
    /// (252 / 239.7 / 228.7 / ~190pt, depending on which page's word was in the
    /// slot). The capsule is therefore laid out once and never re-measured by
    /// paging.
    ///
    /// A `.stacked` field — a permanent row under the title — was built and
    /// removed. It cost a whole row of chrome for an affordance that is one tap
    /// away here, and it brought a defect with it: its collapse is driven by
    /// the tracked scroll view, which on this screen is the PAGER's, whose
    /// `contentOffset.y` never moves. So the field could be collapsed by a
    /// push and had nothing that could ever scroll it back open — it vanished
    /// for good after backing out of a thread, and only
    /// `hidesSearchBarWhenScrolling = false` held it in place.
    /// `.integratedButton` has no scroll-view relationship at all, so that
    /// whole class of bug is simply absent.
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
        // The bar STAYS while the field is active: under `.integratedButton` the
        // field expands inside the bar itself, so hiding the bar would take the
        // field being typed into with it. The results are presented over
        // everything anyway, so the tabs behind them assert nothing.
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
        searchResults.onWillOpenResult = { [weak self] in self?.undockSearch() }

        // Presented in THIS view controller's context, which is what puts the
        // results over the pager rather than over the window. Nothing has to hide
        // the header: it is simply covered, and with it every suggestion that the
        // query has a tab-shaped scope.
        definesPresentationContext = true

        // ⚠️ **NOT `navigationItem.searchController`.** Any bar-hosted search on
        // this screen costs the leading group: `.integratedButton` collapsed the
        // compose glyph AND the selector into a `•••` on every width below 440pt,
        // and `.stacked` only moved the problem to 375pt. The field belongs to the
        // LIST now — mounted at the top of the pages and scrolling away with them,
        // the way Messages and Telegram do it — which leaves the navigation bar
        // carrying nothing but the glyph and the selector.
        configureSharedSearchBar()
    }

    #if DEBUG
    /// `-inbox-scroll <points>`: scrolls the ACTIVE page and reports where the
    /// first sticky section header lands relative to the top of the visible area.
    ///
    /// That gap is the bug this architecture replaced: with the bar as an overlay
    /// plus a matching `contentInset`, these `.plain` lists pinned their sticky
    /// headers at the INSET and left a band of dead space above them. Flush is 0.
    private func runSearchCollapseDemo(points: CGFloat) {
        var attempts = 0
        func attempt() {
            attempts += 1
            guard let surface = activeSurface else { return }
            let scrollView = surface.listScrollView
            let reachable = scrollView.contentSize.height - scrollView.bounds.height
            if reachable > 1 {
                let target = min(points, reachable)
                scrollView.setContentOffset(
                    CGPoint(x: 0, y: target - scrollView.adjustedContentInset.top),
                    animated: false
                )
                scrollView.layoutIfNeeded()
                let table = scrollView as? UITableView
                let visibleTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
                let headerTop = table?.rectForHeader(inSection: 0).minY ?? .nan
                print(String(format:
                    "[inbox-scroll] to %.0f insetTop=%.0f stickyGap=%.0f listHeader=%@",
                    target, scrollView.adjustedContentInset.top, headerTop - visibleTop,
                    table?.tableHeaderView == nil ? "none" : "mounted"))
                return
            }
            if attempts < 60 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
            } else {
                print("[inbox-scroll] gave up: no scrollable content")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: attempt)
    }
    #endif

    // MARK: - Search: in the list, and docked while typing

    /// The one search bar every tab shares, so a query survives a swipe.
    ///
    /// ⚠️ **OURS, not `searchController.searchBar`.** Taking that bar meant taking
    /// its delegate, which `UISearchController` owns and uses to drive its own
    /// results-controller lifecycle — so it went on managing a presentation this
    /// screen no longer performs, and pulled the results view back out of the
    /// hierarchy moments after it was mounted. Measured: the child was in the
    /// window and correctly sized at dock time, and painting it bright red showed
    /// nothing on screen a few seconds later.
    ///
    /// The controller survives as the carrier `updateSearchResults(for:)` needs;
    /// its bar's text is mirrored from ours before each update.
    private let searchBar = UISearchBar()

    /// Carries the bar at the top of whichever list is in front. Sized in points
    /// rather than by constraints: `tableHeaderView` is laid out from its FRAME,
    /// and an auto-layout-only header measures zero and never appears.
    private let listHeader = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 56))

    /// Carries the bar while typing, pinned under the navigation bar.
    private let dockedHeader = UIView()
    private var isSearchDocked = false

    private func configureSharedSearchBar() {
        searchBar.delegate = self
        searchBar.placeholder = searchController.searchBar.placeholder
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.returnKeyType = .search
        searchBar.searchBarStyle = .minimal
        searchBar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        searchBar.frame = listHeader.bounds
        listHeader.addSubview(searchBar)

        dockedHeader.translatesAutoresizingMaskIntoConstraints = false
        dockedHeader.backgroundColor = .systemBackground
        dockedHeader.isHidden = true
        view.addSubview(dockedHeader)
        NSLayoutConstraint.activate([
            dockedHeader.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            dockedHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dockedHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dockedHeader.heightAnchor.constraint(equalToConstant: listHeader.bounds.height)
        ])
    }

    /// Moves the shared bar into the page that is now in front.
    ///
    /// One instance, re-parented — not one per page. Two bars would disagree
    /// about what was typed the moment a swipe landed.
    private func mountSearchBar(in surface: any InboxSurface) {
        guard !isSearchDocked else { return }
        for other in surfaces where other !== surface {
            other.setListHeaderView(nil)
        }
        listHeader.frame.size.width = view.bounds.width
        searchBar.frame = listHeader.bounds
        surface.setListHeaderView(listHeader)
    }

    /// Lifts the bar out of the list and pins it under the navigation bar, with
    /// the results below it.
    ///
    /// ⚠️ This replaced `UISearchController`'s own presentation, which covered
    /// the very view the bar had moved into — the field was invisible while its
    /// results were up, so you could not see what you were typing. Presented over
    /// a bar that lives in the navigation item this never happens; the moment the
    /// bar lives in the content, the presentation has to go.
    private func dockSearch() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-inbox-search-query") {
            print("[inbox-search] dockSearch docked=\(isSearchDocked) results=\(searchResults != nil)")
        }
        #endif
        guard !isSearchDocked, let results = searchResults else { return }
        isSearchDocked = true
        activeSurface?.setListHeaderView(nil)

        dockedHeader.isHidden = false
        searchBar.frame = dockedHeader.bounds
        dockedHeader.addSubview(searchBar)
        searchBar.setShowsCancelButton(true, animated: true)

        addChild(results)
        // ⚠️ OPAQUE. As a presented controller it had a backdrop of its own; as a
        // child it is just a view, and a clear one lets the inbox list show
        // through — which reads as the query having matched everything.
        results.view.backgroundColor =
            ProcessInfo.processInfo.arguments.contains("-inbox-paint-results")
            ? .systemRed : .systemBackground
        // ⚠️ Un-hidden explicitly. This controller spent its previous life being
        // PRESENTED by a `UISearchController`, and that lifecycle leaves the view
        // hidden on dismissal. Re-used as a child it was mounted, in the window,
        // correctly sized and filtering — sections=[1] for "lena" — while the
        // inbox list showed through it, because nothing had ever put it back.
        results.view.isHidden = false
        results.view.alpha = 1
        results.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(results.view)
        NSLayoutConstraint.activate([
            results.view.topAnchor.constraint(equalTo: dockedHeader.bottomAnchor),
            results.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            results.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            results.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        results.didMove(toParent: self)
        view.bringSubviewToFront(dockedHeader)
        updateResults()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-inbox-search-query") {
            view.layoutIfNeeded()
            print("[inbox-search] order=" + view.subviews.map {
                String(describing: type(of: $0)) + (($0 === results.view) ? "*" : "")
            }.joined(separator: " > "))
            print(String(format: "[inbox-search] docked results frame=%.0f,%.0f %.0fx%.0f "
                + "inWindow=%@ children=%d text=%@",
                results.view.frame.minX, results.view.frame.minY,
                results.view.frame.width, results.view.frame.height,
                results.view.window != nil ? "yes" : "NO", children.count,
                searchBar.text ?? "-"))
        }
        #endif
    }

    /// Mirrors our text into the controller the results updater reads from.
    private func updateResults() {
        searchController.searchBar.text = searchBar.text
        searchResults?.updateSearchResults(for: searchController)
    }

    private func undockSearch() {
        guard isSearchDocked else { return }
        isSearchDocked = false
        if let results = searchResults {
            results.willMove(toParent: nil)
            results.view.removeFromSuperview()
            results.removeFromParent()
        }
        searchBar.setShowsCancelButton(false, animated: true)
        searchBar.resignFirstResponder()
        dockedHeader.isHidden = true
        if let surface = activeSurface { mountSearchBar(in: surface) }
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
        mountSearchBar(in: surface)
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
        categoryBar.sizeToFit()
        navigationController?.navigationBar.setNeedsLayout()
        navigationController?.navigationBar.layoutIfNeeded()
    }

}

// MARK: - UISearchBarDelegate

extension MessagesInboxViewController: UISearchBarDelegate {
    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        dockSearch()
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        guard isSearchDocked else { return }
        updateResults()
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = nil
        undockSearch()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
