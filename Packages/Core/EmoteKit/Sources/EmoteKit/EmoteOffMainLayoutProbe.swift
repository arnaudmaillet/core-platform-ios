import Foundation
import ObjectiveC
import Synchronization
import UIKit

#if DEBUG
/// **#1603's witness.** Every view laid out OFF the main thread says which it
/// is — its type, its window, its superviews, who last marked it for layout,
/// the thread and the stack — just before UIKit's own assertion stops the
/// process. Installed on the first off-main commit, in every test run
/// (`XCTestConfigurationFilePath` in the environment) and wherever
/// `EMOTE_OFFMAIN_PROBE=1` is set; never in a release build.
///
/// It also watches UIKit's floating bar (`_UIFloatingBarContainerView`, the
/// view #1603's crashes name), compared by class, so a view of any other
/// class costs one pointer comparison:
/// - who last marked one for layout (`setNeedsLayout`, `setFrame:`,
///   `setBounds:`), on which thread, and whether the main thread was asleep;
/// - whether one IN A WINDOW is still pending when the main thread falls
///   asleep, after the park's flush (`checkAfterFlush`).
///
/// ⚠️ A DETACHED BAR PENDING FOREVER IS NOT A FINDING. A navigation
/// controller that outlives its window keeps its bar, and a first-responder
/// change anywhere marks every bar in the process. A tree in no window is laid
/// out by no commit, on any thread (`EmoteCommitReachTests`), so only bars in
/// a window are reported.
enum EmoteOffMainLayoutProbe {
    private static let installed = Atomic<Bool>(false)

    /// Whether the probe is installed.
    static var isOn: Bool { installed.load(ordering: .relaxed) }

    /// The watched class. Nil on a system without it: nothing is watched.
    nonisolated(unsafe) private static var floatingBar: AnyClass?

    /// A mark for layout: where it came from.
    private struct Mark {
        let selector: String
        let onMain: Bool
        let mainAsleep: Bool
        let stack: [String]
    }

    private final class WeakLayer: @unchecked Sendable {
        weak var layer: CALayer?
        init(_ layer: CALayer) { self.layer = layer }
    }

    /// The bars laid out on the main thread, by layer, weakly; and each one's
    /// last mark.
    private struct Watch {
        var layers: [ObjectIdentifier: WeakLayer] = [:]
        var marks: [ObjectIdentifier: Mark] = [:]
        var pendingReports = 0
    }

    private static let watch = Mutex(Watch())

    /// Whether this process should carry the probe.
    static var isAsked: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["EMOTE_OFFMAIN_PROBE"] == "1" || environment["XCTestConfigurationFilePath"] != nil
    }

    static func installIfAsked() {
        guard isAsked, installed.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else {
            return
        }
        floatingBar = NSClassFromString("_UIFloatingBarContainerView")
        swizzleLayout()
        swizzleMark(#selector(UIView.setNeedsLayout))
        swizzleMark(NSSelectorFromString("setFrame:"), argument: CGRect.self)
        swizzleMark(NSSelectorFromString("setBounds:"), argument: CGRect.self)
        print("[emote-offmain] probe installed")
    }

    /// Called by the park's sleep mark on the main thread, right after its
    /// flush: a watched bar in a window still pending here would be laid out
    /// by whichever thread commits its context next.
    static func checkAfterFlush() {
        guard isOn else { return }
        let pending = watch.withLock { state -> [(CALayer, Mark?)] in
            state.layers = state.layers.filter { $0.value.layer != nil }
            guard state.pendingReports < 20 else { return [] }
            var found: [(CALayer, Mark?)] = []
            for (key, entry) in state.layers {
                guard let layer = entry.layer, layer.needsLayout(),
                      let view = layer.delegate as? UIView, view.window != nil
                else { continue }
                found.append((layer, state.marks[key]))
            }
            if !found.isEmpty { state.pendingReports += 1 }
            return found
        }
        guard !pending.isEmpty else { return }
        var lines: [String] = []
        for (layer, mark) in pending {
            lines.append("[emote-offmain] STILL PENDING after the park's flush, in a window: \(layer.delegate.map { String(describing: type(of: $0)) } ?? "?")")
            if let view = layer.delegate as? UIView { lines += place(of: view) }
            lines += describe(mark)
        }
        print(lines.joined(separator: "\n"))
        fflush(stdout)
    }

    private static func isWatched(_ object: AnyObject) -> Bool {
        guard let floatingBar else { return false }
        return object_getClass(object) == floatingBar
    }

    private static func swizzleLayout() {
        let selector = #selector(CALayerDelegate.layoutSublayers(of:))
        guard let method = class_getInstanceMethod(UIView.self, selector) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, CALayer) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject, CALayer) -> Void = { view, layer in
            if !Thread.isMainThread {
                report(view, layer: layer)
            } else if isWatched(view) {
                let key = ObjectIdentifier(layer)
                watch.withLock { state in
                    if state.layers[key] == nil { state.layers[key] = WeakLayer(layer) }
                }
            }
            original(view, selector, layer)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    private static func swizzleMark(_ selector: Selector) {
        guard let method = class_getInstanceMethod(UIView.self, selector) else { return }
        typealias Original = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject) -> Void = { view in
            if isWatched(view) { note(view, selector) }
            original(view, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    private static func swizzleMark(_ selector: Selector, argument: CGRect.Type) {
        guard let method = class_getInstanceMethod(UIView.self, selector) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, CGRect) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject, CGRect) -> Void = { view, rect in
            if isWatched(view) { note(view, selector) }
            original(view, selector, rect)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// Records who marks a watched bar, from whatever thread does it.
    private static func note(_ view: AnyObject, _ selector: Selector) {
        guard let layer = (view as? UIView)?.layer else { return }
        let mark = Mark(
            selector: NSStringFromSelector(selector),
            onMain: Thread.isMainThread,
            mainAsleep: EmoteMainPark.debugMainAsleep,
            stack: Array(Thread.callStackSymbols.dropFirst(2).prefix(24))
        )
        watch.withLock { $0.marks[ObjectIdentifier(layer)] = mark }
    }

    /// The view's window and superviews.
    private static func place(of view: UIView) -> [String] {
        var lines: [String] = []
        if let window = view.window {
            lines.append("[emote-offmain]   window: \(type(of: window)) hidden \(window.isHidden) root \(window.rootViewController.map { String(describing: type(of: $0)) } ?? "nil")")
        } else {
            lines.append("[emote-offmain]   window: nil")
        }
        var chain: [String] = []
        var ancestor = view.superview
        while let next = ancestor, chain.count < 16 {
            chain.append(String(describing: type(of: next)))
            ancestor = next.superview
        }
        lines.append("[emote-offmain]   superviews: \(chain.joined(separator: " < "))")
        return lines
    }

    private static func describe(_ mark: Mark?) -> [String] {
        guard let mark else {
            return ["[emote-offmain]   last mark: none seen (marked by Core Animation itself, or before the probe)"]
        }
        var lines = ["[emote-offmain]   last mark: \(mark.selector) on \(mark.onMain ? "MAIN" : "A BACKGROUND THREAD"), main \(mark.mainAsleep ? "ASLEEP" : "awake")"]
        lines += mark.stack.map { "[emote-offmain]     \($0)" }
        return lines
    }

    private static func report(_ object: AnyObject, layer: CALayer) {
        var lines = ["[emote-offmain] laid out OFF MAIN: \(type(of: object)) \(Unmanaged.passUnretained(object).toOpaque())"]
        if let view = object as? UIView {
            lines += place(of: view)
            lines.append("[emote-offmain]   subviews: \(view.subviews.map { String(describing: type(of: $0)) })")
        }
        lines.append("[emote-offmain]   layer: \(type(of: layer)) superlayer: \(layer.superlayer.map { String(describing: type(of: $0)) } ?? "nil")")
        lines += describe(watch.withLock { $0.marks[ObjectIdentifier(layer)] })
        lines.append("[emote-offmain]   thread: \(Thread.current) qos: \(qos_class_self().rawValue)")
        lines += Thread.callStackSymbols.prefix(48).map { "[emote-offmain]   \($0)" }
        print(lines.joined(separator: "\n"))
        fflush(stdout)
    }
}
#endif
