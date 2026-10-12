import UIKit

/// The blur at the foot of the screen: the mirror of `StatusBarBlurView`.
/// Full strength at the screen's bottom edge, easing out to nothing upward,
/// exactly as tall as the status band at the top (62pt on an iPhone 18 Pro).
/// Asked for on 2026-10-12 (#1002), with the height "symmetric to the top".
///
/// ## Why UIKit's bottom edge effect, and how it is reached
///
/// Like the top band, it is UIKit's own scroll edge effect on an empty, inert
/// scroll view — never a hand-built frost (the 2026-09-22 lesson: a masked
/// material reads as non-native). Getting the bottom one took three findings,
/// all measured on iOS 27 (2026-10-12):
///
/// - **A bottom edge draws nothing on its own.** The top band exists because
///   the status bar sits over the scroll view's top edge; nothing plays that
///   part at the bottom, so UIKit never even creates the bottom effect view.
///   A view registered with `UIScrollEdgeElementContainerInteraction` over
///   the bottom edge is what makes it: here `pocket`, at the foot.
/// - **The container must hold content.** An empty one, or one holding a
///   bare view or `UIControl`, still drew nothing; a `UILabel` does, even
///   with clear text. `element` is that label: one space, clear ink, hidden
///   from VoiceOver.
/// - **`.soft` is the gradient.** `.automatic` and `.hard` drew a flat tinted
///   band with a hard top edge over the pocket; `.soft` draws a variable blur
///   plus a half-opacity gaussian, both masked full at the bottom and easing
///   to nothing — the top band's look, upside down. Its height is
///   `softEdgeHeight` (60pt) whatever the pocket's height, so the scroll view
///   is scaled vertically, about its bottom edge, by `statusBand /
///   softEdgeHeight` to make it the status band's height. (Mirroring the top
///   band with a flip transform was tried first: UIKit sees the flip and
///   resolves the effect to nothing.)
///
/// ## Why in each navigation controller, not in the window
///
/// The top band lies over everything because nothing of the app's own is
/// drawn in the status band. The bottom 62pt hold the app's chrome: the tab
/// bar, a pushed screen's floating toolbar (the snap feed's), the bottom
/// accessory. A band over them blurred them (filmed: the tab bar's labels
/// smeared). So the band sits UNDER the chrome and OVER the screens: one per
/// navigation controller, inserted directly above its content
/// (`UINavigationTransitionView`, the first subview), below its navigation
/// bar and toolbar — and the tab bar, drawn by the tab bar controller over
/// the whole navigation controller, stays above it too. Like the top band it
/// belongs to no screen: pushes and pops slide the screens under it.
///
/// Installed in the four tab stacks (`MainTabCoordinator`). Not in sheets or
/// full-screen presentations, which draw their own bottom.
///
/// ## Light and dark
///
/// Follows the stack's style. The snap feed lends its settled page's style
/// to it as it does to the top band (`lendStyle(_:from:)`).
///
/// ## Touches, VoiceOver, tap-to-top
///
/// None: the band, its scroll view and its label take no touch, are hidden
/// from VoiceOver, and the scroll view never answers the status-bar tap
/// (`InertEdgeScrollView`).
///
/// Verify with `-status-bar-blur-audit`: each frame prints the bottom band's
/// height (`bottom=`) next to the top one's.
public final class BottomEdgeBlurView: UIView {

    /// Inserts the band into `navigationController`'s view, directly above
    /// its content; a no-op when it already carries one. Returns the band.
    @discardableResult
    public static func install(in navigationController: UINavigationController) -> BottomEdgeBlurView {
        if let existing = installed(in: navigationController) { return existing }
        let band = BottomEdgeBlurView()
        let root = navigationController.view!
        band.frame = root.bounds
        band.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Index 0 is the content (`UINavigationTransitionView`); the bar
        // above it, and the toolbar UIKit adds later, stay over the band.
        root.insertSubview(band, at: min(1, root.subviews.count))
        return band
    }

    /// The band `navigationController` carries, if any.
    public static func installed(in navigationController: UINavigationController?) -> BottomEdgeBlurView? {
        navigationController?.viewIfLoaded?.subviews.lazy.compactMap { $0 as? BottomEdgeBlurView }.first
    }

    // MARK: - Arithmetic

    /// The height of UIKit's `.soft` bottom edge effect, whatever the
    /// pocket's height (measured on iOS 27, iPhone 18 Pro, 2026-10-12).
    static let softEdgeHeight: CGFloat = 60

    /// The vertical scale that makes the soft effect `statusBandHeight` tall.
    /// Zero hides the band (no status band: landscape).
    public static func scale(statusBandHeight: CGFloat) -> CGFloat {
        max(0, statusBandHeight) / softEdgeHeight
    }

    // MARK: - Style

    /// Who lent the band its current style, if anyone.
    private(set) weak var styleLender: AnyObject?

    /// Makes the band wear `style` on behalf of `lender`; the latest lender
    /// wins. Same contract as `StatusBarBlurView.lendStyle(_:from:)`.
    public func lendStyle(_ style: UIUserInterfaceStyle, from lender: AnyObject) {
        styleLender = lender
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
    }

    /// Hands the band back to the stack's style — only if `lender` is still
    /// the one that lent it.
    public func returnStyle(from lender: AnyObject) {
        guard styleLender === lender else { return }
        styleLender = nil
        overrideUserInterfaceStyle = .unspecified
    }

    // MARK: - View

    /// The empty scroll view whose bottom edge effect IS the blur.
    let edgeScrollView: UIScrollView = InertEdgeScrollView()
    /// Registered over the scroll view's bottom edge, so UIKit draws it.
    let pocket = UIView()
    /// The content the pocket must hold for the effect to be drawn.
    let element = UILabel()
    private var configuredEdges = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        edgeScrollView.layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        addSubview(edgeScrollView)
        pocket.isUserInteractionEnabled = false
        pocket.accessibilityElementsHidden = true
        element.text = " "
        element.textColor = .clear
        element.isAccessibilityElement = false
        pocket.addSubview(element)
        addSubview(pocket)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // ⚠️ On window attach, not in `init`: touching an edge effect
        // materialises Liquid Glass machinery (see `StatusBarBlurView`).
        if window != nil, !configuredEdges {
            configuredEdges = true
            edgeScrollView.topEdgeEffect.isHidden = true
            edgeScrollView.leftEdgeEffect.isHidden = true
            edgeScrollView.rightEdgeEffect.isHidden = true
            edgeScrollView.bottomEdgeEffect.style = .soft
            let interaction = UIScrollEdgeElementContainerInteraction()
            interaction.scrollView = edgeScrollView
            interaction.edge = .bottom
            pocket.addInteraction(interaction)
        }
        setNeedsLayout()
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let band = window?.safeAreaInsets.top ?? 0
        // ⚠️ `softEdgeHeight` is measured on iOS 27 (iPhone 18 Pro); check
        // `-status-bar-blur-audit`'s `bottom=` against `h=` on a new OS or
        // device class.
        let scale = Self.scale(statusBandHeight: band)
        isHidden = scale <= 0
        if styleLender == nil, overrideUserInterfaceStyle != .unspecified {
            overrideUserInterfaceStyle = .unspecified
        }
        guard scale > 0 else { return }
        // Scaled about its bottom edge (anchor at the foot), so the effect
        // ends exactly at the screen's bottom and rises `band` points.
        let transform = CGAffineTransform(scaleX: 1, y: scale)
        if edgeScrollView.bounds.size != bounds.size || edgeScrollView.transform != transform {
            edgeScrollView.transform = .identity
            edgeScrollView.bounds = CGRect(origin: edgeScrollView.bounds.origin, size: bounds.size)
            edgeScrollView.center = CGPoint(x: bounds.midX, y: bounds.maxY)
            edgeScrollView.transform = transform
        }
        // "Scrolled" over empty content both ways, so the effect shows.
        let size = CGSize(width: bounds.width, height: bounds.height * 3)
        if edgeScrollView.contentSize != size { edgeScrollView.contentSize = size }
        let offset = CGPoint(x: 0, y: bounds.height)
        if edgeScrollView.contentOffset != offset { edgeScrollView.contentOffset = offset }
        // Taller than the effect, so its height is UIKit's cap and nothing
        // of the pocket's own.
        pocket.frame = CGRect(x: 0, y: bounds.maxY - band, width: bounds.width, height: band)
        element.frame = pocket.bounds
    }
}
