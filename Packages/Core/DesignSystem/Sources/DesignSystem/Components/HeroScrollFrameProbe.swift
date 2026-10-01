import UIKit

/// The picture-led headers' own work, by kind — what `HeroScrollFrameProbe`
/// splits a frame's banner time into. Timed only while a probe runs, and
/// only in DEBUG; elsewhere `measure` is the body and nothing else.
public enum HeroBannerCost {
    public enum Section: String, CaseIterable, Sendable {
        /// `HeroBannerPictureView`'s layout pass (its blur's composition
        /// included).
        case layout
        /// One composition of the blurred run-out (`HeroBannerBlurRows`).
        case compose
        /// A bake landing on the main thread: adopting the levels, and
        /// everything it sets off.
        case adopt
        /// `HeroBannerRampView`'s layout pass.
        case ramp
        /// A header reading the ground under its type and picking its ink.
        case ink
    }

    /// Runs `body`, timed under `section` while a probe runs.
    @MainActor @inline(__always)
    public static func measure<T>(_ section: Section, _ body: () throws -> T) rethrows -> T {
        #if DEBUG
        return try HeroScrollFrameProbe.measure(section, body)
        #else
        return try body()
        #endif
    }

    /// Counts a bake started — on a background queue, so its time is not
    /// the main thread's; how many a gesture starts is what tells.
    @MainActor @inline(__always)
    public static func countBake() {
        #if DEBUG
        HeroScrollFrameProbe.countBake()
        #endif
    }
}

#if DEBUG
/// What a scripted scroll of a picture-led header costs, frame by frame —
/// the instrument behind `-profile-scroll-sweep`, `-place-scroll-sweep` and
/// the pull-down `-profile-stretch-sweep` / `-place-stretch-sweep`.
///
/// Two numbers a simulator CAN give, and one it cannot:
/// - **the main thread's share of a frame**: each step (the offset, the
///   layout it causes, the commit that hands the layer tree to the render
///   server) is timed with an explicit `CATransaction.flush()`, so the
///   number includes what the run loop's own commit would have cost — and,
///   inside it, the BANNER's share (`HeroBannerCost`, by section);
/// - **the display link's intervals**, which a main-thread stall stretches
///   — including the ones no step caused (a refresh landing between two);
/// - and NOT the GPU's share. A simulator renders on the Mac's GPU, orders
///   of magnitude past a phone's (`sim-animation-qa`), so an offscreen pass
///   costs it nothing measurable. What stands in for it is a CENSUS of the
///   layers that force one — masks, shadows without a path, group opacity
///   over a subtree — taken every frame on the header's own tree: the count
///   is the same on a device, and on a device each one is a render pass of
///   its own, every frame the layer moves.
///
/// One line on standard error at the end, and one per phase when the sweep
/// names them (unbuffered — `print` from an app that never exits reads
/// empty from a file sink):
/// `HERO-SCROLL <name>[/phase] frames=… main mean/p95/max … banner … link hitches=… sections … bakes=… offscreen max …`.
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

    /// The probe running, if any: what `HeroBannerCost` reports to.
    private static weak var running: HeroScrollFrameProbe?

    /// Every blur composition on the main thread while a probe runs
    /// (`HeroBannerPictureView.composeBlur`): its milliseconds and rows —
    /// the CPU the masks' offscreen passes were traded for.
    private static var composeSamples: [(milliseconds: Double, rows: Int)] = []

    /// Called by the banner after each composition.
    public static func recordCompose(_ milliseconds: Double, rows: Int) {
        composeSamples.append((milliseconds, rows))
    }

    /// How deep the banner's timed sections are nested right now: only the
    /// outermost one counts towards a frame's banner time (a layout pass
    /// includes the composition it runs).
    private static var depth = 0

    fileprivate static func measure<T>(_ section: HeroBannerCost.Section, _ body: () throws -> T) rethrows -> T {
        guard let probe = running else { return try body() }
        let began = CACurrentMediaTime()
        depth += 1
        defer {
            depth -= 1
            let milliseconds = (CACurrentMediaTime() - began) * 1000
            probe.sections[section, default: Ledger()].add(milliseconds)
            if depth == 0 { probe.bannerThisFrame += milliseconds }
        }
        return try body()
    }

    fileprivate static func countBake() {
        running?.bakes += 1
    }

    /// One section's count and total.
    private struct Ledger {
        var count = 0
        var milliseconds: Double = 0
        mutating func add(_ value: Double) {
            count += 1
            milliseconds += value
        }
    }

    /// What one phase of a sweep recorded.
    private struct Phase {
        var name: String
        var main: [Double] = []
        var banner: [Double] = []
        var intervals: [Double] = []
    }

    private let name: String
    private weak var root: UIView?
    private var phases: [Phase]
    private var sections: [HeroBannerCost.Section: Ledger] = [:]
    private var bakes = 0
    private var bannerThisFrame: Double = 0
    private var census = Census()
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    public init(name: String, root: UIView) {
        self.name = name
        self.root = root
        phases = [Phase(name: "")]
        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        Self.composeSamples = []
        Self.running = self
    }

    /// Starts a named phase of the sweep — a pull, a release, the settle
    /// after it — reported on its own line as well as in the total.
    public func beginPhase(_ phase: String) {
        if phases.count == 1, phases[0].main.isEmpty, phases[0].intervals.isEmpty {
            phases[0].name = phase
        } else {
            phases.append(Phase(name: phase))
        }
    }

    /// One frame of the scroll: `step` moves it, and the layout and commit
    /// it causes are timed with it.
    public func frame(_ step: () -> Void) {
        bannerThisFrame = 0
        let began = CACurrentMediaTime()
        step()
        root?.window?.layoutIfNeeded()
        CATransaction.flush()
        phases[phases.count - 1].main.append((CACurrentMediaTime() - began) * 1000)
        phases[phases.count - 1].banner.append(bannerThisFrame)
        if let layer = root?.layer {
            let now = Census(of: layer)
            census.masks = max(census.masks, now.masks)
            census.shadows = max(census.shadows, now.shadows)
            census.groups = max(census.groups, now.groups)
            census.rasterized = max(census.rasterized, now.rasterized)
        }
    }

    /// Stops the display link and writes the lines.
    public func finish() {
        link?.invalidate()
        link = nil
        if Self.running === self { Self.running = nil }
        func stats(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "n/a" }
            let sorted = values.sorted()
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return String(format: "mean=%.2f p95=%.2f max=%.2f", mean, p95, sorted.last ?? 0)
        }
        let target = 1000 / Double(max(1, root?.window?.screen.maximumFramesPerSecond ?? 60))
        func line(_ label: String, _ phase: Phase) -> String {
            let hitches = phase.intervals.filter { $0 > target * 1.5 }.count
            return "HERO-SCROLL \(label) frames=\(phase.main.count) main[\(stats(phase.main))]ms "
                + "banner[\(stats(phase.banner))]ms "
                + "link[frames=\(phase.intervals.count) hitches=\(hitches) \(stats(phase.intervals))]ms"
        }
        var lines: [String] = []
        if phases.count > 1 || !phases[0].name.isEmpty {
            lines += phases.map { line("\(name)/\($0.name)", $0) + "\n" }
        }
        let total = Phase(
            name: "", main: phases.flatMap(\.main), banner: phases.flatMap(\.banner),
            intervals: phases.flatMap(\.intervals)
        )
        let ledger = HeroBannerCost.Section.allCases.map { section -> String in
            let entry = sections[section] ?? Ledger()
            return String(format: "%@ n=%d %.1fms", section.rawValue, entry.count, entry.milliseconds)
        }.joined(separator: ", ")
        lines.append(
            line(name, total) + " "
                + "compose[n=\(Self.composeSamples.count) rows=\(Self.composeSamples.map(\.rows).max() ?? 0) "
                + "\(stats(Self.composeSamples.map(\.milliseconds)))]ms "
                + "sections[\(ledger)] bakes=\(bakes) "
                + "offscreen-max[\(census)]\n"
        )
        for text in lines { FileHandle.standardError.write(Data(text.utf8)) }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        if lastTick > 0 { phases[phases.count - 1].intervals.append((link.timestamp - lastTick) * 1000) }
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

/// The pull-down both picture-led headers are swept through by
/// `-profile-stretch-sweep` / `-place-stretch-sweep`: the page pulled past
/// its top to `depth` (the banner stretching), held there a beat, let go —
/// where a profile refreshes, as a finger's release past the threshold
/// does — and watched at rest while the refresh lands.
public enum HeroStretchSweep {
    public enum Phase: String, Sendable {
        case pull, hold, release, settle
    }

    /// How far past its top the page is pulled — past a refresh's 120.
    public static let depth: CGFloat = 160

    /// Each phase and how long it lasts, in order.
    static let timeline: [(phase: Phase, seconds: Double)] = [
        (.pull, 1.5), (.hold, 0.5), (.release, 1.0), (.settle, 1.5)
    ]

    /// Where the sweep stands `t` seconds in — its phase, and the page's
    /// offset (negative: pulled down) — or nil once it is over.
    public static func at(_ t: Double) -> (phase: Phase, offset: CGFloat)? {
        var start = 0.0
        for (phase, seconds) in timeline {
            defer { start += seconds }
            guard t < start + seconds else { continue }
            let x = CGFloat(max(0, min((t - start) / seconds, 1)))
            let eased = x * x * (3 - 2 * x)
            switch phase {
            case .pull: return (phase, -depth * eased)
            case .hold: return (phase, -depth)
            case .release: return (phase, -depth * (1 - eased))
            case .settle: return (phase, 0)
            }
        }
        return nil
    }
}
#endif
