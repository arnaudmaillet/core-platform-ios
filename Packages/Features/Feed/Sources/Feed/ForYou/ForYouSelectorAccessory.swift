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

    /// `-foryou-minimize-only`: arm the minimize with NO accessory at all.
    ///
    /// ⚠️ **THE BASELINE, AND IT IS WHAT ACQUITS THE ACCESSORY.** Measured on
    /// the simulator, inter-frame difference over the chrome band alone:
    ///
    ///     Apple Music, real device @120fps   24 frames = 200ms, peak 28
    ///     this app WITH the accessory        5 frames  =  83ms, peak 87
    ///     this app WITHOUT it (this flag)    1 frame   =  17ms, peak 93
    ///
    /// The bare bar snaps HARDER and FASTER than the accessory does, so nothing
    /// about the accessory introduced it. Ruled out along the way, each by its
    /// own run: the foot-cover re-publish from `layoutSubviews`, the
    /// `fillsWidth` toggle in the trait callback, the shell's per-layout
    /// overlay alignment, a slow finger instead of a flick (the collapse is not
    /// tracked to the drag), Reduce Motion, and Slow Animations.
    ///
    /// ⚠️ AND THE COMPARISON IS DEVICE-VERSUS-SIMULATOR. The reference is a
    /// 1320x2868 120fps device recording; every measurement here is a
    /// simulator. Settling it needs a device, which this instrument cannot
    /// reach — so do not "fix" the accessory for it.
    static var isMinimizeOnly: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-foryou-minimize-only")
        #else
        false
        #endif
    }

    /// `-foryou-dock-no-catchup`: leave the strip where UIKit puts it, in one
    /// step. On by default in the spike — see
    /// `ForYouSelectorAccessoryHost.playCatchUpIfMoved`.
    static var animatesCatchUp: Bool {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("-foryou-dock-no-catchup")
        #else
        true
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
    /// The gap between the strip and the container, on EVERY side.
    ///
    /// ⚠️ ONE NUMBER, FOUR EDGES, AND THAT IS THE POINT. Pinned flush
    /// horizontally and centred vertically, the selection lens touched the
    /// container's left and right edges while sitting 6pt clear of its top and
    /// bottom — a selected first or last tab read as spilling out of the band.
    /// The lens fills its segment when the backdrop is suppressed, so the
    /// strip's inset IS the lens's margin, and pinning all four edges to the
    /// same constant makes them equal by construction rather than by
    /// arithmetic that goes stale when the container's height changes.
    private static let contentInset: CGFloat = 4

    private let strip: PagedTabBar

    /// Fired from `layoutSubviews`, because there is no other signal.
    ///
    /// ⚠️ `UITabAccessory` has exactly ONE property — its content view. There
    /// is no delegate, no `willMinimize`, no notification; the environment is a
    /// trait and nothing else. A screen that needs to know the chrome moved
    /// hears it here.
    var onLayoutChanged: (() -> Void)?

    init(strip: PagedTabBar) {
        self.strip = strip
        super.init(frame: .zero)

        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)

        let inset = Self.contentInset
        NSLayoutConstraint.activate([
            // ⚠️ NO WIDTH CONSTRAINT — see the note above. These are edge pins,
            // which say where the strip is, not how wide it may be.
            strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            strip.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])

        // ⚠️ **FILLED IN BOTH ENVIRONMENTS, AND `.inline` IS WHY.** Hugging
        // was the obvious answer for the docked state — ask only for what the
        // titles need, so the strip reads as a control beside the tab bubbles
        // rather than a bar. Measured, it is the arrangement that puts a hole
        // on each side: the accessory hands out 226pt, the titles want 173, and
        // the capsule centres itself in the difference, leaving ~26pt of dead
        // glass left and right INSIDE the container. `fillsWidth` decides
        // whether the row hugs or spans, so spanning it is, and the margins
        // stay the four equal ones the edge pins give.
        strip.fillsWidth = true

        registerForTraitChanges([UITraitTabAccessoryEnvironment.self]) {
            (self: ForYouSelectorAccessoryHost, _) in
            self.trace("trait")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playCatchUpIfMoved()
        trace("layout")
        onLayoutChanged?()
    }

    /// Where this view was last seen, in window space — the only thing a
    /// catch-up needs to know.
    ///
    /// ⚠️ MEASURED FROM `center`, NOT FROM `frame`. `center` mirrors
    /// `layer.position`, which a transform does not move; a frame read back
    /// while the catch-up is mid-flight would include the very offset being
    /// animated, and each pass would chase the last one. Both this and
    /// `lastWidth` describe the CONTAINER, since that is what is carried.
    private var lastCentre: CGPoint?

    /// The width this view was last laid out at.
    ///
    /// ⚠️ **A PURE WIDTH CHANGE MOVES NO CENTRE, AND THAT IS WHY THE EXPAND WAS
    /// STILL JUMPING.** The two directions do not run their passes in the same
    /// order. Collapsing, the width and x land first and the y last:
    ///
    ///     360x48@21,735 → 234x48@84,735 → 234x48@84,798
    ///
    /// Expanding, the y goes first and the width last:
    ///
    ///     234x48@84,798 → 234x48@84,735 → 360x48@21,735
    ///
    /// A catch-up watching only the centre therefore caught the whole collapse
    /// — its last event was the 63pt drop — and the first two thirds of the
    /// expand, leaving the 126pt widening, the event a viewer actually sees, to
    /// land in one frame. The centre is 201 before and after it.
    private var lastWidth: CGFloat?

    /// Carries the strip from where it WAS to where UIKit just put it.
    ///
    /// ⚠️ **THIS EXISTS BECAUSE UIKIT DOES NOT ANIMATE THE MOVE, and it is a
    /// spike's answer, not a good one.** Measured with the trace below, a whole
    /// collapse is THREE layout passes: 360x48@21,735 → 234x48@84,735 →
    /// 234x48@84,798. The width and the x land in one step and the y in
    /// another, with no animation attached to the layer either time — which is
    /// what "teleported over the tab bar" is.
    ///
    /// So the move is inverted and played back: the view is put back where it
    /// was with a transform, and the transform is animated to identity. It is
    /// the standard trick for a layout change you do not own. What it does NOT
    /// carry is the width change — a scale would stretch the type — so the
    /// strip still narrows in one step while it travels. Half of Apple's
    /// motion, which is more than none.
    private func playCatchUpIfMoved() {
        // ⚠️ **THE CONTAINER, NOT US, AND THAT IS THE WHOLE CORRECTION.** The
        // glass capsule a viewer sees in this band is NOT ours — the strip's
        // own backdrop is suppressed — it is drawn by UIKit's
        // `_UITabAccessoryContainer`, which is our superview. Transforming
        // ourselves therefore scaled the TITLES inside a capsule that had
        // already snapped to its final width, which is exactly what "it takes
        // its final width from the start of the animation" looks like.
        //
        // Apple Music's own expand, filmed on a device: the capsule itself
        // widens frame by frame. So the capsule is what has to be carried.
        guard let window, let container = superview,
              let containerHost = container.superview
        else { return }
        let centreNow = containerHost.convert(container.center, to: window)
        let widthNow = container.bounds.width
        defer { lastCentre = centreNow; lastWidth = widthNow }
        guard ForYouSelectorDock.animatesCatchUp,
              let was = lastCentre, let wasWidth = lastWidth, widthNow > 1
        else { return }
        let dx = was.x - centreNow.x
        let dy = was.y - centreNow.y
        // ⚠️ **WIDENING ONLY, AND THE ASYMMETRY IS THE WHOLE POINT.** Carrying
        // the width in BOTH directions was a regression on the collapse, which
        // was already right: there the width lands FIRST, under tab items that
        // are still fading out, so nothing needs carrying and a scale only adds
        // a stretch nobody asked for. Expanding, the width lands LAST, alone,
        // in front of a settled bar — and that is the frame a viewer sees.
        //
        // So the collapse takes the same translate-only path it took when it
        // was approved, and only the grow is scaled. A trace of a collapse
        // shows no `scaleX` at all; if one appears there, this guard broke.
        let isWidening = widthNow > wasWidth + 1
        let scale = isWidening ? wasWidth / widthNow : 1
        // A pass that did not move it, or moved it a hair, is not a journey.
        guard abs(dx) > 1 || abs(dy) > 1 || isWidening else { return }
        if ForYouSelectorDock.isTracing {
            print(String(format: "[dock] catchup dx=%.0f dy=%.0f scaleX=%.2f", dx, dy, scale))
        }
        // The type stretches for the length of the spring on a grow, 0.65 to 1.
        // Against a 126pt capsule appearing between two frames, a third of a
        // second of narrow text is the cheaper artefact; the alternative that
        // does not distort is a width CONSTRAINT, which cannot start until the
        // pass after the one that resized us.
        container.transform = CGAffineTransform(translationX: dx, y: dy)
            .scaledBy(x: scale, y: 1)
        UIView.animate(
            withDuration: 0.32, delay: 0,
            usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
            // ⚠️ The scroll that caused this is still under the finger.
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            container.transform = .identity
        }
    }

    private var lastTrace = ""
    private var traceCount = 0

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
        // ⚠️ THE POSITION, NOT ONLY THE SIZE. A collapse that reads as a
        // teleport is either a frame that snaps or a frame that travels while
        // its CONTENTS snap, and only the origin tells them apart.
        let inWindow = window.map { convert(bounds, to: $0) } ?? .zero
        // ⚠️ READ AFTER THE PASS, NOT DURING IT. `layoutSubviews` runs before
        // Core Animation attaches anything, so a presentation layer read here
        // is nil whether or not an animation is coming — a measurement that
        // can only ever return "no animation". The animation KEYS answer the
        // same question honestly.
        let keys = layer.animationKeys()?.joined(separator: "+") ?? "none"
        let line = String(
            format: "env=%@ host=%.0fx%.0f@%.0f,%.0f anim=%@ "
                + "strip=%.0fx%.0f wants=%.0f overflow=%.0f",
            environment, bounds.width, bounds.height, inWindow.minX, inWindow.minY,
            keys,
            strip.bounds.width, strip.bounds.height,
            wanted, max(0, wanted - strip.bounds.width)
        )
        guard line != lastTrace else { return }
        lastTrace = line
        traceCount += 1
        print("[dock] #\(traceCount) \(reason) \(line)")
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
        guard let controller else { return }
        if ForYouSelectorDock.isMinimizeOnly {
            if savedMinimizeBehavior == nil {
                savedMinimizeBehavior = controller.tabBarMinimizeBehavior
            }
            controller.tabBarMinimizeBehavior = .onScrollDown
            print("[dock] installed BASELINE - minimize armed, no accessory")
            return
        }
        guard controller.bottomAccessory?.contentView !== hostView else { return }

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
