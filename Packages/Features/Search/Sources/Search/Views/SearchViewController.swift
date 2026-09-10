import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import UIKit

/// The Search tab.
///
/// **One collection view for all three phases.** The resting history, the
/// narrowing-as-you-type list and a submitted search's results are sections in
/// the same diffable data source, so moving between them is a snapshot diff
/// the rows animate through rather than a view being swapped underneath them.
///
/// ⚠️ **The search field is not in the navigation bar.** This screen is hosted
/// by a `UISearchTab`, and iOS renders that tab's field as a capsule in the
/// TAB BAR at the bottom of the screen — the navigation bar carries only the
/// title. Two things follow, and both are load-bearing below: the list runs
/// full-bleed so rows pass UNDER that capsule, with the last of them kept
/// reachable by a content inset rather than by a shorter frame (see
/// `updateBottomInsetForSearchField`); and the empty states ride
/// `keyboardLayoutGuide` so they centre in the space actually left over rather
/// than behind the keyboard.
final class SearchViewController: UIViewController {
    /// Where this screen was reached from, which decides its header and what
    /// submitting does.
    enum Mode {
        /// Pushed from the Maps or For You header: `[back][field]`, and
        /// submitting pushes the answer.
        case origin
        /// Pushed from the ANSWER, to ask again: `[field][Cancel]`, and
        /// submitting pops back onto the answer it just changed.
        ///
        /// ⚠️ Cancel is the only way out of this one. Hiding the back button
        /// is what gives the field the full width, and
        /// `ProfileRelationshipsViewController` records the consequence in the
        /// same breath: the interactive edge pop goes with the button, and
        /// comes back with it. That is a real cost, taken deliberately —
        /// the alternative is a back chevron beside a Cancel, two ways out of
        /// the same screen sitting next to each other.
        case refine
    }

    private let viewModel: SearchViewModel
    private let mode: Mode
    private let imagePipeline: ImagePipeline
    /// Filled by the composition root; `nil` in a composition without Feed —
    /// see `SearchPostSurfaceProviding`.
    private let postSurfaces: (any SearchPostSurfaceProviding)?
    /// Carried, not worn: the RESULTS screen this one builds wears the badge.
    private let wallet: WalletStore?
    private let makeWalletSheet: (@MainActor () -> UIViewController)?

    /// The field. A TRAILING BAR ITEM, like the results screen's.
    ///
    /// ⚠️ **IT WAS THE `titleView`, AND THAT IS NOT A BAR ITEM.** A title view
    /// is centred and sized to the whole slot, so it filled the bar from the
    /// chevron to the trailing margin with no platter of its own — read off
    /// `-header-bar-tree`, which showed exactly ONE platter on this screen (the
    /// back chevron) where the results screen shows four. The two screens wear
    /// the same field and the same query; they should host it the same way, and
    /// only one of them was in a bar item.
    private let searchField = UISearchTextField()

    /// The field's bar item, so the width can be re-stated as the bar changes.
    private lazy var fieldItem = UIBarButtonItem(customView: searchField)

    /// What the field is currently asking for, held so it can be re-stated —
    /// a bar item has no slot to fill, so its custom view has to say how wide
    /// it is.
    private lazy var fieldWidth: NSLayoutConstraint = {
        let constraint = searchField.widthAnchor.constraint(equalToConstant: 240)
        // ⚠️ THE FIELD IS THE THING THAT YIELDS — the same rule the results
        // screen states: both of that screen's `•••` burns were REQUIRED
        // widths, so this one is beatable and floored at a bubble.
        constraint.priority = .defaultHigh
        return constraint
    }()

    private var collectionView: UICollectionView!
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusView = EmptyStateView()

    private var dataSource: UICollectionViewDiffableDataSource<SearchSection, SearchItem>!

    /// What the visible sections are, in order — the layout asks this by index
    /// for whether a section carries a header, and the header registration
    /// asks it for which section it is titling.
    private var visibleSections: [SearchSection] = []
    /// The rows currently on screen, by item. Cells read from here rather than
    /// from the phase, so a cell dequeued after a phase change still finds
    /// what it was asked to show.
    private var recentsByID: [String: SearchRowDisplayModel] = [:]
    private var resultsByID: [ProfileID: SearchResultDisplayModel] = [:]
    private var creatorsByID: [ProfileID: ExploreCreator] = [:]

    init(
        viewModel: SearchViewModel,
        imagePipeline: ImagePipeline,
        postSurfaces: (any SearchPostSurfaceProviding)? = nil,
        wallet: WalletStore? = nil,
        makeWalletSheet: (@MainActor () -> UIViewController)? = nil,
        mode: Mode = .origin
    ) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.postSurfaces = postSurfaces
        self.wallet = wallet
        self.makeWalletSheet = makeWalletSheet
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        // ⚠️ IN THE INITIALISER, not `viewDidLoad`. A navigation controller
        // reads this when the push BEGINS, and `viewDidLoad` can run inside
        // that same push — set there it is a coin toss whether the bar goes.
        //
        // This screen is a destination now, not a tab root: it is pushed from
        // the Maps and For You headers, and the bar it would sit under belongs
        // to the screen it came from. UIKit puts that bar back on the pop; the
        // fade below is only about HOW it leaves and returns.
        //
        // ⚠️ **AND THIS SCREEN'S FLAG DECIDES THE RESULTS SCREEN'S BAR TOO.**
        // `MainTabCoordinator.syncTabBarVisibility` keeps the bar hidden while
        // ANY pushed controller on the stack asked for it — deliberately, so a
        // flagged screen with an unflagged one above it does not get the bar
        // slid back over it. So `-search-results-tab-bar` has to reach here as
        // well: with this one still flagged, the results screen un-setting its
        // own flag and calling `setTabBarHidden(false)` was undone by the next
        // reconciliation, and the band sat at the foot with no bar under it.
        hidesBottomBarWhenPushed = !SearchResultsViewController.wantsTabBar
        #if DEBUG
        installKeyboardTraceIfRequested()
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    #if DEBUG
    /// `-search-layout-trace`: how long the keyboard takes to arrive, timed
    /// from the moment this screen is BUILT — which is the moment the route
    /// fires, one line before the push.
    ///
    /// ⚠️ The push's own animation is inside that number, which is the whole
    /// reason to measure it here rather than from `viewDidAppear`: the question
    /// is what the viewer waits through between tapping a magnifier and being
    /// able to type, and an animated push spends its duration inside that wait.
    private func installKeyboardTraceIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-search-layout-trace") else { return }
        let start = CACurrentMediaTime()
        for name: Notification.Name in [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification
        ] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { note in
                print(String(format: "[search-keyboard] t=%4.0fms %@",
                             (CACurrentMediaTime() - start) * 1000,
                             note.name.rawValue.replacingOccurrences(of: "UIKeyboard", with: "")))
            }
        }
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        view.backgroundColor = .systemBackground
        configureSearchAffordance()
        configureCollectionView()
        configureStatusViews()

        viewModel.onPhaseChange = { [weak self] phase in
            self?.render(phase)
        }
        viewModel.onQueryTextChange = { [weak self] text in
            // Recorded as already reported BEFORE the assignment: setting the
            // field re-enters `updateSearchResults`, and without this the
            // screen would narrow the history for the very query it is in the
            // middle of searching for.
            self?.lastReportedQuery = text
            self?.setFieldText(text)
        }
        // ⚠️ ONLY THE ORIGIN SCREEN RESETS TO THE HISTORY. A refine screen
        // shares its view model with the answer it was pushed over, so
        // `showExplore()` here would cancel that screen's in-flight search and
        // drive the shared phase to `.explore` — which the results screen maps
        // to a spinner, so a post answer landing while the refine screen is up
        // would flip the Posts tab back to loading. The refine branch of
        // `configureSearchAffordance` has already put the query in and reported
        // it; resetting straight afterwards would undo that too.
        if case .origin = mode { viewModel.showExplore() }

        #if DEBUG
        applyDebugArguments()
        #endif
    }

    /// ⚠️ **AUTO-FOCUS IS BACK, AND THE REASON IT WAS REMOVED NO LONGER
    /// HOLDS.** It was dropped because the keyboard covers roughly half the
    /// screen, so a viewer who selected the Search TAB had the two sections
    /// that tab existed to show hidden before they had done anything.
    ///
    /// This is not a tab any more. It is reached by tapping a magnifier in the
    /// Maps or For You header — a gesture that already says "I want to
    /// search" — so opening in the state that gesture asked for costs nothing
    /// and saves a tap. The suggestions are one keyboard-dismiss away, which is
    /// the opposite of the old trade rather than a repeat of it.
    ///
    private var hasClaimedField = false

    // ⚠️ THE HISTORY OF THIS BAR, kept because it is the reason it looks
    // nothing like a `UISearchController`. A search controller owns its own
    // activation animation, and on iOS 26 it collapses the active field into
    // the navigation bar's glass PLATTER — which is not the app's to remove,
    // resize or opt out of. Measured frame by frame through every placement
    // (`.stacked`, `.integrated`, `.integratedButton`, `.integratedCentered`),
    // with and without a placeholder, with the text field hidden and with the
    // search bar hidden: the platter's width animation survives all of it.
    // What removed the artefact was removing the resting state, not fighting
    // the animation.

    /// ⚠️ AS SOON AS THE SCREEN IS STILL — which, since this route stopped
    /// animating its push, is immediately.
    ///
    /// The history is worth keeping because both ends of it were tried on
    /// screen. `viewWillAppear` is the earliest a first responder can be
    /// claimed: a view must be in a window, and the navigation controller has
    /// put this one into the transition's container by then. Claimed there,
    /// the keyboard rises WHILE the push slides — two animations at once, and
    /// judged worse than a keyboard arriving on a settled page. Claimed after
    /// the push, the keyboard is a whole transition late: measured from the
    /// route firing, `WillShow` at 872–1055ms and `DidShow` at 1281–1475ms
    /// over four runs.
    ///
    /// What actually fixed it was removing the push animation rather than
    /// moving the claim (`RouteResolver`'s `.search` case): same code, same
    /// ordering, `WillShow` at 330–471ms and `DidShow` at 773–887ms.
    ///
    /// ⚠️ THE `isAnimated` AND RETURN-VALUE GUARDS ARE NOT BELT AND BRACES.
    /// `animate(alongsideTransition:)` DROPS its block, returning false, when
    /// the coordinator cannot queue it — and the coordinator is not
    /// necessarily nil on an unanimated push. Trusting `if let` alone would
    /// mean the completion never fires and the keyboard NEVER appears, which
    /// reads as a broken screen rather than as a rejected design. The pattern
    /// is `ProfileViewController.alongsideTransition`'s, for the same reason.
    ///
    /// ⚠️ ONCE. `viewDidAppear` fires again when anything this screen pushed
    /// pops back, and re-claiming the keyboard there would fight a viewer who
    /// has just come back to read a result.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasClaimedField else { return }
        hasClaimedField = true
        let claim = { [weak self] in self?.searchField.becomeFirstResponder() }
        if let coordinator = transitionCoordinator, coordinator.isAnimated,
           coordinator.animate(alongsideTransition: nil, completion: { _ in claim() }) {
            return
        }
        claim()
    }

    /// ⚠️ THIS SCREEN NO LONGER TOUCHES THE BOTTOM CHROME, and the three hooks
    /// that did are gone. It hid the bar by fading it out here and faded it
    /// back in on return — machinery from when Search was a TAB ROOT that
    /// pushed profiles over itself.
    ///
    /// It is a pushed destination now (`hidesBottomBarWhenPushed`), so UIKit
    /// owns the bar for the whole visit: it goes on the push and comes back on
    /// the pop, and anything Search pushes is pushed over a screen that already
    /// has no bar.
    ///
    /// Leaving the fade in place did real damage, and the guard could not catch
    /// it: `topViewController !== self` was written to mean "something was
    /// pushed OVER me", but it is equally true while this screen is being
    /// POPPED — so the pop faded the chrome to alpha 0 on its way out and the
    /// map underneath came back with an invisible tab bar. Filmed.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-search-layout-audit") { dumpBottomChrome() }
        #endif
    }

    /// The view holding the bottom chrome — the bar, its platters, and the
    /// search capsule.
    ///
    /// ⚠️ **Not `tabBarController.tabBar`.** On iOS 26 the tab-hosted search
    /// field is a SIBLING of the bar, not a child of it: the hierarchy is
    /// `_UITabBarContainerView` → { `UITabBar`, `_UITabHostedSearchContainer`,
    /// a loose platter }. Fading the bar was tried first and moved nothing on
    /// screen, because the capsule was never inside it. The container is the
    /// nearest view that holds all three.
    ///
    /// Reached by relationship rather than by class name, and guarded: if a
    /// future layout ever makes the bar a direct child of the controller's own
    /// view, fading that would fade the whole screen, so the bar itself is the
    /// fallback.
    private var tabBarChrome: UIView? {
        guard let tabBar = tabBarController?.tabBar else { return nil }
        guard let container = tabBar.superview, container !== tabBarController?.view else {
            return tabBar
        }
        return container
    }


    #if DEBUG
    /// `-search-layout-audit`: names every view sitting in the bottom band at
    /// push time. The search capsule is drawn by iOS somewhere in the tab bar's
    /// hierarchy and is not `tabBarController.tabBar`, so finding out what to
    /// animate means asking rather than assuming.
    private func dumpBottomChrome() {
        guard let window = view.window, let root = tabBarController?.view else { return }
        let band = window.bounds.height - 140
        func walk(_ view: UIView, depth: Int) {
            let frame = view.convert(view.bounds, to: window)
            if frame.maxY > band, frame.height > 8, frame.width > 40 {
                print(String(
                    format: "[chrome] %@%@ frame=%@ alpha=%.2f hidden=%@",
                    String(repeating: "  ", count: depth), String(describing: type(of: view)),
                    NSCoder.string(for: frame), view.alpha, view.isHidden ? "y" : "n"
                ))
            }
            view.subviews.forEach { walk($0, depth: depth + 1) }
        }
        walk(root, depth: 0)
    }
    #endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBottomInsetForSearchField()
    }

    /// Keeps the last row reachable while the list runs full-bleed underneath
    /// the search field and the keyboard.
    ///
    /// **The field is not in this view hierarchy at all.** `UISearchTab`
    /// mirrors the search controller into a capsule it draws in the tab bar;
    /// The field lives in the navigation bar's title slot, so its own window is
    /// so the capsule's position cannot be measured — only its height, which
    /// the bar still reports because it is the object UIKit is mirroring.
    ///
    /// **This is the EXTRA inset, on top of the safe area.** The scroll view
    /// adjusts for the safe area by itself, and at rest the safe area already
    /// covers the tab-bar band the capsule is drawn in — so at rest the extra
    /// is zero, and rows scroll under the glass exactly as far as the safe
    /// area lets them come back out. Raise the keyboard and neither the safe
    /// area nor the guide accounts for the capsule any more: the guide stops
    /// at the top of the KEYBOARD, and the capsule floats above that. What is
    /// added is therefore the keyboard's own overhang past the resting bottom,
    /// plus the capsule sitting on top of it.
    private func updateBottomInsetForSearchField() {
        let restingBottom = view.bounds.height - view.safeAreaInsets.bottom
        let keyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
        let keyboardIsUp = keyboardTop < restingBottom - 1
        let inset = keyboardIsUp
            ? (restingBottom - keyboardTop) + searchField.bounds.height
            : 0
        // Guarded: assigning an inset lays out again, and an unguarded
        // assignment here would be a layout loop.
        guard abs(collectionView.contentInset.bottom - inset) > 0.5 else { return }
        collectionView.contentInset.bottom = inset
        collectionView.verticalScrollIndicatorInsets.bottom = inset
        #if DEBUG
        // `-search-layout-audit`: the numbers behind the reservation, since
        // "the field was accounted for" and "the guard bailed out and nothing
        // happened" look identical in a screenshot.
        if ProcessInfo.processInfo.arguments.contains("-search-layout-audit") {
            print(String(
                format: "[search-layout] kbTop=%.1f restingBottom=%.1f safeBottom=%.1f keyboardUp=%@ extraInset=%.1f adjusted=%.1f",
                keyboardTop, restingBottom, view.safeAreaInsets.bottom,
                keyboardIsUp ? "yes" : "no", inset, collectionView.adjustedContentInset.bottom
            ))
        }
        #endif
    }

    /// The last text the view model was told about.
    ///
    /// ⚠️ **`updateSearchResults` is not "the viewer typed".** UIKit also
    /// calls it when the field becomes or stops being first responder, and
    /// with auto-focus on, that lands right after a search has already
    /// returned: the results were replaced by the narrowed history a beat
    /// after arriving, for a query nobody re-typed. Comparing against what was
    /// last reported is what makes this a text-CHANGE callback.
    private var lastReportedQuery: String?

    // MARK: - Setup

    /// The bar, which has ONE state: `[ back ][ field ———————————————— ]`.
    ///
    /// ⚠️ NO `UISearchController`, AND NOW NO SWAP EITHER.
    ///
    /// A search controller owns its own activation animation: on iOS 26 it
    /// collapses the active field into the navigation bar's glass PLATTER, and
    /// that platter is not this app's to remove, resize or opt out of. Measured
    /// frame by frame through every placement (`.stacked`, `.integrated`,
    /// `.integratedButton`, `.integratedCentered`), with and without a
    /// placeholder, with the field hidden and with the bar hidden: the
    /// platter's width animation survives all of it, and the closing reads as a
    /// wide empty capsule crossing the bar.
    ///
    /// `MessagesInboxViewController` avoided that by swapping the bar itself
    /// and dissolving between a resting magnifier and a searching field. This
    /// screen went one step further and has no resting state at all: it IS the
    /// search, so the field is simply always there. The magnifier that opens it
    /// lives on the Maps and For You headers, which is where the choice to
    /// search is actually made.
    ///
    /// The closing animation that took a dozen attempts to tame therefore does
    /// not exist here any more. There is nothing to close: the way out is the
    /// back button.
    private func configureSearchAffordance() {
        searchField.placeholder = "Search..."
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.returnKeyType = .search
        // Stated rather than inherited: clearing through the system glyph
        // routes back out through `searchTextChanged`, so an emptied field
        // restores the history by the same path typing narrowed it.
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        // ⚠️ A BARE `UISearchTextField`, not a `UISearchBar` — the inbox's note
        // verbatim, and for the same reason: a search bar carries its own
        // chrome (a background, its own layout margins, a field inset within
        // them) and sits the input off the back button's centre line whatever
        // the title slot does. A bare field IS the input, so it centres on the
        // slot's axis, which is the axis UIKit centres a bar item on.
        searchField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            searchField.heightAnchor.constraint(equalToConstant: Self.fieldHeight),
            fieldWidth,
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.fieldHeight)
        ])
        // ⚠️ THE TRAILING SLOT IS EMPTY UNTIL THERE ARE RESULTS, and it has
        // now been wrong twice in the other direction.
        //
        // First it held a "Search" button, which did what the keyboard's own
        // Search key already did on a screen that opens with that keyboard up.
        // Then it held the filter tray permanently — but the tray carries ONE
        // dimension (the only one `search.v1` can express; see gap §19), and a
        // one-line menu is not worth a permanent seat over a screen that is
        // usually showing a history and a keyboard.
        //
        navigationItem.titleView = nil
        switch mode {
        case .origin:
            // ⚠️ NOTHING TRAILING, AND THE TRAY THAT WAS HERE IS NOT MISSING.
            // It moved to the results screen's TOOLBAR, because that is the
            // only screen with an answer to filter — this one shows a history
            // and a typeahead, and neither has an order.
            // `[0]` IS THE SCREEN EDGE, so one item renders hard against it —
            // the same place the results screen's field sits.
            navigationItem.rightBarButtonItems = [fieldItem]
        case .refine:
            // ⚠️ THE FIELD OPENS CARRYING THE QUERY. This screen exists to
            // change an answer that already exists, so starting empty would
            // make "adjust one word" mean "type the whole thing again" — and
            // the query is right there in the header the viewer just tapped.
            //
            // Reported as typed, through the same path a keystroke takes, so
            // the list underneath is the typeahead for what is in the field
            // rather than a history that disagrees with it.
            setFieldText(viewModel.submittedQueryText)
            lastReportedQuery = viewModel.submittedQueryText
            viewModel.queryChanged(viewModel.submittedQueryText)

            // `[ field ————————————————— ][ Cancel ]`, which is the inbox's
            // searching bar and the relationship lists', in that order and for
            // the same reason: the field wants the width, and Cancel is the way
            // back to what it is refining.
            navigationItem.setHidesBackButton(true, animated: false)
            // `[0]` IS THE SCREEN EDGE, so Cancel leads this array to render
            // TRAILING of the field: `[ field ][ Cancel ]`.
            navigationItem.rightBarButtonItems = [
                UIBarButtonItem(
                    title: "Cancel",
                    primaryAction: UIAction { [weak self] _ in
                        guard let self else { return }
                        // ⚠️ RESTORES BEFORE IT POPS. This screen shares its
                        // view model with the answer underneath, so the typing
                        // that happened here has already driven the phase to
                        // `.suggesting` — a typeahead, on a screen whose whole
                        // content is an answer. Cancelling means "forget I
                        // asked", and forgetting has to include putting the
                        // answer back.
                        self.viewModel.restoreSubmittedAnswer()
                        self.navigationController?.popViewController(animated: false)
                    }
                ),
                fieldItem
            ]
        }
        applyFieldWidth()
    }

    /// The field takes what the bar has left.
    ///
    /// ⚠️ A PROPORTION OF WHAT IS LEFT, NOT A NUMBER — the rule the results
    /// screen learned the hard way: it stated 150pt a side and was ten points
    /// over on a 402pt bar, which UIKit answered with a `•••`. The arithmetic
    /// is that screen's, reused rather than restated, because a second copy of
    /// a measured budget is a second thing to drift.
    private func applyFieldWidth() {
        guard let bar = navigationController?.navigationBar, bar.bounds.width > 0 else { return }
        guard transitionCoordinator == nil else { return }
        // In `.refine` the back button is hidden and Cancel takes a platter of
        // its own; in `.origin` there is nothing beside the field at all.
        let sibling: CGFloat
        switch mode {
        case .origin:
            sibling = 0
        case .refine:
            sibling = navigationItem.rightBarButtonItems?
                .first { $0 !== fieldItem }?
                .customView?.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
                ?? NavigationBarMetrics.itemPlatterHeight * 2
        }
        let wanted = SearchResultsViewController.queryWidth(
            inBarOfWidth: bar.bounds.width,
            trailingSiblingWanted: sibling,
            // Refine hides the chevron, and charging one that is not there is
            // what left a hole at the leading edge.
            hasBackButton: !navigationItem.hidesBackButton
        )
        guard fieldWidth.constant != wanted else { return }
        fieldWidth.constant = wanted
        searchField.superview?.layoutIfNeeded()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        applyFieldWidth()
    }


    /// ⚠️ **Submitting is what fills the list.** Typing only narrows the
    /// history — `queryChanged` moves the view model to `.suggesting`, which is
    /// autocompletion over what has been searched before. The people search
    /// itself runs on submit, and the results replace the suggestions in the
    /// same collection view, through the same diffable data source.
    ///
    /// So there is nothing to push and nothing to clear by hand: the
    /// suggestions go because the snapshot that replaces them is the results
    /// snapshot.
    private func submitCurrentQuery() {
        let text = searchField.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // ⚠️ THE KEYBOARD GOES BEFORE THE PUSH, not after. With no push
        // animation the destination arrives instantly, so a keyboard dismissed
        // afterwards would be sliding down under a screen that is already
        // there.
        searchField.resignFirstResponder()
        viewModel.submitQuery(text)
        switch mode {
        case .origin:
            showResults()
        case .refine:
            // ⚠️ POPS RATHER THAN PUSHING A SECOND ANSWER. This screen and the
            // results screen underneath share ONE view model, so submitting has
            // already changed the answer that is down there — pushing a fresh
            // results screen would stack two views of the same state, and going
            // back would walk through spellings the viewer abandoned. That
            // property is why the answer was given its own screen at all.
            navigationController?.popViewController(animated: false)
        }
    }

    /// ⚠️ UNANIMATED, and the POP is untouched by that. `animated:` describes
    /// one transition; nothing on the view controller records it. The back
    /// button always pops animated, and the edge gesture's begin is decided by
    /// `NativePopPolicy` — neither reads how the push was drawn. So the answer
    /// arrives as a cut and leaves as a slide, which is what was asked for.
    ///
    /// ⚠️ ONE SCREEN, NOT A STACK OF THEM. Asking again from the results
    /// screen's own field re-runs in place; only a submit made HERE pushes.
    /// Otherwise a viewer refining a query three times would have three
    /// answers to swipe back through, each to a spelling they abandoned.
    private func showResults() {
        let results = SearchResultsViewController(
            viewModel: viewModel,
            imagePipeline: imagePipeline,
            postSurfaces: postSurfaces,
            wallet: wallet,
            makeWalletSheet: makeWalletSheet
        )
        // ⚠️ UNANIMATED BOTH WAYS ON THIS ONE PATH. The ordinary back button
        // still slides — that is UIKit's and it is right, because leaving an
        // answer is a departure. Tapping the QUERY is not a departure: it is
        // the same field the viewer is already looking at, and animating a
        // slide between two headers that differ by one control reads as a
        // glitch rather than as travel.
        // ⚠️ ASKING AGAIN PUSHES A FRESH SCREEN RATHER THAN POPPING TO THIS
        // ONE. It used to pop back here, which worked but meant this screen had
        // to survive underneath the answer for the whole visit — and it is the
        // screen Back would then land on, which is not where Back belongs (see
        // the stack replacement below). A refine screen is built on demand,
        // shares this screen's view model so the filters and the history carry
        // over, and pops itself when it is done.
        results.onEditQuery = { [weak results, viewModel, imagePipeline, postSurfaces] in
            guard let results else { return }
            let refine = SearchViewController(
                viewModel: viewModel,
                imagePipeline: imagePipeline,
                postSurfaces: postSurfaces,
                mode: .refine
            )
            results.navigationController?.pushViewController(refine, animated: false)
        }

        // ⚠️ THIS SCREEN LEAVES THE STACK AS THE ANSWER ARRIVES. Back on the
        // results screen has to reach the ORIGIN — the map or For You — not the
        // search screen: a viewer who has an answer is done asking, and making
        // them walk back through the question is a step nobody wants.
        //
        // ⚠️ THE VIEW MODEL SURVIVES THIS, and that is the load-bearing part.
        // The results screen holds it with a `let`, so it is retained by the
        // screen that is staying rather than by the one that is going. A refine
        // screen built later is handed the same instance, which is what keeps
        // the recent history, the sort and the scope continuous across a
        // question the viewer asks twice.
        guard let navigation = navigationController else { return }
        var stack = navigation.viewControllers
        stack.removeAll { $0 === self }
        stack.append(results)
        navigation.setViewControllers(stack, animated: false)
    }

    /// ⚠️ KEPT AS ITS OWN METHOD WITH ONE CALLER. It reads like something to
    /// inline back into `textFieldShouldReturn` now that the bar's button is
    /// gone — but the debug seeder (`-search-submit`) is the second caller, and
    /// it exists precisely so the instrument runs the viewer's path rather than
    /// poking the view model behind it.

    /// The one way to write the field programmatically. A viewer typing routes
    /// through `searchTextChanged`; assigning `searchField.text` raises no
    /// editing event, so anything that has to follow the text goes here rather
    /// than beside each assignment.
    private func setFieldText(_ text: String) {
        searchField.text = text
    }

    /// The field's height: the bar's own glass platter, from
    /// `NavigationBarMetrics.itemPlatterHeight`.
    ///
    /// ⚠️ MEASURED TWICE, and the first measurement was wrong. It started at
    /// 36 (the inbox's constant), then went to 40 off a column profile through
    /// a screenshot — a technique that reads whatever the anti-aliased capsule
    /// edge happens to give at the sampled column. Walking the view hierarchy
    /// instead names the view and its exact bounds: `PlatterGlassView` is
    /// 44.0pt. The screenshot was measuring the pill's rounded end.
    private static let fieldHeight = NavigationBarMetrics.itemPlatterHeight

    /// ⚠️ NOT "the viewer typed" on its own. The field also fires this when it
    /// is cleared programmatically, so the last reported text is compared
    /// rather than trusted — that comparison is what makes this a text-CHANGE
    /// callback, and it is what stopped a returning search being replaced by
    /// the narrowed history a beat after it arrived.
    @objc private func searchTextChanged() {
        report(query: searchField.text ?? "")
    }

    private func report(query text: String) {
        guard text != lastReportedQuery else { return }
        lastReportedQuery = text
        viewModel.queryChanged(text)
    }


    private func configureCollectionView() {
        let layout = ExploreLayout.make { [weak self] index in
            self?.visibleSections[safe: index]?.title != nil
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        // ⚠️ **Full bleed, all four edges.** It used to end at
        // `keyboardLayoutGuide.top`, which at rest is the top of the tab bar —
        // so the list stopped in a hard line above the search capsule and the
        // glass had nothing passing under it. A floating bar is only floating
        // if content goes beneath it. What keeps the last row reachable is the
        // INSET, not a shorter frame — see `updateBottomInsetForSearchField`.
        collectionView.constrain(in: view) { parent in
            collectionView.topAnchor.constraint(equalTo: parent.topAnchor)
            collectionView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            collectionView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            collectionView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        }

        // The SAME cell the Suggestions and results sections use. A remembered
        // person and a suggested person are the same person, and the screen
        // used to draw them differently — a 48pt avatar in one section and a
        // 22pt glyph in the other.
        let rowRegistration = UICollectionView.CellRegistration<PersonListCell, String> {
            [weak self] cell, _, id in
            guard let self, let model = self.recentsByID[id] else { return }
            cell.configure(
                with: model.rowContent,
                // Only the history is the viewer's to forget; a completion is
                // not remembered in the first place.
                onDelete: model.isRemovable ? { [weak self] in self?.viewModel.didDeleteRecent(id) } : nil
            )
            self.loadAvatar(model.avatarURL, into: cell, stillShowing: .row(id))
        }

        let seeMoreRegistration = UICollectionView.CellRegistration<SeeMoreCell, Int> {
            cell, _, hiddenCount in
            cell.configure(hiddenCount: hiddenCount)
        }

        let resultRegistration = UICollectionView.CellRegistration<PersonListCell, ProfileID> {
            [weak self] cell, _, id in
            guard let self, let model = self.resultsByID[id] else { return }
            cell.configure(with: model.rowContent)
            self.loadAvatar(model.avatarURL, into: cell, stillShowing: .result(id))
        }

        // The SAME row the results list uses, and the compose picker, and the
        // inbox's search. A creator and a search hit are both a person, and a
        // screen that drew them differently would be saying they are not.
        let suggestedRegistration = UICollectionView.CellRegistration<PersonListCell, ProfileID> {
            [weak self] cell, _, id in
            guard let self, let creator = self.creatorsByID[id] else { return }
            cell.configure(with: PersonRowContent(
                displayName: creator.displayName,
                handle: creator.handle,
                monogram: creator.monogram,
                context: creator.context
            ))
            self.loadAvatar(creator.avatarURL, into: cell, stillShowing: .suggested(id))
        }

        let suggestedSkeletonRegistration =
            UICollectionView.CellRegistration<PersonSkeletonCell, Int> { cell, _, index in
                cell.configure(at: index)
            }

        // A plain list pins its headers, so rows pass DIRECTLY under this one.
        // The pill inside carries its own glass, and its clear background is
        // what lets the rows show through around it.
        let headerRegistration = UICollectionView.SupplementaryRegistration<ExploreSectionHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            // Captured by SECTION, not by index path: the header is reused and
            // its index path is only valid for this configure pass, whereas
            // the section it names survives the snapshots that reshuffle rows
            // beneath it.
            let section = self?.visibleSections[safe: indexPath.section]
            header.configure(
                title: section?.title,
                actionTitle: section?.actionTitle,
                leadsList: indexPath.section == 0
            )
            header.onAction = { [weak self] in
                guard section == .recent else { return }
                self?.viewModel.didClearRecents()
            }
        }

        dataSource = UICollectionViewDiffableDataSource<SearchSection, SearchItem>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .row(let id):
                collectionView.dequeueConfiguredReusableCell(
                    using: rowRegistration, for: indexPath, item: id
                )
            case .seeMoreRecents(let hiddenCount):
                collectionView.dequeueConfiguredReusableCell(
                    using: seeMoreRegistration, for: indexPath, item: hiddenCount
                )
            case .result(let id):
                collectionView.dequeueConfiguredReusableCell(
                    using: resultRegistration, for: indexPath, item: id
                )
            case .suggested(let id):
                collectionView.dequeueConfiguredReusableCell(
                    using: suggestedRegistration, for: indexPath, item: id
                )
            case .suggestedSkeleton(let index):
                collectionView.dequeueConfiguredReusableCell(
                    using: suggestedSkeletonRegistration, for: indexPath, item: index
                )
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration, for: indexPath
            )
        }
    }

    /// Fills a creator row's disc, if the corpus carried a picture.
    ///
    /// Cache-first and synchronous when it can be: a warm avatar set inside
    /// the cell registration never shows the monogram at all, where an
    /// unconditional `Task` would flash initials for a frame on every scroll.
    ///
    /// The task is keyed by the row's own identity rather than held: cells are
    /// recycled, and by the time a slow load returns the cell may be showing
    /// someone else. Re-reading the item at completion is what keeps the wrong
    /// face off the right row.
    private func loadAvatar(_ url: URL?, into cell: PersonListCell, stillShowing item: SearchItem) {
        guard let url else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            return cell.setAvatarImage(cached)
        }
        Task { [weak self, weak cell] in
            guard let image = try? await self?.imagePipeline.image(for: url) else { return }
            guard let self, let cell,
                  let indexPath = self.collectionView.indexPath(for: cell),
                  self.dataSource.itemIdentifier(for: indexPath) == item
            else { return }
            cell.setAvatarImage(image)
        }
    }

    private func configureStatusViews() {
        spinner.hidesWhenStopped = true
        spinner.constrain(in: view) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

        statusView.isHidden = true
        // The same keyboard bound the list has: `EmptyStateView` centres its
        // column in whatever space it is given, and the space actually left
        // over is what it should centre in.
        statusView.constrain(in: view) { parent in
            statusView.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            statusView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            statusView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            statusView.bottomAnchor.constraint(equalTo: parent.keyboardLayoutGuide.topAnchor)
        }
    }

    // MARK: - Render

    private func render(_ phase: SearchViewModel.Phase) {
        switch phase {
        case .explore(let model):
            spinner.stopAnimating()
            recentsByID = Dictionary(uniqueKeysWithValues: model.recents.map { ($0.id, $0) })
            creatorsByID = Dictionary(
                model.trending.creators.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
            )
            apply(exploreSnapshot(model))
            if model.isEmpty {
                showStatus(
                    symbolName: "magnifyingglass",
                    title: "Find people",
                    subtitle: "Search by name or @handle. What you search for shows up here."
                )
            } else {
                hideStatus()
            }

        case .suggesting(let query, let rows):
            spinner.stopAnimating()
            recentsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            apply(suggestionsSnapshot(rows))
            if rows.isEmpty {
                // Not a failure, and the wording has to say so: nothing has
                // been searched for yet. This is also where the screen teaches
                // that searching is something you DO, since the flow is
                // submit-driven and nothing happens while you type.
                // ⚠️ "ON THE KEYBOARD", since the bar's Search button was
                // deleted. It was the obvious thing this sentence pointed at
                // for exactly one round; the keyboard's return key still reads
                // "Search", and now it is the only thing that does.
                showStatus(
                    symbolName: "return",
                    title: "Press Search",
                    subtitle: "Press Search on the keyboard to look for “\(query)”."
                )
            } else {
                hideStatus()
            }

        case .loading:
            spinner.startAnimating()
            hideStatus()

        case .results(let models):
            spinner.stopAnimating()
            resultsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            apply(resultsSnapshot(models))
            // ⚠️ AN EMPTY SCOPE IS NOT AN EMPTY SEARCH, and the two must not
            // wear the same words. `.empty` means the query matched nothing —
            // "Nothing matched X. Try different words." Reaching zero rows from
            // a full answer means the FILTER emptied it, and telling the viewer
            // to try different words would blame the query for a control they
            // set themselves.
            if models.isEmpty {
                showStatus(
                    symbolName: "line.3.horizontal.decrease",
                    title: "Nothing in this scope",
                    subtitle: "The search found people, but none of them are in "
                        + "the scope you picked. Widen it to see the rest."
                )
            } else {
                hideStatus()
            }

        case .empty(let query):
            spinner.stopAnimating()
            apply(NSDiffableDataSourceSnapshot<SearchSection, SearchItem>())
            // ⚠️ NOT "no people", and not a `person.slash` either. This screen
            // is the app's ONE search: profiles are what `search.v1` answers
            // for it today, but posts, places and tags are the same box and the
            // same submit, and copy that names one kind would have to be
            // rewritten the day a second kind arrives — or, worse, would read
            // as "there are no PEOPLE called that" to someone who was looking
            // for a place.
            //
            // ⚠️ It also does not promise what is not wired. The request is
            // `entityTypes = [.profile]` (`SearchRepository`), so a subtitle
            // listing posts and locations would be a lie the viewer can catch.
            // Type-NEUTRAL is the honest register: it is true now and stays
            // true when the other kinds land.
            showStatus(
                symbolName: "magnifyingglass",
                title: "No results",
                subtitle: "Nothing matched “\(query)”. Try different words."
            )

        case .failed(let message):
            spinner.stopAnimating()
            apply(NSDiffableDataSourceSnapshot<SearchSection, SearchItem>())
            showStatus(symbolName: "exclamationmark.triangle", title: "Couldn't search", subtitle: message)
        }
    }

    // MARK: - Snapshots

    private func exploreSnapshot(
        _ model: ExploreDisplayModel
    ) -> NSDiffableDataSourceSnapshot<SearchSection, SearchItem> {
        var snapshot = NSDiffableDataSourceSnapshot<SearchSection, SearchItem>()
        if !model.recents.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems(model.recents.map { .row($0.id) }, toSection: .recent)
            if model.showsMoreRecentsRow {
                snapshot.appendItems([.seeMoreRecents(model.hiddenRecentCount)], toSection: .recent)
            }
        }

        switch model.trending {
        case .unavailable, .failed:
            // No section at all. A suggestions list that failed is not worth
            // a row of apology on a screen whose search still works.
            break
        case .loading:
            snapshot.appendSections([.suggestions])
            snapshot.appendItems(
                (0..<Self.suggestedSkeletonCount).map { .suggestedSkeleton($0) }, toSection: .suggestions
            )
        case .loaded(let creators):
            guard !creators.isEmpty else { break }
            snapshot.appendSections([.suggestions])
            snapshot.appendItems(creators.map { .suggested($0.id) }, toSection: .suggestions)
        }
        return snapshot
    }

    /// Enough rows to reach the fold, so the shimmer reads as "a list is
    /// coming" rather than as two stray bones.
    private static let suggestedSkeletonCount = 5

    private func suggestionsSnapshot(
        _ rows: [SearchRowDisplayModel]
    ) -> NSDiffableDataSourceSnapshot<SearchSection, SearchItem> {
        var snapshot = NSDiffableDataSourceSnapshot<SearchSection, SearchItem>()
        guard !rows.isEmpty else { return snapshot }
        snapshot.appendSections([.completions])
        snapshot.appendItems(rows.map { .row($0.id) }, toSection: .completions)
        return snapshot
    }

    private func resultsSnapshot(
        _ models: [SearchResultDisplayModel]
    ) -> NSDiffableDataSourceSnapshot<SearchSection, SearchItem> {
        var snapshot = NSDiffableDataSourceSnapshot<SearchSection, SearchItem>()
        guard !models.isEmpty else { return snapshot }
        snapshot.appendSections([.results])
        snapshot.appendItems(models.map { .result($0.id) }, toSection: .results)
        return snapshot
    }

    private func apply(_ snapshot: NSDiffableDataSourceSnapshot<SearchSection, SearchItem>) {
        var snapshot = snapshot
        // ⚠️ **A row whose ITEM is unchanged is not re-rendered.** Diffable
        // compares identifiers, and every identifier here is an id or a query
        // string — stable by design, because that is what makes the animations
        // right. So when an avatar resolves and the same people are re-emitted,
        // the diff is empty and the cells keep their initials forever: the
        // pictures were arriving and nothing was drawing them.
        //
        // `reconfigureItems` is the counterpart — same cell, run its
        // registration again. Only the rows that CARRY OVER need it; new ones
        // are configured on the way in.
        let carried = Set(dataSource.snapshot().itemIdentifiers)
        let surviving = snapshot.itemIdentifiers.filter(carried.contains)
        if !surviving.isEmpty { snapshot.reconfigureItems(surviving) }
        // Recorded BEFORE the apply. The layout's section provider and the
        // header registration both read this, and both run during the apply —
        // updating it afterwards would lay the new sections out against the
        // old list's answers.
        visibleSections = snapshot.sectionIdentifiers
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func showStatus(symbolName: String, title: String, subtitle: String) {
        statusView.configure(symbolName: symbolName, title: title, subtitle: subtitle)
        statusView.isHidden = false
    }

    private func hideStatus() {
        statusView.isHidden = true
    }

    // MARK: - Debug

    #if DEBUG
    private func applyDebugArguments() {
        // ⚠️ LAUNCH ARGUMENTS ARE PROCESS-WIDE, AND THIS SCREEN NOW EXISTS
        // TWICE. A refine screen is a second `SearchViewController` in the same
        // process, so it read `-search-query … -search-submit` too, seeded
        // itself and submitted — which in refine mode pops. It closed itself
        // the instant it was born, and the instrument reported "the push did
        // not happen" for a push that had happened and been undone.
        //
        // The seeding belongs to the screen the argument was written for: the
        // one reached from a tab header.
        guard case .origin = mode else { return }
        let arguments = ProcessInfo.processInfo.arguments
        // `-search-query <text>` seeds the field on launch, so the typing path
        // is testable without driving the keyboard.
        guard let index = arguments.firstIndex(of: "-search-query"), index + 1 < arguments.count
        else { return }
        // `-search-sort <relevance|recency|popularity>` picks the order the
        // filter tray would pick. The tray is a `UIMenu` and the simulator taps
        // nothing, so without this the one thing the tray DOES — change what
        // goes on the wire and therefore what comes back — has no way to be
        // seen offline.
        if let sortIndex = arguments.firstIndex(of: "-search-sort"),
           sortIndex + 1 < arguments.count,
           let order = SearchSortOrder(rawValue: arguments[sortIndex + 1]) {
            viewModel.setSortOrder(order)
        }

        let seeded = arguments[index + 1]
        lastReportedQuery = seeded
        setFieldText(seeded)
        viewModel.queryChanged(seeded)
        // `-search-submit`: also press Search. Seeding alone only types, and
        // typing deliberately searches nothing — so without this the results
        // and history paths have no way to run in-sim, where neither the Search
        // key nor the bar's button can be tapped.
        //
        // ⚠️ THROUGH `submitCurrentQuery`, not `viewModel.submitQuery`. Calling
        // the view model directly skipped the resign, so the instrument left
        // the keyboard up over results it had just asked for — a state no
        // viewer can reach, filmed as though it were the real one.
        if arguments.contains("-search-submit") {
            submitCurrentQuery()
        }
        // `-search-scope <everyone|following>` picks the perimeter the sheet
        // would pick. Applied AFTER the submit, because a scope narrows an
        // answer rather than asking for one.
        if let index = arguments.firstIndex(of: "-search-scope"),
           index + 1 < arguments.count,
           let scope = SearchScope(rawValue: arguments[index + 1]) {
            viewModel.setScope(scope)
        }
    }
    #endif
}



extension SearchViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .row(let id):
            viewModel.didSelectRow(id)
            searchField.resignFirstResponder()
        case .seeMoreRecents:
            viewModel.didRequestMoreRecents()
        case .result(let id):
            viewModel.didSelectResult(id)
        case .suggested(let id):
            viewModel.didSelectCreator(id)
        case .suggestedSkeleton:
            break
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The dismissal's own choreography. Conformance is UNCONDITIONAL — the pill
/// fade below is product behaviour, and an earlier revision of this file had
/// the whole extension behind `#if DEBUG`, which would have shipped the very
/// animation this exists to remove.

extension SearchViewController: UITextFieldDelegate {
    /// The keyboard's Search key — the same method the bar's Search button
    /// runs, so the two cannot come to mean different things.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitCurrentQuery()
        return true
    }
}
