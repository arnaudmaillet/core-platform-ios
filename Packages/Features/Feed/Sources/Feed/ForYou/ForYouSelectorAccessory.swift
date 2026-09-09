import DesignSystem
import UIKit

/// Whether the For You selector rides the BOTTOM of the screen instead of the
/// navigation bar.
///
/// ⚠️ A SPIKE, BEHIND A FLAG. In Release the flag is a literal `false`, so the
/// optimiser drops every branch and the arrangement that ships is unchanged.
enum ForYouSelectorDock {
    /// `-foryou-dock-selector`: the strip moves to a `UITabAccessory`.
    static var isRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-foryou-dock-selector")
        #else
        false
        #endif
    }

    /// `-foryou-dock-glass`: the strip keeps its own capsule rather than
    /// rendering bare. Measured both ways — see `ForYouSelectorAccessoryHost`.
    static var keepsOwnGlass: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-foryou-dock-glass")
        #else
        false
        #endif
    }

    /// `-foryou-dock-trace`: one line per layout and per environment change.
    static var isTracing: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-foryou-dock-trace")
        #else
        false
        #endif
    }
}

/// The view a `UITabAccessory` is built around: a `PagedTabBar` and the rules
/// that keep it a control at both of the widths UIKit hands it.
///
/// # What the accessory actually gives you
///
/// Measured on iPhone 17 Pro / iOS 26.5 with `-tab-accessory-probe`, reading
/// the content view's own superview:
///
///     regular   _UITabAccessoryContainer 360x48
///     inline    _UITabAccessoryContainer 234x48
///
/// Two things fall out of that, and both contradict what you would assume:
///
/// ⚠️ **UIKIT ADDS NO PLATTER OF ITS OWN.** The container is EXACTLY the
/// content view's size in both environments — unlike a `UIBarButtonItem`, whose
/// custom view rides inside a 44pt glass platter the app does not own. So
/// nothing here is drawn for us: whatever backdrop the band shows is the
/// strip's own.
///
/// ⚠️ **`.inline` IS NOT SHORTER.** "Inline with the collapsed bottom tab bar"
/// reads like a shorter band and is not one: 48pt in both. What changes is the
/// WIDTH, 360 → 234, because the collapsed bar keeps a bubble at each end.
///
/// # Why there is no width cap here
///
/// The navigation bar needed one — `LeadingSelectorHost` exists because UIKit
/// silently declines to host an over-wide leading custom view and sweeps the
/// group into a `•••`. **An accessory has no item groups and no overflow
/// control, so that failure cannot happen here.** The analogous one can: a
/// width bounded only from above, with nothing requiring it positive, is how
/// `LeadingSelectorHost` once settled at zero and was not hosted at all. So the
/// strip is pinned leading and trailing with `equalTo` and given no width
/// constraint of any kind — under-width it SCROLLS, keeping every title whole
/// (`PagedTabBar`'s segment widths are required, and its content is `>=` the
/// frame guide).
final class ForYouSelectorAccessoryHost: UIView {
    private let strip: PagedTabBar
    private let stripHeight: CGFloat

    /// Fired from `layoutSubviews`, because there is no other signal.
    ///
    /// ⚠️ `UITabAccessory` has exactly ONE property — its content view. There
    /// is no delegate, no `willMinimize`, no notification; the environment is a
    /// trait and nothing else. A screen that needs to know the chrome moved
    /// hears it here.
    var onLayoutChanged: (() -> Void)?

    init(strip: PagedTabBar) {
        self.strip = strip
        // Bare, the capsule's padding and lens inset are zero, so the strip is
        // its segments and nothing more; with its own glass it wants the full
        // 44 the capsule is drawn for.
        self.stripHeight = ForYouSelectorDock.keepsOwnGlass ? 44 : 36
        super.init(frame: .zero)

        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)

        let height = strip.heightAnchor.constraint(equalToConstant: stripHeight)
        // ⚠️ 999, NOT REQUIRED. The container is 48pt today in both
        // environments, but a required equality would break constraints
        // outright the first time UIKit hands out a shorter band — where the
        // `<=` below simply makes the strip shorter, which is the direction
        // that still renders.
        height.priority = .init(999)

        NSLayoutConstraint.activate([
            // No width constraint. See the note above.
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.centerYAnchor.constraint(equalTo: centerYAnchor),
            height,
            strip.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor)
        ])

        // The one appearance property that may change after init, and the only
        // per-environment lever there is: filled reads as a bar across the full
        // width, hugging reads as a control docked beside the tab bubbles.
        registerForTraitChanges([UITraitTabAccessoryEnvironment.self]) {
            (self: ForYouSelectorAccessoryHost, _) in
            self.applyEnvironment()
            self.trace("trait")
        }
        applyEnvironment()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: stripHeight + 8)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trace("layout")
        onLayoutChanged?()
    }

    private func applyEnvironment() {
        strip.fillsWidth = traitCollection.tabAccessoryEnvironment == .regular
    }

    private var lastTrace = ""

    private func trace(_ reason: String) {
        guard ForYouSelectorDock.isTracing else { return }
        let environment: String
        switch traitCollection.tabAccessoryEnvironment {
        case .inline: environment = "inline"
        case .regular: environment = "regular"
        case .none: environment = "none"
        case .unspecified: environment = "unspecified"
        @unknown default: environment = "?"
        }
        let wanted = strip.intrinsicContentSize.width
        let line = String(
            format: "env=%@ host=%.0fx%.0f strip=%.0fx%.0f wants=%.0f overflow=%.0f",
            environment, bounds.width, bounds.height,
            strip.bounds.width, strip.bounds.height,
            wanted, max(0, wanted - strip.bounds.width)
        )
        guard line != lastTrace else { return }
        lastTrace = line
        print("[dock] \(reason) \(line)")
    }
}

/// Installs and removes the strip's accessory, and owns the two pieces of
/// SHELL-WIDE state that come with it.
///
/// # The rule, and it is the whole design
///
/// **The accessory exists only between For You's `viewDidAppear` and its
/// `viewWillDisappear`.** `bottomAccessory` and `tabBarMinimizeBehavior` are
/// properties of the TAB BAR CONTROLLER — neither has a per-tab scope — so a
/// screen's control installed there outlives the screen. Measured, not
/// reasoned: with the accessory left up, `hidesBottomBarWhenPushed` takes the
/// tab bar away and leaves the strip floating over the pushed profile, and
/// switching to Maps shows it over the map. The screen that installs it is the
/// screen that takes it down, one line each, and every hazard that comes from
/// it being shell-lifetime state goes away with the bracket.
@MainActor
final class ForYouSelectorAccessory {
    let hostView: ForYouSelectorAccessoryHost
    private var savedMinimizeBehavior: UITabBarController.MinimizeBehavior?

    init(strip: PagedTabBar) {
        hostView = ForYouSelectorAccessoryHost(strip: strip)
    }

    func install(into controller: UITabBarController?) {
        guard let controller, controller.bottomAccessory?.contentView !== hostView else { return }

        // Belt and braces, and the reason is written down in
        // `LeadingSelectorHost.sizeToOwnContent()`: a custom view keeps its
        // autoresizing mask, so the size UIKit reads at hand-over is the
        // frame, and an unlaid host's frame is zero. The accessory sizes by
        // constraint — this only guarantees the first pass is not measured on
        // a zero-sized view.
        hostView.setNeedsLayout()
        hostView.layoutIfNeeded()

        controller.bottomAccessory = UITabAccessory(contentView: hostView)
        if savedMinimizeBehavior == nil {
            savedMinimizeBehavior = controller.tabBarMinimizeBehavior
        }
        controller.tabBarMinimizeBehavior = .onScrollDown

        // ⚠️ UNCONDITIONAL, and that is the point: an empty log reads exactly
        // like a passing one. This line is what tells "the flag never arrived"
        // from "it installed and nothing moved".
        print("[dock] installed behaviour=onScrollDown host=\(hostView.bounds.size)")
    }

    func remove(from controller: UITabBarController?) {
        guard let controller, controller.bottomAccessory != nil else { return }
        controller.setBottomAccessory(nil, animated: true)
        // ⚠️ RESTORED, or the other four tabs inherit a minimizing bar. The
        // behaviour is shell-wide; only the accessory is ours.
        if let saved = savedMinimizeBehavior {
            controller.tabBarMinimizeBehavior = saved
            savedMinimizeBehavior = nil
        }
        print("[dock] removed")
    }

    /// The strip's content changed width — a badge appeared, a count grew.
    func contentWidthDidChange() {
        hostView.invalidateIntrinsicContentSize()
        hostView.setNeedsLayout()
    }
}
