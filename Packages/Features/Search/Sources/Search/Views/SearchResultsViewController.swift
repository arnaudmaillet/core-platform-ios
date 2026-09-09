import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// A submitted search's answer, on its own screen.
///
/// # Why this is a screen and not a section
///
/// The answer used to be a third phase of the search screen's one collection
/// view — history, typeahead and results as sections of the same list. That
/// works while the answer is one kind. It stops working the moment the answer
/// is three: posts as cards, media as a grid, people as rows are three
/// LAYOUTS, and the search screen's list has exactly one.
///
/// # The header
///
/// `[back][selector]` in the LEADING group, `[query]` in the trailing one.
///
/// ⚠️ REAL BAR ITEMS, AND THE COMPOSITE THEY REPLACE IS WHY. This was one
/// `UIStackView` in `navigationItem.titleView` holding both controls, which
/// looked identical at rest and animated wrongly: a title view is ONE view to
/// UIKit, so a push snapshots it and cross-fades the picture. The individual
/// glass bubbles cannot interpolate into the destination's, because as far as
/// the bar is concerned there are no individual bubbles. Bar ITEMS do
/// interpolate, which is what every other header in this app relies on.
///
/// ⚠️ `leftItemsSupplementBackButton = true` IS LOAD-BEARING, not tidiness.
/// `NativePopPolicy` refuses the interactive edge pop when a custom leading
/// item sits beside the back button and that flag is false — which is exactly
/// why an earlier revision here concluded the leading group was unusable and
/// reached for the title slot instead. The flag is the answer that policy is
/// asking for: the system back button stays the back button, and the selector
/// beside it is a supplement.
///
/// ⚠️ THE SELECTOR SCROLLS WHEN IT DOES NOT FIT — `PagedTabBar`'s documented
/// behaviour for a bar host. Its minimums are required, so the strip overflows
/// and scrolls rather than truncating a title, with `keepLensVisible` bringing
/// the selected tab back: it degrades by hiding a tab reachably instead of by
/// rendering an unreadable word.
///
/// # The three pages
///
/// Posts and Media are the same two surfaces For You's Following and Discover
/// tabs are, and they are NOT built here: they arrive as opaque child view
/// controllers through `SearchPostSurfaceProviding`, which the composition root
/// fills from Feed. That is the rule this codebase holds to — no feature
/// package imports another feature package, and `ForYouExploreAdapter` exists
/// for exactly this reason on exactly this screen's behalf.
@MainActor
final class SearchResultsViewController: UIViewController {
    private let viewModel: SearchViewModel
    private let imagePipeline: ImagePipeline
    private let postSurfaces: (any SearchPostSurfaceProviding)?

    /// The query — a `UISearchTextField` that is never edited.
    ///
    /// ⚠️ IT LOOKS LIKE AN INPUT AND IS A DOOR. Tapping it takes the viewer
    /// BACK to the search screen with its own field already focused, rather
    /// than opening a keyboard here. That is the honest arrangement: the search
    /// screen owns asking — it has the history, the typeahead, and a field the
    /// viewer has already used once — and duplicating a lesser version of it in
    /// this header would give the same gesture two different answers depending
    /// on which screen you were standing on.
    ///
    /// A real field rather than a styled button so the two screens' headers are
    /// the same object: same capsule, same magnifier, same metrics, and no
    /// second thing to keep in step when one changes. The focus is refused at
    /// `textFieldShouldBeginEditing`, which is UIKit's own hook for exactly
    /// this — the field never becomes first responder, so no keyboard is ever
    /// summoned and dismissed.
    private let searchField = UISearchTextField()

    /// ⚠️ `.navigationTitle`, because it lives IN the bar now. That style is
    /// documented as "compact, marginless, and BARE: the navigation bar
    /// supplies the backdrop" — a `.floating` bar carries its own glass, which
    /// inside the bar's platter would draw a second lens over the first.
    private let tabBar = PagedTabBar(titles: ["Posts", "Media", "Users"], style: .navigationTitle)

    private var pager: HorizontalPagerView!

    private let peoplePage: SearchPeoplePage
    /// The Users tab, for tests that need to see what this screen actually
    /// rendered rather than what it was told.
    var peoplePageForTesting: SearchPeoplePage { peoplePage }
    private let postsPage: any SearchPostSurface
    private let mediaPage: any SearchPostSurface

    /// Called when the viewer taps the query. The pusher owns the navigation:
    /// it pops itself back into view and focuses its own field.
    var onEditQuery: (() -> Void)?

    init(
        viewModel: SearchViewModel,
        imagePipeline: ImagePipeline,
        postSurfaces: (any SearchPostSurfaceProviding)?
    ) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.postSurfaces = postSurfaces
        peoplePage = SearchPeoplePage(imagePipeline: imagePipeline)
        postsPage = postSurfaces?.makePostSurface(style: .cards)
            ?? SearchPendingSurfaceViewController(kind: .posts)
        mediaPage = postSurfaces?.makePostSurface(style: .gallery)
            ?? SearchPendingSurfaceViewController(kind: .media)
        super.init(nibName: nil, bundle: nil)
        // ⚠️ IN THE INITIALISER. A navigation controller reads this when the
        // push BEGINS, and `viewDidLoad` can run inside that same push — set
        // there it is a coin toss whether the bar goes. The screen underneath
        // hides it too, so this only keeps it hidden rather than hiding it.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureHeader()
        configurePages()
        configureToolbar()
        subscribe()
        render(viewModel.currentPhase)
        showPosts(postState(for: viewModel.currentPhase))
        #if DEBUG
        // `-search-results-tab <0|1|2>` opens on a tab. The pager is driven by
        // a swipe and the simulator injects none, so without this only the
        // first tab can ever be seen offline.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-search-results-tab"),
           index + 1 < arguments.count,
           let tab = Int(arguments[index + 1]), (0...2).contains(tab) {
            DispatchQueue.main.async { [weak self] in
                self?.tabBar.select(tab)
                self?.pager.setActivePage(tab, animated: false)
            }
        }
        // `-search-filters-open` raises the filter sheet. The tray is a toolbar
        // item and the simulator taps nothing, so without this the sheet has no
        // way to be seen offline.
        // `-search-tap-query` taps the query the way a viewer would, which is
        // the only way to reach the way BACK to the search screen offline. It
        // goes through `becomeFirstResponder` on purpose: the refusal it meets
        // in `textFieldShouldBeginEditing` is the thing being tested, so an
        // instrument calling `onEditQuery` directly would prove nothing.
        if arguments.contains("-search-tap-query") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                _ = self?.searchField.becomeFirstResponder()
            }
        }
        if arguments.contains("-search-filters-open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.presentFilters()
            }
        }
        #endif
    }

    // MARK: - Header

    private func configureHeader() {
        searchField.text = viewModel.submittedQueryText
        searchField.placeholder = "Search..."
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.returnKeyType = .search
        searchField.delegate = self

        searchField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            searchField.heightAnchor.constraint(
                equalToConstant: NavigationBarMetrics.itemPlatterHeight
            ),
            queryWidth,
            // ⚠️ THE FLOOR IS REQUIRED even though the width above is not: a
            // field allowed to compress to nothing is not a control. One
            // perfect bubble is the least it may be — the same floor
            // `LeadingSelectorItem.ceiling(bubbleWidth:)` uses for the strip.
            searchField.widthAnchor.constraint(
                greaterThanOrEqualToConstant: NavigationBarMetrics.itemPlatterHeight
            )
        ])

        // ⚠️ TRAILING FIRST, THEN THE SELECTOR. `installLeadingSelector`
        // measures the room the rest of the bar has already claimed, so the
        // field has to be in place before it is asked. Its own note says the
        // same: "add the trailing actions BEFORE calling this".
        navigationItem.rightBarButtonItems = [UIBarButtonItem(customView: searchField)]

        // ⚠️ `leftItemsSupplementBackButton` KEEPS THE INTERACTIVE POP ALIVE
        // beside a custom leading item — `NativePopPolicy` refuses the edge
        // gesture without it, which is why an earlier revision here concluded
        // the leading group was unusable and reached for the title slot.
        navigationItem.leftItemsSupplementBackButton = true
    }

    /// What the query field asks for: HALF of what the bar has left beside the
    /// back button and the selector, floored at one perfect bubble.
    ///
    /// ⚠️ A PROPORTION, NOT A NUMBER, and the first version here was a number.
    /// 150pt a side was ten points over the budget on a 402pt bar and UIKit
    /// answered with a `•••` — a stated width can be wrong for a device nobody
    /// tested, and this one would have been wrong on every one of them. Floored
    /// at the control's own height, the worst case is a bar holding three
    /// bubbles, which no device is narrower than.
    ///
    /// Restated on every layout, because a bar item's custom view is measured
    /// before it has a bar to measure against — the constraint is created with
    /// a placeholder and corrected as soon as there is a width to read.
    /// ⚠️ **NOT REQUIRED, AND FOUR ARRANGEMENTS WERE FILMED TO GET HERE.** The
    /// symptom each time was the trailing group collapsing to a `•••` for a few
    /// frames of a POP and re-expanding — a pop carries the departing screen's
    /// back-button title beside the arriving items, so the bar is briefly
    /// narrower than it settles at, and UIKit's answer to items that will not
    /// fit is an overflow.
    ///
    ///   - both halves required          → `•••`
    ///   - 48% rather than 50%           → `•••` (the transient width is
    ///                                     smaller than any share of the
    ///                                     settled one)
    ///   - field required, SELECTOR left
    ///     to absorb the shortfall       → `•••`
    ///   - field yielding                → no `•••`
    ///
    /// ⚠️ THE THIRD IS THE INTERESTING ONE, because it is the better model on
    /// paper: put the give in the control built to give — a `PagedTabBar` in a
    /// bar host caps itself and SCROLLS, a text field short of room is just a
    /// worse field. Filmed, it did not work. The selector's host re-measures on
    /// its OWN layout pass, which does not come in time; the field's constraint
    /// priority is read by the very pass that decides whether to overflow. Only
    /// one of those two is in the room when the decision is made.
    ///
    /// So the field yields, and the cost is written down where it shows: it
    /// narrows towards its bubble as the profile leaves and is back at full
    /// width by the time the bar settles. A continuous width change instead of
    /// a discrete collapse.
    private lazy var queryWidth: NSLayoutConstraint = {
        let width = searchField.widthAnchor.constraint(
            equalToConstant: NavigationBarMetrics.itemPlatterHeight
        )
        width.priority = .defaultHigh
        return width
    }()

    /// ⚠️ THE FIELD IS SIZED BEFORE THE SELECTOR IS INSTALLED, and the order is
    /// the whole fix. `installLeadingSelector` caps the strip against the room
    /// the TRAILING group is asking for AT THAT MOMENT. Installed in
    /// `viewDidLoad`, it measured a field still holding its one-bubble
    /// placeholder, handed the selector nearly the whole bar, and then the field
    /// grew to its half — two groups over the bar's width, and UIKit answered
    /// with a `•••`. Nudging the bar to re-measure afterwards did not help: the
    /// cap had already been taken.
    ///
    /// So nothing is installed until there is a real bar width to divide.
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard let bar = navigationController?.navigationBar, bar.bounds.width > 0 else { return }
        // ⚠️ NOT WHILE A TRANSITION IS RUNNING. This fires during a push and a
        // pop too, and the bar's width is not settled there — resizing an item
        // mid-flight makes UIKit re-measure the groups at a moment when the
        // destination's own items are half installed, which is the other half
        // of the `•••` flicker. The width that matters is the settled one, and
        // the next layout after the transition is where it arrives.
        guard transitionCoordinator == nil else { return }
        let wanted = NavigationBarShare.halfBesideBackButton(
            inBarOfWidth: bar.bounds.width,
            bubble: NavigationBarMetrics.itemPlatterHeight
        )
        if queryWidth.constant != wanted {
            queryWidth.constant = wanted
            searchField.superview?.layoutIfNeeded()
        }
        guard !hasInstalledSelector else { return }
        hasInstalledSelector = true
        navigationItem.installLeadingSelector(tabBar)
    }

    private var hasInstalledSelector = false

    // MARK: - Pages

    private func configurePages() {
        tabBar.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.pager.setActivePage(self.tabBar.selectedIndex, animated: true)
        }, for: .valueChanged)

        // ⚠️ THE USERS TAB HAD NO HANDLER AT ALL. `SearchPeoplePage.onSelect`
        // was declared and never assigned, so a tap on a person did nothing —
        // and "nothing" on a row that highlights and deselects under the finger
        // is indistinguishable from a screen that has stopped responding.
        //
        // A PLAIN PUSH, deliberately, and not the flight the post tabs get. A
        // person row has no picture to carry: the avatar is a 48pt disc that a
        // profile header does not open out of, and this app already reserves
        // the flight for a media surface that the destination redraws at full
        // size. `SearchViewModel.didSelectResult` is the same path the inline
        // results used before this screen existed — it records the visit and
        // routes with the identity stub the row already holds, so the profile
        // opens on a name and a face rather than on a spinner.
        peoplePage.onSelect = { [weak self] id in self?.viewModel.didSelectResult(id) }

        for page in [postsPage.viewController, mediaPage.viewController, peoplePage] {
            addChild(page)
            page.didMove(toParent: self)
        }
        pager = HorizontalPagerView(
            pages: [postsPage.viewController.view, mediaPage.viewController.view, peoplePage.view],
            initialIndex: 0
        )
        pager.translatesAutoresizingMaskIntoConstraints = false
        // ⚠️ The bar follows the SWIPE as well as the tap. A selector that only
        // moved on its own taps would sit on "Posts" while the viewer read the
        // gallery, which is the bug this channel exists to prevent.
        pager.onProgress = { [weak self] progress in self?.tabBar.setProgress(progress) }
        pager.onSettled = { [weak self] index in
            self?.tabBar.select(index)
            self?.updatePlayback()
        }

        view.addSubview(pager)
        NSLayoutConstraint.activate([
            // ⚠️ TO THE TOP OF THE VIEW, NOT THE SAFE AREA, and that is what
            // makes the header look like the app's other headers. A navigation
            // bar is translucent: it blurs whatever passes UNDER it. Pinned
            // below the safe area the pages start where the bar ends, so
            // nothing ever passes under it and the glass has nothing to work
            // with — it reads as a flat slab, which is exactly what was
            // reported. The pages' own scroll views keep their first row clear
            // through their safe-area insets, so nothing is hidden by this.
            //
            // The inbox's search results are pinned the same way for the same
            // reason, and say so in the same words.
            //
            // Measured after the change, on the Media tab:
            //
            //     UICollectionView insetTop=116.0 frameY=0.0 offsetY=-116.0
            //     safeAreaTop=116.0  pagerY=0.0
            //
            // The list starts at the top of the SCREEN and is inset by exactly
            // the bar's height, so the first row rests below it and every row
            // after passes under it. A static screenshot at the top of a list
            // cannot tell that from the flat version — the numbers can.
            pager.topAnchor.constraint(equalTo: view.topAnchor),
            pager.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - Toolbar

    /// The filter tray, bottom-trailing, in the system toolbar.
    ///
    /// ⚠️ IT MOVED OUT OF THE NAVIGATION BAR, and the bar is why. That bar now
    /// carries a back button and a full-width field; a third item would take
    /// the width straight off the query the viewer is reading. The toolbar is
    /// empty on this screen and within thumb reach, which is where a control
    /// used mid-scroll belongs.
    private func configureToolbar() {
        let filter = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            primaryAction: UIAction { [weak self] _ in self?.presentFilters() }
        )
        filter.accessibilityLabel = "Filters"
        toolbarItems = [.flexibleSpace(), filter]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // ⚠️ RE-SUBSCRIBED EVERY TIME, and this is not belt and braces.
        // `SearchViewModel`'s callbacks are single-assignment slots, and a
        // refine screen pushed over this one takes `onPhaseChange` in its own
        // `viewDidLoad` and never hands it back. Without this, coming back from
        // a refine left this screen deaf: the Users tab and the header query
        // would keep showing the OLD answer while the post tabs — driven by a
        // different callback — showed the new one. One screen, two answers.
        subscribe()
        // ⚠️ THE HEADER'S QUERY IS RE-READ, not set once. A refine screen can
        // change what was searched for while this screen sits underneath it,
        // and the field was assigned in `configureHeader` — so after a refine
        // submit the tabs showed the new answer under the OLD words.
        searchField.text = viewModel.submittedQueryText
        render(viewModel.currentPhase)
        showPosts(postState(for: viewModel.currentPhase))
        // ⚠️ SHOWN HERE AND HIDDEN ON THE WAY OUT, because a navigation
        // controller's toolbar is SHARED: left visible, it would follow the pop
        // back onto the search screen, which has no toolbar items and would
        // show an empty bar.
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // ⚠️ HERE, NOT `viewWillAppear`. The window is what
        // `updatePlayback` reads, and a screen arriving has none until it has
        // appeared — asked earlier it would decide "not visible" and leave
        // every clip frozen on the screen the viewer is looking at.
        updatePlayback()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Anything pushed over this screen — a post, a profile, a refine — gets
        // the pool. A grid under another screen holding players is the leak
        // this call exists to prevent.
        postsPage.setPlaybackActive(false)
        mediaPage.setPlaybackActive(false)
        guard isMovingFromParent else { return }
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    private func presentFilters() {
        present(SearchFilterSheetViewController.inSheet(groups: viewModel.filterGroups()) {
            [weak self] group, option in
            self?.viewModel.applyFilter(group: group, option: option)
        }, animated: true)
    }

    // MARK: - Rendering

    private func render(_ phase: SearchViewModel.Phase) {
        switch phase {
        case .results(let models):
            peoplePage.render(.results(models))
        case .loading:
            peoplePage.render(.loading)
        case .empty(let query):
            peoplePage.render(.empty(query: query))
        case .failed(let message):
            peoplePage.render(.failed(message: message))
        case .explore, .suggesting:
            // Reached only if the viewer clears the field. The answer on screen
            // is the last one submitted; it stays until they ask again.
            break
        }
    }

    /// ⚠️ THE POST TABS ARE NOT THE PEOPLE TAB'S STATE. The two searches are
    /// separate round trips with separate answers, and they disagree often:
    /// "harbour" matches two posts and nobody at all. Deriving the post tabs
    /// from the people phase showed an empty Posts tab for exactly that query.
    ///
    /// The phase is still read for LOADING and FAILED, which are properties of
    /// the request rather than of either answer.
    private func postState(for phase: SearchViewModel.Phase) -> SearchPostSurfaceState {
        switch phase {
        case .loading where viewModel.postResults.isEmpty:
            .loading
        case .failed(let message):
            .failed(message: message)
        case .explore, .suggesting:
            .loading
        case .loading, .results, .empty:
            viewModel.postResults.isEmpty
                ? .empty(query: viewModel.submittedQueryText)
                : .posts(viewModel.postResults)
        }
    }

    /// ⚠️ THE TWO TABS GET DIFFERENT SETS. Posts is every match; Media is the
    /// subset with a picture. Handing the gallery the full set drew a blank
    /// tile per text post — filmed, a grid of empty rectangles among the
    /// photographs.
    /// Claims the view model's callbacks for this screen.
    private func subscribe() {
        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onPostResultsChange = { [weak self] _ in
            guard let self else { return }
            self.showPosts(self.postState(for: self.viewModel.currentPhase))
        }
    }

    /// Exactly ONE surface plays: the tab that is showing, and only while this
    /// screen is.
    ///
    /// ⚠️ THE OTHER TABS ARE LAID OUT AND MUST BE SILENT. A pager builds every
    /// page; without this, two grids would hold players for tabs nobody is
    /// reading, out of a pool the whole app shares. For You's pager applies the
    /// same rule at the same granularity — the page at the active index, and no
    /// other.
    private func updatePlayback() {
        let active = isViewLoaded && view.window != nil
        let index = tabBar.selectedIndex
        postsPage.setPlaybackActive(active && index == 0)
        mediaPage.setPlaybackActive(active && index == 1)
    }

    private func showPosts(_ state: SearchPostSurfaceState) {
        postsPage.show(state)
        mediaPage.show(mediaState(from: state))
    }

    private func mediaState(from state: SearchPostSurfaceState) -> SearchPostSurfaceState {
        guard case .posts = state else { return state }
        let media = viewModel.mediaResults
        return media.isEmpty ? .empty(query: viewModel.submittedQueryText) : .posts(media)
    }
}

extension SearchResultsViewController: UITextFieldDelegate {
    /// ⚠️ ALWAYS FALSE, AND THE TAP IS NOT LOST. Returning false is what stops
    /// the field becoming first responder — no keyboard is summoned, so none
    /// has to be dismissed on the way out, which is the difference between this
    /// and hiding the field behind a transparent button. The gesture still
    /// arrives, and it means "let me ask again": that is the search screen's
    /// job, so it goes back there.
    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        onEditQuery?()
        return false
    }
}
