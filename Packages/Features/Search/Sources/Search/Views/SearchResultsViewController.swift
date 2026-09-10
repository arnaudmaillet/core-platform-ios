import CoreModels
import CoreStorage
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
///     navigation bar   [back] ………… [credit][query field]
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
/// the failure the navigation bar has is not available to it. The credit badge
/// then fits beside the field with room to spare: on a 402pt bar a 250-point
/// balance leaves the field ~188pt, and the required minimums come to ~273
/// against the narrowest bar the app supports.
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

    /// The viewer's spendable points, beside the query.
    ///
    /// ⚠️ BUILT HERE, NOT THROUGH THE SHELL'S `WalletBadgeInstaller`, for the
    /// reason the post screen and the place page give: a PUSHED screen owns its
    /// own navigation item, and what that installer exists to share — the
    /// freshness rules — is two closures here. Every installer the app holds
    /// belongs to a tab coordinator and is documented as living "as long as the
    /// process"; it removes no observer and re-arms a timer, so one per pushed
    /// results screen would leave a registration behind per query.
    ///
    /// ⚠️ AND IT IS THIS SCREEN'S OWN BADGE. A badge is a view and a view lives
    /// in one bar — borrowing the map's or For You's would strip it from there.
    /// Only the `WalletStore` is shared, which is all that has to be.
    private let walletBadge = WalletBadgeButton()
    private var walletItem: UIBarButtonItem?
    private var fieldItem: UIBarButtonItem?
    private let wallet: WalletStore?
    /// Nil in a composition without the shell's claim sheet — the badge is then
    /// a read-out, not a control.
    private let makeWalletSheet: (@MainActor () -> UIViewController)?
    private let walletObservers = SearchNotificationObserverBag()

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
        postSurfaces: (any SearchPostSurfaceProviding)?,
        wallet: WalletStore? = nil,
        makeWalletSheet: (@MainActor () -> UIViewController)? = nil
    ) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.postSurfaces = postSurfaces
        self.wallet = wallet
        self.makeWalletSheet = makeWalletSheet
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
        fieldItem = UIBarButtonItem(customView: searchField)
        configureWalletBadge()
        applyTrailingItems()

        #if DEBUG
        // `-search-filter-in-bar` — the filter as a LEADING item beside the
        // chevron, giving `[back][filter][credit][field]`. Behind a flag
        // because the only thing that can answer whether it fits is a 375pt
        // device, and the failure mode is a `•••` that takes the whole group.
        if Self.wantsFilterInBar {
            navigationItem.leftBarButtonItems = [UIBarButtonItem(customView: barFilterButton)]
            // ⚠️ WITHOUT THIS THE ITEM REPLACES THE BACK BUTTON, and UIKit
            // silently disables the interactive pop with it — the failure this
            // flag exists to guard.
            navigationItem.leftItemsSupplementBackButton = true
        } else {
            // ⚠️ NO `leftItemsSupplementBackButton`, because there is no leading
            // custom item to supplement. That flag exists so an item that
            // REPLACES the back button cannot silently disable the interactive
            // pop; with the leading group empty the back button is the back
            // button and `NativePopPolicy` has nothing to refuse.
            navigationItem.leftItemsSupplementBackButton = false
        }
        #else
        navigationItem.leftItemsSupplementBackButton = false
        #endif
    }


    /// ⚠️ THE SELECTOR IS INSTALLED WHEN THERE IS A REAL BAR TO MEASURE, not in
    /// `viewDidLoad`. A bar-item host has to take its measurement ONCE, before
    /// the item is offered to UIKit — a cap applied later arrives on a view that
    /// no longer has anywhere to be. So the install waits for a bar with a
    /// width.
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
        _ = bar
        applyHeaderWidths()
    }

    /// ⚠️ **`[0]` IS THE SCREEN EDGE, so this array renders left-to-right as
    /// `[back] … [credit][query]`** — the order every other host of this badge
    /// wears, and the one that was asked for. The credit sits immediately left
    /// of the field rather than against the chevron with 190pt of air between
    /// them, which is what a LEADING item would have given.
    ///
    /// ⚠️ AND IT KEEPS THE LEADING GROUP EMPTY, which is not a detail. A custom
    /// leading item makes `NativePopPolicy.shouldBegin` return false unless
    /// `leftItemsSupplementBackButton` is flipped back to true, and the failure
    /// is silent: the chevron still pops, so only a real edge swipe shows it —
    /// and injected touches cannot produce one here.
    ///
    /// ⚠️ `sharesBackground = false` ON BOTH, or iOS 26 draws one pill around
    /// them and a balance welded to a search field reads as a segmented
    /// control.
    private func applyTrailingItems() {
        let items = [fieldItem, walletItem].compactMap { $0 }
        for item in items { item.sharesBackground = false }
        navigationItem.rightBarButtonItems = items
    }

    /// The badge, and the rules that keep it true.
    private func configureWalletBadge() {
        guard let wallet else { return }
        // A badge with no sheet behind it is a read-out, not a control.
        walletBadge.isUserInteractionEnabled = makeWalletSheet != nil
        walletBadge.addAction(
            UIAction { [weak self] _ in
                guard let self, let sheet = self.makeWalletSheet?() else { return }
                self.present(sheet, animated: true)
            },
            for: .primaryActionTriggered
        )
        // ⚠️ A GROWN COUNT NEEDS A FRESH WRAPPER. Re-assigning the same item
        // hands the bar the same wrapper at the same frozen size (measured on
        // the post screen: "120" still came back wrapped), so a new item is the
        // only thing a bar measures anew — and the FIELD is refitted in the
        // same pass, because the badge takes its points off the same run.
        walletBadge.onFittedWidthChange = { [weak self] in
            guard let self else { return }
            self.walletItem = self.makeWalletItem()
            self.applyTrailingItems()
            self.applyHeaderWidths()
        }
        walletItem = makeWalletItem()
        refreshWalletBadge()
        // Spends and claims wherever they happen — a boost in a feed pushed
        // over this screen, a claim taken on the map beneath it.
        walletObservers.add(NotificationCenter.default.addObserver(
            forName: WalletStore.didChangeNotification, object: wallet, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWalletBadge() }
        })
    }

    private func makeWalletItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: walletBadge)
        item.accessibilityLabel = "Points balance"
        return item
    }

    private func refreshWalletBadge() {
        guard let wallet else { return }
        let snapshot = wallet.snapshot()
        walletBadge.update(
            balance: snapshot.balance,
            // A badge with no sheet to open must not advertise a claim the
            // viewer has no way to take from here.
            claimAvailable: makeWalletSheet != nil && snapshot.claimAvailable,
            claimProgress: snapshot.claimCountdown.map {
                WalletBadgeButton.ClaimProgress(fraction: $0.fraction, remaining: $0.remaining)
            }
        )
    }

    /// What the badge is asking for, or 0 when there is none.
    private func walletWanted() -> CGFloat {
        guard walletItem != nil else { return 0 }
        return walletBadge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
    }

    /// ⚠️ CANNOT REACH THE `•••`, and this is an invariant rather than a
    /// reassurance. UIKit sweeps a group when the items' REQUIRED minimums
    /// exceed the bar, and both burns on this screen were required-width burns
    /// (a stated 150 a side, then two halves each required at 141 on 402). The
    /// required minimums here are the fixed 116, the spacing, the field's
    /// required 44 floor and the badge's widest realistic intrinsic — about 273
    /// against the narrowest supported bar, 375. The field's own width stays
    /// `.defaultHigh`, so a `claimed` that drifts low costs a narrower field
    /// and never an overflow.
    /// The width a custom leading item wants, or 0 when the leading group is
    /// empty.
    private func leadingWanted() -> CGFloat {
        guard let item = navigationItem.leftBarButtonItems?.first,
              let custom = item.customView
        else { return 0 }
        return max(NavigationBarMetrics.itemPlatterHeight,
                   custom.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width)
    }

    private func applyHeaderWidths() {
        guard let bar = navigationController?.navigationBar, bar.bounds.width > 0 else { return }
        // ⚠️ NOT WHILE A TRANSITION IS RUNNING: the bar's width is not settled
        // there, and rebuilding the trailing run mid-flight is its own flash.
        guard transitionCoordinator == nil else { return }
        let wanted = Self.queryWidth(inBarOfWidth: bar.bounds.width,
                                     walletWanted: walletWanted(),
                                     leadingWanted: leadingWanted())
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
    /// The width UIKit gives a glyph bar item's platter, measured — `59`, where
    /// the button inside it fits under the 44pt touch target.
    ///
    /// ⚠️ NOT `itemWidth`. 44 is the least a platter can be, not what a glyph
    /// item comes out at, and the 15pt between them is the whole margin
    /// this screen has on a 375pt bar.
    static let glyphItemPlatterWidth: CGFloat = 59

    /// - Parameter leadingWanted: the width a custom LEADING item wants, or 0
    ///   when the leading group is empty. Charged the same way the badge is —
    ///   its own platter beside the chevron's, `max(44, wanted)` because UIKit
    ///   draws no platter narrower than the touch target, and the wider of the
    ///   two measured gaps between it and the back button.
    static func queryWidth(inBarOfWidth barWidth: CGFloat,
                           walletWanted: CGFloat,
                           leadingWanted: CGFloat = 0) -> CGFloat {
        // 16 a side, the back button's platter, the gap between the leading and
        // trailing groups, and the trailing platter's own inset.
        //
        // ⚠️ **THIS IS NOW THE ONLY COPY OF THESE MEASUREMENTS.** They were
        // `LeadingSelectorBudget`'s, measured on iPhone 17 Pro / iOS 26.5 and
        // pinned by tests; that type went with the leading-selector machinery
        // when every selector moved to an accessory or a toolbar, and these are
        // what is left of it. Measured, so they can be checked again:
        //
        //     barMargin           16   the bar's own margin, each end
        //     itemWidth           44   a bar item's platter — the touch target,
        //                              and the least a glyph item can occupy
        //     interGroupGap       24   leading group → trailing group. A FLOOR:
        //                              at a 20pt gap both groups drew, at 5 the
        //                              trailing pair became a `•••`
        //     platterPadding       8   a platter's inset around its content —
        //                              a 267pt capsule rides a 275pt platter
        //     sharedItemSpacing   27   between two items INSIDE one shared
        //                              pill. Two trailing glyphs measure 115pt
        //                              together, not 88 — charging 44 each is
        //                              what swept the profile's actions into a
        //                              `•••`
        //     platterGap          12   between two ADJACENT platters
        //     titledItemPadding   34   what a titled item's platter adds to its
        //                              word ("Following": 72pt of text, 106pt
        //                              platter)
        //
        // They are a floor, not a ceiling: the field YIELDS, so a number that
        // has drifted low costs a narrower field and never an overflow — the
        // direction that stays safe.
        //
        // ⚠️ AND THE BACK BUTTON IS CHARGED A BARE 44pt CHEVRON, measured
        // beside a leading custom view: iOS 26 draws it as a bare 44pt chevron
        // platter. This screen has no leading custom view, so if UIKit ever
        // gives the chevron its word back the field is 44pt too generous — and
        // yields, rather than overflowing.
        var claimed: CGFloat = 16 * 2 + 44 + 24 + 8
        if walletWanted > 0 {
            // The badge opts out of the shared background, so it wears its OWN
            // platter: that platter's inset, its width — charged
            // `max(44, wanted)` because UIKit draws no platter narrower than
            // the touch target — and the spacing to the field.
            //
            // ⚠️ 27 IS CHARGED ON PURPOSE, though two separate platters are
            // likely 12 apart. Over-charging costs the field a few points;
            // under-charging costs an overflow, and only the field can yield.
            claimed += 8 + max(44, walletWanted) + 27
        }
        if leadingWanted > 0 {
            // Read off the bar rather than reasoned out — `-header-bar-tree` at
            // 375pt, the four platters left to right:
            //
            //     back    16..60   (44 wide)
            //     filter  72..131  (59)
            //     credit  162..242 (80)
            //     field   254..359 (105)
            //
            // ⚠️ **THE GAP IS 12, NOT THE SHARED-PILL 27.** 60 → 72: the
            // chevron and a custom leading item wear their OWN platters, so the
            // spacing between items inside one pill does not apply here.
            //
            // ⚠️ **AND THE PLATTER IS WIDER THAN THE VIEW IN IT.** A glyph
            // button's `systemLayoutSizeFitting` answers under the 44pt touch
            // target, and UIKit drew it 59 wide — so charging what the VIEW
            // wants under-charges by 15, which is the direction that ends in a
            // `•••`. A test caught it: the arithmetic said 90 and the bar drew
            // 105, and the two only agreed because the badge's own charge
            // happens to over-state by about the same amount.
            claimed += max(Self.glyphItemPlatterWidth, leadingWanted + 16) + 12
        }
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

    /// The band at the foot of the screen: the format selector, and the filter
    /// riding its trailing edge inside the same glass.
    ///
    /// ⚠️ **AN ACCESSORY, ON A SCREEN WITH NO TAB BAR UNDER IT.** This screen
    /// sets `hidesBottomBarWhenPushed`, which made it the one place the
    /// question could be asked — and the answer is yes. `UITabAccessory.h`
    /// defines `.regular` as "above the bottom tab bar when it is visible; or,
    /// at the bottom of the UITabBarController's view", and that is what it
    /// does. Measured here: `env=.regular`, container 360x48 at y=805 of an
    /// 874pt window, laid out exactly as it is on a tab root.
    ///
    /// ⚠️ **AND THE TOOLBAR HAD TO GO, NOT MOVE OVER.** A toolbar and an
    /// accessory both claim the bottom of the screen and UIKit coordinates
    /// neither — the accessory belongs to the `UITabBarController` and the
    /// toolbar to a `UINavigationController` descendant, and the two headers do
    /// not mention each other. Filmed: the toolbar's filter glyph drawn
    /// UNDERNEATH the band, half-hidden by its trailing edge. This screen
    /// therefore presents no toolbar items at all — which also gives
    /// `SnapFeedViewController.successorUsesToolbar` the right answer when a
    /// post pushed from here is popped back.
    ///
    /// ⚠️ **AND THE FILTER IS NOT IN THE BAND EITHER, BECAUSE ONE ACCESSORY IS
    /// ONE CAPSULE.** `_UITabAccessoryContainer` draws its glass around the
    /// WHOLE content view whatever is inside it — measured twice: an accessory
    /// built with a nil content view still draws its bubble around nothing, and
    /// a strip given its own glass came back as a pill inside a pill. So a
    /// filter sharing the band cannot have a capsule of its own, and side by
    /// side is not available either: UIKit fixes the band at 360pt centred in a
    /// 402pt window, leaving 21pt at each edge.
    ///
    /// What IS available is the arrangement the profile tab root already uses,
    /// and for the same reason: a tray in the SCREEN'S OWN VIEW, pinned above
    /// its `safeAreaLayoutGuide.bottom`. The safe area already accounts for the
    /// band — measured, `safeAreaInsets.bottom = 69` in an 874pt window with the
    /// band's top edge at exactly 805 — so the tray clears it for free, with no
    /// arithmetic and nothing to keep in step. Two separate glass capsules, the
    /// selector's and the filter's, and neither drawn over the other.
    private func configureToolbar() {
        // A BARE control: `InlineFilterTrayView` supplies the one glass capsule
        // around it, and a button carrying its own background would be a bubble
        // inside a bubble.
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "line.3.horizontal.decrease")
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: 10, bottom: 0, trailing: 10
        )
        let filter = UIButton(configuration: configuration,
                              primaryAction: UIAction { [weak self] _ in self?.presentFilters() })
        filter.accessibilityLabel = "Filters"

        // ⚠️ **NO WIDTH CAP HERE, AND A TOOLBAR IS WHY.** The cap that used to
        // exist did so because a UINavigationBar sweeps a leading group it
        // cannot fit into a `•••`; a toolbar has no item groups and no overflow
        // control, so that failure is not available to it. The app already hosts a wide
        // custom view in this same shared toolbar with no arithmetic at all —
        // the chat composer's sticker strip — and that is the precedent
        // followed here.
        //
        // ⚠️ BARE, THOUGH. UIKit wraps a bar item's custom view in its own
        // glass capsule wherever the item lives, so a bar carrying its own
        // backdrop draws a lens inside a lens. `SelectorAccessoryHost` sets the
        // same flag for the same reason on the screens that use an accessory.
        tabBar.suppressesBackdrop = true

        // ⚠️ `toolbarItems` IS PER VIEW CONTROLLER even though the toolbar is
        // the navigation controller's, so the selector cannot leak onto another
        // screen. What IS shared is the toolbar's visibility, which is why this
        // screen still shows it on the way in and hides it on the way out.
        selectorAccessory = SelectorAccessory(strip: tabBar)

        #if DEBUG
        if Self.wantsFilterInBar {
            // The bar's own copy — configured in `configureHeader`, which runs
            // BEFORE this. Nothing else to place: no tray, no accessory
            // trailing item.
            return
        }
        #endif
        let tray = InlineFilterTrayView(trailing: filter)
        view.addSubview(tray)
        NSLayoutConstraint.activate([
            // ⚠️ **LEADING AS WELL AS TRAILING, AND A UITEST HAD TO FIND OUT
            // WHY.** The tray takes its width from its subviews, and its one
            // capsule is pinned to the TRAILING edge — so pinned on that side
            // alone the tray resolved to zero width. It still drew, because
            // nothing clips, and it was perfectly legible in a screenshot; but
            // hit-testing and the accessibility tree are both bounded by the
            // view's own frame, so the filter answered nothing and
            // `app.buttons["Filters"]` could not find it at all. This is the
            // trap already recorded for cell accessories — draws, never
            // receives — in a second place.
            tray.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            tray.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            tray.heightAnchor.constraint(equalToConstant: InlineFilterTrayView.height),
            tray.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                         constant: -InlineFilterTrayView.spacingBelow)
        ])

        // ⚠️ THE STRIP WINS THE TOUCH IT IS UNDER. Docked at the foot of the
        // screen the selector sits over a pager of scrolling grids, and a drag
        // that starts on it was scrolling the page underneath at the same time.
        // The strip is the thing the finger is on, so it takes priority.
        // ⚠️ THE STRIP WINS THE TOUCH IT IS UNDER — see `SelectorTouchProbe`,
        // which carries the two traps this needed: `.touchDown` on the control
        // never fires (the strip's inner scroller eats the touch), and a
        // recogniser that does not recognise simultaneously silences the very
        // control it was added to watch.
        selectorTouchProbe.attach(to: tabBar)
    }

    #if DEBUG
    /// ⚠️ NAMES WHAT IS ACTUALLY LISTENING, because two gates aimed at guesses
    /// have now missed. Walks from the selector up to the window and prints
    /// every recogniser on the way, with its class, its state and the view it
    /// is attached to — the one that leaves this screen is in that list.
    private func auditGestures(_ reason: String) {
        guard ProcessInfo.processInfo.arguments.contains("-search-gesture-audit") else { return }
        var lines: [String] = []
        var node: UIView? = tabBar
        while let current = node {
            for recogniser in current.gestureRecognizers ?? [] {
                lines.append("\(type(of: recogniser)) on \(type(of: current)) "
                             + "state=\(recogniser.state.rawValue) enabled=\(recogniser.isEnabled)")
            }
            node = current.superview
        }
        for recogniser in navigationController?.view.gestureRecognizers ?? [] {
            lines.append("NAV \(type(of: recogniser)) state=\(recogniser.state.rawValue) "
                         + "enabled=\(recogniser.isEnabled)")
        }
        print("[gesture-audit] \(reason)\n  " + lines.joined(separator: "\n  "))
    }
    #endif

    private lazy var selectorTouchProbe = SelectorTouchProbe { [weak self] isTouching in
        guard let self, !Self.gestureGateIsOff else { return }
        #if DEBUG
        self.auditGestures(isTouching ? "selector touch" : "after release")
        #endif
        self.setPageScrollEnabled(!isTouching)
    }

    /// `-search-no-gesture-gate`: leave the stack's recognisers alone.
    ///
    /// ⚠️ AN A/B SWITCH, BECAUSE THE FAILING GESTURE CANNOT BE INJECTED. A real
    /// finger is the only thing that drives
    /// `_UIParallaxTransitionPanGestureRecognizer` here, so whether this gate
    /// is behind a two-level pop cannot be settled from this machine. One run
    /// with the flag and one without settles it in a minute on a device.
    private static var gestureGateIsOff: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-search-no-gesture-gate")
        #else
        false
        #endif
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
        setPopGestureEnabled(isEnabled)
    }

    /// ⚠️ **THE STACK HAS TWO BACK-SWIPE RECOGNISERS AND
    /// `interactivePopGestureRecognizer` VENDS ONLY ONE.** Audited on the
    /// simulator by walking from the strip to the window while a rightward
    /// swipe was in flight (`-search-gesture-audit`):
    ///
    ///     began   _UIParallaxTransitionPanGestureRecognizer  enabled=true
    ///             _UIParallaxTransitionPanGestureRecognizer  enabled=true
    ///     moved   _UIParallaxTransitionPanGestureRecognizer  enabled=FALSE  ← gated
    ///             _UIParallaxTransitionPanGestureRecognizer  state=began    ← drove it
    ///
    /// So gating the vended one looked right, printed right, and left the
    /// screen anyway: the second recogniser — the full-surface back swipe, not
    /// the edge one — is what carried the dismissal. Two fixes aimed at guesses
    /// missed before this was measured rather than reasoned about.
    ///
    /// Every pan on the navigation controller's own container view is
    /// suspended for the length of the touch instead of one named recogniser.
    ///
    /// ⚠️ AND EACH IS RESTORED TO WHAT IT WAS, not to `true`.
    /// `NativePopGestureEnabler` owns the vended recogniser's delegate and
    /// `NativePopPolicy` decides whether a begin is allowed; forcing them
    /// enabled on release would hand back a state this screen never
    /// established.
    private func setPopGestureEnabled(_ isEnabled: Bool) {
        Self.traceNavigation(
            "pans \(isEnabled ? "restored" : "suspended") "
            + "depth=\(navigationController?.viewControllers.count ?? -1) "
            + "top=\(navigationController?.topViewController === self ? "results" : "other")"
        )
        if isEnabled {
            for (recogniser, wasEnabled) in suspendedPans { recogniser.isEnabled = wasEnabled }
            suspendedPans = []
            return
        }
        // ⚠️ **ONLY WHILE THIS SCREEN IS THE TOP ONE.** These recognisers belong
        // to the STACK, not to this screen: suspending them is reaching outside
        // our own lifetime, and a suspend left open while something is pushed
        // over us would be arbitrating another screen's dismissal. The probe
        // should not fire off-window — the strip is in a toolbar this screen
        // owns — but "should not" is not a guarantee worth betting a back
        // gesture on, and `viewWillDisappear` closes the window either way.
        guard navigationController?.topViewController === self else { return }
        guard suspendedPans.isEmpty, let host = navigationController?.view else { return }
        let pans = (host.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer }
        suspendedPans = pans.map { ($0, $0.isEnabled) }
        for recogniser in pans { recogniser.isEnabled = false }
    }

    private var suspendedPans: [(UIGestureRecognizer, Bool)] = []


    private var isPageScrollEnabled = true

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // `minimizesOnScroll: false` — there is no tab bar under this screen to
        // minimize, and arming a shell-wide behaviour from a screen that cannot
        // use it is how every other tab inherits a collapsing bar.
        installBottomChromeWhenAppearing { [weak self] in
            guard let self else { return }
            selectorAccessory?.install(into: tabBarController,
                                       alongside: transitionCoordinator)
        }
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
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        selectorAccessory?.install(into: tabBarController)
        #if DEBUG
        reportAccessorySpike()
        #endif
        // ⚠️ HERE, NOT `viewWillAppear`. The window is what
        // `updatePlayback` reads, and a screen arriving has none until it has
        // appeared — asked earlier it would decide "not visible" and leave
        // every clip frozen on the screen the viewer is looking at.
        updatePlayback()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // ⚠️ NOTHING OF OURS OUTLIVES THIS SCREEN'S TURN ON TOP. A suspended
        // pan is stack-wide state; carrying one into a pushed screen's
        // dismissal is how a gesture that should pop one level pops two.
        selectorAccessory?.remove(from: tabBarController, alongside: transitionCoordinator)
        setPageScrollEnabled(true)
        Self.traceNavigation(
            "results willDisappear movingFromParent=\(isMovingFromParent) "
            + "depth=\(navigationController?.viewControllers.count ?? -1)"
        )
        // Anything pushed over this screen — a post, a profile, a refine — gets
        // the pool. A grid under another screen holding players is the leak
        // this call exists to prevent.
        postsPage.setPlaybackActive(false)
        mediaPage.setPlaybackActive(false)
    }

    /// Internal, not private, so the tests can assert what is IN the band.
    /// The arrangement moved out of `toolbarItems` — which a test could read —
    /// into a content view UIKit owns, and a rule nothing can see is a rule
    /// that quietly stops being true.
    private(set) var selectorAccessory: SelectorAccessory?

    #if DEBUG
    static var wantsFilterInBar: Bool {
        ProcessInfo.processInfo.arguments.contains("-search-filter-in-bar")
    }

    /// The filter as a bar item's custom view.
    ///
    /// ⚠️ A CUSTOM VIEW, NOT `UIBarButtonItem(image:)`, because the budget has
    /// to be able to ASK how wide it wants to be — `leadingWanted()` reads
    /// `systemLayoutSizeFitting`, and a system item has no view to ask.
    private lazy var barFilterButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "line.3.horizontal.decrease")
        let button = UIButton(configuration: configuration,
                              primaryAction: UIAction { [weak self] _ in self?.presentFilters() })
        button.accessibilityLabel = "Filters"
        return button
    }()
    #endif

    #if DEBUG
    /// What the spike actually produced, in numbers — whether the accessory was
    /// accepted at all, where UIKit put it, and whether the tab bar it is
    /// nominally attached to is even on screen.
    private func reportAccessorySpike() {
        let host = selectorAccessory?.hostView
        let container = host?.superview
        let bar = tabBarController?.tabBar
        print("[search-accessory] hosted=\(host?.window != nil)"
            + " accessorySet=\(tabBarController?.bottomAccessory != nil)"
            + " env=\(host.map { String(describing: $0.traitCollection.tabAccessoryEnvironment) } ?? "nil")"
            + String(format: " container=%.0fx%.0f at %.0f,%.0f",
                     container?.bounds.width ?? -1, container?.bounds.height ?? -1,
                     container.map { $0.convert($0.bounds, to: nil).minX } ?? -1,
                     container.map { $0.convert($0.bounds, to: nil).minY } ?? -1)
            + " tabBarHidden=\(tabBarController?.isTabBarHidden ?? false)"
            + String(format: " barY=%.0f", bar.map { $0.convert($0.bounds, to: nil).minY } ?? -1)
            + String(format: " windowH=%.0f", view.window?.bounds.height ?? -1))
    }
    #endif

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

extension SearchResultsViewController {
    /// ⚠️ A FILE, NOT ONLY A CONSOLE. The defect this records — a back gesture
    /// that pops two levels — needs a real finger, so it happens on a device or
    /// in a hand-driven simulator run where nobody is attached to stdout. Every
    /// line is appended to `search-nav-trace.log` in the app's Documents
    /// directory, read afterwards with
    /// `xcrun simctl get_app_container <udid> <bundle> data`.
    static func traceNavigation(_ line: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-search-nav-trace") else { return }
        print("[search-nav] \(line)")
        guard let directory = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return }
        let url = directory.appendingPathComponent("search-nav-trace.log")
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        #endif
    }
}

/// ⚠️ A BOX, BECAUSE A `@MainActor` SCREEN'S `deinit` MAY NOT READ ITS OWN
/// STORED TOKENS under Swift 6. Feed keeps one of these for the same reason and
/// it is internal to Feed, so Search carries its own rather than reaching
/// across a package for five lines.
final class SearchNotificationObserverBag: @unchecked Sendable {
    private var tokens: [any NSObjectProtocol] = []
    func add(_ token: any NSObjectProtocol) { tokens.append(token) }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
