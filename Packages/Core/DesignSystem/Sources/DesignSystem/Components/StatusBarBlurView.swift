import UIKit

/// A progressive blur behind the system status bar (clock, network, battery):
/// strongest at the very top of the screen, gone at the bottom of the status
/// band (the window's top safe-area inset). It covers ONLY that band — the
/// navigation bar's pills below it stay on bare content.
///
/// ## ⚠️ Custom, behind a launch argument — why
///
/// UIKit has no public way to draw its own edge blur over the status band
/// alone. Measured on iOS 27 (2026-09-30, with a throwaway DEBUG probe that
/// dumped every `ScrollEdgeEffectView` frame): `UIScrollView.topEdgeEffect` has only a
/// style and a hidden flag, and its `.soft` extent is the safe area plus a
/// ~40pt fade (102pt on a pills-only bar), 156pt under a bar title and 198pt
/// under the inbox's pinned section pill; hiding the bar or re-pointing the
/// bar's content scroll view changed nothing, and
/// `UIScrollEdgeElementContainerInteraction` can only grow it. The Map's
/// gradient is MapKit's own copy of that effect (156pt, the whole header).
/// So the user asked (2026-09-30) for a custom reproduction, OFF by default,
/// on with `-status-bar-blur` (DEBUG builds only) — this view. It is a
/// hand-built frost, which is exactly what the 2026-09-22 decision rejected
/// ("doesn't look native"); keep it behind the argument until the user has
/// judged it on device.
///
/// ## How the ramp is built
///
/// A live backdrop blur must be a `UIVisualEffectView`; UIKit offers no
/// variable-radius blur. So the view holds `layerCount` blur views (ONE by
/// default), each masked (through `UIView.mask`, the one masking UIKit
/// supports on an effect view — never `layer.mask`) by a vertical gradient
/// that is opaque at the top and eases to zero lower down: layer `i` of `n`
/// fades out at `(i + 1) / n` of the band. The blur therefore cross-fades from
/// full strength at the screen's edge to nothing at the band's foot.
/// `StatusBarBlurView.maskStops` is the arithmetic.
///
/// ⚠️ Why one layer and full opacity (compared on screenshots, 2026-09-30,
/// iOS 27 sim, light and dark, over the profile poster, the snap feed's media
/// and For You scrolled and at rest): stacking three layers did NOT deepen
/// the blur — each effect view blurs the same backdrop — it only stacked the
/// material's TINT into a grey/white frost over photos. Three layers at half
/// opacity each lost the blur instead: text under the clock stayed sharp and
/// merely washed out. One `.systemUltraThinMaterial` layer at full opacity is
/// a real blur behind the clock with the least haze; `.regular` and `.light`
/// frost more (`.light` tints media orange-white). The layer count, peak
/// opacity and style stay tunable by launch argument for the user's device
/// judgement (`-status-bar-blur-layers`, `-status-bar-blur-peak`,
/// `-status-bar-blur-style`).
///
/// ## Geometry
///
/// Pinned to its host's top, full width, `height = bandHeight(…)`: the part of
/// the window's status band the host actually overlaps. A host that starts at
/// the window's top gets the whole band; a host lower down (a panel, a sheet)
/// gets nothing; landscape (no status bar, inset 0) gets nothing. Recomputed
/// on every layout, window move and safe-area change, so rotation and a
/// status bar that appears or hides are followed.
///
/// It sits ABOVE the host's content (`layer.zPosition`, so subviews added
/// later stay under it) and — being inside the controller's view — below the
/// navigation bar and its items. It never takes touches.
public final class StatusBarBlurView: UIView {

    // MARK: - Switch

    /// The launch argument that turns the blur on.
    public static let launchArgument = "-status-bar-blur"

    /// Whether `arguments` ask for the blur. Release builds never do.
    public static func isEnabled(arguments: [String]) -> Bool {
        #if DEBUG
        arguments.contains(launchArgument)
        #else
        false
        #endif
    }

    /// Whether this process asked for the blur.
    public static let isEnabled = isEnabled(arguments: ProcessInfo.processInfo.arguments)

    /// Adds the blur to `host` (a full-screen controller's view) when the
    /// launch argument is on; a no-op otherwise, and a no-op when `host`
    /// already carries one. Returns the installed view, or nil.
    @discardableResult
    public static func install(in host: UIView, enabled: Bool = isEnabled) -> StatusBarBlurView? {
        guard enabled else { return nil }
        if let existing = host.subviews.lazy.compactMap({ $0 as? StatusBarBlurView }).first {
            return existing
        }
        let arguments = ProcessInfo.processInfo.arguments
        let blur = StatusBarBlurView(style: tunedStyle(arguments: arguments),
                                     layerCount: tunedLayerCount(arguments: arguments),
                                     peak: tunedPeak(arguments: arguments))
        host.addSubview(blur)
        blur.translatesAutoresizingMaskIntoConstraints = false
        let height = blur.heightAnchor.constraint(equalToConstant: 0)
        blur.heightConstraint = height
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: host.topAnchor),
            blur.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            height,
        ])
        return blur
    }

    // MARK: - Arithmetic

    /// How much of the window's status band (`statusBandHeight`, the window's
    /// top safe-area inset) a host whose top edge sits at `hostTopInWindow`
    /// overlaps. Never negative, never more than the band.
    public static func bandHeight(statusBandHeight: CGFloat, hostTopInWindow: CGFloat) -> CGFloat {
        min(max(0, statusBandHeight - hostTopInWindow), max(0, statusBandHeight))
    }

    /// The mask of blur layer `index` of `count`, as gradient `(locations,
    /// alphas)` from the band's top (0) to its foot (1): opaque at the top,
    /// zero from `(index + 1) / count` down, eased (smoothstep) in between so
    /// no layer ends on a visible line.
    public static func maskStops(index: Int, count: Int, peak: CGFloat = 1) -> [(location: CGFloat, alpha: CGFloat)] {
        let peak = min(max(peak, 0), 1)
        let count = max(1, count)
        let end = CGFloat(min(max(index, 0), count - 1) + 1) / CGFloat(count)
        let samples = 6
        var stops: [(CGFloat, CGFloat)] = []
        for step in 0...samples {
            let t = CGFloat(step) / CGFloat(samples)
            let eased = t * t * (3 - 2 * t)
            stops.append((end * t, peak * (1 - eased)))
        }
        stops.append((1, 0))
        return stops
    }

    // MARK: - Tuning (QA only)

    /// `-status-bar-blur-style ultrathin|thin|regular|chrome|plain|light|dark`
    /// (`plain` = `UIBlurEffect.Style.regular`, `regular` = `.systemMaterial`).
    /// Default `.systemUltraThinMaterial`: the least tint of the materials,
    /// so the band reads as blur rather than frost.
    static func tunedStyle(arguments: [String]) -> UIBlurEffect.Style {
        guard let index = arguments.firstIndex(of: "-status-bar-blur-style"),
              index + 1 < arguments.count
        else { return .systemUltraThinMaterial }
        return switch arguments[index + 1] {
        case "thin": .systemThinMaterial
        case "regular": .systemMaterial
        case "chrome": .systemChromeMaterial
        case "light": .light
        case "dark": .dark
        case "plain": .regular
        default: .systemUltraThinMaterial
        }
    }

    /// `-status-bar-blur-layers <1…6>`, default 1 (see "Why one layer").
    static func tunedLayerCount(arguments: [String]) -> Int {
        guard let index = arguments.firstIndex(of: "-status-bar-blur-layers"),
              index + 1 < arguments.count, let count = Int(arguments[index + 1])
        else { return 1 }
        return min(max(count, 1), 6)
    }

    /// `-status-bar-blur-peak <0…1>`: each layer's opacity at the very top,
    /// default 1 (see "Why one layer").
    static func tunedPeak(arguments: [String]) -> CGFloat {
        guard let index = arguments.firstIndex(of: "-status-bar-blur-peak"),
              index + 1 < arguments.count, let peak = Double(arguments[index + 1])
        else { return 1 }
        return min(max(CGFloat(peak), 0), 1)
    }

    // MARK: - View

    private var heightConstraint: NSLayoutConstraint?
    private let style: UIBlurEffect.Style
    let blurLayers: [UIVisualEffectView]

    init(style: UIBlurEffect.Style, layerCount: Int, peak: CGFloat) {
        self.style = style
        // ⚠️ `effect: nil` here, the blur set on window attach: materialising a
        // `UIBlurEffect` in an initialiser contacts the render server, which
        // stalled headless CI ~45s (PR #46, see the ticker's blur view).
        blurLayers = (0..<max(1, layerCount)).map { index in
            let effect = UIVisualEffectView(effect: nil)
            effect.mask = GradientMaskView(stops: StatusBarBlurView.maskStops(index: index, count: layerCount, peak: peak))
            return effect
        }
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.zPosition = 1_000
        clipsToBounds = true
        blurLayers.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            for layerView in blurLayers where layerView.effect == nil {
                layerView.effect = UIBlurEffect(style: style)
            }
        }
        updateHeight()
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateHeight()
    }

    public override func layoutSubviews() {
        updateHeight()
        super.layoutSubviews()
        for layerView in blurLayers {
            layerView.frame = bounds
            layerView.mask?.frame = layerView.bounds
        }
    }

    private func updateHeight() {
        guard let heightConstraint else { return }
        var target: CGFloat = 0
        if let window, let host = superview {
            let hostTop = host.convert(CGPoint.zero, to: window).y
            target = Self.bandHeight(statusBandHeight: window.safeAreaInsets.top, hostTopInWindow: hostTop)
        }
        if abs(heightConstraint.constant - target) > 0.5 {
            heightConstraint.constant = target
            superview?.setNeedsLayout()
        }
        isHidden = target <= 0
    }
}

/// A `UIView.mask` whose alpha follows a vertical gradient.
private final class GradientMaskView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    init(stops: [(location: CGFloat, alpha: CGFloat)]) {
        super.init(frame: .zero)
        let gradient = layer as! CAGradientLayer
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.locations = stops.map { NSNumber(value: Double($0.location)) }
        gradient.colors = stops.map { UIColor.black.withAlphaComponent($0.alpha).cgColor }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
