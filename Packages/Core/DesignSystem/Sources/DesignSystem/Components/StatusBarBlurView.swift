import UIKit

/// The blur behind the system status bar (clock, network, battery) on the
/// full-screen screens. It is the SAME effect the Map draws under its status
/// bar, not a copy of it: UIKit's own top scroll edge effect, hosted by an
/// empty scroll view that does nothing else.
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
/// status-bar tap, invisible to VoiceOver, empty. The dump of this view's
/// effect on For You, Messages, Profile (tab root and pushed) and the place
/// page matched the Map's filter for filter — same radius, scale, height and a
/// byte-identical mask image — in light and in dark; the snap feed, which
/// always wears dark, matched the Map's dark variant. The previous
/// version (#333, a masked `UIVisualEffectView` behind `-status-bar-blur`) was
/// a hand-built frost and could never match it.
///
/// ## ⚠️ A bar TITLE changes what UIKit draws
///
/// `.automatic` is resolved from the navigation bar the screen sits under (a
/// `FloatingBarContainerView` trait the navigation controller hands down — not
/// public, not overridable). Under a bar with a title it becomes the whole
/// header: 156pt, a gaussian frost plus a tinting colour matrix — the header
/// blur the 2026-09-22 decision removed. Measured on the post detail ("Post"):
/// hosting the scroll view in a child controller, in a nested navigation
/// controller, or clipping it to the status band all kept that variant; only
/// removing the title (or leaving the navigation controller's hierarchy
/// altogether) gave the Map's. So a screen with a bar title must NOT install
/// this view — which is why the post detail does not.
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
/// Pinned to all four edges of its host (a full-screen controller's view), so
/// the scroll view inherits exactly the safe area a real list there would —
/// which is what UIKit sizes the effect from. Hidden when the host does not
/// reach into the window's status band (`bandHeight == 0`): a panel or sheet
/// lower down, landscape without a status bar. It sits above the host's
/// content (`layer.zPosition`, so subviews added later stay under it) and —
/// being inside the controller's view — below the navigation bar and its
/// items.
///
/// ## Cost
///
/// One backdrop over the status band, the one the Map draws and the one every
/// list here would draw if it did not hide its own. On the iOS 27 simulator,
/// dragging For You for 12s: 720 frames, every one 16.67ms, with and without
/// the view (main-thread pacing; render-server cost is a device question).
public final class StatusBarBlurView: UIView {

    /// Adds the blur to `host` (a full-screen controller's view, under a bar
    /// with no title — see above); a no-op when `host` already carries one.
    /// Returns the installed view.
    @discardableResult
    public static func install(in host: UIView) -> StatusBarBlurView {
        if let existing = host.subviews.lazy.compactMap({ $0 as? StatusBarBlurView }).first {
            return existing
        }
        let blur = StatusBarBlurView()
        host.addSubview(blur)
        blur.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: host.topAnchor),
            blur.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return blur
    }

    // MARK: - Arithmetic

    /// How much of the window's status band (`statusBandHeight`, the window's
    /// top safe-area inset) a host whose top edge sits at `hostTopInWindow`
    /// overlaps. Never negative, never more than the band. Zero hides the
    /// view.
    public static func bandHeight(statusBandHeight: CGFloat, hostTopInWindow: CGFloat) -> CGFloat {
        min(max(0, statusBandHeight - hostTopInWindow), max(0, statusBandHeight))
    }

    // MARK: - View

    /// The empty scroll view whose top edge effect IS the blur.
    let edgeScrollView: UIScrollView = InertEdgeScrollView()
    private var hidesOtherEdges = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.zPosition = 1_000
        addSubview(edgeScrollView)
    }

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
