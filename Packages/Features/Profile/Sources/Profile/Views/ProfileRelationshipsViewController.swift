import CoreModels
import CoreNavigation
import DesignSystem
import MediaCore
import UIKit

/// The followers / following / friends screen, pushed from the profile
/// header's counter row.
///
/// **One screen, three lists, a swipeable pager between them.** The selector is
/// a `PagedTabBar` in the navigation bar's title slot — where the screen's
/// title would otherwise be — and the lists are pages in a
/// `HorizontalPagerView` beneath it.
///
/// **Why the title slot survives three counted titles when a segmented control
/// did not.** This began as a `UISegmentedControl` there, and a third tab broke
/// it: the bar caps the slot (measured at 258pt), and `UISegmentedControl`
/// answers "too much text" by TRUNCATING — "12.4K Followers" and
/// "200+ Following" both become "…Follow…", which are the two labels a viewer
/// most needs to tell apart. A fallback that dropped the counts on narrow
/// screens was built and deleted. `PagedTabBar` answers the same question by
/// SCROLLING: its segments are pinned to their own measured widths inside a
/// scroll view, so a crowded strip slides instead of clipping and every count
/// stays whole. That property is the reason this control is here, and
/// `PagedTabBarTitleOverflowTests` pins it.
///
/// **The pager is what the tab bar was always for.** `PagedTabBar.setProgress`
/// takes a *fractional* page position, so the lens tracks a finger mid-swipe
/// instead of snapping at the end — and a tap animates the pager, which reports
/// progress the same way, so taps and swipes drive the header through one path.
/// The two directions of that sync are `pager.onProgress` and the control's
/// `.valueChanged`; the view model is told only once a page settles.
///
/// The @handle the title slot used to carry survives as the screen's
/// accessibility label, and the back button and search glyph keep their slots
/// either side.
final class ProfileRelationshipsViewController: UIViewController {
    private let viewModel: ProfileRelationshipsViewModel
    private let imagePipeline: ImagePipeline?

    /// The direction selector. Internal so tests can read what the segments
    /// actually say — the point of the rewrite is that they say it in full.
    let tabBar: PagedTabBar
    /// Internal alongside `tabBar` so tests can assert the two stay in step —
    /// which is the whole contract of this screen's chrome.
    let pager: HorizontalPagerView
    /// One list per direction, in `Self.directions` order.
    private let pages: [ProfileRelationshipListViewController]

    /// THE SYSTEM'S SEARCH (#1679, the owner 2026-10-24): a `UISearchController`
    /// whose bar rests as the magnifier — its own item, placed in the trailing
    /// group by `applySearchAvailability` — and expands into the field in
    /// place, UIKit's own animation. The lists filter in place (no results
    /// controller), as the country shop's does. It replaced a field swapped
    /// into the title slot under a hand-made dissolve of the bar (R3), whose
    /// caret had to be hidden through the dissolve.
    ///
    /// ⚠️ The magnifier is PLACED, never left to `.integratedButton`'s own
    /// placement: that collapsed the leading group into a `•••` on narrow
    /// bars when the selector still sat there.
    private(set) lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchResultsUpdater = self
        controller.delegate = self
        controller.obscuresBackgroundDuringPresentation = false
        let bar = controller.searchBar
        bar.delegate = self
        bar.placeholder = "Search..."
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.returnKeyType = .search
        return controller
    }()
    /// From the search's `willPresent` to its `willDismiss`.
    private var isSearching = false

    /// Segment order, so index ↔ direction never drifts.
    ///
    /// ⚠️ Must stay in the same order as
    /// `ProfileRelationshipsViewModel.segmentTitles`, which maps
    /// `RelationshipDirection.allCases` — segment *i* pairs with direction *i*
    /// and nothing checks the two agree.
    private static let directions: [RelationshipDirection] = RelationshipDirection.allCases

    init(viewModel: ProfileRelationshipsViewModel, imagePipeline: ImagePipeline?) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.tabBar = PagedTabBar(titles: viewModel.segmentTitles, style: .navigationTitle)
        self.pages = Self.directions.map {
            ProfileRelationshipListViewController(
                direction: $0, viewModel: viewModel, imagePipeline: imagePipeline
            )
        }
        let start = Self.directions.firstIndex(of: viewModel.direction) ?? 0
        // ⚠️ LAZY, AND THE DIFFERENCE IS THE WHOLE PUSH. `pages.map(\.view)`
        // loaded all three lists here, in the init, and each rendered a
        // viewport of skeleton rows before the push began —
        // `-presentation-budget` blamed this screen for ~200 ms of it. A page
        // is made when the pager is about to show it (charter P3).
        self.pager = HorizontalPagerView(
            lazyPages: pages.map { page in { page.view } }, initialIndex: start, prefersClearTopEdge: false
        )
        super.init(nibName: nil, bundle: nil)
        // The profile underneath hides the tab bar on push; this screen is one
        // level deeper and must not bring it back.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureNavigationBar()
        configurePager()

        viewModel.onPhaseChange = { [weak self] direction, phase in
            self?.page(for: direction)?.render(phase)
            // Privacy is per tab — a backend refusal can lock one list while
            // the others read fine — so the search affordance is re-evaluated
            // whenever the ACTIVE tab's phase moves.
            if direction == self?.viewModel.direction { self?.applySearchAvailability() }
        }
        viewModel.onDirectionChange = { [weak self] direction in
            guard let self, let index = Self.directions.firstIndex(of: direction) else { return }
            self.tabBar.select(index)
            self.pager.setActivePage(index, animated: true)
        }
        viewModel.onSegmentTitlesChange = { [weak self] titles in
            self?.tabBar.setTitles(titles)
        }
        viewModel.onActionResult = { [weak self] result in self?.render(result) }
        // Removing a follower: the row leaves at once, Undo in the toast,
        // sent when its countdown runs out (#957).
        viewModel.onUndoable = { [weak self] action in
            guard let self else { return }
            Feedback.undoable(
                action.message, symbol: action.symbol, from: self,
                commit: action.commit, undo: action.undo
            )
        }

        viewModel.viewDidLoad()
        applySearchAvailability()
    }

    // MARK: - Pager

    private func configurePager() {
        for page in pages {
            addChild(page)
            page.didMove(toParent: self)
        }

        pager.pin(to: view)
        // ⚠️ THE TITLED HEADER'S SOFT BLUR, ON THE PAGER (#1591; the owner,
        // 2026-10-22, filmed: only the status band blurred). The lists are
        // nested in this scroll view and UIKit draws no edge effect for
        // them; this one sits right under the bar, and covers it.
        pager.pagingScrollView.applyTopEdge(for: .titled)

        // Tap → page. Animated, so the lens rides the same progress stream a
        // finger produces rather than jumping.
        tabBar.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.pager.setActivePage(self.tabBar.selectedIndex, animated: true)
            },
            for: .valueChanged
        )
        // Drag on the pill → pages, every frame of the finger; the release
        // hands the pager a velocity and it lands itself.
        tabBar.onScrub = { [weak self] progress in self?.pager.scrub(to: progress) }
        tabBar.onScrubEnd = { [weak self] velocity in
            self?.pager.settleAfterScrub(velocityInPages: velocity)
        }
        // Swipe → lens, every frame of the drag.
        pager.onProgress = { [weak self] progress in
            #if DEBUG
            // Dev convenience: `-relationships-trace-progress` prints the
            // fractional page position every frame. Whether the lens TRACKS a
            // swipe or snaps at the end of it is invisible to a screenshot and
            // easy to misread from a video — a frame-by-frame measurement that
            // includes the selected segment's bold text reads as a jump even
            // when the lens is moving perfectly.
            if ProcessInfo.processInfo.arguments.contains("-relationships-trace-progress") {
                print("REL-PROGRESS \(progress)")
            }
            #endif
            self?.tabBar.setProgress(progress)
        }
        // Only a SETTLED page changes the model's direction. Telling it
        // mid-swipe would make the search field and the QA hooks flicker
        // between tabs while a finger is still deciding.
        pager.onSettled = { [weak self] index in
            guard let self, let direction = Self.directions[safe: index] else { return }
            self.viewModel.selectDirection(direction)
        }
        tabBar.select(Self.directions.firstIndex(of: viewModel.direction) ?? 0)
    }

    private func page(for direction: RelationshipDirection) -> ProfileRelationshipListViewController? {
        pages.first { $0.direction == direction }
    }

    /// The active tab's phase, which is what the search affordance keys off.
    private var phase: ProfileRelationshipsViewModel.Phase {
        viewModel.phase(for: viewModel.direction)
    }

    /// Whether the search affordance should be withheld.
    ///
    /// Reads the view model's `access` as well as the rendered phase, and that
    /// ordering is what lets the search bar be installed at the *top* of
    /// `viewDidLoad`: `access` is resolved from the seeded subject at init, so
    /// privacy is knowable before anything has rendered. The phase is the
    /// second source only for the case privacy can't predict — a backend
    /// refusal arriving later.
    private var isRestricted: Bool {
        if viewModel.access == .private { return true }
        if case .restricted = phase { return true }
        return false
    }

    /// Shows or withholds search according to privacy.
    ///
    /// Only search is withheld — the selector stays, so the viewer can still
    /// switch direction. Restriction is not always symmetric: a backend refusal
    /// applies per tab, so one list can be locked while the other reads fine.
    ///
    /// Idempotent; re-run on every phase change.
    private func applySearchAvailability() {
        // The screen's own items, never a bar toast's (#1420).
        let searchItem = navigationItem.searchBarPlacementBarButtonItem
        var items = ownTrailingBarItems.filter { $0 !== searchItem }
        if isRestricted {
            if searchController.isActive { searchController.isActive = false }
            navigationItem.searchController = nil
        } else {
            if navigationItem.searchController == nil {
                definesPresentationContext = true
                navigationItem.searchController = searchController
                navigationItem.preferredSearchBarPlacement = .integratedButton
                navigationItem.hidesSearchBarWhenScrolling = false
            }
            items.insert(navigationItem.searchBarPlacementBarButtonItem, at: 0)
        }
        guard !items.elementsEqual(ownTrailingBarItems, by: ===) else { return }
        setOwnTrailingBarItems(items, animated: false)
    }

    /// Opens search, focused — the magnifier's tap, and the QA hooks'.
    func presentSearch() {
        guard navigationItem.searchController != nil, !searchController.isActive else { return }
        searchController.isActive = true
        DispatchQueue.main.async { [weak self] in
            self?.searchController.searchBar.searchTextField.becomeFirstResponder()
        }
    }

    /// Closes search: the field folds back into the magnifier.
    func dismissSearch() {
        searchController.isActive = false
    }

    /// ⚠️ ONLY A BAR THIS SCREEN SHOWS (#782). Pushed with
    /// `hidesBottomBarWhenPushed`, the bar is UIKit's: the search's hide did
    /// nothing, and its show on Cancel slid the tab bar in over the list and
    /// its toolbar — with nothing to take it away again after the pop.
    private var ownsAppTabBar: Bool {
        navigationController?.showsAppTabBar(for: self) ?? false
    }

    /// The whole input contract, as on the inbox: a string.
    private func applyQuery(_ text: String) {
        viewModel.searchQueryChanged(text)
    }

    #if DEBUG
    /// The launch-argument hooks in `viewDidAppear` run on the FIRST
    /// appearance only. `viewDidAppear` fires again whenever something pushed
    /// from here pops back — a row's profile, above all — and re-arming then
    /// toggled `-profile-relationships-action`'s follow a second time (undoing
    /// the first) and re-tapped `-profile-relationships-open-self`. The
    /// profile screen learned the same lesson; see its `hasArmedDebugHooks`.
    private var hasArmedDebugHooks = false

    /// Runs `act` on the active list's rows once that list has SETTLED — out
    /// of `.loading` — and prints a `[qa] GAVE UP` line when it settles into
    /// anything but rows, or when `act` returns a reason it could not act.
    ///
    /// Settled rather than "has a row": the row the hook wants may be on a
    /// later page, but a list that has answered is the last state worth
    /// waiting for, and an empty / restricted / failed answer is a finished
    /// one that should say so at once rather than time out.
    private func qaWhenListSettled(
        _ label: String,
        _ act: @escaping @MainActor ([ProfileRelationshipsViewModel.Row]) -> String?
    ) {
        QAWait.until(label, { [weak self] in
            guard let self else { return false }
            return self.viewModel.phase(for: self.viewModel.direction) != .loading
        }) { [weak self] in
            guard let self else { return }
            let phase = viewModel.phase(for: viewModel.direction)
            guard case .content(let rows, _) = phase else {
                QAWait.fail(label, "the \(viewModel.direction) list settled without rows: \(phase)")
                return
            }
            if let reason = act(rows) { QAWait.fail(label, reason) }
        }
    }

    /// Continues the search QA sequence after typing: optionally clear, then
    /// optionally cancel. The clear step goes through the text field's own
    /// `editingChanged` — the same notification the system's clear glyph
    /// raises — so it exercises the real path back to `updateSearchResults`
    /// rather than calling the updater directly.
    private func qaContinueSearchSequence(_ arguments: [String]) {
        let clears = arguments.contains("-profile-relationships-search-clear")
        let cancels = arguments.contains("-profile-relationships-search-cancel")
        guard clears || cancels else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if clears {
                let field = self.searchController.searchBar.searchTextField
                print("PROFILE-SEARCH-QA clearButtonMode=\(field.clearButtonMode.rawValue) "
                    + "searching=\(self.isSearching)")
                field.text = ""
                field.sendActions(for: .editingChanged)
            }
            guard cancels else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.dismissSearch()
            }
        }
    }
    #endif

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // ⚠️ NOTHING OF OURS OUTLIVES THIS SCREEN'S TURN ON TOP: a suspended pan
        // is stack-wide state, and carrying one into a pushed screen's
        // dismissal is how a gesture that should pop one level pops two.
        setStackGesturesEnabled(true)
        guard isMovingFromParent else { return }
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        subordinatePagerToBackSwipes()
        #if DEBUG
        // ARMED ONCE — see `hasArmedDebugHooks`.
        defer { hasArmedDebugHooks = true }
        if hasArmedDebugHooks { return }
        let arguments = ProcessInfo.processInfo.arguments
        // Dev convenience: `-profile-relationships-tab following|friends` opens
        // on that tab, and `-profile-relationships-action` fires the first row's
        // trailing button — neither is reachable in the simulator, which can
        // deliver no taps.
        if let index = arguments.firstIndex(of: "-profile-relationships-tab") {
            switch arguments.dropFirst(index + 1).first {
            case "following": viewModel.qaSelectDirection(.following)
            case "friends": viewModel.qaSelectDirection(.friends)
            default: break
            }
        }
        // Both row hooks keep their 2s beat (the push settles on camera first)
        // and then WAIT FOR THE ROWS: the list is a network read, and under
        // `-mock-latency` the fixed delay found no rows, the view model's
        // `guard … else { return }` swallowed the tap, and the run printed
        // nothing either way.
        if arguments.contains("-profile-relationships-action") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.qaWhenListSettled("profile-relationships-action") { rows in
                    guard let target = rows.first(where: { !$0.isViewer }) else {
                        return "no row other than the viewer's own"
                    }
                    guard target.action != .inert else {
                        return "the first row (\(target.handle)) offers no action"
                    }
                    self?.viewModel.qaActivateFirstRowAction()
                    return nil
                }
            }
        }
        // Dev convenience: `-profile-relationships-open-self` taps the viewer's
        // own "(Me)" row — the route that must land on the personal profile
        // directly, with no stranger-profile frame in between.
        if arguments.contains("-profile-relationships-open-self") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.qaWhenListSettled("profile-relationships-open-self") { rows in
                    guard rows.contains(where: \.isViewer) else {
                        return "the viewer is not in this list"
                    }
                    self?.viewModel.qaOpenSelfRow()
                    return nil
                }
            }
        }
        // Dev convenience: `-profile-relationships-search <text>` types into
        // the pinned header's field ~1.5s in, through its own `query` setter so
        // the real change path runs — rather than poking the view model, which
        // would prove only that the filter compiles.
        // `-profile-relationships-search-open`: presents search and types NOTHING,
        // so the placeholder is on screen for the whole transition and can be
        // measured frame by frame.
        if arguments.contains("-profile-relationships-search-open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.presentSearch()
            }
        }
        if let index = arguments.firstIndex(of: "-profile-relationships-search"),
           let text = arguments.dropFirst(index + 1).first, !text.hasPrefix("-") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                // Activate exactly as a tap on the magnifier would, then type.
                self.presentSearch()
                self.searchController.searchBar.text = text
                self.applyQuery(text)
                self.qaContinueSearchSequence(arguments)
            }
        }
        // Dev convenience: `-profile-relationships-pop` pops back to the
        // profile ~2s in. The app-level `-auto-pop` fires at a fixed 2.5s,
        // which is before this screen has even been pushed; this one is
        // anchored to its own appearance, so the pop transition is recordable.
        if arguments.contains("-profile-relationships-pop") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.navigationController?.popViewController(animated: true)
            }
        }
        #endif
    }

    // MARK: - Setup

    private func configureNavigationBar() {
        // The selector IS the title. It sits where the @handle used to, between
        // the back button and the search glyph, and the bar sizes the slot from
        // the bar's intrinsic width — see `PagedTabBar`'s `intrinsicContentSize`.
        // ⚠️ **The TITLE slot here, not the leading group** — unlike the inbox.
        // ⚠️ **THE STRIP IS AT THE FOOT OF THE SCREEN NOW, NOT IN THE TITLE
        // SLOT.** The paragraph this replaces was about a navigation bar's
        // arithmetic — this screen is pushed, its leading group already holds a
        // back button, and back + selector took the whole group into a `•••` on
        // an SE, so the title slot was the only place left. A toolbar has
        // neither item groups nor an overflow control, so the strip is simply
        // put there, and the freed title slot goes back to the @handle it was
        // surrendered for.
        navigationItem.title = viewModel.title
        navigationItem.largeTitleDisplayMode = .never
        // Chevron only, never "Back" beside it (#727).
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.accessibilityLabel = viewModel.title
        configureToolbar()
    }

    /// The strip, at the foot of the screen.
    ///
    /// ⚠️ **THIS SCREEN HIDES THE TAB BAR, SO THE TOOLBAR IS WHAT OWNS THE
    /// BOTTOM.** `hidesBottomBarWhenPushed` is true here, so there is no tab
    /// bar to hang an accessory over — the navigation controller's own toolbar
    /// is the band, and the selector leads it exactly as it does on the search
    /// results screen.
    ///
    /// ⚠️ AND IT MUST RAISE AND HIDE THE TOOLBAR ITSELF. `toolbarItems` is per
    /// view controller, but the toolbar's VISIBILITY belongs to the stack: left
    /// up it follows the pop back onto a profile that has its own tray in that
    /// band, and never raised it would simply not appear. Its parent cannot do
    /// it either — a tab-root profile's `concealFilterToolbar` returns early.
    private func configureToolbar() {
        // ⚠️ NO WIDTH ARITHMETIC. A toolbar has no item groups and no overflow
        // control, so the `•••` that drove this strip into the title slot is
        // not available to it. The app already hosts a wide custom view in this
        // same shared toolbar with no width math at all — the chat composer's
        // sticker strip.
        selectorTouchProbe.attach(to: tabBar)
        // ⚠️ **A BAR ITEM GETS THE SYSTEM'S OWN GLASS PLATTER**, 4pt larger than
        // the view it hosts on every side. Left to draw its own capsule the strip
        // rendered as a bubble inside a bubble — which this screen shipped, the
        // only selector in the app still doing so. `.platter` draws no material
        // and lays the strip out against the platter's edge, so its titles
        // scroll right up to the glass the viewer sees.
        tabBar.hosting = .platter
        toolbarItems = [UIBarButtonItem(customView: tabBar), .flexibleSpace()]
    }

    /// ⚠️ THE STRIP WINS THE TOUCH IT IS UNDER — see `SelectorTouchProbe`.
    private lazy var selectorTouchProbe = SelectorTouchProbe { [weak self] isTouching in
        self?.setStackGesturesEnabled(!isTouching)
    }

    /// Suspends every pan on the navigation controller's own container view for
    /// the length of a touch on the strip.
    ///
    /// ⚠️ **THE STACK HAS TWO BACK-SWIPE RECOGNISERS AND
    /// `interactivePopGestureRecognizer` VENDS ONLY ONE** — audited on the
    /// search results screen, where gating the vended one looked right and left
    /// the screen anyway. Every pan on the container is suspended, each
    /// restored to the value it had rather than to `true`, and only while this
    /// screen is the top one.
    private func setStackGesturesEnabled(_ isEnabled: Bool) {
        if isEnabled {
            for (recogniser, wasEnabled) in suspendedPans { recogniser.isEnabled = wasEnabled }
            suspendedPans = []
            return
        }
        guard navigationController?.topViewController === self,
              suspendedPans.isEmpty,
              let host = navigationController?.view
        else { return }
        let pans = (host.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer }
        suspendedPans = pans.map { ($0, $0.isEnabled) }
        for recogniser in pans { recogniser.isEnabled = false }
    }

    private var suspendedPans: [(UIGestureRecognizer, Bool)] = []

    /// Whether the pager's pan waits on the stack's back swipes yet.
    private var didSubordinatePagerToPop = false

    /// ⚠️ THE PAGER WAITS FOR THE BACK SWIPE (#1300), as a pushed profile's
    /// gallery does (#1324). Left simultaneous, a rightward drag on Followers
    /// began the pager's pan — which on the first page can only bounce — and
    /// the screen stayed: only the 28pt edge strip, which the pager yields,
    /// went back. The full-surface swipe declines on Following and Friends
    /// (`allowsContentPop`), and the pager pages there. Deferred to the first
    /// appearance: the navigation controller is not set at `viewDidLoad`.
    private func subordinatePagerToBackSwipes() {
        guard !didSubordinatePagerToPop, let navigationController else { return }
        didSubordinatePagerToPop = true
        if let pop = navigationController.interactivePopGestureRecognizer {
            pager.horizontalPan.require(toFail: pop)
        }
        if #available(iOS 26.0, *), let content = navigationController.interactiveContentPopGestureRecognizer {
            pager.horizontalPan.require(toFail: content)
        }
    }

    /// A failed row mutation. A toast, not an alert: the row has already
    /// rolled back to its previous state, so there is nothing for the user to
    /// dismiss or decide.
    private func render(_ result: ProfileRelationshipsViewModel.ActionResult) {
        switch result {
        case .failed(let message):
            Feedback.failure(message, from: self)
        }
    }

}

// MARK: - The native back swipe (#1300)

/// A pushed paged screen pops with the system's full-surface swipe on its
/// FIRST tab only (`PagedScreenDismissalPolicy`): nothing lies to the left of
/// Followers, while on Following and Friends a rightward drag pages back. The
/// edge strip pops on every tab — that is the other recogniser's, ungated.
/// Not while the search field holds the bar: a drag across a half-typed query
/// leaves the screen only from the edge, as it always has (#1300).
extension ProfileRelationshipsViewController: ContentPopGating {
    func allowsContentPop(beginningAt point: CGPoint, in view: UIView) -> Bool {
        guard let navigationController, !isSearching else { return false }
        return PagedScreenDismissalPolicy.allowsFullWidthDismissal(
            activeIndex: pager.activeIndex,
            isPushed: navigationController.viewControllers.first !== self
        )
    }
}

private extension Array {
    /// A segmented control's selected index can be `NSNotFound` between
    /// configuration and first layout.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension ProfileRelationshipsViewController: UISearchResultsUpdating, UISearchControllerDelegate, UISearchBarDelegate {
    func updateSearchResults(for searchController: UISearchController) {
        applyQuery(searchController.searchBar.text ?? "")
    }

    func willPresentSearchController(_ searchController: UISearchController) {
        isSearching = true
        if ownsAppTabBar { tabBarController?.setTabBarHidden(true, animated: true) }
    }

    func willDismissSearchController(_ searchController: UISearchController) {
        isSearching = false
        applyQuery("")
        if ownsAppTabBar { tabBarController?.setTabBarHidden(false, animated: true) }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.searchTextField.resignFirstResponder()
    }
}
