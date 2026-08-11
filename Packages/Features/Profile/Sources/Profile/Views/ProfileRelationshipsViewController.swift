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
    /// This screen's own search, with no `UISearchController` behind it.
    ///
    /// The native `.integratedButton` placement collapsed the whole leading group
    /// — back button, selector and all — into a `•••` on narrow bars, which is
    /// exactly what the inbox measured before it moved off that placement too.
    private let searchField = TracedRelationshipsSearchField()
    private lazy var searchItem = UIBarButtonItem(
        bouncingImage: UIImage(systemName: "magnifyingglass"),
        accessibilityLabel: "Search"
    ) { [weak self] in self?.presentSearch() }
    private lazy var cancelItem = UIBarButtonItem(
        title: "Cancel",
        primaryAction: UIAction { [weak self] _ in self?.dismissSearch() }
    )
    private var restingRightItems: [UIBarButtonItem] = []
    private var isSearching = false
    private static let searchFieldHeight: CGFloat = 36

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
        guard !isRestricted else {
            if isSearching { dismissSearch() }
            navigationItem.rightBarButtonItems =
                restingRightItems.filter { $0 !== searchItem }
            return
        }
        guard !isSearching else { return }
        var items = navigationItem.rightBarButtonItems ?? []
        if !items.contains(where: { $0 === searchItem }) {
            items.insert(searchItem, at: 0)
        }
        restingRightItems = items
        navigationItem.rightBarButtonItems = items
    }

    /// Morphs this header into the field, exactly as the inbox does.
    private func presentSearch() {
        guard !isSearching else { return }
        isSearching = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-search-layout-trace") {
            let start = CACurrentMediaTime()
            searchField.activatedAt = start
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { _ in
                print(String(format: "[keyboard] t=%4.0fms WillShow",
                             (CACurrentMediaTime() - start) * 1000))
            }
        }
        #endif
        tabBarController?.setTabBarHidden(true, animated: true)
        // ⚠️ The caret is HIDDEN for the length of the morph. It is drawn at the
        // text's insertion point, and that point is only final once the field has
        // its destination width — so on the way there the caret rendered mid-field
        // and slid left as the layout resolved. Nothing else in the field moves;
        // this is the one part that had to wait.
        let caretTint = searchField.tintColor
        searchField.tintColor = .clear
        morphBar(duration: 0.3) {
            self.setBarOpaque(true)
            // ⚠️ The back button goes too, so the field has the full width and
            // this header reads exactly like the inbox's. Cancel is the way out
            // while searching — and it restores the button, which restores the
            // interactive pop with it.
            self.navigationItem.setHidesBackButton(true, animated: false)
            self.navigationItem.rightBarButtonItems = [self.cancelItem]
            self.navigationItem.titleView = self.searchField
            // ⚠️ LAID OUT FIRST. A title view is installed on the bar's next
            // layout pass, and `becomeFirstResponder` on a view that is not in a
            // window yet fails silently — measured as `focusedAtMorph=false`,
            // which is the focus arriving late and the placeholder re-laying
            // itself out under the keyboard: the jump.
            self.navigationController?.navigationBar.layoutIfNeeded()

            // ⚠️ **The FIELD's own layout, not just the bar's.** Laying out the
            // bar installs the title view and gives it a frame; the field then
            // still has to place its glyph, placeholder and caret inside that
            // frame, and it was doing so on a later pass — mid-crossfade, at a
            // width it was about to leave. Measured from a screen recording of
            // the relationships header: the placeholder's box walked +14 → +23 →
            // +11 → +7 → +10 horizontally and 0 → 8 → 10 → 4 vertically before it
            // settled. Forcing the pass here means the first frame the viewer
            // sees is already the final one.
            self.searchField.setNeedsLayout()
            self.searchField.layoutIfNeeded()
            self.searchField.becomeFirstResponder()
        }
        // Restored a beat after the crossfade ends, so it appears already in
        // place rather than travelling to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            self?.searchField.tintColor = caretTint
        }
    }

    private func dismissSearch() {
        guard isSearching else { return }
        isSearching = false
        searchField.resignFirstResponder()
        searchField.text = nil
        applyQuery("")
        morphBar(duration: 0.26) {
            self.setBarOpaque(false)
            self.navigationItem.setHidesBackButton(false, animated: false)
            self.navigationItem.titleView = self.tabBar
            self.navigationItem.rightBarButtonItems = self.restingRightItems
        }
        tabBarController?.setTabBarHidden(false, animated: true)
    }

    /// The whole input contract, as on the inbox: a string.
    private func applyQuery(_ text: String) {
        viewModel.searchQueryChanged(text)
    }

    private func morphBar(duration: TimeInterval, _ change: @escaping () -> Void) {
        guard let bar = navigationController?.navigationBar else { change(); return }
        UIView.transition(with: bar, duration: duration,
                          options: [.transitionCrossDissolve, .allowUserInteraction],
                          animations: change)
    }

    /// Opaque while searching so the list does not read through the field.
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
        appearance.shadowColor = nil
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
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
                let field = self.searchField
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
                self.searchField.text = text
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
        // This screen is PUSHED, so its leading group already holds a back button,
        // and two leading items collapse into a `•••` on a narrow bar: measured on
        // the SE, back + selector took the whole group down. The inbox gets away
        // with the leading group because its selector is alone there. The title
        // slot hosts what it is given at every width, which is also where the
        // search field goes when this header morphs.
        navigationItem.titleView = tabBar
        navigationItem.largeTitleDisplayMode = .never
        // The @handle is gone from the bar, so it survives as the screen's
        // accessibility label rather than being lost with the title.
        navigationItem.backButtonTitle = "Back"
        navigationItem.accessibilityLabel = viewModel.title
    }

    /// The field itself; where the magnifier goes is `applySearchAvailability`'s job.
    private func configureSearch() {
        searchField.placeholder = "Search"
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.heightAnchor.constraint(
            equalToConstant: Self.searchFieldHeight
        ).isActive = true
        prewarmSearchField()
    }

    /// ⚠️ **Renders the field once, off screen, before it is ever presented.**
    ///
    /// A `UISearchTextField` builds its glyph, placeholder label and clear button
    /// on its first layout, and until then it has no idea how wide any of them
    /// are. On the FIRST activation that work landed mid-crossfade — the
    /// magnifier materialised part-way across the bar and slid to its place —
    /// while every activation afterwards was clean, because by then the subviews
    /// existed. Forcing the pass here means the first presentation is the second
    /// render.
    ///
    /// A window is required: a field with no window lays out, but its text
    /// metrics resolve against nothing and the pass proves less than it looks.
    private func prewarmSearchField() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: Self.searchFieldHeight))
        host.isHidden = true
        view.addSubview(host)
        searchField.translatesAutoresizingMaskIntoConstraints = true
        searchField.frame = host.bounds
        host.addSubview(searchField)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        searchField.setNeedsLayout()
        searchField.layoutIfNeeded()
        // Handed back exactly as it was found, so the title slot sizes it.
        searchField.removeFromSuperview()
        host.removeFromSuperview()
        searchField.translatesAutoresizingMaskIntoConstraints = false
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

extension ProfileRelationshipsViewController: UITextFieldDelegate {
    @objc fileprivate func searchTextChanged() {
        applyQuery(searchField.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
