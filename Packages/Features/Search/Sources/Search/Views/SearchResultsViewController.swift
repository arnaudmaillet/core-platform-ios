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
/// # The chrome, top and bottom
///
///     navigation bar   [back] ……………………………… [query field]
///     bottom toolbar   [selector] ………………………… [filter tray]
///
/// ⚠️ REAL BAR ITEMS, AND THE COMPOSITE THEY REPLACE IS WHY. The header was one
/// `UIStackView` in `navigationItem.titleView` holding both controls, which
/// looked identical at rest and animated wrongly: a title view is ONE view to
/// UIKit, so a push snapshots it and cross-fades the picture. The individual
/// glass bubbles cannot interpolate into the destination's, because as far as
/// the bar is concerned there are no individual bubbles. Bar ITEMS do
/// interpolate, which is what every other header in this app relies on.
///
/// ⚠️ **THE SELECTOR IS NOT IN THIS BAR, AND ARITHMETIC IS WHY.** With both it
/// and the query field up there, each asking for half of what was left, the two
/// halves paved a 402pt bar EXACTLY — 120pt of fixed cost, 141 each — and iOS
/// 26 answers items that will not fit by sweeping the whole trailing group into
/// a `•••`. A pop briefly narrows the bar, so there was no margin to be had:
/// the field was cut to a 44pt glyph to save the arrangement, and the header
/// stopped showing what had been searched for. Moving the strip to the toolbar
/// buys that back — a toolbar has no item groups and no overflow control, so
/// the failure the navigation bar has is not available to it.
///
/// ⚠️ AND `leftItemsSupplementBackButton` IS FALSE NOW, where it used to be
/// load-bearing. That flag exists because `NativePopPolicy` refuses the
/// interactive edge pop when a custom leading item sits beside the back button
/// without it — which is why an earlier revision concluded the leading group
/// was unusable and reached for the title slot. With nothing in the leading
/// group the back button is the back button and the policy has nothing to
/// refuse.
///
/// ⚠️ THE SELECTOR SCROLLS WHEN IT DOES NOT FIT — `PagedTabBar`'s documented
/// behaviour. Its minimums are required, so the strip overflows and scrolls
/// rather than truncating a title, with `keepLensVisible` bringing the selected
/// tab back: it degrades by hiding a tab reachably instead of by rendering an
/// unreadable word.
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

    /// The query, shown and tappable — a `UISearchTextField` that is never
    /// edited here.
    ///
    /// ⚠️ IT LOOKS LIKE AN INPUT AND IS A DOOR. Tapping it takes the viewer
    /// BACK to the search screen with its own field already focused, rather
    /// than opening a keyboard here. The refusal happens in
    /// `textFieldShouldBeginEditing`, which is UIKit's own hook for exactly
    /// this: the field never becomes first responder, so no keyboard is ever
    /// summoned and none has to be dismissed on the way out.
    ///
    /// ⚠️ **IT WAS A GLYPH, AND THE SELECTOR IS WHY.** With both in this bar,
    /// each asking for half of what was left, the two halves paved a 402pt bar
    /// EXACTLY — 120pt of fixed cost, 141 each — and iOS 26's answer to items
    /// that will not fit is to sweep the whole trailing group into a `•••`. A
    /// pop briefly narrows the bar, so there was no margin to be had and the
    /// field had to go (edf4f78). The selector now lives in the BOTTOM toolbar,
    /// which leaves this bar holding a back button and one trailing item, and
    /// the arithmetic is no longer tight: 402 − 32 margins − 44 back − 24
    /// inter-group − 8 padding = 294pt for a field that needs nothing like it.
    private let searchField = UISearchTextField()

    /// What the field asks for: everything the bar has left beside the back
    /// button, floored at one perfect bubble.
    ///
    /// ⚠️ YIELDING, NOT REQUIRED, and the reason is the same measurement that
    /// cost the field its place the first time: a required width cannot give,
    /// and UIKit's answer to a width it cannot honour is the overflow, not a
    /// narrower control. The floor IS required — a field allowed to compress to
    /// nothing is not a control — which is the pairing that filmed clean.
    private lazy var queryWidth: NSLayoutConstraint = {
        let width = searchField.widthAnchor.constraint(
            equalToConstant: NavigationBarMetrics.itemPlatterHeight
        )
        width.priority = .defaultHigh
        return width
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
            searchField.widthAnchor.constraint(
                greaterThanOrEqualToConstant: NavigationBarMetrics.itemPlatterHeight
            )
        ])
        navigationItem.rightBarButtonItems = [UIBarButtonItem(customView: searchField)]

        // ⚠️ NO `leftItemsSupplementBackButton` ANY MORE, because there is no
        // leading custom item to supplement. That flag exists so an item that
        // REPLACES the back button cannot silently disable the interactive pop;
        // with the leading group empty the back button is the back button and
        // `NativePopPolicy` has nothing to refuse.
        navigationItem.leftItemsSupplementBackButton = false
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
        // ⚠️ NOT WHILE A TRANSITION IS RUNNING. This fires during a push and a
        // pop too, and the bar's width is not settled there — resizing an item
        // mid-flight makes UIKit re-measure the groups at a moment when the
        // destination's own items are half installed.
        guard transitionCoordinator == nil else { return }
        let wanted = Self.queryWidth(inBarOfWidth: bar.bounds.width)
        guard queryWidth.constant != wanted else { return }
        queryWidth.constant = wanted
        searchField.superview?.layoutIfNeeded()
    }

    /// Everything the bar has left beside the back button.
    ///
    /// ⚠️ A PROPORTION OF WHAT IS LEFT, NOT A NUMBER. The first version of this
    /// screen stated 150pt a side and was ten points over the budget on a 402pt
    /// bar, which UIKit answered with a `•••` — a stated width can be wrong for
    /// a device nobody tested, and that one was wrong on every one of them.
    private static func queryWidth(inBarOfWidth barWidth: CGFloat) -> CGFloat {
        // 16 a side, the back button's platter, the gap between the leading and
        // trailing groups, and the trailing platter's own inset.
        //
        // ⚠️ THESE ARE COPIES. The originals are `LeadingSelectorBudget`'s,
        // measured on iPhone 17 Pro and pinned by tests — but that type is
        // internal to DesignSystem, so a caller outside it can only restate
        // them. They are a floor, not a ceiling: the field YIELDS, so a copy
        // that has drifted low costs a narrower field and never an overflow,
        // which is the direction that stays safe. If the budget ever goes
        // public, delete these.
        //
        // ⚠️ AND THE BACK BUTTON IS CHARGED A BARE 44pt CHEVRON, which is what
        // `LeadingSelectorHost` measured beside a leading custom view: "iOS 26
        // draws the back button as a bare 44pt chevron platter". This screen
        // has no leading custom view, so if UIKit ever gives the chevron its
        // word back the field is 44pt too generous — and yields, rather than
        // overflowing.
        let claimed: CGFloat = 16 * 2 + 44 + 24 + 8
        return max(NavigationBarMetrics.itemPlatterHeight, barWidth - claimed)
    }


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

        // ⚠️ **NO WIDTH CAP HERE, AND A TOOLBAR IS WHY.** `LeadingSelectorHost`
        // exists because a UINavigationBar sweeps a leading group it cannot fit
        // into a `•••`; a toolbar has no item groups and no overflow control,
        // so that failure is not available to it. The app already hosts a wide
        // custom view in this same shared toolbar with no arithmetic at all —
        // the chat composer's sticker strip — and that is the precedent
        // followed here.
        //
        // ⚠️ BARE, THOUGH. UIKit wraps a bar item's custom view in its own
        // glass capsule wherever the item lives, so a bar carrying its own
        // backdrop draws a lens inside a lens. Same reason
        // `installLeadingSelector` sets this.
        tabBar.suppressesBackdrop = true

        // ⚠️ `toolbarItems` IS PER VIEW CONTROLLER even though the toolbar is
        // the navigation controller's, so the selector cannot leak onto another
        // screen. What IS shared is the toolbar's visibility, which is why this
        // screen still shows it on the way in and hides it on the way out.
        toolbarItems = [UIBarButtonItem(customView: tabBar), .flexibleSpace(), filter]

        // ⚠️ THE STRIP WINS THE TOUCH IT IS UNDER. Docked at the foot of the
        // screen the selector sits over a pager of scrolling grids, and a drag
        // that starts on it was scrolling the page underneath at the same time.
        // The strip is the thing the finger is on, so it takes priority.
        tabBar.addGestureRecognizer(selectorTouchProbe)
    }

    /// Reports a touch on the selector without taking it.
    ///
    /// ⚠️ **NOT `.touchDown` ON THE CONTROL, AND `PagedTabBar` BEING A
    /// `UIControl` IS THE TRAP.** The obvious spelling is the filter sheet's —
    /// `addAction(for: [.touchDown, …])`, which is how the sheet stops its own
    /// drag while a segment is being used. It cannot work here: the strip fills
    /// itself with a horizontal scroller (`delaysContentTouches = false`), so
    /// touches land in that scroller and the control's own tracking never
    /// begins. The actions would be wired, correct-looking and silent.
    ///
    /// ⚠️ AND IT MUST NOT SWALLOW WHAT IT WATCHES. `cancelsTouchesInView` is
    /// false and the delegate recognises simultaneously, so the strip still
    /// scrolls and still selects — this only observes. A recogniser added
    /// without both of those silences the control it was meant to watch, which
    /// this codebase has already paid for once: a tap with no action still
    /// prevents an ancestor's.
    private lazy var selectorTouchProbe: UILongPressGestureRecognizer = {
        let probe = UILongPressGestureRecognizer(
            target: self, action: #selector(selectorTouchChanged)
        )
        probe.minimumPressDuration = 0
        probe.cancelsTouchesInView = false
        probe.delaysTouchesBegan = false
        probe.delaysTouchesEnded = false
        probe.delegate = self
        return probe
    }()

    @objc private func selectorTouchChanged(_ probe: UILongPressGestureRecognizer) {
        switch probe.state {
        case .began, .changed:
            setPageScrollEnabled(false)
        case .ended, .cancelled, .failed:
            setPageScrollEnabled(true)
        default:
            break
        }
    }

    /// Stops the FINGER driving anything under the pager while the selector is
    /// in use, without stopping the pager itself.
    ///
    /// ⚠️ **THE PAN, NOT `isScrollEnabled`, AND THE DIFFERENCE BROKE TAB
    /// SELECTION.** The first cut set `isScrollEnabled = false` on every
    /// scroller under the pager, which reads as the same thing and is not: a
    /// disabled scroll view also ignores `setContentOffset(_:animated:)`, and
    /// that is exactly how `setActivePage` moves the pages. Measured — tapping
    /// "Media" left the content byte-identical (MAE 0), so the selector still
    /// lit the new tab and the pager never followed. Disabling the PAN
    /// recogniser takes the gesture away and leaves the programmatic move
    /// alone.
    ///
    /// ⚠️ FOUND BY WALKING, because the pager keeps its pages laid out side by
    /// side and vends none of their scrollers. The walk stops at the pager, so
    /// the strip's own scroller — which lives in the toolbar, not here — is
    /// never touched and goes on scrolling under the finger, which is the whole
    /// point.
    private func setPageScrollEnabled(_ isEnabled: Bool) {
        guard isEnabled != isPageScrollEnabled else { return }
        isPageScrollEnabled = isEnabled
        func walk(_ view: UIView) {
            (view as? UIScrollView)?.panGestureRecognizer.isEnabled = isEnabled
            view.subviews.forEach(walk)
        }
        walk(pager)
    }

    private var isPageScrollEnabled = true

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
        // ⚠️ **THE QUERY IS RE-READ HERE, AND HERE ONLY.** A refine screen
        // pushed over this one shares this screen's view model and POPS on
        // submit, so the words change while this screen is off-window and
        // nothing tells it. Assigning the field in `configureHeader` covers the
        // first appearance and no other: searching "test", refining to "test2"
        // and coming back left "test" in the bar over an answer about "test2".
        //
        // ⚠️ AND IT WAS WRITTEN INTO `viewDidLoad` BY MISTAKE, one line below a
        // `subscribe()` that appears in both methods — where it did nothing at
        // all, because `configureHeader` had already set the same value two
        // lines earlier.
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

extension SearchResultsViewController: UIGestureRecognizerDelegate {
    /// ⚠️ ALWAYS TRUE, AND THAT IS WHAT KEEPS THE PROBE A PROBE. The recogniser
    /// on the selector exists to be TOLD about a touch, not to win it; refusing
    /// simultaneous recognition would make it compete with the strip's own
    /// scroller and with its segment taps.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
