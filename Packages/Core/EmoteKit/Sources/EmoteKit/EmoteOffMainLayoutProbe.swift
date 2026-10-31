import Foundation
import ObjectiveC
import Synchronization
import UIKit

#if DEBUG
/// **#1603's witness.** With `EMOTE_OFFMAIN_PROBE=1` in the environment
/// (`TEST_RUNNER_EMOTE_OFFMAIN_PROBE=1` for a test run), every view laid out
/// OFF the main thread says which it is — its type, whether it has a window,
/// its superviews, the thread and the stack — just before UIKit's own
/// assertion stops the process. Installed on the first off-main commit.
/// Public runtime API on a public selector (`layoutSublayers(of:)`); never
/// in a release build, never without the variable.
enum EmoteOffMainLayoutProbe {
    private static let installed = Atomic<Bool>(false)

    static func installIfAsked() {
        guard ProcessInfo.processInfo.environment["EMOTE_OFFMAIN_PROBE"] == "1",
              installed.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged
        else { return }
        let selector = #selector(CALayerDelegate.layoutSublayers(of:))
        guard let method = class_getInstanceMethod(UIView.self, selector) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, CALayer) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject, CALayer) -> Void = { view, layer in
            if !Thread.isMainThread { report(view, layer: layer) }
            original(view, selector, layer)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        print("[emote-offmain] probe installed")
    }

    private static func report(_ object: AnyObject, layer: CALayer) {
        var lines = ["[emote-offmain] laid out OFF MAIN: \(type(of: object)) \(Unmanaged.passUnretained(object).toOpaque())"]
        if let view = object as? UIView {
            lines.append("[emote-offmain]   window: \(view.window.map { String(describing: type(of: $0)) } ?? "nil")")
            var chain: [String] = []
            var ancestor = view.superview
            while let next = ancestor, chain.count < 16 {
                chain.append(String(describing: type(of: next)))
                ancestor = next.superview
            }
            lines.append("[emote-offmain]   superviews: \(chain.joined(separator: " < "))")
            lines.append("[emote-offmain]   subviews: \(view.subviews.map { String(describing: type(of: $0)) })")
        }
        lines.append("[emote-offmain]   layer: \(type(of: layer)) superlayer: \(layer.superlayer.map { String(describing: type(of: $0)) } ?? "nil")")
        lines.append("[emote-offmain]   thread: \(Thread.current) qos: \(qos_class_self().rawValue)")
        lines += Thread.callStackSymbols.prefix(48).map { "[emote-offmain]   \($0)" }
        print(lines.joined(separator: "\n"))
        fflush(stdout)
    }
}
#endif
