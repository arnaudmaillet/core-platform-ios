#if DEBUG
import UIKit

/// What a scripted scroll of a picture-led header costs, frame by frame —
/// the instrument behind `-profile-scroll-sweep` and `-place-scroll-sweep`.
///
/// Two numbers a simulator CAN give, and one it cannot:
/// - **the main thread's share of a frame**: each step (the offset, the
///   layout it causes, the commit that hands the layer tree to the render
///   server) is timed with an explicit `CATransaction.flush()`, so the
///   number includes what the run loop's own commit would have cost;
/// - **the display link's intervals**, which a main-thread stall stretches;
/// - and NOT the GPU's share. A simulator renders on the Mac's GPU, orders
///   of magnitude past a phone's (`sim-animation-qa`), so an offscreen pass
///   costs it nothing measurable. What stands in for it is a CENSUS of the
///   layers that force one — masks, shadows without a path, group opacity
///   over a subtree — taken every frame on the header's own tree: the count
///   is the same on a device, and on a device each one is a render pass of
///   its own, every frame the layer moves.
///
/// One line on standard error at the end (unbuffered — `print` from an app
/// that never exits reads empty from a file sink):
/// `HERO-SCROLL <name> frames=… main mean/p95/max … link hitches=… offscreen max masks/shadows/groups (rasterized)`.
@MainActor
public final class HeroScrollFrameProbe {
    /// The layers in a tree that make the render server draw offscreen.
    public struct Census: Equatable, Sendable, CustomStringConvertible {
        /// Layers with a mask — an offscreen pass each, the size of the
        /// masked layer.
        public var masks = 0
        /// Shadows with no `shadowPath`: the shape is read off the layer's
        /// rendered alpha, offscreen, every frame.
        public var shadows = 0
        /// Partial opacity over a subtree (`allowsGroupOpacity`): the
        /// subtree is flattened offscreen before it is faded.
        public var groups = 0
        /// Rasterized layers: offscreen once, then a cached bitmap while
        /// their content holds — the cheap side of the ledger.
        public var rasterized = 0

        public var offscreen: Int { masks + shadows + groups }
        public var description: String {
            "masks=\(masks) shadows=\(shadows) groups=\(groups) (rasterized=\(rasterized))"
        }

        public init() {}

        /// Walks `layer`'s visible tree. A rasterized subtree is one cached
        /// bitmap: what is inside it is not drawn again while it holds.
        public init(of layer: CALayer) {
            visit(layer)
        }

        private mutating func visit(_ layer: CALayer) {
            guard !layer.isHidden, layer.opacity > 0.001 else { return }
            if layer.shouldRasterize {
                rasterized += 1
                return
            }
            if layer.mask != nil { masks += 1 }
            if layer.shadowOpacity > 0, layer.shadowPath == nil { shadows += 1 }
            let sublayers = layer.sublayers ?? []
            if layer.opacity < 0.999, layer.allowsGroupOpacity,
               sublayers.count + (layer.contents == nil ? 0 : 1) > 1 {
                groups += 1
            }
            for sublayer in sublayers { visit(sublayer) }
        }
    }

    private let name: String
    private weak var root: UIView?
    private var mainMilliseconds: [Double] = []
    private var census = Census()
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var intervals: [Double] = []

    public init(name: String, root: UIView) {
        self.name = name
        self.root = root
        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// One frame of the scroll: `step` moves it, and the layout and commit
    /// it causes are timed with it.
    public func frame(_ step: () -> Void) {
        let began = CACurrentMediaTime()
        step()
        root?.window?.layoutIfNeeded()
        CATransaction.flush()
        mainMilliseconds.append((CACurrentMediaTime() - began) * 1000)
        if let layer = root?.layer {
            let now = Census(of: layer)
            census.masks = max(census.masks, now.masks)
            census.shadows = max(census.shadows, now.shadows)
            census.groups = max(census.groups, now.groups)
            census.rasterized = max(census.rasterized, now.rasterized)
        }
    }

    /// Stops the display link and writes the line.
    public func finish() {
        link?.invalidate()
        link = nil
        func stats(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "n/a" }
            let sorted = values.sorted()
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return String(format: "mean=%.2f p95=%.2f max=%.2f", mean, p95, sorted.last ?? 0)
        }
        let target = 1000 / Double(max(1, root?.window?.screen.maximumFramesPerSecond ?? 60))
        let hitches = intervals.filter { $0 > target * 1.5 }.count
        let line = "HERO-SCROLL \(name) frames=\(mainMilliseconds.count) main[\(stats(mainMilliseconds))]ms "
            + "link[frames=\(intervals.count) hitches=\(hitches) \(stats(intervals))]ms "
            + "offscreen-max[\(census)]\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    fileprivate func tick(_ link: CADisplayLink) {
        if lastTick > 0 { intervals.append((link.timestamp - lastTick) * 1000) }
        lastTick = link.timestamp
    }

    /// The display link retains its target; this keeps it from retaining
    /// the probe.
    /// Main-actor: the link runs on the main run loop.
    @MainActor private final class Ticker: NSObject {
        weak var probe: HeroScrollFrameProbe?
        init(_ probe: HeroScrollFrameProbe) { self.probe = probe }
        @objc func tick(_ link: CADisplayLink) { probe?.tick(link) }
    }
}
#endif
