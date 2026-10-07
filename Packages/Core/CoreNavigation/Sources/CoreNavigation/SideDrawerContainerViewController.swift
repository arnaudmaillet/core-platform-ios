import DesignSystem
import UIKit

/// A container that keeps a drawer BEHIND its main screen and reveals it by
/// sliding the main screen to the right — the sidebar of the Claude and
/// ChatGPT iOS apps. Open, the main screen is a dimmed sliver at the trailing
/// edge; a tap on the sliver, or a drag back, closes it.
///
/// ```
///   closed                       open
///   ┌──────────────┐             ┌──────────┬───┐
///   │              │             │ drawer   │ m │  ← main, slid right by
///   │     main     │             │ (behind) │ a │    `drawerWidth`, dimmed,
///   │              │             │          │ i │    corners rounded to the
///   │   [tab bar]  │             │          │ n │    bezel
///   └──────────────┘             └──────────┴───┘
/// ```
///
/// ## Why a custom container — there is no native one on iPhone
///
/// Checked against the iOS 27 SDK headers (Xcode 27.0), 2026-09-28:
/// - `UISplitViewController` COLLAPSES in a compact width: its primary and
///   secondary become one navigation stack (`isCollapsed`, "-showColumn:
///   pushes the column"), so a sidebar column on an iPhone is a push, which is
///   exactly what this replaces. Its iOS 26 `.inspector` column is a trailing
///   column with the same collapse.
/// - `UITabBarController.Sidebar` (iOS 18) is the TAB sidebar: it lists the
///   controller's `UITab`s, not arbitrary content, and on iPhone it is not
///   drawn — iOS 27's `preferredPlacement` says "when the sidebar and tab bar
///   are mutually exclusive… on iOS, this resolves to showing the tab bar".
/// - Nothing named drawer, slide-over or side panel exists in UIKit's public
///   headers.
///
/// ## What moves, and what does not
///
/// The whole main screen moves as ONE view (`mainHost`), by transform — its
/// navigation bars, its tab bar and its accessory included, which is what the
/// reference apps do and what keeps native chrome untouched: nothing here
/// writes an alpha or a frame on a bar (see `native-chrome-uikit-only`). The
/// transform is a translation, so the main screen never re-lays out while it
/// slides; its safe area in portrait is unchanged by it.
///
/// The drawer sits underneath at the leading edge, `drawerWidth` wide, with a
/// light parallax (it starts a quarter of its width to the left and arrives
/// with the main screen). Reduce Motion drops the parallax and the spring.
///
/// ## Gestures
///
/// - `edgePan` — a rightward drag that STARTS in the left edge band opens the
///   drawer following the finger (a plain pan, not a screen-edge recogniser:
///   see the property for why). It asks `canOpenInteractively` on every
///   touch, so the host decides where the edge belongs to the drawer (a tab
///   ROOT) and where it belongs to the navigation stack's own back swipe (a
///   pushed screen) or to nobody (a sheet up). It makes every competing drag
///   under the finger WAIT for it to fail, so a horizontal scroller at the
///   edge (a pager, the map) never steals an edge swipe — and, because it
///   only receives touches that land in the edge band, never delays a drag
///   that starts anywhere else.
/// - `closePan` — once open, a horizontal drag anywhere (sliver or drawer)
///   moves the main screen back with the finger.
/// - `dimTap` — a tap on the sliver closes.
///
/// A release settles by `SideDrawerMotion.shouldOpen` (velocity first, then
/// the projected resting point) on a critically damped spring seeded with the
/// finger's speed. A touch that lands mid-settle catches the main screen where
/// it is and carries on from there.
///
/// ## Appearance
///
/// The drawer child gets real appearance callbacks — `viewWillAppear` when it
/// starts to show, `viewDidAppear` when it settles open, the disappear pair
/// when it closes — so a drawer can refresh on its way in and mark things seen
/// once it has been looked at, without knowing it lives in a drawer. The main
/// child never "disappears" here: a sliver of it is always on screen.
@MainActor
public final class SideDrawerContainerViewController: UIViewController {
    /// Where the drawer is.
    public enum Phase: Equatable, Sendable {
        /// Hidden behind a main screen that covers the display.
        case closed
        /// A finger is moving it.
        case tracking
        /// Animating to rest, open or closed.
        case settling(open: Bool)
        /// At rest, open.
        case open
    }

    public let mainViewController: UIViewController
    public let drawerViewController: UIViewController

    /// Whether a left-edge swipe may open the drawer RIGHT NOW. Asked on every
    /// touch that lands in the edge band, so keep it cheap.
    public var canOpenInteractively: () -> Bool = { true }
    /// The drawer settled open.
    public var onDidOpen: (() -> Void)?
    /// The drawer settled closed.
    public var onDidClose: (() -> Void)?

    /// VoiceOver's name for the dimmed sliver, which is a button that closes.
    public var dimmingAccessibilityLabel = "Close" {
        didSet { dimView.accessibilityLabel = dimmingAccessibilityLabel }
    }

    /// What shows between the drawer and the main screen when a drag stretches
    /// past fully open — the drawer's own ground, so the stretch reads as the
    /// drawer growing rather than a gap opening.
    public var drawerBackgroundColor: UIColor = .systemGroupedBackground {
        didSet { if isViewLoaded { view.backgroundColor = drawerBackgroundColor } }
    }

    public private(set) var phase: Phase = .closed
    /// 0 closed … 1 open; above 1 while a drag stretches past open.
    public private(set) var progress: CGFloat = 0

    /// True when the drawer is open or on its way there.
    public var isOpen: Bool {
        phase == .open || phase == .settling(open: true)
    }

    /// The drawer's width for the current container size.
    public var drawerWidth: CGFloat {
        SideDrawerMotion.drawerWidth(forContainerWidth: view.bounds.width)
    }

    /// How far into the parallax the drawer starts: a quarter of its width to
    /// the left, arriving with the main screen.
    static let drawerParallax: CGFloat = 0.25
    /// The band along the left edge in which a touch can become an edge swipe.
    /// A touch that lands anywhere else is never shown to `edgePan`, so it
    /// never makes a scroller wait on it.
    static let edgeTouchBand: CGFloat = 28
    /// The settle spring. Critically damped: a drawer that bounces reads as a
    /// toy, and neither reference app overshoots.
    static let settleDuration: TimeInterval = 0.42
    static let reducedMotionDuration: TimeInterval = 0.22

    private let mainHost = UIView()
    private let dimView = DimmingView()
    private let drawerHost = DrawerHostView()

    /// The edge swipe: a PLAIN pan, held to the edge by where its touch landed
    /// (`shouldReceive`) and to a rightward horizontal drag (`shouldBegin`).
    ///
    /// ⚠️ NOT a `UIScreenEdgePanGestureRecognizer`, which was the first build.
    /// Measured on the iOS 27 simulator with injected drags starting at x = 8:
    /// the recogniser was SHOWN the touch (`shouldReceive` fired) and then
    /// failed on its own — `shouldBegin` never asked, no failure requirement
    /// ever queried — while the map under it panned. It decides edge-ness
    /// from the touch's own edge flags, not from its position, and a touch
    /// without them never qualifies. A plain pan decides from the position
    /// this class can see, so the same drag behaves the same wherever it comes
    /// from. (`-drawer-trace` prints each decision.)
    private(set) lazy var edgePan: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = self
        return recognizer
    }()
    private(set) lazy var closePan: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }()
    private(set) lazy var dimTap: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDimTap))
        recognizer.delegate = self
        return recognizer
    }()

    private enum AppearanceState { case disappeared, appearing, appeared, disappearing }
    private var drawerAppearance = AppearanceState.disappeared
    private var isDrawerViewInstalled = false
    private var trackingStartProgress: CGFloat = 0
    /// Bumped by every settle and every interruption, so a superseded
    /// animation's completion knows it no longer speaks for the drawer.
    private var settleGeneration = 0
    private var pendingCloseCompletions: [() -> Void] = []
    private var statusBarFollowsDrawer = false
    /// #561: the main screen blurs as it slides away — none at rest, full
    /// with the drawer open. Between `mainHost` and `dimView`, moved with
    /// them, so it blurs the LIVE main screen (video, map, glass bars) and the
    /// dim keeps the tap and VoiceOver's close on top.
    private let blurView = ProgressBlurView(style: .systemThinMaterial)
    /// Drives the blur through a settle, frame by frame from the main
    /// screen's presentation: a blur's strength does not animate inside the
    /// spring's `UIView.animate`.
    private var blurLink: CADisplayLink?

    public init(main: UIViewController, drawer: UIViewController) {
        self.mainViewController = main
        self.drawerViewController = drawer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = drawerBackgroundColor

        drawerHost.isHidden = true
        drawerHost.accessibilityElementsHidden = true
        drawerHost.onEscape = { [weak self] in self?.close() }
        view.addSubview(drawerHost)

        mainHost.layer.cornerCurve = .continuous
        view.addSubview(mainHost)
        addChild(mainViewController)
        mainViewController.view.frame = mainHost.bounds
        mainViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mainHost.addSubview(mainViewController.view)
        mainViewController.didMove(toParent: self)

        // The drawer is a child from the start (its trait and presentation
        // context are ours), but its VIEW is loaded only when it is first
        // revealed — `installDrawerViewIfNeeded`.
        addChild(drawerViewController)
        drawerViewController.didMove(toParent: self)

        // A SIBLING of the main screen, moved with it, rather than a subview of
        // it: the main screen's accessibility elements are hidden while the
        // drawer is open, and the sliver's close button must not be hidden
        // with them.
        dimView.layer.cornerCurve = .continuous
        dimView.alpha = 0
        dimView.isUserInteractionEnabled = false
        dimView.accessibilityLabel = dimmingAccessibilityLabel
        dimView.onActivate = { [weak self] in self?.close() }
        dimView.addGestureRecognizer(dimTap)
        view.addSubview(dimView)

        blurView.layer.cornerCurve = .continuous
        blurView.clipsToBounds = true
        blurView.accessibilityIdentifier = "side-drawer-main-blur"
        view.insertSubview(blurView, belowSubview: dimView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reduceTransparencyChanged),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil
        )

        view.addGestureRecognizer(edgePan)
        view.addGestureRecognizer(closePan)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        for host in [drawerHost, mainHost, blurView, dimView] as [UIView] {
            if host.bounds.size != bounds.size { host.bounds = CGRect(origin: .zero, size: bounds.size) }
            if host.center != centre { host.center = centre }
        }
        if isDrawerViewInstalled {
            let frame = CGRect(x: 0, y: 0, width: drawerWidth, height: bounds.height)
            if drawerViewController.view.frame != frame { drawerViewController.view.frame = frame }
        }
        // The bezel radius, set once it can be read and never animated: at
        // rest the clip is off, and while the main screen moves it is exactly
        // the display's own corner, so there is no step when it switches on.
        let radius = ScreenGeometry.cornerRadius(behind: view)
        if mainHost.layer.cornerRadius != radius {
            mainHost.layer.cornerRadius = radius
            dimView.layer.cornerRadius = radius
            blurView.layer.cornerRadius = radius
        }
        // A width change (rotation, a resize) moves the drawer's edge.
        applyProgress(progress)
    }

    // The children's appearance is forwarded by hand: the main screen's
    // follows the container's, the drawer's follows whether it is showing.
    public override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        mainViewController.beginAppearanceTransition(true, animated: animated)
        if phase != .closed { beginDrawerAppearance(true) }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        mainViewController.endAppearanceTransition()
        if phase == .open { endDrawerAppearance() }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        mainViewController.beginAppearanceTransition(false, animated: animated)
        if drawerAppearance == .appeared || drawerAppearance == .appearing { beginDrawerAppearance(false) }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        mainViewController.endAppearanceTransition()
        if drawerAppearance == .disappearing { endDrawerAppearance() }
    }

    // MARK: - Forwarded system appearance

    public override var childForStatusBarStyle: UIViewController? {
        statusBarFollowsDrawer ? drawerViewController : mainViewController
    }
    public override var childForStatusBarHidden: UIViewController? { mainViewController }
    public override var childForHomeIndicatorAutoHidden: UIViewController? { mainViewController }
    public override var childForScreenEdgesDeferringSystemGestures: UIViewController? { mainViewController }
    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        // A hero in the air pins the orientation it took off in — see
        // `FlightOrientationLock`.
        if FlightOrientationLock.isHeld,
           let current = view.window?.windowScene?.effectiveGeometry.interfaceOrientation,
           let held = FlightOrientationLock.mask(holding: current) {
            return held
        }
        return mainViewController.supportedInterfaceOrientations
    }
    public override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        mainViewController.preferredInterfaceOrientationForPresentation
    }

    // MARK: - Opening and closing

    /// Opens the drawer — the bell's action. A no-op when it is open, opening,
    /// or under a finger.
    public func open(animated: Bool = true) {
        guard isViewLoaded else { return }
        switch phase {
        case .open, .settling(open: true), .tracking: return
        case .closed, .settling(open: false): break
        }
        interruptSettle()
        mainViewController.view.endEditing(true)
        settle(open: true, velocity: 0, animated: animated)
    }

    /// Closes the drawer; `completion` runs once it is closed (at once when it
    /// already is). A drag in progress is cancelled — a close is an order.
    public func close(animated: Bool = true, completion: (() -> Void)? = nil) {
        guard isViewLoaded, phase != .closed else {
            completion?()
            return
        }
        if let completion { pendingCloseCompletions.append(completion) }
        if phase == .settling(open: false) { return }
        if phase == .tracking {
            // Toggling `isEnabled` cancels the recogniser; its `.cancelled`
            // arrives later and finds the phase already settling, and ignores it.
            for recognizer in [edgePan, closePan] as [UIGestureRecognizer] where recognizer.state != .possible {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
        }
        interruptSettle()
        settle(open: false, velocity: 0, animated: animated)
    }

    // MARK: - Tracking (the gestures' path, and the tests')

    /// A finger has taken the drawer.
    func beginTracking() {
        interruptSettle()
        if phase == .closed { mainViewController.view.endEditing(true) }
        phase = .tracking
        trackingStartProgress = progress
        setRevealed(true)
        beginDrawerAppearance(true)
    }

    /// The finger has moved `translation` points right of where it took hold.
    func updateTracking(translation: CGFloat) {
        guard phase == .tracking else { return }
        progress = SideDrawerMotion.progress(
            startProgress: trackingStartProgress, translation: translation, drawerWidth: drawerWidth
        )
        applyProgress(progress)
    }

    /// The finger let go at `velocity` points per second along x.
    func endTracking(velocity: CGFloat, animated: Bool = true) {
        guard phase == .tracking else { return }
        let open = SideDrawerMotion.shouldOpen(progress: progress, velocity: velocity, drawerWidth: drawerWidth)
        settle(open: open, velocity: velocity, animated: animated)
    }

    /// The gesture was cancelled: back to where it began.
    func cancelTracking(animated: Bool = true) {
        guard phase == .tracking else { return }
        settle(open: trackingStartProgress >= 0.5, velocity: 0, animated: animated)
    }

    /// True while an edge swipe may begin: the drawer is closed (or on its way
    /// there) and the host allows it.
    var edgeOpenIsAllowed: Bool {
        switch phase {
        case .closed, .settling(open: false): canOpenInteractively()
        case .tracking, .open, .settling(open: true): false
        }
    }

    /// True while the close gestures (drag back, tap on the sliver) are live.
    var closeGesturesAreArmed: Bool { isOpen }

    /// The main screen's current horizontal offset — for tests and probes.
    var mainScreenOffset: CGFloat { mainHost.transform.tx }
    /// Whether the main screen's accessibility elements are hidden.
    var mainScreenIsAccessibilityHidden: Bool { mainHost.accessibilityElementsHidden }
    /// Whether the drawer is on screen at all.
    var drawerIsRevealed: Bool { !drawerHost.isHidden }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state != .changed {
            Self.trace("\(recognizer === edgePan ? "edge" : "close") pan state \(recognizer.state.rawValue)")
        }
        switch recognizer.state {
        case .began:
            beginTracking()
            updateTracking(translation: recognizer.translation(in: view).x)
        case .changed:
            updateTracking(translation: recognizer.translation(in: view).x)
        case .ended:
            endTracking(velocity: recognizer.velocity(in: view).x)
        case .cancelled, .failed:
            cancelTracking()
        default:
            break
        }
    }

    @objc private func handleDimTap() {
        close()
    }

    // MARK: - Settling

    private func settle(open: Bool, velocity: CGFloat, animated: Bool) {
        let target: CGFloat = open ? 1 : 0
        phase = .settling(open: open)
        if open {
            setRevealed(true)
            beginDrawerAppearance(true)
        } else {
            beginDrawerAppearance(false)
        }
        settleGeneration += 1
        let generation = settleGeneration
        let finish: () -> Void = { [weak self] in
            guard let self, generation == settleGeneration else { return }
            finishSettle(open: open)
        }
        let from = progress
        progress = target
        guard animated, view.window != nil else {
            applyProgress(target)
            finish()
            return
        }
        // The blur follows the slide on screen, frame by frame, and lands on
        // the target with it — no pop at the end.
        startBlurLink()
        let landed: () -> Void = { [weak self] in
            guard let self, generation == settleGeneration else { return }
            stopBlurLink()
            blurView.setStrength(Self.blurStrength(forProgress: target))
            finish()
        }
        if MotionPreference.reducesMotion {
            UIView.animate(
                withDuration: Self.reducedMotionDuration, delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction]
            ) {
                self.applyProgress(target, drivesBlur: false)
            } completion: { _ in landed() }
        } else {
            let springVelocity = SideDrawerMotion.initialSpringVelocity(
                from: from, to: target, velocity: velocity, drawerWidth: drawerWidth
            )
            UIView.animate(
                springDuration: Self.settleDuration, bounce: 0, initialSpringVelocity: springVelocity,
                delay: 0, options: [.allowUserInteraction]
            ) {
                self.applyProgress(target, drivesBlur: false)
            } completion: { _ in landed() }
        }
    }

    // MARK: - Blur

    /// The blur's strength for a drawer at `progress`: the reveal itself,
    /// full past open (the rubber band), and none at all with Reduce
    /// Transparency on — the dim alone then.
    static func blurStrength(forProgress progress: CGFloat, reducesTransparency: Bool = UIAccessibility.isReduceTransparencyEnabled) -> CGFloat {
        reducesTransparency ? 0 : min(max(progress, 0), 1)
    }

    /// The blur's strength now — for tests and probes.
    var mainScreenBlurStrength: CGFloat { blurView.strength }

    private func startBlurLink() {
        stopBlurLink()
        let link = CADisplayLink(target: BlurLinkTarget(self), selector: #selector(BlurLinkTarget.tick))
        link.add(to: .main, forMode: .common)
        blurLink = link
    }

    private func stopBlurLink() {
        blurLink?.invalidate()
        blurLink = nil
    }

    /// One frame of a settle: the blur at the slide the screen shows.
    fileprivate func blurFrame() {
        guard drawerWidth > 0, let presentation = mainHost.layer.presentation() else { return }
        blurView.setStrength(Self.blurStrength(forProgress: presentation.affineTransform().tx / drawerWidth))
    }

    @objc private func reduceTransparencyChanged() {
        blurView.setStrength(Self.blurStrength(forProgress: progress))
    }

    private func finishSettle(open: Bool) {
        phase = open ? .open : .closed
        if !open { setRevealed(false) }
        endDrawerAppearance()
        if open {
            UIAccessibility.post(notification: .screenChanged, argument: drawerViewController.viewIfLoaded)
            onDidOpen?()
        } else {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
            onDidClose?()
            let completions = pendingCloseCompletions
            pendingCloseCompletions.removeAll()
            completions.forEach { $0() }
        }
    }

    /// Catches a settle where it is on screen, so a finger (or a reversed
    /// order) carries on from there instead of from where it was headed.
    private func interruptSettle() {
        guard case .settling = phase else { return }
        let current: CGFloat = if let presentation = mainHost.layer.presentation(), drawerWidth > 0 {
            presentation.affineTransform().tx / drawerWidth
        } else {
            progress
        }
        settleGeneration += 1
        stopBlurLink()
        for layer in [mainHost.layer, blurView.layer, dimView.layer, drawerHost.layer] {
            layer.removeAllAnimations()
        }
        progress = max(0, current)
        // The blur carries on from the slide the screen showed.
        applyProgress(progress)
    }

    // MARK: - Applying

    /// Places everything for `progress`. Animatable properties only — what is
    /// not animatable (visibility, clipping, accessibility) is `setRevealed`.
    /// `drivesBlur` is false inside a settle's animation, where the blur is
    /// driven frame by frame instead (`blurFrame`).
    private func applyProgress(_ progress: CGFloat, drivesBlur: Bool = true) {
        let width = drawerWidth
        let slide = CGAffineTransform(translationX: progress * width, y: 0)
        mainHost.transform = slide
        blurView.transform = slide
        dimView.transform = slide
        if drivesBlur { blurView.setStrength(Self.blurStrength(forProgress: progress)) }
        let reveal = min(max(progress, 0), 1)
        let parallax = MotionPreference.reducesMotion ? 0 : Self.drawerParallax
        drawerHost.transform = CGAffineTransform(translationX: -(1 - reveal) * width * parallax, y: 0)
        dimView.alpha = reveal
        let followsDrawer = reveal >= 0.5
        if followsDrawer != statusBarFollowsDrawer {
            statusBarFollowsDrawer = followsDrawer
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    /// Shows or hides the drawer layer and everything that goes with it.
    private func setRevealed(_ revealed: Bool) {
        if revealed { installDrawerViewIfNeeded() }
        drawerHost.isHidden = !revealed
        drawerHost.accessibilityElementsHidden = !revealed
        // Clipped only while it moves: at rest the main screen is untouched.
        mainHost.clipsToBounds = revealed
        dimView.clipsToBounds = revealed
        dimView.isUserInteractionEnabled = revealed
        dimView.isAccessibilityElement = revealed
        mainHost.accessibilityElementsHidden = revealed
    }

    private func installDrawerViewIfNeeded() {
        guard !isDrawerViewInstalled else { return }
        isDrawerViewInstalled = true
        let drawerView = drawerViewController.view!
        drawerView.frame = CGRect(x: 0, y: 0, width: drawerWidth, height: view.bounds.height)
        drawerView.autoresizingMask = [.flexibleHeight]
        drawerHost.addSubview(drawerView)
    }

    private func beginDrawerAppearance(_ appearing: Bool) {
        // No callbacks for a container that is not itself on screen; its own
        // appearance forwards them when it arrives.
        guard viewIfLoaded?.window != nil else { return }
        switch (appearing, drawerAppearance) {
        case (true, .disappeared), (true, .disappearing):
            drawerViewController.beginAppearanceTransition(true, animated: true)
            drawerAppearance = .appearing
        case (false, .appeared), (false, .appearing):
            drawerViewController.beginAppearanceTransition(false, animated: true)
            drawerAppearance = .disappearing
        default:
            break
        }
    }

    private func endDrawerAppearance() {
        switch drawerAppearance {
        case .appearing:
            drawerViewController.endAppearanceTransition()
            drawerAppearance = .appeared
        case .disappearing:
            drawerViewController.endAppearanceTransition()
            drawerAppearance = .disappeared
        case .appeared, .disappeared:
            break
        }
    }

    #if DEBUG
    /// Freezes the drawer at `progress` as if a finger held it there — for a
    /// still of a half-open state, which no simulator script can hold.
    public func debugHold(progress: CGFloat) {
        beginTracking()
        self.progress = SideDrawerMotion.rubberBanded(progress)
        applyProgress(self.progress)
    }

    /// Drives the tracking path — the one the gestures take, minus the
    /// recogniser — from the current progress to `target` over `duration`,
    /// then releases at `releaseVelocity` points per second.
    public func debugScriptedDrag(
        to target: CGFloat, duration: TimeInterval, releaseVelocity: CGFloat,
        completion: (@MainActor () -> Void)? = nil
    ) {
        beginTracking()
        let start = progress
        let width = drawerWidth
        let began = CACurrentMediaTime()
        Task { @MainActor [weak self] in
            while let self {
                let fraction = min(1, (CACurrentMediaTime() - began) / max(duration, 0.01))
                // Ease-out, like a finger decelerating toward where it stops.
                let eased = 1 - pow(1 - fraction, 2)
                self.updateTracking(translation: (target - start) * width * eased)
                if fraction >= 1 {
                    self.endTracking(velocity: releaseVelocity)
                    completion?()
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
    #endif
}

// MARK: - Gesture arbitration

extension SideDrawerContainerViewController: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === edgePan {
            // Only touches that land in the edge band — anywhere else this
            // recogniser takes no part, and nothing waits on it.
            let x = touch.location(in: view).x
            guard x <= Self.edgeTouchBand else { return false }
            let allowed = edgeOpenIsAllowed
            Self.trace("edge receive x=\(Int(x)) allowed=\(allowed)")
            return allowed
        }
        if gestureRecognizer === closePan || gestureRecognizer === dimTap {
            return closeGesturesAreArmed
        }
        return true
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === edgePan {
            // Rightward and mostly horizontal: a vertical drag from the edge
            // is the screen scrolling, and a leftward one is nothing of ours.
            let velocity = edgePan.velocity(in: view)
            let translation = edgePan.translation(in: view)
            let dx = translation.x != 0 ? translation.x : velocity.x
            let dy = translation.y != 0 ? translation.y : velocity.y
            let allowed = edgeOpenIsAllowed && Self.isRightwardSwipe(dx: dx, dy: dy)
            Self.trace("edge shouldBegin \(allowed) dx=\(Int(dx)) dy=\(Int(dy))")
            return allowed
        }
        if gestureRecognizer === closePan {
            guard closeGesturesAreArmed else { return false }
            // Horizontal only: a vertical drag in the drawer is its list
            // scrolling, and this pan steps aside for it.
            let velocity = closePan.velocity(in: view)
            return abs(velocity.x) > abs(velocity.y)
        }
        return true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard Self.competesForDrag(otherGestureRecognizer) else {
            if gestureRecognizer === edgePan {
                Self.trace("edge leaves alone: \(type(of: otherGestureRecognizer))")
            }
            return false
        }
        let otherIsInDrawer = otherGestureRecognizer.view?.isDescendant(of: drawerHost) == true
        // The edge swipe beats every drag on the main screen that starts in
        // the band: a pager at its first page would bounce, a map would pan.
        if gestureRecognizer === edgePan {
            // Only the main screen's own drags: UIKit's window-level gates
            // (`_UISystemGestureGateGestureRecognizer` turned up here) are the
            // system's to schedule, not ours.
            let otherIsInMain = otherGestureRecognizer.view?.isDescendant(of: mainHost) == true
            Self.trace("edge makes wait: \(type(of: otherGestureRecognizer)) → \(otherIsInMain)")
            return otherIsInMain
        }
        // The drag back beats the drawer's own list for a horizontal drag; it
        // fails at once for a vertical one, and the list scrolls.
        if gestureRecognizer === closePan { return otherIsInDrawer }
        return false
    }

    /// A drag heading right, within 45° of the horizontal.
    static func isRightwardSwipe(dx: CGFloat, dy: CGFloat) -> Bool {
        dx > 0 && dx >= abs(dy)
    }

    /// `-drawer-trace` (DEBUG): the edge swipe's decisions, one line each —
    /// which touches it was shown, whether it began, whom it made wait. A
    /// null edge swipe has three causes (never shown, refused, beaten) and
    /// only these lines tell them apart.
    static func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
        if isTracing { print("[drawer] \(line())") }
        #endif
    }

    #if DEBUG
    private static let isTracing = ProcessInfo.processInfo.arguments.contains("-drawer-trace")
    #endif

    /// Whether `other` is a DRAG that would fight for the same finger. Taps
    /// and presses are left alone: made to wait, a long press at the edge
    /// would never fire, because an edge pan under a still finger never fails.
    static func competesForDrag(_ other: UIGestureRecognizer) -> Bool {
        !(other is UITapGestureRecognizer)
            && !(other is UILongPressGestureRecognizer)
            && !(other is UIHoverGestureRecognizer)
    }
}

// MARK: - Views

/// The layer the drawer lives in. VoiceOver's escape (the two-finger Z)
/// anywhere in the drawer closes it.
private final class DrawerHostView: UIView {
    var onEscape: (() -> Void)?

    override func accessibilityPerformEscape() -> Bool {
        guard let onEscape else { return false }
        onEscape()
        return true
    }
}

/// The dim over the main screen's sliver. It takes the touches the main
/// screen would otherwise get while the drawer is open, and to VoiceOver it is
/// the button that closes.
private final class DimmingView: UIView {
    var onActivate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Deeper in the dark, where a light dim over dark content barely
        // registers; the alpha carries the progress, this the maximum.
        backgroundColor = UIColor { traits in
            UIColor.black.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.5 : 0.22)
        }
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return onActivate != nil
    }

    override func accessibilityPerformEscape() -> Bool {
        accessibilityActivate()
    }
}

/// Breaks the display link → controller retain cycle. Main-actor: the link
/// runs on the main run loop.
@MainActor
private final class BlurLinkTarget: NSObject {
    weak var container: SideDrawerContainerViewController?
    init(_ container: SideDrawerContainerViewController) { self.container = container }
    @objc func tick(_ link: CADisplayLink) {
        guard let container else {
            link.invalidate()
            return
        }
        container.blurFrame()
    }
}
