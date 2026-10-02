import UIKit

/// The blur behind the system status bar (clock, network, battery), on EVERY
/// screen of the app. It is the SAME effect the Map draws under its status
/// bar, not a copy of it: UIKit's own top scroll edge effect, hosted by an
/// empty scroll view that does nothing else — installed ONCE, in the window.
///
/// ## Why an inert scroll view
///
/// The Map's blur is not drawn by this app. `MKMapView` hosts a
/// `ScrollEdgeEffectView` of its own (style `.automatic`), and on a screen whose
/// navigation bar carries only glass items and no title, UIKit resolves that
/// style to a variable blur over the status band alone. Dumped on iOS 27
/// (2026-10-01): one backdrop, 402x62, `variableBlur` radius 2 at half scale,
/// full strength down to ~20% of the band, then an eased falloff to nothing at
/// its foot; in dark mode a second, half-opacity gaussian backdrop is added
/// over the same 62pt. No tint, nothing under the bar's items.
///
/// Every scroll view draws that effect — this app's lists HIDE theirs
/// (`prefersClearTopEdge`, the 2026-09-22 "no blur under any header"
/// decision). So this view brings back one, on a scroll view whose only job is
/// to own it: never scrolls, never takes a touch, never answers the
/// status-bar tap, invisible to VoiceOver, empty. The previous version (#333,
/// a masked `UIVisualEffectView` behind `-status-bar-blur`) was a hand-built
/// frost and could never match it.
///
/// ## Why in the WINDOW, not in each screen (2026-10-02)
///
/// Until then (#337) five full-screen screens each installed one in their own
/// view. The user asked for the band to be there ALWAYS — every pushed screen,
/// every presentation, every frame of a transition. A band inside a screen
/// travels with that screen: a hero flight scales the destination up from its
/// card, band included, and a screen without an install (the post detail, the
/// pushed lists, the galleries) had none. One band in the window, over
/// everything the app draws, belongs to no screen.
///
/// - **Over every presentation.** UIKit adds each one as a later window
///   subview; the band's `layer.zPosition` keeps it drawn over all of them,
///   whatever their order (hit-testing ignores `zPosition`, and the band takes
///   no touch anyway). The status bar itself is the system's, in a window
///   above this one.
/// - **The bar-title trap is gone.** `.automatic` is resolved from the
///   navigation bar a scroll view sits under (a `FloatingBarContainerView`
///   trait the navigation controller hands down — not public, not
///   overridable): under a bar with a TITLE it becomes the whole header,
///   156pt, a gaussian frost plus a tinting colour matrix — the header blur
///   the 2026-09-22 decision removed. Measured on the post detail in #337:
///   only removing the title, or leaving the navigation controller's
///   hierarchy altogether, gave the Map's. A window subview is outside every
///   navigation controller, so titled screens get the Map's band too.
/// - **Sheets.** A sheet's top sits below the status band, so the band lies
///   over what the sheet leaves visible behind the clock — the presenting
///   screen, dimmed — just as it did before the sheet came up. It never
///   blurs a sheet's own content: the camera is a full-height sheet, its
///   preview starts under the grabber.
/// - **Blur over blur** where something under the band draws an edge effect of
///   its own: the Map (MapKit's, the same effect) and the notifications
///   drawer (its soft edge). Kept on purpose: one more backdrop over 62pt,
///   and no rule about which screen is on top to get wrong mid-transition.
///
/// ## Light and dark
///
/// The band follows the window's style. A screen that pins a style of its own
/// while it covers the band — the snap feed is dark over a photograph — LENDS
/// it (`lendStyle(_:from:)`) and takes it back when it leaves
/// (`returnStyle(from:)`), so the band wears the dark variant over it, as it
/// did when it lived in that screen's view.
///
/// ## Why it is "scrolled"
///
/// The effect only shows over content that has scrolled under the edge: at
/// rest at the top of its content it sits at alpha 0. The scroll view is
/// given an empty content area three screens tall, offset by one screen, so
/// the effect is always on.
///
/// ## Geometry
///
/// The whole window, so the scroll view inherits the window's safe area —
/// what UIKit sizes the effect from. Hidden when the window has no status
/// band (`bandHeight == 0`: landscape without a status bar).
///
/// ## Cost
///
/// One backdrop over the status band — the one the Map draws, and the one
/// every list here would draw if it did not hide its own — made once per
/// window instead of once per screen. On the iOS 27 simulator (#337),
/// dragging For You for 12s: 720 frames, every one 16.67ms, with and without
/// it (main-thread pacing; render-server cost is a device question).
public final class StatusBarBlurView: UIView {

    /// Adds the band to `window`, over everything the app draws in it; a no-op
    /// when the window already carries one. Returns the band.
    ///
    /// A window only, never a screen's view — see "Why in the WINDOW".
    @discardableResult
    public static func install(in window: UIWindow) -> StatusBarBlurView {
        if let existing = installed(in: window) { return existing }
        let blur = StatusBarBlurView()
        blur.frame = window.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(blur)
        return blur
    }

    /// The band `window` carries, if any.
    public static func installed(in window: UIWindow?) -> StatusBarBlurView? {
        window?.subviews.lazy.compactMap { $0 as? StatusBarBlurView }.first
    }

    // MARK: - Arithmetic

    /// How much of the window's status band (`statusBandHeight`, the window's
    /// top safe-area inset) a view whose top edge sits at `hostTopInWindow`
    /// overlaps. Never negative, never more than the band. Zero hides the
    /// band.
    public static func bandHeight(statusBandHeight: CGFloat, hostTopInWindow: CGFloat) -> CGFloat {
        min(max(0, statusBandHeight - hostTopInWindow), max(0, statusBandHeight))
    }

    // MARK: - Style

    /// Who lent the band its current style, if anyone.
    private(set) weak var styleLender: AnyObject?

    /// Makes the band wear `style` on behalf of `lender`: a screen that pins
    /// its own style while it covers the band. `.unspecified` is the window's
    /// style, with `lender` still the owner. The latest lender wins.
    public func lendStyle(_ style: UIUserInterfaceStyle, from lender: AnyObject) {
        styleLender = lender
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
    }

    /// Hands the band back to the window's style — only if `lender` is still
    /// the one that lent it, so a screen leaving late never undoes the style
    /// of the screen that came over it.
    public func returnStyle(from lender: AnyObject) {
        guard styleLender === lender else { return }
        styleLender = nil
        overrideUserInterfaceStyle = .unspecified
    }

    // MARK: - View

    /// The empty scroll view whose top edge effect IS the blur.
    let edgeScrollView: UIScrollView = InertEdgeScrollView()
    private var hidesOtherEdges = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.zPosition = Self.zPosition
        addSubview(edgeScrollView)
    }

    /// Over every sibling in the window: presentations' containers, a hero
    /// flight's chrome replica, the emote suggestion strip — all at 0.
    static let zPosition: CGFloat = 10_000

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // ⚠️ On window attach, not in `init`: touching an edge effect
        // materialises Liquid Glass machinery, which once held a headless CI
        // test process ~64s (see `prefersClearTopEdge`). The TOP effect is
        // left exactly as UIKit made it — `.automatic`, shown — because that
        // default is the Map's look; only the edges that would draw over the
        // tab bar and the screen's sides go.
        if window != nil, !hidesOtherEdges {
            hidesOtherEdges = true
            edgeScrollView.bottomEdgeEffect.isHidden = true
            edgeScrollView.leftEdgeEffect.isHidden = true
            edgeScrollView.rightEdgeEffect.isHidden = true
        }
        setNeedsLayout()
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        var band: CGFloat = 0
        if let window {
            let top = convert(CGPoint.zero, to: window).y
            band = Self.bandHeight(statusBandHeight: window.safeAreaInsets.top, hostTopInWindow: top)
        }
        isHidden = band <= 0
        // A lender gone without handing the style back (released mid-flight)
        // must not leave the band pinned.
        if styleLender == nil, overrideUserInterfaceStyle != .unspecified {
            overrideUserInterfaceStyle = .unspecified
        }
        edgeScrollView.frame = bounds
        // "Scrolled" over empty content, so the effect shows (see above).
        let size = CGSize(width: bounds.width, height: bounds.height * 3)
        if edgeScrollView.contentSize != size { edgeScrollView.contentSize = size }
        let offset = CGPoint(x: 0, y: bounds.height)
        if edgeScrollView.contentOffset != offset { edgeScrollView.contentOffset = offset }
    }
}

/// An empty scroll view that only exists to draw its top edge effect.
///
/// ⚠️ `scrollsToTop = false` is load-bearing: when more than one on-screen
/// scroll view answers the status-bar tap, NONE of them scrolls, and the
/// screen's real list would lose tap-to-top.
private final class InertEdgeScrollView: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isScrollEnabled = false
        scrollsToTop = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
