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
        if let searchResults {
            // A picked row takes the search UI down BEFORE the thread goes up.
            searchResults.onWillOpenResult = { [weak self] in self?.dismissSearch() }
        }
        configureSearchAffordance()
        // ⚠️ Loaded NOW, not on the first tap. This controller builds a
        // compositional layout, four cell registrations and a diffable source in
        // `viewDidLoad`, and doing that inside the morph is the pause between the
        // magnifier and the field. Loading the view is all it takes; it stays out
        // of the hierarchy until search opens.
        searchResults?.loadViewIfNeeded()

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

        for surface in surfaces { surface.didMove(toParent: self) }

        // ⚠️ **The selector has the leading group to ITSELF; compose rides
        // trailing beside the magnifier.**
        //
        // Two leading items collapse on a narrow bar and one survives — the same
        // rule the profile hit, where moving its switcher trailing is what finally
        // hosted its selector. Measured here: with compose leading, 402pt hosts and
        // 375pt collapses the whole group into a `•••`; with compose trailing, both
        // host. Width is not the trigger, so a narrower selector does not help.
        navigationItem.leftBarButtonItem = nil
        selectorItem = navigationItem.installLeadingSelector(categoryBar)

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
        // Drives the same path the magnifier does: present, type, filter.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            // Requirement checks, both invisible in a screenshot: the results
            // must already be built before the first tap, and the field must be
            // focused as the crossfade lands rather than after it.
            print("[inbox-search] prewarmed=\(self.searchResults?.isViewLoaded == true)")
            self.presentSearch()
            print("[inbox-search] focusedAtMorph=\(self.searchField.isFirstResponder)")
            self.searchField.text = text
            self.searchResults?.applyQuery(text)
            #if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let results = self.searchResults else { return }
                let lists = results.view.subviews.compactMap { $0 as? UICollectionView }
                let rows = lists.first.map { list in
                    (0..<list.numberOfSections).map { list.numberOfItems(inSection: $0) }
                } ?? []
                // The alignment requirement is an equality, so it is measured as
                // one: both centres in window space, and the difference between.
                if let bar = self.navigationController?.navigationBar,
                   let window = bar.window {
                    func findLabel(_ view: UIView) -> UILabel? {
                        if let label = view as? UILabel, label.text == "Cancel" { return label }
                        for sub in view.subviews {
                            if let found = findLabel(sub) { return found }
                        }
                        return nil
                    }
                    let fieldCentre = self.searchField.convert(
                        CGPoint(x: self.searchField.bounds.midX, y: self.searchField.bounds.midY),
                        to: window
                    )
                    let cancelCentre = findLabel(bar).map { label in
                        label.convert(
                            CGPoint(x: label.bounds.midX, y: label.bounds.midY), to: window
                        )
                    }
                    print(String(format: "[inbox-search] fieldCY=%.1f cancelCY=%@ delta=%@ fieldH=%.0f",
                                 fieldCentre.y,
                                 cancelCentre.map { String(format: "%.1f", $0.y) } ?? "not-found",
                                 cancelCentre.map { String(format: "%.1f", fieldCentre.y - $0.y) } ?? "-",
                                 self.searchField.bounds.height))
                }
                print("[inbox-search] searching=\(self.isSearching) "
                    + "resultsOnScreen=\(results.view.window != nil) "
                    + "sections=\(rows) text=\(self.searchField.text ?? "-")")
            }
            #endif
            guard arguments.contains("-inbox-search-cancel") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.dismissSearch()
            }
        }
    }
    #endif

    // MARK: - Search

    /// The classic magnifier, trailing.
    private lazy var searchItem = UIBarButtonItem(
        image: UIImage(systemName: "magnifyingglass"),
        primaryAction: UIAction { [weak self] _ in self?.presentSearch() }
    )

    private lazy var cancelItem = UIBarButtonItem(
        title: "Cancel",
        primaryAction: UIAction { [weak self] _ in self?.dismissSearch() }
    )

    /// The field that takes the bar over while searching.
    ///
    /// It goes in the TITLE SLOT, which is the one place on this bar that hosts
    /// whatever it is given at every width — a leading custom view collapses into
    /// a `•••` on narrow bars once anything shares the row with it, which is the
    /// whole reason the selector has that group to itself.
    private let searchField = UISearchTextField()

    /// The selector's item, kept so the bar can be put back exactly as it was.
    private var selectorItem: UIBarButtonItem?
    private var isSearching = false

    /// The field's height, which is also the Cancel item's touch height, so the
    /// two share a centre line with nothing left over above or below.
    private static let fieldHeight: CGFloat = 36

    private func configureSearchAffordance() {
        searchItem.accessibilityLabel = "Search"
        searchField.placeholder = "Search"
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        // ⚠️ Zero vertical margins, and stated rather than inherited. A
        // `UISearchBar` was here first and carries its own chrome — a background,
        // its own layout margins, and a text field inset within them — which sat
        // the input a few points off the Cancel item's centre no matter what the
        // title slot did. A bare `UISearchTextField` IS the input: it centres on
        // the slot's axis, which is the same axis UIKit centres a bar item on.
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.heightAnchor.constraint(equalToConstant: Self.fieldHeight).isActive = true
        applyRestingBar()
    }

    /// `[ selector ] ———— [ compose ][ search ]`
    private func applyRestingBar() {
        navigationItem.rightBarButtonItems = [searchItem, composeItem]
        navigationItem.leftBarButtonItems = [selectorItem].compactMap { $0 }
        let emptyTitle = UIView()
        emptyTitle.frame = .zero
        navigationItem.titleView = emptyTitle
    }

    /// `[ field ————————————————— ][ Cancel ]`
    private func applySearchingBar() {
        navigationItem.leftBarButtonItems = []
        navigationItem.rightBarButtonItems = [cancelItem]
        navigationItem.titleView = searchField
    }

    /// Morphs the bar into the field, with the results directly beneath it.
    ///
    /// The swap itself is a CROSSFADE of the navigation bar. Bar items are not
    /// individually animatable — assigning them is instantaneous — so the honest
    /// way to make one set become another is to dissolve the bar between the two
    /// states, which is also what UIKit does for its own title transitions.
    private func presentSearch() {
        guard !isSearching, let results = searchResults else { return }
        isSearching = true

        addChild(results)
        results.view.translatesAutoresizingMaskIntoConstraints = false
        results.view.backgroundColor = .systemBackground
        view.addSubview(results.view)
        NSLayoutConstraint.activate([
            // ⚠️ To the TOP OF THE WINDOW, not to the safe area. The list runs
            // BEHIND the header rather than starting under it, so nothing is
            // clipped at the bar's edge; the collection view's own safe-area
            // inset still starts the first row below the bar.
            results.view.topAnchor.constraint(equalTo: view.topAnchor),
            results.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            results.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            results.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        results.didMove(toParent: self)
        results.applyQuery("")
        results.view.alpha = 0

        // Searching is a mode, not a place: the tab bar is a way OUT of it that
        // would take the query with it, and the results deserve the height.
        tabBarController?.setTabBarHidden(true, animated: true)
        morphBar(duration: 0.3) {
            self.setBarOpaque(true)
            self.applySearchingBar()
            // ⚠️ LAID OUT FIRST. A title view is installed on the bar's next
            // layout pass, and `becomeFirstResponder` on a view that is not in a
            // window yet fails silently — measured as `focusedAtMorph=false`,
            // which is the focus arriving late and the placeholder re-laying
            // itself out under the keyboard: the jump.
            self.navigationController?.navigationBar.layoutIfNeeded()
            // ⚠️ FOCUSED INSIDE the change block, so the state the crossfade
            // dissolves TO is the focused one. Focusing afterwards meant the
            // field faded in unfocused and then re-laid itself out when the
            // keyboard arrived — the placeholder shifting under its own glyph,
            // which is the jump.
            self.searchField.becomeFirstResponder()
        }
        UIView.animate(withDuration: 0.24) { results.view.alpha = 1 }
    }

    /// Puts the selector and the glyphs back.
    private func dismissSearch() {
        guard isSearching else { return }
        isSearching = false
        searchField.resignFirstResponder()
        searchField.text = nil
        let results = searchResults

        morphBar(duration: 0.26) {
            self.setBarOpaque(false)
            self.applyRestingBar()
        }
        tabBarController?.setTabBarHidden(false, animated: true)
        UIView.animate(withDuration: 0.2) {
            results?.view.alpha = 0
        } completion: { _ in
            guard let results else { return }
            results.willMove(toParent: nil)
            results.view.removeFromSuperview()
            results.removeFromParent()
        }
    }

    /// The bar is translucent by default and the list runs under it — which is
    /// right until the bar becomes the search field, at which point the rows
    /// sliding behind the text are simply noise. Opaque while searching, and back
    /// to inherited afterwards so the resting bar keeps the system's material.
    private func setBarOpaque(_ opaque: Bool) {
        guard opaque else {
            navigationItem.standardAppearance = nil
            navigationItem.scrollEdgeAppearance = nil
            navigationItem.compactAppearance = nil
            return
        }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .systemBackground
        // No hairline. The results start immediately under the bar, so a divider
        // there separates the field from its own results — the two are one surface
        // while searching, and the line is the only thing saying otherwise.
        appearance.shadowColor = nil
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
    }

    private func morphBar(duration: TimeInterval, _ change: @escaping () -> Void) {
        guard let bar = navigationController?.navigationBar else { change(); return }
        UIView.transition(with: bar, duration: duration,
                          options: [.transitionCrossDissolve, .allowUserInteraction],
                          animations: change)
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

// MARK: - UITextFieldDelegate

extension MessagesInboxViewController: UITextFieldDelegate {
    @objc fileprivate func searchTextChanged() {
        searchResults?.applyQuery(searchField.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
