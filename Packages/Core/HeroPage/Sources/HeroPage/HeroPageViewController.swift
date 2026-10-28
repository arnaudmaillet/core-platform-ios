import DesignSystem
import UIKit

/// The hero page's measures shared by every page kind.
public enum HeroPageMetrics {
    /// The slot the docked selector holds under the bar, whether or not the
    /// selector is in it: the strip's own height plus the air between it and
    /// the first row it filters, taken from the strip rather than restated.
    public static let dockedSlot: CGFloat = PagedTabBar.Style.navigationTitle.height + 16
    /// The band the pull's spinner centres in, under the navigation bar.
    static let pullIndicatorHeight: CGFloat = 44
}

/// The hero page (#1655): the screen a profile and a place page share — a
/// banner behind paged content, a header floating over it, docking under a
/// transparent bar as the pages climb.
///
/// **What the container owns**, the same for every page kind:
/// - the layout: the pages fill the screen and scroll themselves; the header
///   (`HeroHeaderView`) floats over them in a passthrough host, moved by the
///   active page's offset; the banner stands behind the pages, resting on the
///   header's top and stretching under a pull;
/// - the scroll arithmetic (`HeroScrollCoordinator`): the dock line, the
///   content floor, the identity's fade, the detents, the header's measured
///   height (cached by its `layoutRevision`);
/// - the bar: transparent at rest and docked, its ink white over the banner
///   and the system's once the header is gone;
/// - the pull to refresh, the status block (`EmptyStateView`), the video
///   banner's play rule, the selector (`HeroPageSelector`, placed by the page
///   kind) and the stack's pans held off while a finger is on it.
///
/// **The contract a page kind fulfils** — small, by overriding:
/// - hand its header and its pager to `init` (and the selector's strip and
///   home, used only if it places the selector);
/// - `heroPageRefresh()`: a pull was released past its threshold;
/// - `heroPageHeaderDidMove(travelled:)`: the header moved — a bar identity
///   item on scroll-away hangs here (`isActionRowUnderBar`);
/// - `heroPageBottomBreathingRoom`: the air under the last row.
///
/// Its own data, menus, bar items and transitions stay the page kind's.
open class HeroPageViewController<Tab: Equatable>: UIViewController {
    /// The identity block floating over the pages.
    public let heroHeader: HeroHeaderView
    /// The pages, each its own scroll view.
    public let heroPager: HeroPagePager<Tab>
    /// The header's host — passthrough, so a drag that begins on the
    /// avatar or the bio still scrolls the page under it.
    ///
    /// ⚠️ **Not in a scroll view.** The profile used to be one outer scroll
    /// view holding the header and a pager sized to its active page; every
    /// layout defect on that screen came from the container resizing. The
    /// pages own all vertical motion and this host is MOVED by whichever page
    /// is being read.
    public let headerHost = ScrollPassthroughView()
    /// How far the host has been pulled up, driven by the active page's offset.
    private var headerTopConstraint: NSLayoutConstraint?
    /// The pull indicator, above the header rather than inside a list — see
    /// `HeroPullToRefreshView` for why the stock control could not be used.
    public let pullIndicator = HeroPullToRefreshView()
    /// A failed load with its way out, or a page for no one.
    public let statusView = EmptyStateView()
    /// The pages' selector strip — the SAME `PagedTabBar` For You and
    /// Messages wear. It never moves once placed.
    public let selectorBar: PagedTabBar
    private let selectorPlacement: HeroPageSelector.Placement
    /// The strip, kept in step with the pager and placed at the foot of the
    /// screen (`HeroPageSelector`) — by the page kind, when it has tabs.
    public private(set) lazy var selector = HeroPageSelector(
        bar: selectorBar, placement: selectorPlacement, touchProbe: selectorTouchProbe
    )
    /// The docked selector's slot under the bar.
    private let dockedSlot: CGFloat
    /// The bar's see-through dress, worn only while the banner is behind it.
    private var transparentBarAppearance: UINavigationBarAppearance?
    /// Whether the bar is currently see-through.
    private var isBarTransparent = true
    /// Between `viewWillAppear` and `viewWillDisappear`.
    public private(set) var isShownOnScreen = false
    /// Between `viewWillDisappear` and `viewDidDisappear`: the screen is
    /// leaving and the banner's loop plays on through it (#1399). A
    /// cancelled interactive pop never reaches `viewDidDisappear`;
    /// `viewWillAppear` clears it.
    public private(set) var isLeavingScreen = false
    #if DEBUG
    /// How many times the header has been measured — `headerHeight`'s fitting
    /// passes, which a frame that only scrolls must not add to.
    public private(set) var debugHeaderMeasureCount = 0
    #endif

    /// - Parameters:
    ///   - selectorBar: the strip the page kind's tabs are titled in.
    ///   - selectorPlacement: its home once placed — the tab bar's
    ///     accessory on a tab root, the toolbar on a pushed page.
    ///   - dockedSlot: the room the docked selector holds under the bar.
    public init(
        header: HeroHeaderView, pager: HeroPagePager<Tab>,
        selectorBar: PagedTabBar, selectorPlacement: HeroPageSelector.Placement = .toolbar,
        dockedSlot: CGFloat = HeroPageMetrics.dockedSlot
    ) {
        heroHeader = header
        heroPager = pager
        self.selectorBar = selectorBar
        self.selectorPlacement = selectorPlacement
        self.dockedSlot = dockedSlot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - The contract

    /// A pull was released past its threshold (the spinner is turning), or
    /// a page asked for a refresh. Nothing by default.
    open func heroPageRefresh() {}

    /// The header moved to `travelled` — after its position, fade and bar
    /// ink have followed. Nothing by default.
    open func heroPageHeaderDidMove(travelled: CGFloat) {}

    /// The air under the last row, over what the bars cover.
    open var heroPageBottomBreathingRoom: CGFloat { 8 }

    // MARK: - Lifecycle

    open override func viewDidLoad() {
        super.viewDidLoad()
        // The video banner rests under Reduce Motion, Low Power Mode and idle
        // calm, and plays again when they end (#944).
        NotificationCenter.default.addObserver(
            self, selector: #selector(decorativeMotionDidChange), name: .decorativeMotionDidChange, object: nil
        )
        // The page the cards lie on, a step below them — see `Surface`.
        view.backgroundColor = Surface.page
        configureHeroNavigationBar()
        installHeroLayout()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isShownOnScreen = true
        isLeavingScreen = false
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateBannerVideo()
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isShownOnScreen = false
        setStackGesturesEnabled(true)
        // ⚠️ NOT THE BANNER (#1399): it is muted, and stopping it here took
        // the loop off the card for the whole dismissal — the page slid away
        // on an empty banner. It plays on while the screen leaves, and stops
        // once it has gone (`viewDidDisappear`).
        isLeavingScreen = true
    }

    open override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isLeavingScreen = false
        updateBannerVideo()
    }

    open override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // With a transparent bar the view extends under the chrome, so the top
        // safe-area inset is exactly the status-bar + navigation-bar height the
        // header's overlay content must clear.
        heroHeader.chromeTopInset = chromeTop
    }

    /// The status bar and the navigation bar the header runs under: the top
    /// safe area — or, while this screen is laid out OFF a window, the bar's
    /// own foot.
    ///
    /// ⚠️ A PAGE STAGED BEFORE IT IS SHOWN (a close from the map lands the
    /// place page from under the feed, #1656) has no safe area yet: its
    /// bannerless header — which starts under the bar — was measured 116pt
    /// short, grew by that once on screen, and the page came to rest pulled
    /// down by it, the spinner showing (the owner, on a device, 2026-10-23).
    ///
    /// ⚠️ …AND OFTEN NO STACK EITHER: a page staged under the feed it is
    /// about to land a close from is not in the stack yet. Whoever stages it
    /// says what chrome it will run under (`stagingChromeTop`).
    public var chromeTop: CGFloat {
        if let navigationController, !navigationController.isNavigationBarHidden {
            return max(view.safeAreaInsets.top, navigationController.navigationBar.frame.maxY)
        }
        if view.window == nil, let stagingChromeTop {
            return max(view.safeAreaInsets.top, stagingChromeTop)
        }
        return view.safeAreaInsets.top
    }

    /// The chrome a page staged off a window and off a stack will run under,
    /// told by whoever stages it — read by `chromeTop` until the page has a
    /// stack or a window of its own.
    public var stagingChromeTop: CGFloat?

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        HeroScreenCost.measure("layout.page") { layoutPages() }
    }

    // MARK: - Layout

    /// The banner runs under the navigation area, so the bar is transparent
    /// while the header is at the scroll edge (white title over the banner's
    /// top scrim) and stays transparent, with the title in the system's ink,
    /// once content scrolls up underneath it.
    private func configureHeroNavigationBar() {
        // A custom leading item silently disables the navigation controller's
        // interactive pop gesture. The page must keep the native edge swipe in
        // every pushed context, so any leading item an owner installs
        // supplements the back button instead of replacing it. Harmless at a
        // stack root, where no back button exists.
        navigationItem.leftItemsSupplementBackButton = true
        let transparent = UINavigationBarAppearance()
        transparent.configureWithTransparentBackground()
        transparent.titleTextAttributes = [.foregroundColor: UIColor.white]
        transparentBarAppearance = transparent
        navigationItem.scrollEdgeAppearance = transparent
        // ⚠️ TRANSPARENT HERE TOO, not a fresh `UINavigationBarAppearance()`: a
        // default one is the system's material slab, and this bar wears none in
        // any state — `updateBarTransparency` only ever changes the title's
        // colour.
        navigationItem.standardAppearance = dockedBarAppearance
    }

    private func installHeroLayout() {
        // The pages fill the screen and scroll themselves; the header floats
        // over them. Order matters — the header is added second so it draws
        // above the content sliding under it.
        heroPager.pin(to: view)

        headerHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerHost)
        let top = headerHost.topAnchor.constraint(equalTo: view.topAnchor)
        headerTopConstraint = top
        NSLayoutConstraint.activate([
            top,
            headerHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        heroHeader.constrain(in: headerHost) { parent in
            heroHeader.topAnchor.constraint(equalTo: parent.topAnchor)
            heroHeader.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            heroHeader.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        }
        // ⚠️ **THE IDENTITY BLOCK'S BOTTOM IS WHAT GIVES THE HOST A HEIGHT.**
        // Without it `headerHeight` goes ambiguous, taking the pages' inset,
        // the dock line and the content floor with it.
        heroHeader.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor).isActive = true

        // ⚠️ Stretchy banner. The host is moved by its TOP CONSTRAINT rather
        // than by a transform precisely so this works: constraints cannot see
        // a transform, and `lessThanOrEqualTo` the view's top is what pins the
        // banner while the host travels down under a pull, stretching it
        // instead of dragging it away and exposing the background behind.
        // ⚠️ THE BANNER STANDS BEHIND THE PAGES, not in the floating header:
        // the pages are clear and only their cards cover it. It still rests on
        // the header's top and travels with it, so the fade, the ink and the
        // stretch are read as before.
        heroHeader.moveBanner(into: view, below: heroPager)
        heroHeader.anchorBanner(toViewportTop: view.topAnchor)

        heroPager.onVerticalScroll = { [weak self] offset in
            guard let self else { return }
            self.applyHeaderOffset(offset)
            // Negative travel is the overscroll the indicator draws from.
            self.pullIndicator.setPull(
                max(0, -offset), isTracking: self.heroPager.activePage?.scrollView.isTracking ?? false
            )
        }
        heroPager.onPullReleased = { [weak self] distance in
            guard let self, self.pullIndicator.shouldRefresh(releasedAt: distance) else { return }
            self.pullIndicator.beginRefreshing()
            self.heroPageRefresh()
        }
        heroPager.onPullToRefresh = { [weak self] in self?.heroPageRefresh() }
        // The band's minimize rides whichever page is in front. The pager is
        // what knows, and it is what says so.
        heroPager.onActiveScrollViewChanged = { [weak self] scroller in
            self?.setContentScrollView(scroller, for: .bottom)
        }

        // Above everything, including the header it is pulled out from under:
        // the band between the safe-area top and the first content is exactly
        // where a refresh belongs, and the header slides down past it.
        pullIndicator.constrain(in: view) { parent in
            pullIndicator.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            pullIndicator.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            pullIndicator.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            pullIndicator.heightAnchor.constraint(equalToConstant: HeroPageMetrics.pullIndicatorHeight)
        }
        view.bringSubviewToFront(pullIndicator)

        statusView.isHidden = true
        statusView.constrain(in: view) { parent in
            statusView.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            statusView.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor)
            statusView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            statusView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        }
    }

    /// How much of this screen's foot the tab bar actually covers.
    ///
    /// The bar floats over these pages rather than insetting them, so the safe
    /// area understates it by the bar's own height. Asked of the bar rather
    /// than written down as a number, which goes stale on the next device.
    ///
    /// Public: a page kind's own landings measure the same cover (the place
    /// page's `landingOcclusion`).
    public var floatingBarCover: CGFloat {
        guard let bar = tabBarController?.tabBar, !bar.isHidden, let host = bar.superview
        else { return view.safeAreaInsets.bottom }
        let inPage = view.convert(bar.frame, from: host)
        return max(view.safeAreaInsets.bottom, view.bounds.maxY - inPage.minY)
    }

    private func layoutPages() {
        // The host has just been laid out by the same constraints the fitting
        // pass solves: a height it disagrees with is a header that changed
        // behind `layoutRevision`'s back — measure again rather than trust it.
        if let cached = headerHeightCache, abs(headerHost.bounds.height - cached.height) > 0.5 {
            headerHeightCache = nil
        }
        // Off a window the safe area says nothing yet — see `chromeTop`.
        if heroHeader.chromeTopInset != chromeTop { heroHeader.chromeTopInset = chromeTop }
        // The pages opt out of automatic inset adjustment (the banner must
        // start at y = 0), so the bottom safe area — which includes the
        // toolbar while it shows — is re-added by hand, plus breathing room so
        // the last row scrolls clear of the bars' glass.
        //
        // ⚠️ AND NEVER LESS THAN THE BAR ACTUALLY COVERS. The tab bar FLOATS —
        // it draws over these pages without insetting them — so
        // `safeAreaInsets.bottom` understates it by the bar's own height.
        let bottom = max(floatingBarCover, view.safeAreaInsets.bottom + heroPageBottomBreathingRoom)
        heroPager.setContentBottomInset(bottom)
        // The pages are inset by the header floating over them, so their content
        // starts below it rather than behind it. Applied here because the
        // header's height is only known once it has laid out.
        heroPager.setContentTopInset(headerHeight)
        heroPager.setStickyTopOcclusion(stickyTopOcclusion)
        // Every tab must be able to absorb the header's whole travel, or a
        // short one cannot hold the position a long one was left at and the
        // header follows the clamp back up. See `setMinimumScrollTravel`.
        heroPager.setMinimumScrollTravel(contentTravel)
        // Where the header stops, and so where the offset stops being the
        // screen's business and starts being each tab's own. See the pager's
        // `alignedOffset`.
        heroPager.setSharedTravel(dockLine: headerTravel, contentFloor: contentTravel)
        // Where a release rests while the header is on screen: the top, the
        // first post — and a band card's avatar just under the bar (#1208).
        // A band resting collapsed has its avatar there already: no notch.
        let notch = heroHeader.bannerFormat == .band ? heroHeader.bandAvatarDetent.flatMap { $0 > 0 ? $0 : nil } : nil
        heroPager.setSnapDetents(scroll.detents(notch: notch), catching: notch.map { [$0] } ?? [])
    }

    /// What content actually passes under at the top: the chrome
    /// (`chromeTop`) and nothing else. It already reaches the bottom of the
    /// navigation bar.
    ///
    /// Assembled rather than read off the selector's frame: that bar is
    /// transiently out of any window during a push, so measuring it made the
    /// occlusion flip between values between reveals.
    private var stickyTopOcclusion: CGFloat {
        chromeTop
    }

    // MARK: - The header's travel

    /// The height the header takes when nothing is scrolled — what the pages
    /// are inset by so their content starts below it rather than behind it.
    ///
    /// ⚠️ MEASURED ONCE PER CONTENT, NOT PER FRAME. It is read five times a
    /// frame while the page moves — the header's offset, its fade, the pages'
    /// insets and travels — and each read was a fitting pass over the whole
    /// header: about 5 ms a frame of a pull on a profile, most of a 120 Hz
    /// frame's 8.3. The answer only changes with what the header holds
    /// (`HeroHeaderView.layoutRevision`), the width, the chrome above it and
    /// Dynamic Type, so those are its key; and should anything else ever
    /// resize the header, the laid-out host disagreeing with the cached
    /// height drops it (`layoutPages`).
    public var headerHeight: CGFloat {
        let key = HeaderHeightKey(
            width: view.bounds.width,
            safeTop: chromeTop,
            contentSize: traitCollection.preferredContentSizeCategory,
            revision: heroHeader.layoutRevision
        )
        if let cached = headerHeightCache, cached.key == key { return cached.height }
        let height = HeroScreenCost.measure("layout.headerHeight") {
            #if DEBUG
            debugHeaderMeasureCount += 1
            #endif
            return measuredHeaderHeight
        }
        headerHeightCache = (key, height)
        return height
    }

    /// The header's height, measured afresh — what the cached answer must
    /// agree with.
    public var measuredHeaderHeight: CGFloat {
        headerHost.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    private var headerHeightCache: (key: HeaderHeightKey, height: CGFloat)?

    /// The header's scroll arithmetic (#1652): the dock line, the content's
    /// floor, the header's position, the identity's fade, the detents — read
    /// fresh, since the header's height is cached and the rest is a few
    /// subtractions.
    public var scroll: HeroScrollCoordinator {
        HeroScrollCoordinator(headerHeight: headerHeight, safeTop: chromeTop, dockedSlot: dockedSlot)
    }

    /// How far the header travels before its selector reaches the navigation
    /// bar — the moment it docks.
    public var headerTravel: CGFloat { scroll.dockLine }

    /// How far a tab must be able to scroll for its first row to sit directly
    /// beneath the navigation bar (see `HeroScrollCoordinator.contentFloor`).
    public var contentTravel: CGFloat { scroll.contentFloor }

    /// **The coordinator.** Moves the header from the active page's offset, and
    /// decides docking from the same number.
    ///
    /// ⚠️ The header's position, the docking state and the tab-switch
    /// continuity all read the SAME offset, so they cannot disagree.
    public func applyHeaderOffset(_ travelled: CGFloat) {
        HeroScreenCost.measure("scroll.coordinator") { applyHeaderOffsetNow(travelled) }
    }

    /// `applyHeaderOffset` without the cost probe.
    public func applyHeaderOffsetNow(_ travelled: CGFloat) {
        // ⚠️ **Negative travel is not clamped, and that is the point.** Letting
        // the constant go POSITIVE carries the header down by exactly the
        // overscroll, so the banner, the identity block and the selector
        // travel with the content they belong to and the whole top of the
        // screen stretches as one. Only the downward end is free: the upward
        // end stops at `headerTravel`, where the header has finished docking
        // under the navigation bar.
        headerTopConstraint?.constant = scroll.headerTop(travelled: travelled)
        heroHeader.setTravelled(travelled)
        if heroHeader.hasBannerVideo { updateBannerVideo() }
        applyIdentityFade(travelled: travelled)
        updateBarTransparency(travelled: travelled)
        heroPageHeaderDidMove(travelled: travelled)
    }

    /// Whether the header's action row has scrolled under the bar at
    /// `travelled` — or faded with the identity.
    ///
    /// ⚠️ AT REST THE ROW IS ON SCREEN, whatever the frames say: a push reads
    /// them before the header has laid out (a row foot at 0, an identity not
    /// faded in yet), and a bar pill showed over a profile that had not moved
    /// (the owner, on a device, 2026-10-15).
    public func isActionRowUnderBar(travelled: CGFloat) -> Bool {
        guard travelled > 0, heroHeader.bounds.height > 0,
              let rowFoot = heroHeader.actionTrayMaxY(in: headerHost), rowFoot > 0 else { return false }
        return scroll.isUnderBar(foot: rowFoot, travelled: travelled) || heroHeader.alpha < 0.5
    }

    /// Fades the identity block out as it reaches the navigation bar, and back
    /// in on the way down — a function of a POSITION, not a state.
    private func applyIdentityFade(travelled: CGFloat) {
        let alpha = scroll.identityAlpha(travelled: travelled)
        guard abs(heroHeader.alpha - alpha) > 0.001 else { return }
        heroHeader.alpha = alpha
        // ⚠️ Nothing drawn, nothing to touch. The host still spans the band
        // between the navigation bar and the content once the header has
        // travelled, and a `UIView` takes touches inside its bounds whether or
        // not it has anything to show — so left interactive it swallows
        // scrolls in that band.
        headerHost.isUserInteractionEnabled = alpha > 0.01
    }

    // MARK: - The bar

    /// Swaps the bar's title colour once the banner is no longer behind it.
    ///
    /// ⚠️ **UIKit normally does this for us and cannot here.** The scroll-edge
    /// appearance is chosen by watching a scroll view in the hierarchy, and
    /// this screen has none at the top level — the pages own their own
    /// scrolling, one level down.
    ///
    /// ⚠️ THE DOCKED BAR IS AS TRANSPARENT AS THE BANNER ONE: no header in the
    /// app wears a blurred band (`prefersClearTopEdge`), so the only thing
    /// this swap changes is the ink.
    private func updateBarTransparency(travelled: CGFloat) {
        let shouldBeTransparent = scroll.barIsAtRest(travelled: travelled)
        guard shouldBeTransparent != isBarTransparent else { return }
        isBarTransparent = shouldBeTransparent
        let appearance = shouldBeTransparent ? transparentBarAppearance : dockedBarAppearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.standardAppearance = appearance
        navigationItem.compactAppearance = appearance
        forceNavigationBarLayout()
    }

    /// The bar's dress once the header has scrolled behind it: the same
    /// transparent background, with the title back in the system's ink.
    private var dockedBarAppearance: UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        return appearance
    }

    /// The nav bar caches its title view's size, so a change of dress has to
    /// make it re-measure.
    private func forceNavigationBarLayout() {
        guard let bar = navigationController?.navigationBar else { return }
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
    }

    // MARK: - The video banner

    /// Plays the video banner or stops it, by the rule below.
    public func updateBannerVideo() {
        heroHeader.setBannerVideoPlaying(bannerVideoShouldPlay)
    }

    /// The video banner (#944) plays while this screen is on show or
    /// leaving, the banner on screen and decorative motion allowed — the
    /// poster under Reduce Motion, Low Power Mode and idle calm (#580), and as
    /// soon as the banner has scrolled away.
    public var bannerVideoShouldPlay: Bool {
        view.window != nil && heroHeader.bannerShouldPlay(hostShowing: isShownOnScreen || isLeavingScreen)
    }

    @objc private func decorativeMotionDidChange() {
        updateBannerVideo()
    }

    // MARK: - The selector's touch

    /// ⚠️ THE STRIP WINS THE TOUCH IT IS UNDER — see `SelectorTouchProbe`.
    private lazy var selectorTouchProbe = SelectorTouchProbe { [weak self] isTouching in
        self?.setStackGesturesEnabled(!isTouching)
    }

    /// ⚠️ THE STACK HAS TWO BACK-SWIPE RECOGNISERS AND
    /// `interactivePopGestureRecognizer` VENDS ONLY ONE. Every pan on the
    /// container is suspended for the length of a touch, restored to the
    /// value it had, and only while this screen is on top.
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
}

/// What `headerHeight` was last measured for. Outside the generic
/// controller: a generic type keeps no static or nested stored layouts.
private struct HeaderHeightKey: Equatable {
    var width: CGFloat
    var safeTop: CGFloat
    var contentSize: UIContentSizeCategory
    var revision: Int
}
