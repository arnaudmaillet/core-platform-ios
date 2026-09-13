import UIKit

/// The upload flow's stack, with its back-swipe held to the window's leading
/// edge.
///
/// ⚠️ **UIKit PUTS TWO BACK-SWIPE PANS HERE AND ONLY THE FULL-WIDTH ONE WORKS.**
/// Measured, in this order:
///
/// 1. A probe on a delegate installed on the vended `interactivePopGestureRecognizer`
///    was **never asked to begin** during a real drag, while UIKit consulted it
///    about `_UIParallaxTransitionPanGestureRecognizer` on the stack's
///    `UILayoutContainerView`.
/// 2. That second pan recognises **anywhere**: a drag started mid-screen carried
///    the screen back on both pushed screens (RMSE 0.012 and 0.009 against the
///    destination).
/// 3. Disabling it — hoping the vended edge recogniser would take over and give
///    edge-only behaviour for free — **killed the gesture outright**: an edge
///    drag then moved nothing (0.012 against its own reference). The vended
///    recogniser is enabled and inert.
///
/// So the full-width pan is the gesture, and holding it to the edge means owning
/// its `shouldBegin`. Two costs, both deliberate:
///
/// - **`Self.edgeWidth` IS A CHOICE, NOT A MEASUREMENT.** UIKit's own screen-edge
///   band is not published and this code cannot read it; 20pt matches the usual
///   feel. Widen it if the gesture feels hard to catch.
/// - **Direction is NOT tested here, and must not be added back.** Translation and
///   velocity both read `(0,0)` when this delegate is asked — measured once each
///   way, two builds apart, each time refusing every drag and looking exactly like
///   a killed gesture. The recogniser keeps its own direction logic: measured, a
///   vertical drag starting 12pt from the edge never reaches this method at all —
///   the finalisation list scrolled and the screen stayed.
/// - **NOR IS THE START POSITION KNOWABLE HERE** — an earlier revision of this very
///   comment claimed it was, and the claim was false. The zeroed translation is a
///   REBASE, not a still finger: by the time this runs the touch has already
///   travelled a VARIABLE distance (measured: 24.0 from a drag begun at x=10, and
///   30.0 from one begun at x=6 — nearer the edge reading further from it). Every
///   such refusal looks exactly like a back-swipe that has been broken, which is
///   how it survived a green suite for a whole session. The start is captured at
///   touch-down in `shouldReceive` instead.
@MainActor
final class UploadNavigationController: UINavigationController {
    /// ⚠️ **THE SAME BAND THE CAROUSELS YIELD OVER, STATED ONCE.** If this gate
    /// accepted a narrower edge than `CarouselBackSwipe` stands aside for, drags
    /// in the difference would get neither a pop nor a rubber-band — the carousel
    /// would have declined its own pan for a gesture that then refuses the touch.
    private static var edgeWidth: CGFloat { CarouselBackSwipe.edgeWidth }

    /// The pan that actually pops. Weak: UIKit owns it.
    private weak var fullWidthPan: UIPanGestureRecognizer?

    /// Where the finger landed, recorded at touch-down.
    ///
    /// ⚠️ **BY THE TIME `shouldBegin` RUNS THE FINGER HAS ALREADY MOVED — AND NOT
    /// BY A FIXED AMOUNT.** Measured on this screen with the probe below: a drag
    /// injected from x=10 reported `startX=24.0`, and one from x=6 — further left
    /// — reported `startX=30.0`. Starting NEARER the edge read FURTHER from it, so
    /// the offset is not a constant to subtract; it grows with how slowly the drag
    /// accelerates before the recogniser commits.
    ///
    /// So inside `shouldBegin` there is no trustworthy start position at all:
    /// translation reads `(0,0)` because the recogniser rebases, and `location`
    /// has already travelled. `shouldReceive` is the one moment the touch is still
    /// where the viewer put it.
    private var touchDownX: CGFloat?

    override func viewDidLoad() {
        super.viewDidLoad()
        holdTheBackSwipeToTheEdge()
    }

    /// ⚠️ RE-APPLIED AS THE STACK CHANGES. UIKit re-arms its transition gestures
    /// around pushes, so a delegate taken once at load is not enough.
    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        super.pushViewController(viewController, animated: animated)
        holdTheBackSwipeToTheEdge()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        holdTheBackSwipeToTheEdge()
    }

    /// ⚠️ **IDENTITY, NOT CLASS NAME** — "a pan on the stack's view that is not
    /// the vended one" — so a renamed private class in a future iOS does not
    /// silently restore the full-width gesture.
    private func holdTheBackSwipeToTheEdge() {
        for recogniser in view.gestureRecognizers ?? [] {
            guard let pan = recogniser as? UIPanGestureRecognizer,
                  pan !== interactivePopGestureRecognizer
            else { continue }
            fullWidthPan = pan
            pan.delegate = self
        }
        logGateState()
    }

    /// ⚠️ **THE DENOMINATOR FOR THE PROBE BELOW.** `logGate` only speaks when
    /// `shouldBegin` is called, so its silence is ambiguous: a delegate never
    /// installed and a delegate never consulted look identical. This says which,
    /// and it must be read BEFORE any conclusion is drawn from that silence.
    private func logGateState() {
        let pans = (view.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
        logGate(
            "state pansOnNavView=\(pans.count) "
                + "gated=\(fullWidthPan.map { "\(type(of: $0))" } ?? "NONE FOUND") "
                + "delegateIsMine=\(debugGatesTheBackSwipe) "
                + "gatedEnabled=\(fullWidthPan?.isEnabled.description ?? "nil") "
                + "vendedEnabled=\(interactivePopGestureRecognizer?.isEnabled.description ?? "nil")"
        )
    }

    /// Internal for tests: whether the gate is actually installed.
    ///
    /// ⚠️ A test can assert this, and that the decision below is right. It CANNOT
    /// assert that the screen pops — no unit test begins a pan — which is why the
    /// reach is proven with injected drags on a device.
    var debugGatesTheBackSwipe: Bool { fullWidthPan?.delegate === self }
}

// MARK: - Where a back-swipe may begin

extension UploadNavigationController: UIGestureRecognizerDelegate {
    /// ⚠️ **A PROBE, NOT A FILTER — IT ALWAYS ANSWERS TRUE.** Its only purpose is
    /// to read the touch while it is still at its origin, because `shouldBegin` is
    /// asked too late to know. Answering false here would silence the gesture
    /// outright, which is a different bug wearing the same face.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        if gestureRecognizer === fullWidthPan {
            touchDownX = touch.location(in: view).x
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            logGate("asked about a non-pan \(type(of: gestureRecognizer)) -> true")
            return true
        }
        guard pan === fullWidthPan else {
            logGate("asked about \(type(of: pan)) which is NOT the gated one -> true")
            return true
        }
        // The safety UIKit's own delegate provided, re-stated because taking the
        // delegate slot took it away.
        guard viewControllers.count > 1, transitionCoordinator == nil else {
            logGate("refuse: depth=\(viewControllers.count) transitioning=\(transitionCoordinator != nil)")
            return false
        }
        guard let top = topViewController, !top.navigationItem.hidesBackButton else {
            logGate("refuse: hidesBackButton")
            return false
        }

        // ⚠️ **THIS DELEGATE IS ASKED BEFORE THE TOUCH HAS MOVED AT ALL — NEITHER
        // TRANSLATION NOR VELOCITY EXISTS YET.** Measured on this screen, with the
        // finger 10pt in and travelling right: `moved=(0.0, 0.0)` first, then
        // `v=(0.0, 0.0)` after switching to velocity. A direction test refuses
        // EVERY drag here and looks exactly like a gesture that has been killed —
        // it cost two builds to tell those apart.
        //
        // So only WHERE the touch began is decidable at this instant, and that is
        // the whole question anyway: the recogniser keeps its own direction logic
        // for the rest of the gesture. A vertical drag starting near the leading
        // edge is therefore left to it, and that case is verified on a device
        // rather than asserted here — no unit test can begin this pan.
        //
        // ⚠️ **`location` IS NOT WHERE THE DRAG BEGAN — THAT CLAIM STOOD HERE, IN
        // CAPITALS, AND WAS WRONG.** The recogniser asks only once the touch looks
        // like a pan, by which point the finger has travelled a VARIABLE distance:
        // measured, a drag begun at x=10 read 24.0 and one begun at x=6 read 30.0.
        // Nearer the edge read further from it, so there is no fixed offset to
        // subtract. Both refusals looked exactly like a back-swipe someone had
        // broken, which is how this survived a green suite.
        //
        // `touchDownX` is captured in `shouldReceive` above, where the touch is
        // still at rest. The fallback covers only a recogniser that somehow began
        // without one, and it keeps the old (wrong) reading rather than refusing.
        let startX = touchDownX ?? pan.location(in: view).x

        // ⚠️ **THE EDGE BAND AND THE FIRST CHIP OVERLAP, AND THE BACK-SWIPE WAS
        // WINNING.** The editing band's row starts at x=16 while this gate accepts
        // anything within 20pt of the edge, so a drag begun on the leftmost chip
        // was claimed as a back-swipe and the row would not scroll. Reported from
        // a device as "sometimes scrolling from an item does nothing".
        //
        // A band holds a control of its own; drags inside it belong to that
        // control, never to the stack.
        let inBand = Self.beginsInsideTheEditingBand(pan.location(in: top.view), in: top.view)
        let verdict = !inBand && Self.allows(startX: startX, edgeWidth: Self.edgeWidth)
        logGate("ask on \(type(of: top)) startX=\(startX) inBand=\(inBand) -> \(verdict)")
        return verdict
    }

    /// Whether a touch begins inside the editing band, whose tenant owns its own
    /// drags.
    ///
    /// ⚠️ NOT "inside any horizontal scroller" — the editor's canvas is one and
    /// runs the whole screen, so that rule would disable the back-swipe entirely.
    /// It is the BAND that claims its drags, not scrolling in general.
    static func beginsInsideTheEditingBand(_ point: CGPoint, in root: UIView) -> Bool {
        guard let hit = root.hitTest(point, with: nil) else { return false }
        var node: UIView? = hit
        while let current = node {
            if current is MediaEditorBandView { return true }
            if current === root { return false }
            node = current.superview
        }
        return false
    }

    /// ⚠️ A DEBUG PROBE, BECAUSE FOUR PREDICTIONS IN A ROW WERE WRONG ON THIS
    /// SCREEN. Silence here means the delegate is not on the recogniser that
    /// acts — a different defect from a refusal, and they need opposite fixes.
    func logGate(_ what: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.arguments.contains("-upload-log-sheet") else { return }
        let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[gate] t=\(stamp) \(what())\n".utf8))
    }

    /// Whether a drag beginning at `startX` may be a back-swipe.
    ///
    /// ⚠️ PURE, AND DELIBERATELY THE ONLY THING THIS DECIDES: at the moment the
    /// delegate is asked, the touch has not moved, so direction is not knowable
    /// here. See the call site.
    static func allows(startX: CGFloat, edgeWidth: CGFloat) -> Bool {
        startX <= edgeWidth
    }
}
