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

    /// `-foryou-dock-empty`: put an EMPTY content view in the accessory — no
    /// strip, nothing to lay out — while keeping the bubble UIKit draws around
    /// it. Pair with `-foryou-dock-no-catchup` for the pure-UIKit baseline.
    ///
    /// ⚠️ THIS IS THE ONLY THING THAT SEPARATES "UIKIT DOES NOT ANIMATE THE
    /// CONTAINER" FROM "OUR CONTENT IS WHAT LAGS". Everything measured so far
    /// has had a `PagedTabBar` inside, re-laying its segments out on every
    /// bounds change, so no run has ever shown what the container does alone.
    static var isEmpty: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-foryou-dock-empty")
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

    /// `-foryou-dock-catchup`: hand-animate the accessory's geometry change.
    ///
    /// ⚠️ **OFF BY DEFAULT NOW, AND THE MEASUREMENT IS WHY.** Asked with an
    /// empty content view and not one line of ours running, NOT ONE view
    /// between the accessory and the window carries an animation at any pass of
    /// a collapse:
    ///
    ///     #3 layout env=regular  360x48@21,735  anim=none
    ///     #4 trait  env=inline   234x48@84,735  anim=none
    ///     #5 layout env=inline   234x48@84,798  anim=none
    ///
    /// UIKit writes the geometry in two steps and animates nothing, anywhere.
    /// So the API is being used as documented — `UITabAccessory` has one
    /// property and no animation surface — and there is simply nothing to ride.
    ///
    /// ⚠️ AND THE CARRY IS WHAT MADE IT UNSTABLE. Every spring it ran was on a
    /// view UIKit re-lays out underneath it, which takes the animation with it;
    /// under a fast flip the springs overlap on that same view and each pass
    /// clobbers the one before. "The capsule does anything and struggles to
    /// keep up" is that, and it is ours, not UIKit's.
    ///
    /// ⚠️ **AND ON A DEVICE THE ACCESSORY ANIMATES BY ITSELF.** Arnaud ran the
    /// same build on an iPhone: the collapse and the expand are smooth with
    /// nothing hand-animated. So `anim=none` on every ancestor is a SIMULATOR
    /// fact, not an iOS one, and the whole hand-animation existed to replace an
    /// animation that is there on real hardware. The premise was checkable from
    /// the first hour — the reference clip was always a device recording and
    /// every measurement here a simulator — and it was written down early, then
    /// argued past for six commits.
    ///
    /// **So do not turn this on to "fix" the simulator.** On a device it fights
    /// a real animation; in the simulator it is the instability it was meant to
    /// cure. It stays only as a comparison instrument.
    static var animatesCatchUp: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-foryou-dock-catchup")
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

    private let strip: PagedTabBar?

    /// Fired from `layoutSubviews`, because there is no other signal.
    ///
    /// ⚠️ `UITabAccessory` has exactly ONE property — its content view. There
    /// is no delegate, no `willMinimize`, no notification; the environment is a
    /// trait and nothing else. A screen that needs to know the chrome moved
    /// hears it here.
    var onLayoutChanged: (() -> Void)?

    init(strip: PagedTabBar?) {
        self.strip = strip
        super.init(frame: .zero)

        guard let strip else {
            // Empty on purpose: the container still draws its bubble around
            // nothing, which is the whole point of the probe.
            registerForTraitChanges([UITraitTabAccessoryEnvironment.self]) {
                (self: ForYouSelectorAccessoryHost, _) in self.trace("trait")
            }
            return
        }

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

    /// ⚠️ A HEIGHT IS STATED, A WIDTH IS NOT, and the asymmetry is the
    /// documented contract. `UITabAccessory` has exactly ONE property — its
    /// content view — and NO animation API of any kind (verified in
    /// `UITabAccessory.h`): UIKit owns the transition, and all an app supplies
    /// is a view that can say how big it wants to be. Saying nothing, which is
    /// what `noIntrinsicMetric` on both axes said, is not a neutral answer.
    ///
    /// The width stays unstated because the accessory's slot is UIKit's to
    /// decide — 360 in `.regular`, 234 in `.inline`, measured — and a content
    /// view that argued about it would be arguing with the environment.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.contentHeight)
    }

    /// The height UIKit has handed this accessory in BOTH environments,
    /// measured: `.regular` 360x48 and `.inline` 234x48. Stated rather than
    /// inferred so the content view is well-formed even before it is hosted.
    private static let contentHeight: CGFloat = 48

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

    /// Carries the accessory from where it WAS to where UIKit just put it.
    ///
    /// ⚠️ **THIS EXISTS BECAUSE UIKIT DOES NOT ANIMATE THE MOVE, and it is a
    /// spike's answer, not a good one.** A whole collapse is three layout
    /// passes — 360x48@21,735 → 234x48@84,735 → 234x48@84,798 — with no
    /// animation attached to the layer at any of them. So the change is
    /// inverted and played back: the view is put back where it was with a
    /// transform, and the transform is animated to identity.
    ///
    /// ⚠️ **THE CONTAINER, NOT US.** The glass capsule a viewer sees is not
    /// ours — the strip's backdrop is suppressed — it is drawn by UIKit's
    /// `_UITabAccessoryContainer`, our superview. Transforming ourselves scaled
    /// the TITLES inside a pill that had already snapped, which is what "it
    /// takes its final width from the start" looks like. Nothing here reads
    /// that view's class or its subviews; it is transformed as any `UIView`
    /// may be, and returned to identity by the animation that set it.
    ///
    /// ⚠️ **EACH PASS COMPOSES ONTO THE ONE IN FLIGHT, AND THAT IS WHAT MAKES
    /// IT SURVIVE REPETITION.** Neither direction delivers its change in one
    /// pass:
    ///
    ///     collapsing   width and x, then the 63pt drop
    ///     expanding    the 63pt rise, then the 126pt widening
    ///
    /// Animating each pass on its own fired two springs back to back, and on
    /// the expand the second — the one carrying the capsule's width — began
    /// only as the first was ending. Coalescing them behind a
    /// `DispatchQueue.main.async` fixed that MOST of the time and is why it
    /// degraded after a few iterations: whether that hop lands between the two
    /// passes or after both is a property of where the runloop turn happens to
    /// fall, not of this code. It was a race, and a race dressed as a fix comes
    /// back.
    ///
    /// So there is no hop and no burst to coalesce. A pass computes the
    /// compensation for ITS OWN delta and CONCATENATES it onto whatever the
    /// presentation layer is currently showing:
    ///
    ///     want   geometryNew ∘ Tnew  ==  geometryOld ∘ Tpresented
    ///     given  geometryNew ∘ delta ==  geometryOld
    ///     so     Tnew = Tpresented.concatenating(delta)
    ///
    /// The extra factor cancels the geometry change exactly, so the pixels do
    /// not move at the instant it is applied, and the same spring carries on to
    /// identity. A first pass finds an identity presentation and reduces to the
    /// simple case. There is no state that can be stale between iterations
    /// because there is no state: the presentation layer IS the memory.
    private func playCatchUpIfMoved() {
        guard let window, let container = superview,
              let containerHost = container.superview
        else { return }
        // ⚠️ A POINT CONVERTED THROUGH THE HOST, so neither reading passes
        // through the transform being animated: `center` mirrors
        // `layer.position`, which a view's own transform does not move.
        let centreNow = containerHost.convert(container.center, to: window)
        let widthNow = container.bounds.width
        defer { lastCentre = centreNow; lastWidth = widthNow }

        guard ForYouSelectorDock.animatesCatchUp,
              let was = lastCentre, let wasWidth = lastWidth, widthNow > 1
        else { return }
        let delta = catchUp(from: (centre: was, width: wasWidth),
                            to: centreNow, width: widthNow)
        guard delta != .identity else { return }

        let presented = container.layer.presentation()?.affineTransform() ?? .identity
        if ForYouSelectorDock.isTracing {
            Self.emit(String(format: "catchup dx=%.0f dy=%.0f scaleX=%.2f onto=%.2f",
                                delta.tx, delta.ty, delta.a, presented.a))
        }
        container.transform = presented.concatenating(delta)
        UIView.animate(
            withDuration: 0.32, delay: 0,
            usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
            // ⚠️ **NO `.beginFromCurrentState`, AND IT IS THE OPTION THAT LOOKS
            // RIGHT HERE.** It makes the animation take its FROM-value from the
            // presentation layer instead of from the model — which would
            // discard the transform seeded on the line above, in proportion to
            // how much of the previous spring is left. The composition IS the
            // continuity: the seeded value already renders exactly what the
            // presentation was showing a moment ago, so the from-value must be
            // the model, and reading the presentation instead throws the carry
            // away in precisely the case it exists for.
            options: [.allowUserInteraction]
        ) {
            container.transform = .identity
        }
    }

    /// The transform that makes the container LOOK like it did at `anchor`.
    ///
    /// ⚠️ THE SCALE IS FOR A GROW ONLY. Carrying the width in both directions
    /// was a regression on the collapse, which was already right: there the
    /// width lands FIRST, under tab items still fading out, so nothing needs
    /// carrying and a scale only adds a stretch nobody asked for. Expanding, it
    /// lands LAST, alone, in front of a settled bar. A trace of a collapse must
    /// show `scaleX=1.00`.
    private func catchUp(
        from anchor: (centre: CGPoint, width: CGFloat),
        to centre: CGPoint, width: CGFloat
    ) -> CGAffineTransform {
        let dx = anchor.centre.x - centre.x
        let dy = anchor.centre.y - centre.y
        let scale = width > anchor.width + 1 ? anchor.width / width : 1
        // A pass that moved it a hair, or only narrowed it, is not a journey.
        guard abs(dx) > 1 || abs(dy) > 1 || scale != 1 else { return .identity }
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: 1)
    }

    /// Forgets what it last saw, so the next pass starts a journey rather than
    /// measuring against geometry from before the accessory was taken down.
    func cancelCatchUp() {
        lastCentre = nil
        lastWidth = nil
    }

    /// ⚠️ **A FILE, NOT ONLY THE CONSOLE, AND THE REASON IS THIS BUG.** The
    /// direction that misbehaves is the EXPAND, and injected touches will not
    /// produce one — only a hand on the device does. A console line nobody is
    /// attached to is a measurement that does not exist, so every line is also
    /// appended to `dock-trace.log` in the app's Documents directory, where it
    /// survives the run and can be read afterwards with
    /// `xcrun simctl get_app_container <udid> <bundle> data`.
    static func emit(_ line: String) {
        print("[dock] \(line)")
        guard ForYouSelectorDock.isTracing,
              let directory = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
              ).first
        else { return }
        let url = directory.appendingPathComponent("dock-trace.log")
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Which views between here and the window are currently animating, named
    /// by class, or "none".
    private func animatedAncestors() -> String {
        var found: [String] = []
        var node: UIView? = self
        while let current = node {
            if let keys = current.layer.animationKeys(), !keys.isEmpty {
                found.append("\(type(of: current)):\(keys.joined(separator: ","))")
            }
            node = current.superview
        }
        return found.isEmpty ? "none" : found.joined(separator: " | ")
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
        let wanted = strip?.intrinsicContentSize.width ?? 0
        // ⚠️ THE POSITION, NOT ONLY THE SIZE. A collapse that reads as a
        // teleport is either a frame that snaps or a frame that travels while
        // its CONTENTS snap, and only the origin tells them apart.
        let inWindow = window.map { convert(bounds, to: $0) } ?? .zero
        // ⚠️ **THE WHOLE ANCESTOR CHAIN, BECAUSE ASKING ONE VIEW HAS TWICE
        // ANSWERED THE WRONG QUESTION.** This read the host (which nothing
        // animates) for four commits, then the container. But UIKit need not
        // animate the view whose geometry changed — it may animate a parent and
        // let the children ride, and a probe pointed at one layer cannot tell
        // "nobody is animating" from "not this one". So every ancestor up to
        // the window is asked, and each that carries keys is named.
        let keys = animatedAncestors()
        let line = String(
            format: "env=%@ host=%.0fx%.0f@%.0f,%.0f anim=%@ "
                + "strip=%.0fx%.0f wants=%.0f overflow=%.0f",
            environment, bounds.width, bounds.height, inWindow.minX, inWindow.minY,
            keys,
            strip?.bounds.width ?? 0, strip?.bounds.height ?? 0,
            wanted, max(0, wanted - (strip?.bounds.width ?? 0))
        )
        guard line != lastTrace else { return }
        lastTrace = line
        traceCount += 1
        Self.emit("#\(traceCount) \(reason) \(line)")
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
        hostView = ForYouSelectorAccessoryHost(
            strip: ForYouSelectorDock.isEmpty ? nil : strip
        )
    }

    func install(into controller: UITabBarController?) {
        guard let controller else { return }
        if ForYouSelectorDock.isMinimizeOnly {
            if savedMinimizeBehavior == nil {
                savedMinimizeBehavior = controller.tabBarMinimizeBehavior
            }
            controller.tabBarMinimizeBehavior = .onScrollDown
            ForYouSelectorAccessoryHost.emit("installed BASELINE - minimize armed, no accessory")
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
        ForYouSelectorAccessoryHost.emit("installed behaviour=onScrollDown host=\(hostView.bounds.size)")
    }

    func remove(from controller: UITabBarController?) {
        guard let controller, controller.bottomAccessory != nil else { return }
        clearCatchUp()
        controller.setBottomAccessory(nil, animated: true)
        // ⚠️ RESTORED, or the other four tabs inherit a minimizing bar. The
        // behaviour is shell-wide; only the accessory is ours.
        if let saved = savedMinimizeBehavior {
            controller.tabBarMinimizeBehavior = saved
            savedMinimizeBehavior = nil
        }
        ForYouSelectorAccessoryHost.emit("removed")
    }

    /// ⚠️ A FLIGHT INTERRUPTED BY A REMOVAL WOULD LEAVE A TRANSFORM BEHIND.
    /// The container is carried for the length of a spring, and if the
    /// accessory goes mid-flight the animation has nothing to land on. UIKit
    /// discards the container with the accessory, so nothing is stranded on
    /// screen, but a view handed back transformed is not a thing to leave to
    /// chance — and the next install must measure from scratch rather than
    /// against geometry from before the accessory was taken down.
    private func clearCatchUp() {
        hostView.superview?.transform = .identity
        hostView.cancelCatchUp()
    }

    /// The strip's content changed width — a badge appeared, a count grew.
    func contentWidthDidChange() {
        hostView.invalidateIntrinsicContentSize()
        hostView.setNeedsLayout()
    }
}
