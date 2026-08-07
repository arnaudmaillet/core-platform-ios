import CoreModels
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

    /// Search, collapsed to a magnifier in the bar's trailing slot until
    /// tapped — `.integratedButton`, which is UIKit's own name for exactly
    /// that behaviour.
    private let searchController = UISearchController(searchResultsController: nil)

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
        self.pager = HorizontalPagerView(pages: pages.map(\.view), initialIndex: start)
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
        configureSearch()
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

        // Tap → page. Animated, so the lens rides the same progress stream a
        // finger produces rather than jumping.
        tabBar.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.pager.setActivePage(self.tabBar.selectedIndex, animated: true)
            },
            for: .valueChanged
        )
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

    /// Shows or withholds the search field according to privacy.
    ///
    /// Only the field is withheld — the selector stays, so the viewer can still
    /// switch direction. Restriction is not always symmetric: a backend refusal
    /// applies per tab, so one list can be locked while the other reads fine.
    ///
    /// Idempotent; re-run on every phase change.
    private func applySearchAvailability() {
        guard isRestricted else {
            guard navigationItem.searchController == nil else { return }
            navigationItem.searchController = searchController
            // The proposal's shape, expressed as the one enum value UIKit
            // provides for it: inactive search is a magnifier button in the
            // trailing slot, tapping expands it into a field, cancelling
            // collapses it back — all system-driven.
            navigationItem.preferredSearchBarPlacement = .integratedButton
            // No toolbar hand-off: that is what produced the magnifying-glass
            // FLASH during the push in an earlier iteration. Here the magnifier
            // is a deliberate, permanent affordance instead.
            navigationItem.searchBarPlacementAllowsToolbarIntegration = false
            return
        }
        guard navigationItem.searchController != nil else { return }
        searchController.isActive = false
        navigationItem.searchController = nil
    }

    #if DEBUG
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
                    + "autoCancel=\(self.searchController.automaticallyShowsCancelButton)")
                field.text = ""
                field.sendActions(for: .editingChanged)
            }
            guard cancels else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.searchController.isActive = false
            }
        }
    }
    #endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
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
        if arguments.contains("-profile-relationships-action") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.viewModel.qaActivateFirstRowAction()
            }
        }
        // Dev convenience: `-profile-relationships-open-self` taps the viewer's
        // own "(Me)" row — the route that must land on the personal profile
        // directly, with no stranger-profile frame in between.
        if arguments.contains("-profile-relationships-open-self") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.viewModel.qaOpenSelfRow()
            }
        }
        // Dev convenience: `-profile-relationships-search <text>` types into
        // the pinned header's field ~1.5s in, through its own `query` setter so
        // the real change path runs — rather than poking the view model, which
        // would prove only that the filter compiles.
        if let index = arguments.firstIndex(of: "-profile-relationships-search"),
           let text = arguments.dropFirst(index + 1).first, !text.hasPrefix("-") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                // Activate exactly as a tap on the magnifier would, then type.
                self.searchController.isActive = true
                self.searchController.searchBar.text = text
                self.updateSearchResults(for: self.searchController)
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
        navigationItem.titleView = tabBar
        navigationItem.largeTitleDisplayMode = .never
        // The @handle is gone from the bar, so it survives as the screen's
        // accessibility label rather than being lost with the title.
        navigationItem.backButtonTitle = "Back"
        navigationItem.accessibilityLabel = viewModel.title
    }

    /// The search controller itself; where its bar goes is `applySearchAvailability`'s job.
    private func configureSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search"
        searchController.searchBar.autocapitalizationType = .none
        searchController.hidesNavigationBarDuringPresentation = false
        // Stated rather than inherited. The clear glyph is the system's own —
        // clearing through it routes back out via `searchBar(_:textDidChange:)`
        // to `updateSearchResults`, so an emptied field restores the full list
        // by the same path typing narrows it.
        searchController.searchBar.searchTextField.clearButtonMode = .whileEditing
        // Left to UIKit deliberately. `automaticallyShowsCancelButton` defaults
        // to YES, and touching `searchBar.showsCancelButton` would flip it to
        // NO and hand us the job of showing and hiding it — which is exactly
        // the standard behaviour we want to keep. Note the affordance renders
        // as an ✕ glyph rather than the word "Cancel" under `.integratedButton`
        // placement; that is the native look for a bar-integrated search, not a
        // missing button.
        searchController.automaticallyShowsCancelButton = true
        definesPresentationContext = true
    }

    /// A failed row mutation. A toast, not an alert: the row has already
    /// rolled back to its previous state, so there is nothing for the user to
    /// dismiss or decide.
    private func render(_ result: ProfileRelationshipsViewModel.ActionResult) {
        switch result {
        case .failed(let message):
            ToastView.present(message, symbol: "exclamationmark.triangle", in: view)
        }
    }

}

private extension Array {
    /// A segmented control's selected index can be `NSNotFound` between
    /// configuration and first layout.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension ProfileRelationshipsViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        viewModel.searchQueryChanged(searchController.searchBar.text ?? "")
    }
}
