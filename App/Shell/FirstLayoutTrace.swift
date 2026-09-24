import ObjectiveC
import UIKit

// ⚠️ THE WHOLE FILE: a DEBUG harness, installed only under `-first-layout-trace`.
#if DEBUG

/// `-first-layout-trace` — names the animation block that captured a screen's
/// FIRST layout pass.
///
/// # The defect it hunts
///
/// Intermittently, a screen arrives by "unfolding" from the top-left corner to
/// the bottom-right instead of sliding, dissolving or flying in. That is the
/// signature of ONE thing: the view's first layout pass ran inside an active
/// animation block, so every subview animated from its birth frame (`.zero`,
/// the top-left corner) to its real one. This repo has filmed it three times
/// (`SearchViewController.viewDidAppear`, `UINavigationController.crossDissolve`,
/// the animated snapshot apply in `PersonListCell`), each time with a different
/// block doing the capturing — the keyboard's, a `UIView.transition`'s, a
/// diffable apply's.
///
/// The bug needs two things in the same run-loop turn: a view installed but not
/// yet laid out, and somebody opening an animation that flushes layout up the
/// hierarchy. Which somebody varies with timing, so a film says WHAT unfolded and
/// never WHO captured it. This does: it swizzles `UIView.layoutSubviews`, and on
/// a screen-sized view's first pass in a window it checks two independent
/// witnesses —
///
///   - `UIView.inheritedAnimationDuration`, non-zero only inside a
///     `UIView.animate`/`transition` block (a property animator's block reports
///     through the same channel);
///   - the implicit `position`/`bounds` animations CoreAnimation has just
///     attached to the view's and its subviews' layers, which exist ONLY if the
///     frame changes were made inside an animation. They are ADDITIVE, so their
///     `fromValue` is the delta birth − final: `bounds.size from {-362, -674}`
///     on a 362x674 view means it grew from nothing, and `position from
///     {-201, -437}` that it grew from the origin — the top-left corner.
///
/// Either one trips a report — `MOVED` when animations were attached (pixels
/// travelled), `AT RISK` when only the block was open — with the view, its
/// controller chain and identity, the frame it had BEFORE the pass, the animation
/// keys with durations and from-values, a guess at the owning block, and the
/// call stack — which is the answer. Console and `Documents/first-layout.log`.
///
/// ⚠️ A view's first pass OFF-window is not reported. It cannot be seen, and
/// prewarmed screens (`prepareForHeroPresentation`, the snap feed's staged
/// panels) lay out off-window on purpose.
@MainActor
enum FirstLayoutTrace {
    private static var isInstalled = false
    private static var reports = 0
    /// Enough for a session; each report is ~40 lines.
    private static let reportCap = 80
    private static var sink: FileHandle?

    static func installIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-first-layout-trace"),
              !isInstalled
        else { return }
        isInstalled = true
        guard let original = class_getInstanceMethod(UIView.self, #selector(UIView.layoutSubviews)),
              let traced = class_getInstanceMethod(
                UIView.self, #selector(UIView.firstLayoutTrace_layoutSubviews))
        else {
            print("[first-layout] FAILED to install: layoutSubviews not found")
            return
        }
        method_exchangeImplementations(original, traced)
        let url = URL.documentsDirectory.appendingPathComponent("first-layout.log")
        try? Data().write(to: url)
        sink = try? FileHandle(forWritingTo: url)
        emit("[first-layout] START sink=\(url.path)")
    }

    /// `-first-layout-trace-selftest`: a POSITIVE CONTROL, because an empty log
    /// reads exactly like a passing one. Three seconds after launch it installs
    /// a screen-sized view and flushes its first layout inside a
    /// `UIView.animate` block — the defect, reproduced on purpose — and the
    /// detector must report the probe as MOVED with `owner=UIView.animate block`
    /// and from-values at the origin (its inner view's animations listed at
    /// depth 1; the inner view's own pass then reads AT RISK, because those
    /// animations were attached by the parent's pass, not its own). No report
    /// there means the detector is broken, not the app.
    static func selfTestIfRequested(in window: UIWindow) {
        guard ProcessInfo.processInfo.arguments.contains("-first-layout-trace-selftest"),
              isInstalled
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let probe = UIView(frame: window.bounds)
            probe.backgroundColor = .clear
            probe.isUserInteractionEnabled = false
            let inner = UIView()
            inner.translatesAutoresizingMaskIntoConstraints = false
            probe.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.leadingAnchor.constraint(equalTo: probe.leadingAnchor, constant: 20),
                inner.trailingAnchor.constraint(equalTo: probe.trailingAnchor, constant: -20),
                inner.topAnchor.constraint(equalTo: probe.topAnchor, constant: 100),
                inner.bottomAnchor.constraint(equalTo: probe.bottomAnchor, constant: -100),
            ])
            window.addSubview(probe)
            emit("[first-layout] SELFTEST begin: expecting the probe CAPTURED MOVED FROM ZERO (its inner view listed at depth 1) and the inner view AT RISK")
            UIView.animate(withDuration: 0.3) {
                probe.layoutIfNeeded()
            } completion: { _ in
                probe.removeFromSuperview()
                emit("[first-layout] SELFTEST end")
            }
        }
    }

    /// Called right after a view's FIRST `layoutSubviews`, in a window.
    /// Every geometry animation already on the view's layer and its two
    /// levels of subviews, keyed by layer identity — taken BEFORE the pass so
    /// only what the pass itself attaches is reported.
    ///
    /// ⚠️ Without this the reveal's own closing spring reported as a capture:
    /// the window host's first pass ran at commit time, after the property
    /// animator had put its 0.55s `bounds`/`position` animations on the card
    /// — legitimate motion, attached earlier, and nothing to do with layout.
    fileprivate static func animationCensus(of view: UIView) -> Set<String> {
        var seen = Set<String>()
        func scan(_ v: UIView, depth: Int) {
            for key in v.layer.animationKeys() ?? [] where isGeometry(key) {
                seen.insert("\(ObjectIdentifier(v.layer).hashValue).\(key)")
            }
            guard depth < 2 else { return }
            for sub in v.subviews { scan(sub, depth: depth + 1) }
        }
        scan(view, depth: 0)
        return seen
    }

    private static func isGeometry(_ key: String) -> Bool {
        key.hasPrefix("position") || key.hasPrefix("bounds") || key == "transform"
    }

    fileprivate static func inspect(_ view: UIView,
                                    inheritedDuration: TimeInterval,
                                    animationsEnabled: Bool,
                                    frameBefore: CGRect,
                                    attachedBefore: Set<String>) {
        // Witness 2: the implicit animations layout just attached. Scanned two
        // levels down — the root's own layer (a wrapper laying it out inside a
        // block animates THIS layer) and the subviews it placed. Animations
        // that were there before the pass are somebody's intended motion.
        var captured: [String] = []
        // The birth rect of whichever captured view moved the most: final
        // frame plus the additive deltas. A zero-sized birth is the defect; a
        // row-sized one is usually a window opening on purpose.
        var birth: (size: CGSize, centre: CGPoint, final: CGRect)?
        func scan(_ v: UIView, depth: Int) {
            var sizeDelta: CGSize?
            var centreDelta: CGPoint?
            for key in v.layer.animationKeys() ?? []
            where isGeometry(key)
                && !attachedBefore.contains("\(ObjectIdentifier(v.layer).hashValue).\(key)") {
                let animation = v.layer.animation(forKey: key)
                let fromValue = (animation as? CABasicAnimation)?.fromValue
                // ⚠️ A from-delta under a point is UIKit re-stating a frame it
                // already had (sheet layout does this at 1e-13). Not a move.
                if let delta = Self.magnitude(of: fromValue), delta < 1 { continue }
                if key.hasPrefix("bounds"), let sz = (fromValue as? NSValue)?.cgSizeValue { sizeDelta = sz }
                if key.hasPrefix("position"), let pt = (fromValue as? NSValue)?.cgPointValue { centreDelta = pt }
                captured.append(
                    String(format: "%@%@.%@ dur=%.3fs from=%@",
                           String(repeating: "  ", count: depth), String(describing: type(of: v)),
                           key, animation?.duration ?? 0,
                           fromValue.map { String(describing: $0) } ?? "?"))
            }
            if let sizeDelta {
                let final = v.frame
                let candidate = (
                    size: CGSize(width: final.width + sizeDelta.width, height: final.height + sizeDelta.height),
                    centre: CGPoint(x: final.midX + (centreDelta?.x ?? 0), y: final.midY + (centreDelta?.y ?? 0)),
                    final: final
                )
                if birth == nil || hypot(sizeDelta.width, sizeDelta.height)
                    > hypot(birth!.final.width - birth!.size.width, birth!.final.height - birth!.size.height) {
                    birth = candidate
                }
            }
            guard depth < 2 else { return }
            for sub in v.subviews { scan(sub, depth: depth + 1) }
        }
        scan(view, depth: 0)

        let suspect = inheritedDuration > 0 && animationsEnabled
        guard suspect || !captured.isEmpty else { return }

        // UIKit's own presentations lay their scaffolding out inside their own
        // springs, and that is their transition, not the defect: a context
        // menu's glass containers, a sheet's shadow view. Logged in one line so
        // the run is still legible, never as a report.
        let symbols = Thread.callStackSymbols
        if let benign = symbols.lazy.compactMap(Self.benignOwner(of:)).first {
            emit(String(format: "[first-layout] ignored t=%.3f view=%@ (%@)",
                        ProcessInfo.processInfo.systemUptime,
                        String(describing: type(of: view)), benign))
            return
        }
        reports += 1
        guard reports <= reportCap else {
            if reports == reportCap + 1 { emit("[first-layout] cap reached (\(reportCap)); silent from here") }
            return
        }
        let start = symbols.firstIndex { $0.contains("layoutSublayersOfLayer") } ?? 3
        let stack = Array(symbols.dropFirst(start).prefix(45))
        let owner = stack.lazy.compactMap(Self.owner(of:)).first ?? "unknown"

        // From the CoreAnimation frame that ran this layout pass; everything
        // above it is this harness. Swift frames print mangled — pipe the log
        // through `xcrun swift-demangle` to read them.
        var lines: [String] = []
        // MOVED FROM ZERO: something grew out of a zero-sized rect — the
        // defect, or a hidden copy of it. MOVED FROM <rect>: it travelled from a
        // real rect, which a window opening from a row does on purpose; with no
        // block open and no owner it is the pass inheriting an ancestor's
        // running animation (autoresizing), i.e. intended motion. AT RISK: the
        // block is open but this pass moved nothing.
        let verdict: String
        if let birth {
            let fromZero = birth.size.width < 2 || birth.size.height < 2
            let fromRect = String(format: "{%.0f,%.0f %.0fx%.0f}",
                                  birth.centre.x - birth.size.width / 2, birth.centre.y - birth.size.height / 2,
                                  birth.size.width, birth.size.height)
            let inherited = inheritedDuration == 0 && owner == "unknown"
            verdict = fromZero ? "MOVED FROM ZERO"
                : "MOVED FROM \(fromRect)" + (inherited ? " (inherited from an animating ancestor: likely intended)" : "")
        } else if captured.isEmpty {
            verdict = "AT RISK"
        } else {
            verdict = "MOVED"
        }
        lines.append(String(format: "[first-layout] ⚠️ CAPTURED %@ t=%.3f view=%@ frame=%@ frameBeforePass=%@",
                            verdict, ProcessInfo.processInfo.systemUptime,
                            String(describing: type(of: view)), NSCoder.string(for: view.frame),
                            NSCoder.string(for: frameBefore)))
        lines.append("[first-layout]   controllers: \(controllerChain(of: view))")
        lines.append("[first-layout]   identity: \(identity(of: view))")
        lines.append(String(format: "[first-layout]   inheritedAnimationDuration=%.3fs animationsEnabled=%@ owner=%@",
                            inheritedDuration, animationsEnabled ? "yes" : "no", owner))
        if captured.isEmpty {
            lines.append("[first-layout]   layer animations: none on root/subviews (block open, nothing captured yet)")
        } else {
            lines.append("[first-layout]   layer animations (\(captured.count)):")
            for line in captured.prefix(12) { lines.append("[first-layout]     \(line)") }
            if captured.count > 12 { lines.append("[first-layout]     … +\(captured.count - 12) more") }
        }
        lines.append("[first-layout]   stack:")
        for frame in stack {
            lines.append("[first-layout]     \(frame.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " "))")
        }
        emit(lines.joined(separator: "\n"))
    }

    /// |from| of an additive animation's delta, whatever CoreAnimation boxed
    /// it as (an NSValue holding a CGPoint or a CGSize, or a number).
    private static func magnitude(of value: Any?) -> CGFloat? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return abs(CGFloat(number.doubleValue)) }
        guard let boxed = value as? NSValue else { return nil }
        let type = String(cString: boxed.objCType)
        if type.contains("CGPoint") {
            let p = boxed.cgPointValue
            return hypot(p.x, p.y)
        }
        if type.contains("CGSize") {
            let sz = boxed.cgSizeValue
            return hypot(sz.width, sz.height)
        }
        return nil
    }

    /// Frames that name a UIKit presentation laying out its OWN scaffolding
    /// inside its own animation. First match wins.
    private static func benignOwner(of frame: String) -> String? {
        let benign: [(String, String)] = [
            ("_UIContextMenuPresentation", "context menu presentation"),
            ("UIRapidClickPresentationAssistant", "context menu presentation"),
            ("_sheetLayoutInfoLayout", "sheet layout"),
            ("UISheetPresentationController", "sheet presentation"),
        ]
        for (needle, name) in benign where frame.contains(needle) {
            return name
        }
        return nil
    }

    /// Enough about the view to know WHICH screen it is: a navigation
    /// controller's stack, a tab's identifier, visibility.
    private static func identity(of view: UIView) -> String {
        var parts: [String] = []
        var responder: UIResponder? = view
        while let current = responder, !(current is UIViewController) {
            responder = current.next
        }
        if let nav = responder as? UINavigationController {
            let stack = nav.viewControllers.map { String(describing: type(of: $0)) }
            parts.append("stack=[\(stack.joined(separator: ", "))]")
        } else if let controller = responder as? UIViewController {
            if let title = controller.title, !title.isEmpty { parts.append("title=\(title)") }
            if let selected = controller.tabBarController?.selectedViewController {
                parts.append("selectedTabRoot=\(String(describing: type(of: selected)))")
            }
        }
        if let controller = responder as? UIViewController {
            parts.append("isViewLoadedBefore=\(controller.isViewLoaded)")
            parts.append("beingPresented=\(controller.isBeingPresented) beingDismissed=\(controller.isBeingDismissed)")
            if let parent = controller.parent as? UITabBarController {
                let index = parent.viewControllers?.firstIndex(of: controller).map(String.init) ?? "?"
                let selected = parent.selectedViewController === controller
                parts.append("tabIndex=\(index) selected=\(selected)")
            }
        }
        parts.append("hidden=\(view.isHidden) alpha=\(view.alpha)")
        parts.append("superview=\(view.superview.map { String(describing: type(of: $0)) } ?? "nil")")
        parts.append("window=\(view.window.map { String(describing: type(of: $0)) } ?? "nil")")
        return parts.joined(separator: " ")
    }

    /// The controller the view belongs to, then its parents — enough to tell a
    /// pushed screen from a tab root from a presented sheet.
    private static func controllerChain(of view: UIView) -> String {
        var responder: UIResponder? = view
        while let current = responder, !(current is UIViewController) {
            responder = current.next
        }
        guard var controller = responder as? UIViewController else { return "none" }
        var names = [String(describing: type(of: controller))]
        while let parent = controller.parent ?? controller.presentingViewController {
            names.append(String(describing: type(of: parent)))
            controller = parent
            if names.count > 5 { break }
        }
        return names.joined(separator: " < ")
    }

    /// The usual suspects, by the frame that names them. First match wins, so
    /// the list runs from the most specific owner to the most generic.
    private static func owner(of frame: String) -> String? {
        let suspects: [(String, String)] = [
            ("setBottomAccessory", "UITabBarController.setBottomAccessory(_:animated:)"),
            ("setTabBarHidden", "UITabBarController.setTabBarHidden(_:animated:)"),
            ("setToolbarHidden", "UINavigationController.setToolbarHidden(_:animated:)"),
            ("setNavigationBarHidden", "UINavigationController.setNavigationBarHidden(_:animated:)"),
            ("UIInputWindowController", "keyboard animation"),
            ("UIPeripheralHost", "keyboard animation"),
            ("UIKeyboard", "keyboard animation"),
            ("transitionWithView", "UIView.transition(with:…)"),
            ("transitionFromView", "UIView.transition(from:to:…)"),
            ("setRootViewController", "UIWindow.rootViewController swap"),
            ("ToastView", "ToastView"),
            ("_performBatchUpdates", "collection/table batch update (animated apply)"),
            ("UIViewPropertyAnimator", "UIViewPropertyAnimator block"),
            ("UIViewControllerWrapperView", "navigation wrapper layout"),
            ("_UINavigationParallaxTransition", "navigation push/pop transition"),
            ("UINavigationController", "UINavigationController"),
            ("UITabBarController", "UITabBarController"),
            ("UIPresentationController", "presentation"),
            ("animateWithDuration", "UIView.animate block"),
        ]
        for (needle, name) in suspects where frame.contains(needle) {
            return name
        }
        return nil
    }

    private static func emit(_ text: String) {
        print(text)
        sink?.write(Data((text + "\n").utf8))
    }
}

extension UIView {
    /// One bit per view: "has had a layout pass". An associated object rather
    /// than a set of identifiers, because a freed view's address is reused and a
    /// set would then skip the newcomer's first pass.
    nonisolated(unsafe) private static let firstLayoutTraceLaidOutKey =
        UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    /// Swapped with `layoutSubviews` by `FirstLayoutTrace.installIfRequested`;
    /// after the exchange, calling this name runs the ORIGINAL implementation.
    @objc dynamic fileprivate func firstLayoutTrace_layoutSubviews() {
        let isFirst = objc_getAssociatedObject(self, UIView.firstLayoutTraceLaidOutKey) == nil
        if isFirst {
            objc_setAssociatedObject(self, UIView.firstLayoutTraceLaidOutKey, true,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        // Witness 1, read BEFORE the pass: the block this layout runs inside.
        let inherited = UIView.inheritedAnimationDuration
        let animationsEnabled = UIView.areAnimationsEnabled
        let frameBefore = frame
        // Only a screen-sized first pass is inspected, so the pre-pass census
        // is taken for those alone — the cost stays off every other layout.
        let inspecting = isFirst && window != nil && firstLayoutTrace_isScreenSized
        let before = inspecting ? FirstLayoutTrace.animationCensus(of: self) : []
        firstLayoutTrace_layoutSubviews()
        guard inspecting else { return }
        FirstLayoutTrace.inspect(self, inheritedDuration: inherited,
                                 animationsEnabled: animationsEnabled,
                                 frameBefore: frameBefore, attachedBefore: before)
    }

    /// A controller's root view, or anything covering 40% of the screen — the
    /// wrappers and containers UIKit puts around one. Cells and controls are
    /// left out: a control unfolding is a different, smaller defect.
    private var firstLayoutTrace_isScreenSized: Bool {
        if next is UIViewController { return true }
        guard let screen = window?.windowScene?.screen.bounds else { return false }
        return bounds.width * bounds.height >= 0.4 * screen.width * screen.height
    }
}

#endif
