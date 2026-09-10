import UIKit

/// How a `SelectorAccessory` is dressed.
///
/// ⚠️ THE DEFAULTS ARE THE SHIPPING ANSWER. `keepsOwnGlass` and
/// `animatesCatchUp` exist as comparison instruments, not as choices a host
/// should be making — the catch-up in particular fights a real animation on a
/// device and IS the instability it was written to cure in the simulator.
public struct SelectorAccessoryOptions: Sendable {
    /// The strip draws its own capsule rather than rendering bare inside
    /// UIKit's. Off: the container's glass is the one the viewer sees.
    public var keepsOwnGlass: Bool = false
    /// Hand-animate the geometry change. See `playCatchUpIfMoved` — leave off.
    public var animatesCatchUp: Bool = false
    /// One line per layout and per environment change.
    public var isTracing: Bool = false

    public init(keepsOwnGlass: Bool = false,
                animatesCatchUp: Bool = false,
                isTracing: Bool = false) {
        self.keepsOwnGlass = keepsOwnGlass
        self.animatesCatchUp = animatesCatchUp
        self.isTracing = isTracing
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
/// The navigation bar needed one — the deleted `LeadingSelectorHost` existed
/// because UIKit silently declines to host an over-wide leading custom view and
/// sweeps the group into a `•••`. **An accessory has no item groups and no
/// overflow control, so that failure cannot happen here.** The analogous one
/// can: a width bounded only from above, with nothing requiring it positive, is
/// how that host once settled at zero and was not hosted at all. So the
/// strip is pinned leading and trailing with `equalTo` and given no width
/// constraint of any kind — under-width it SCROLLS, keeping every title whole
/// (`PagedTabBar`'s segment widths are required, and its content is `>=` the
/// frame guide).
public final class SelectorAccessoryHost: UIView {
    public typealias Options = SelectorAccessoryOptions

    private let options: Options

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
    public var onLayoutChanged: (() -> Void)?

    public init(strip: PagedTabBar?, options: Options = Options()) {
        self.options = options
        self.strip = strip
        super.init(frame: .zero)

        guard let strip else {
            // Empty on purpose: the container still draws its bubble around
            // nothing, which is the whole point of the probe.
            registerForTraitChanges([UITraitTabAccessoryEnvironment.self]) {
                (self: SelectorAccessoryHost, _) in self.trace("trait")
            }
            return
        }

        // ⚠️ **THE HOST SETS THIS, NOT THE SCREEN, AND A TEST HAD TO FIND IT.**
        // Of the five coupled mutations the deleted `installLeadingSelector`
        // performed, this is the ONE that carries over: UIKit's
        // `_UITabAccessoryContainer` draws the capsule the viewer sees, so a
        // strip carrying its own backdrop draws a lens inside a lens. It lived
        // on the one adopting screen while there was one adopting screen; with
        // four hosts, a rule kept outside the component is a rule the next host
        // forgets.
        strip.suppressesBackdrop = !options.keepsOwnGlass

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
            (self: SelectorAccessoryHost, _) in
            self.applyEnvironment()
            self.trace("trait")
        }
        // ⚠️ ONCE FROM `init` AS WELL. `registerForTraitChanges` fires on a
        // CHANGE, and an accessory can be installed onto a bar that is ALREADY
        // minimized — a screen entered while the previous one was scrolled
        // down. Without this the strip would wear its regular arrangement in an
        // inline slot until the viewer happened to scroll.
        applyEnvironment()
    }

    /// The strip's arrangement follows the environment UIKit put it in.
    ///
    /// ⚠️ **`== .inline`, NOT `!= .regular`.** The trait's default is
    /// `.unspecified` (stated in `UITabAccessory.h`), and that is what every
    /// non-accessory host reports — a navigation bar's title slot, the bottom
    /// toolbar, and every detached unit test. Written as `!= .regular` this
    /// rule would silently re-arrange all of them; written as `== .inline` it
    /// is inert everywhere but in a collapsed accessory, which is what makes
    /// "leave the expanded state exactly as it was" true by construction rather
    /// than by care.
    ///
    /// ⚠️ **AND IT REVERSES A MEASURED DECISION, DELIBERATELY.** The note on
    /// `fillsWidth` below records that filling was chosen for BOTH
    /// environments because hugging in `.inline` leaves a hole: the accessory
    /// hands out 226pt, For You's two titles want 173, and a centred row leaves
    /// ~26pt of dead glass at each end INSIDE UIKit's capsule. That hole is
    /// real and comes back here. It is accepted because the other side of the
    /// trade is worse where it bites hardest: equal slots price every segment
    /// at the WIDEST title, so on the inbox "All" wears "Suggestions"' box —
    /// 41pt of word in a 98pt slot — and the strip scrolls to show three.
    private func applyEnvironment() {
        strip?.segmentSizing =
            traitCollection.tabAccessoryEnvironment == .inline ? .naturalWidths : .equalSlots
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
    /// ⚠️ **AND THE WIDTH CANNOT BE STATED — MEASURED, NOT ASSUMED.** The slot
    /// is UIKit's to decide, and it does not negotiate. Driven by UITest on
    /// For You, six runs on one build:
    ///
    ///     stated intrinsic width  240 → container 360x48 regular, 234x48 inline
    ///     stated intrinsic width  120 → container 360x48 regular, 234x48 inline
    ///     REQUIRED width constraint 240 → 360x48 / 234x48
    ///     REQUIRED width constraint 120 → 360x48 / 234x48
    ///     nothing stated (control)     → 360x48 / 234x48
    ///
    /// Identical to the point, including the container's x (21 regular, 84
    /// inline), and — the telling part — **no constraint conflict was logged**.
    /// UIKit does not lay this view out against our constraints at all; it sets
    /// the frame. A required constraint on it is not overridden, it is inert.
    ///
    /// So there is no narrow accessory to be had. Apple's API agrees by
    /// omission: `UITabAccessory` is one property and one initialiser, and
    /// Apple publishes no sizing contract anywhere — the word "accessory" does
    /// not appear in the HIG's Layout, Materials or Tab views pages. The only
    /// width sentence Apple writes is inline-scoped and tells the APP to adapt:
    /// "When the accessory is inline with the tab bar, there is less space
    /// available to display it." That adaptation is `segmentSizing`, below.
    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.contentHeight)
    }

    /// The height UIKit has handed this accessory in BOTH environments,
    /// measured: `.regular` 360x48 and `.inline` 234x48. Stated rather than
    /// inferred so the content view is well-formed even before it is hosted.
    private static let contentHeight: CGFloat = 48

    public override func layoutSubviews() {
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

        guard options.animatesCatchUp,
              let was = lastCentre, let wasWidth = lastWidth, widthNow > 1
        else { return }
        let delta = catchUp(from: (centre: was, width: wasWidth),
                            to: centreNow, width: widthNow)
        guard delta != .identity else { return }

        let presented = container.layer.presentation()?.affineTransform() ?? .identity
        if options.isTracing {
            Self.emit(String(format: "catchup dx=%.0f dy=%.0f scaleX=%.2f onto=%.2f",
                                delta.tx, delta.ty, delta.a, presented.a),
                      options: options)
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
    public func cancelCatchUp() {
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
    static func emit(_ line: String, options: Options) {
        // A STAMP, because the question these lines answer most often is one of
        // ORDER and LATENCY — which of two hosts moved first, and how long
        // after the viewer's tap the band arrived. Neither is legible in a
        // sequence of undated lines.
        print(String(format: "[dock] %.3f %@", ProcessInfo.processInfo.systemUptime, line))
        guard options.isTracing,
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
        guard options.isTracing else { return }
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
        Self.emit("#\(traceCount) \(reason) \(line)", options: options)
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
/// The shell's own minimize behaviour, remembered once per tab bar controller
/// for as long as ANY accessory has it armed.
///
/// ⚠️ **A PER-ACCESSORY `savedMinimizeBehavior` LEAKS THE MOMENT TWO HOSTS
/// OVERLAP.** Measured on a tab switch, headless: the incoming screen's
/// `viewWillAppear` lands 6ms BEFORE the outgoing screen's
/// `viewWillDisappear`. So the newcomer captures `.onScrollDown` — the value
/// the screen it is replacing armed — as though it were the shell's default,
/// and hands that back when it leaves. `.onScrollDown` then belongs to every
/// tab, which is the exact hazard the restore exists to prevent.
///
/// Counted, because the overlap is real and bounded: the first arm records what
/// the shell had, the last release gives it back, and the ones in between are
/// hand-overs that must not touch it.
@MainActor
private enum MinimizeBehaviourStore {
    /// ⚠️ **THE CONTROLLER IS HELD WEAKLY AND CHECKED, NOT JUST KEYED ON.**
    /// `ObjectIdentifier` is an ADDRESS, and a deallocated controller's address
    /// is handed straight to the next one — so a table keyed on it alone serves
    /// the dead object's owner count to its successor. Caught by the tests
    /// rather than reasoned about: one case installs a band and never removes
    /// it (which is what a hand-over looks like), leaving a count of 1 behind,
    /// and the next case's fresh `UITabBarController` landed on the same
    /// address and inherited it — so it never recorded the shell's own
    /// behaviour and never gave it back. Harmless in the app, where the shell's
    /// controller outlives everything; a trap anywhere else, which is exactly
    /// the kind that gets found once and then found again.
    private struct Record {
        weak var controller: UITabBarController?
        var saved: UITabBarController.MinimizeBehavior
        var owners: Int
    }

    private static var records: [ObjectIdentifier: Record] = [:]

    /// The record for `controller`, or nil when the entry belongs to a dead
    /// object that happened to share its address.
    private static func record(for controller: UITabBarController) -> Record? {
        guard let found = records[ObjectIdentifier(controller)],
              found.controller === controller
        else { return nil }
        return found
    }

    static func arm(_ controller: UITabBarController) {
        let key = ObjectIdentifier(controller)
        if var existing = record(for: controller) {
            existing.owners += 1
            records[key] = existing
        } else {
            records[key] = Record(controller: controller,
                                  saved: controller.tabBarMinimizeBehavior,
                                  owners: 1)
        }
        controller.tabBarMinimizeBehavior = .onScrollDown
    }

    static func release(_ controller: UITabBarController) {
        guard var existing = record(for: controller), existing.owners > 0 else { return }
        existing.owners -= 1
        if existing.owners == 0 {
            controller.tabBarMinimizeBehavior = existing.saved
            records[ObjectIdentifier(controller)] = nil
        } else {
            records[ObjectIdentifier(controller)] = existing
        }
    }
}

@MainActor
public final class SelectorAccessory {
    public typealias Options = SelectorAccessoryOptions

    public let hostView: SelectorAccessoryHost
    /// Whether THIS accessory is one of the store's owners, so a double
    /// install or a double remove cannot move the count twice.
    private var holdsMinimize = false

    private let options: Options

    /// - Parameter strip: `nil` builds the accessory EMPTY — the container
    ///   still draws its bubble around nothing, which is how "does UIKit
    ///   animate this at all" was answered.
    public init(strip: PagedTabBar?, options: Options = Options()) {
        self.options = options
        hostView = SelectorAccessoryHost(strip: strip, options: options)
    }

    /// - Parameter minimizesOnScroll: arms the tab bar's scroll-driven
    ///   collapse.
    ///
    ///   ⚠️ **OPT-IN, BECAUSE IT IS SHELL-WIDE.** `tabBarMinimizeBehavior` is a
    ///   property of the TAB BAR CONTROLLER with no per-tab scope, and the
    ///   collapse only means anything on a host that has registered a scroll
    ///   view with `setContentScrollView(_:for: .bottom)`. A host that arms it
    ///   without one arms a behaviour for every other tab and gets nothing back.
    /// - Parameter alongside: the transition the band should move WITH.
    ///
    ///   ⚠️ **THE ACCESSORY WAS ON A CLOCK NOBODY ELSE SHARED.** The tab bar is
    ///   deliberately put on the transition's clock everywhere (see
    ///   `TabBarRevealPolicy`, and `returningSourceChrome` for the flights);
    ///   the accessory was not, and it showed twice over. Pass the screen's
    ///   `transitionCoordinator` and the change rides the push or pop that is
    ///   already running instead of starting a second animation against it.
    public func install(into controller: UITabBarController?,
                        minimizesOnScroll: Bool = false,
                        alongside coordinator: UIViewControllerTransitionCoordinator? = nil) {
        guard let controller else { return }
        guard controller.bottomAccessory?.contentView !== hostView else { return }

        // Belt and braces, and the reason came from the navigation bar: a
        // custom view keeps its autoresizing mask, so the size UIKit reads at
        // hand-over is the FRAME, and an unlaid host's frame is zero — which is
        // how a perfectly configured strip drew nothing. The accessory sizes by
        // constraint — this only guarantees the first pass is not measured on
        // a zero-sized view.
        hostView.setNeedsLayout()
        hostView.layoutIfNeeded()

        // ⚠️ **THIS WAS THE PLAIN PROPERTY SETTER, WHICH IS UIKIT'S UNANIMATED
        // FORM** — while the remove has always used `setBottomAccessory(_:
        // animated: true)`. So the band faded out and then SNAPPED back in, and
        // no comment on either line said why. `setBottomAccessory(_:animated:)`
        // is the only animation hook `UITabAccessory` has: the class is one
        // property and one initialiser, there is no delegate, no
        // `willMinimize`, and Apple's reference page for the method carries no
        // Discussion at all. Symmetry is the whole of what can be asked for.
        let accessory = UITabAccessory(contentView: hostView)
        ride(coordinator) { animated in
            controller.setBottomAccessory(accessory, animated: animated)
        }
        if minimizesOnScroll, !holdsMinimize {
            holdsMinimize = true
            MinimizeBehaviourStore.arm(controller)
        }

        // ⚠️ UNCONDITIONAL, and that is the point: an empty log reads exactly
        // like a passing one. This line is what tells "it never installed" from
        // "it installed and nothing moved".
        SelectorAccessoryHost.emit(
            "installed minimize=\(minimizesOnScroll) host=\(hostView.bounds.size)",
            options: options
        )
    }

    /// ⚠️ **IDENTITY-CHECKED, AND WITH FOUR HOSTS THAT IS NOT PEDANTRY.** The
    /// install already refuses to replace its own accessory; the remove used to
    /// take down WHATEVER was in the slot. On a tab switch between two selector
    /// screens the outgoing host's `viewWillDisappear` can land after the
    /// incoming host's `viewDidAppear`, and an unchecked remove would then
    /// delete the newcomer's accessory and restore a minimize behaviour it had
    /// captured from somewhere else.
    public func remove(from controller: UITabBarController?,
                       alongside coordinator: UIViewControllerTransitionCoordinator? = nil) {
        guard let controller else { return }
        // ⚠️ **RELEASED WHETHER OR NOT THE BAND IS STILL OURS, AND THE IDENTITY
        // GUARD BELOW IS WHY.** This instance armed the minimize, so this
        // instance gives it up — even on the hand-over path where the newcomer
        // has already taken the slot and the guard sends us home. Leaving the
        // release under the guard is how the count runs away: every hand-over
        // adds an owner nothing ever removes, and the shell's default never
        // comes back.
        if holdsMinimize {
            holdsMinimize = false
            MinimizeBehaviourStore.release(controller)
        }
        guard controller.bottomAccessory?.contentView === hostView else {
            // Somebody else's band is up. That is the hand-over working: the
            // incoming screen claimed the slot before we were asked to leave,
            // so there is nothing to take down and no gap to leave behind.
            SelectorAccessoryHost.emit("handed over", options: options)
            return
        }
        clearCatchUp()
        ride(coordinator) { animated in
            controller.setBottomAccessory(nil, animated: animated)
        }
        SelectorAccessoryHost.emit("removed", options: options)
    }

    /// Runs a band change on the right clock.
    ///
    /// With a transition in flight the change goes INSIDE
    /// `animate(alongsideTransition:)` and asks UIKit for no animation of its
    /// own: the enclosing context already has the push's duration and curve,
    /// and a second animation started against it is exactly the mismatch this
    /// exists to remove. The push path is where it matters —
    /// `hidesBottomBarWhenPushed` slides the bar out on the transition's curve
    /// while `viewWillDisappear` fired the accessory's dismissal on UIKit's
    /// default one — and some screens add a THIRD by calling
    /// `setTabBarHidden(true, animated: true)` by hand.
    ///
    /// With no transition (a tab switch, the place page pushed over a bar that
    /// never moves) there is nothing to ride, so it animates on its own. That
    /// case is not a desync, only the abruptness.
    private func ride(_ coordinator: UIViewControllerTransitionCoordinator?,
                      _ change: @escaping (_ animated: Bool) -> Void) {
        guard let coordinator else {
            change(true)
            return
        }
        coordinator.animate(alongsideTransition: { _ in change(false) })
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
    public func contentWidthDidChange() {
        hostView.invalidateIntrinsicContentSize()
        hostView.setNeedsLayout()
    }
}
