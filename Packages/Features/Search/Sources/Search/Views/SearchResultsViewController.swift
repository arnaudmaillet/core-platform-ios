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

    /// The way back to asking: a magnifier, and nothing else.
    ///
    /// ⚠️ IT IS A DOOR, AND IT NO LONGER PRETENDS TO BE AN INPUT. Tapping it
    /// takes the viewer BACK to the search screen with its own field already
    /// focused, rather than opening a keyboard here. The search screen owns
    /// asking — it has the history, the typeahead, and a field the viewer has
    /// already used once — so a second, lesser field in this header would give
    /// the same gesture two different answers depending on which screen you
    /// were standing on.
    ///
    /// ⚠️ **IT WAS A `UISearchTextField` CLAIMING HALF THE BAR, AND THE HALVES
    /// LEFT NO MARGIN.** Measured on iPhone 17 Pro with `-leading-room`: a
    /// 402pt bar, 120pt of fixed costs, 141pt to each of the selector and the
    /// field — which paves the bar EXACTLY, to the point. A pop briefly
    /// narrows the bar (it carries the departing screen's back-button title
    /// beside the arriving items), and UIKit's one answer to items that will
    /// not fit is to sweep the whole group into a `•••`. Every arrangement
    /// tried bought margin somewhere and paid for it somewhere else.
    ///
    /// A glyph asks for 44pt. That is the same shape For You's header has —
    /// `[lens][selector] … [coins][search]` — and it is the arrangement the
    /// budget in `LeadingSelectorBudget` was written for: one elastic claimant,
    /// the selector, taking whatever is left and scrolling for the rest.
    ///
    /// ⚠️ THE COST, WRITTEN DOWN: the header no longer shows what was searched
    /// for. The empty states still name the query; a populated result set does
    /// not.
    private lazy var queryDoorItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"),
            style: .plain,
            target: self,
            action: #selector(editQueryTapped)
        )
        item.accessibilityLabel = "Search"
        return item
    }()

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
        // `-search-tap-query` taps the door the way a viewer would, which is
        // the only way to reach the way BACK to the search screen offline.
        if arguments.contains("-search-tap-query") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.editQueryTapped()
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
        // ⚠️ TRAILING FIRST, THEN THE SELECTOR. `installLeadingSelector`
        // measures the room the rest of the bar has already claimed, so the
        // door has to be in place before it is asked. Its own note says the
        // same: "add the trailing actions BEFORE calling this".
        navigationItem.rightBarButtonItems = [queryDoorItem]

        // ⚠️ `leftItemsSupplementBackButton` KEEPS THE INTERACTIVE POP ALIVE
        // beside a custom leading item — `NativePopPolicy` refuses the edge
        // gesture without it, which is why an earlier revision here concluded
        // the leading group was unusable and reached for the title slot.
        navigationItem.leftItemsSupplementBackButton = true
    }


    /// ⚠️ THE SELECTOR IS INSTALLED WHEN THERE IS A REAL BAR TO MEASURE, not in
    /// `viewDidLoad`. `LeadingSelectorHost` caps the strip against the room the
    /// rest of the bar claims, and takes that measurement ONCE, in
    /// `sizeToOwnContent()`, before the item is offered to UIKit — a cap
    /// applied later arrives on a view that no longer has anywhere to be. So
    /// the install waits for a bar with a width.
    ///
    /// ⚠️ NOT WHILE A TRANSITION IS RUNNING: this fires during a push and a pop
    /// too, and the bar's width is not settled there.
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard let bar = navigationController?.navigationBar, bar.bounds.width > 0 else { return }
        guard transitionCoordinator == nil else { return }
        guard !hasInstalledSelector else { return }
        hasInstalledSelector = true
        navigationItem.installLeadingSelector(tabBar)
    }

    /// The door's action, and the one the `-search-tap-query` instrument fires.
    ///
    /// ⚠️ THERE IS NO REFUSAL TO TEST ANY MORE. While the door was a field, the
    /// instrument went through `becomeFirstResponder` on purpose — the refusal
    /// in `textFieldShouldBeginEditing` was the thing being measured. A button
    /// has nothing to refuse, so the instrument invokes what a tap invokes.
    @objc private func editQueryTapped() {
        onEditQuery?()
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
