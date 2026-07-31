#if DEBUG
import MediaPlayback
import UIKit

/// # Native `.zoom` evaluation spike — issue #83, Step 1
///
/// Answers ONE question before any more custom-transition work is done: does
/// UIKit's system zoom transition (`UIViewController.preferredTransition =
/// .zoom`) keep a live `AVPlayerLayer` rendering through the flight, or does it
/// substitute a static snapshot?
///
/// If it keeps it live, `ZoomAnimator`, `ZoomFlight`, `ZoomTransitionController`,
/// `ZoomDismissInteractionController`, `PostGridFlightCard`, the landing hold and
/// the parent hoist are all deletable. If it snapshots, this path is dead and
/// Step 2 (finish the permanent hoist) is next.
///
/// Run with `-native-zoom-spike`. It replaces the root view controller, so it
/// needs no login, no mock BFF and no grid — just one tile, one full-screen page
/// and a per-frame probe.
///
/// ## Why the instrumentation looks like this
///
/// Video renders BLACK in simulator captures, so pixels cannot tell a live layer
/// from a snapshot of one — both are black. Everything here is therefore
/// programmatic:
///
/// - `isReadyForDisplay` per surface, sampled every frame (a drop is the decode
///   round-trip the issue measured).
/// - `isPosterVisible` per surface — literally the thumbnail flash, since the
///   poster is what covers the layer when it has no frame.
/// - The window's view hierarchy, dumped mid-flight, so a snapshot/portal view
///   substituted for ours is named rather than inferred.
/// - `snapshotView(afterScreenUpdates:)` / `drawHierarchy` on the source tile,
///   which is how UIKit would have to capture it at the UIView level.
///
/// ## The probe must be proven live before a negative means anything
///
/// Issue #83: "Two conclusions in this work were invalidated by probes that were
/// attached after the window under test." Cycle 0 is therefore a CONTROL that
/// provokes a known readiness change (attach a second layer to the same player —
/// measured at 70–99 ms in the issue) and asserts the probe reports it. A clean
/// run whose control failed is reported as BLIND, not as a pass.
enum NativeZoomSpike {
    static let launchArgument = "-native-zoom-spike"

    static func makeRoot() -> UIViewController {
        let navigation = UINavigationController(rootViewController: SpikeSourceViewController())
        navigation.navigationBar.prefersLargeTitles = false
        return navigation
    }

    static func log(_ message: String) {
        print(String(format: "[zoom-spike] %8.3f %@", CACurrentMediaTime() - epoch, message))
    }

    static let epoch = CACurrentMediaTime()

    /// The one asset both surfaces play: a 9:16 synthetic clip, matching the
    /// grid's portrait bricks. `PlaceholderVideoFetcher` synthesizes and caches
    /// it, so no network is involved.
    static let mediaURL = URL(string: "mock://video/native-zoom-spike?w=720&h=1280")!
}

// MARK: - Per-frame probe

/// Samples every registered surface once per display refresh and prints only
/// what CHANGED, plus per-phase counters. Per-frame printing at 120 Hz drowns
/// the signal; change-only printing keeps the exact frame of every transition.
@MainActor
final class SpikeProbe {
    struct State: Equatable {
        var ready = false
        var poster = false
        var visible = false
        var host = "-"
    }

    struct Counters {
        var readyDrops = 0
        var posterFrames = 0
        var frames = 0
        var longestPosterRun = 0
        private var currentPosterRun = 0

        mutating func accumulate(_ state: State, previous: State?) {
            frames += 1
            if previous?.ready == true, !state.ready { readyDrops += 1 }
            if state.poster {
                posterFrames += 1
                currentPosterRun += 1
                longestPosterRun = max(longestPosterRun, currentPosterRun)
            } else {
                currentPosterRun = 0
            }
        }
    }

    private struct Tracked {
        let label: String
        weak var view: VideoRenderView?
        var last: State?
    }

    private var tracked: [Tracked] = []
    private var link: CADisplayLink?
    private(set) var counters: [String: Counters] = [:]
    /// Set by the driver so every line and every counter is attributable to a
    /// leg of the flight rather than to wall-clock guesswork.
    var phase = "idle" {
        didSet { NativeZoomSpike.log("── phase: \(oldValue) → \(phase)") }
    }
    /// Any readiness transition at all, in either direction. The control arm
    /// asserts this is non-zero before the real cycles are trusted.
    private(set) var readinessTransitions = 0

    func register(_ view: VideoRenderView, as label: String) {
        // Set at creation, never at adoption — a probe attached after the window
        // under test reports silence, and silence reads as success.
        view.debugLabel = label
        view.debugTracksFlight = true
        tracked.append(Tracked(label: label, view: view))
        counters[label] = Counters()
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // Sample at the display's full rate: a 65 ms dip is ~8 frames at 120 Hz
        // and would be invisible to a coarser poll.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        for index in tracked.indices {
            guard let view = tracked[index].view else { continue }
            let state = State(
                ready: view.isReadyForDisplay,
                poster: view.isPosterVisible,
                visible: Self.isEffectivelyVisible(view),
                host: view.superview.map { String(describing: type(of: $0)) } ?? "-"
            )
            let previous = tracked[index].last
            if let previous, previous != state {
                NativeZoomSpike.log(
                    "\(tracked[index].label) \(Self.describe(from: previous, to: state)) [phase=\(phase)]"
                )
                if previous.ready != state.ready { readinessTransitions += 1 }
            }
            counters[tracked[index].label]?.accumulate(state, previous: previous)
            tracked[index].last = state
        }
    }

    private static func describe(from old: State, to new: State) -> String {
        var parts: [String] = []
        if old.ready != new.ready { parts.append("ready \(old.ready ? 1 : 0)→\(new.ready ? 1 : 0)") }
        if old.poster != new.poster { parts.append("POSTER \(old.poster ? 1 : 0)→\(new.poster ? 1 : 0)") }
        if old.visible != new.visible { parts.append("visible \(old.visible ? 1 : 0)→\(new.visible ? 1 : 0)") }
        if old.host != new.host { parts.append("host \(old.host)→\(new.host)") }
        return parts.joined(separator: " ")
    }

    /// Effective visibility: a view UIKit has hidden, faded out, or lifted out of
    /// the window is not on screen no matter what its own flags say. The zoom
    /// transition is expected to touch exactly these, which is why the whole
    /// ancestor chain is walked rather than the view's own properties.
    private static func isEffectivelyVisible(_ view: UIView) -> Bool {
        guard view.window != nil else { return false }
        var node: UIView? = view
        while let current = node {
            if current.isHidden || current.alpha <= 0.01 { return false }
            node = current.superview
        }
        return true
    }

    func resetCounters() {
        for key in counters.keys { counters[key] = Counters() }
    }

    func report(_ title: String) {
        NativeZoomSpike.log("┌── \(title)")
        for label in counters.keys.sorted() {
            guard let c = counters[label] else { continue }
            NativeZoomSpike.log(String(
                format: "│ %-6@ frames=%3d readyDrops=%d posterFrames=%d longestPosterRun=%d",
                label as NSString, c.frames, c.readyDrops, c.posterFrames, c.longestPosterRun
            ))
        }
        NativeZoomSpike.log("└──")
    }
}

// MARK: - Hierarchy inspection

enum SpikeHierarchy {
    /// Class-name fragments that would mean UIKit put something of its own where
    /// our live layer used to be. `_UIPortalView` is a render-server mirror and
    /// stays live; `UISnapshotView`/`_UIReplicantView` are static captures and
    /// would be fatal to this path — naming them is the point of the dump.
    private static let interesting = ["Snapshot", "Portal", "Replicant", "Zoom", "Transition", "PlayerLayer"]

    static func dump(_ root: UIView, tag: String, highlighting marked: [ObjectIdentifier: String]) {
        NativeZoomSpike.log("┌── hierarchy @ \(tag)")
        walk(root, depth: 0, marked: marked)
        NativeZoomSpike.log("└──")
    }

    private static func walk(_ view: UIView, depth: Int, marked: [ObjectIdentifier: String]) {
        let name = String(describing: type(of: view))
        var note = ""
        if let label = marked[ObjectIdentifier(view)] { note += "  ⬅︎ OUR SURFACE: \(label)" }
        if interesting.contains(where: name.contains) { note += "  ⚠︎ substitute-candidate" }
        let layerName = String(describing: type(of: view.layer))
        NativeZoomSpike.log(String(
            format: "│ %@%@ [layer=%@ hidden=%@ alpha=%.2f frame=%@]%@",
            String(repeating: "  ", count: depth), name, layerName,
            view.isHidden ? "1" : "0", view.alpha,
            NSCoder.string(for: view.frame.integral), note
        ))
        for subview in view.subviews { walk(subview, depth: depth + 1, marked: marked) }
    }
}

// MARK: - Liveness beacon

/// A view whose background colour steps between two saturated colours five
/// times a second, driven by a `CAAnimation` (so the render server owns it, not
/// the main thread).
///
/// This exists because video renders BLACK in simulator captures: pixels cannot
/// distinguish a live `AVPlayerLayer` from a static capture of one. The beacon
/// is ordinary layer content in the SAME layer tree as the video, so it does
/// capture — and it answers the only question the pixels need to answer:
///
/// - Frozen on one colour for the whole flight → UIKit is flying a **static
///   capture** of the source, and live video through it is impossible.
/// - Still stepping colours mid-flight → UIKit is flying a **live mirror** of
///   the real layer tree, which is the render-server path that carries video.
///
/// It covers the top half of each surface so the bottom half stays video.
/// The two surfaces get DISJOINT palettes so a sampled pixel says which side of
/// the flight it came from. Without that, a colour change mid-flight could be
/// the crossfade between a frozen source and a live destination rather than
/// either one actually being live.
final class SpikeBeaconView: UIView {
    enum Palette {
        /// Source tile: reds and magentas.
        case warm
        /// Destination page: greens and blues.
        case cool

        var colours: [CGColor] {
            switch self {
            case .warm: [UIColor.systemRed.cgColor, UIColor.systemOrange.cgColor]
            case .cool: [UIColor.systemGreen.cgColor, UIColor.systemBlue.cgColor]
            }
        }
    }

    var palette: Palette = .warm

    func startBlinking() {
        let animation = CAKeyframeAnimation(keyPath: "backgroundColor")
        animation.values = palette.colours
        // Discrete: hard steps, so a frame is unambiguously one colour rather
        // than an interpolated blend that could be misread as motion blur.
        animation.calculationMode = .discrete
        animation.duration = 0.8
        animation.repeatCount = .infinity
        // Off the layer's own time base, so it keeps stepping while UIKit
        // retimes the transition's layers around it.
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "beacon")
    }
}

// MARK: - Source screen ("the grid tile")

/// The tile. Subclassed purely to catch UIKit capturing it: a UIView-level
/// snapshot of an `AVPlayerLayer` renders black, so if the system takes one, the
/// zoom is showing a black rectangle where the video was.
final class SpikeTileView: UIView {
    override func snapshotView(afterScreenUpdates: Bool) -> UIView? {
        NativeZoomSpike.log("⚠︎ SYSTEM CALLED snapshotView(afterScreenUpdates: \(afterScreenUpdates)) ON THE TILE")
        return super.snapshotView(afterScreenUpdates: afterScreenUpdates)
    }

    override func drawHierarchy(in rect: CGRect, afterScreenUpdates: Bool) -> Bool {
        NativeZoomSpike.log("⚠︎ SYSTEM CALLED drawHierarchy(afterScreenUpdates: \(afterScreenUpdates)) ON THE TILE")
        return super.drawHierarchy(in: rect, afterScreenUpdates: afterScreenUpdates)
    }
}

@MainActor
final class SpikeSourceViewController: UIViewController {
    private let playback = VideoPlaybackController(source: PlaceholderVideoFetcher())
    private let probe = SpikeProbe()
    private let tile = SpikeTileView()
    private let surface = VideoRenderView()
    private let beacon = SpikeBeaconView()
    /// The control arm's second layer on the same player.
    private let mirror = VideoRenderView()
    private let statusLabel = UILabel()
    private var hasRun = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = "zoom spike"

        // 9:16, the shape a portrait brick has after `arrangedForMotion`, so the
        // flight travels the page's own aspect and nothing here is measuring a
        // crop change by accident.
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.layer.cornerRadius = 18
        tile.layer.cornerCurve = .continuous
        tile.clipsToBounds = true
        view.addSubview(tile)

        surface.frame = tile.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.setPoster(Self.posterImage(.systemPink))
        tile.addSubview(surface)

        beacon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(beacon)

        mirror.translatesAutoresizingMaskIntoConstraints = false
        mirror.setPoster(Self.posterImage(.systemTeal))
        mirror.isHidden = true
        mirror.layer.cornerRadius = 8
        mirror.clipsToBounds = true
        view.addSubview(mirror)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        statusLabel.numberOfLines = 0
        statusLabel.text = "spike: starting"
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            tile.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            tile.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 168),
            tile.heightAnchor.constraint(equalTo: tile.widthAnchor, multiplier: 16.0 / 9.0),

            beacon.topAnchor.constraint(equalTo: tile.topAnchor),
            beacon.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            beacon.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            beacon.heightAnchor.constraint(equalTo: tile.heightAnchor, multiplier: 0.5),

            mirror.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            mirror.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            mirror.widthAnchor.constraint(equalToConstant: 54),
            mirror.heightAnchor.constraint(equalToConstant: 96),

            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)
        ])

        probe.register(surface, as: "tile")
        probe.register(mirror, as: "mirror")
        probe.start()
        beacon.palette = .warm
        beacon.startBlinking()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasRun else { return }
        hasRun = true
        Task { await run() }
    }

    // MARK: - The script

    private func run() async {
        NativeZoomSpike.log("spike start — UIKit .zoom evaluation (issue #83 step 1)")
        await playback.play(NativeZoomSpike.mediaURL, in: surface)
        guard await waitUntilReady(surface, label: "tile") else {
            statusLabel.text = "spike: tile never became ready — nothing to measure"
            NativeZoomSpike.log("ABORT: the tile never reached isReadyForDisplay")
            return
        }

        await runProbeControl()

        for iteration in 1...2 {
            await runCycle(iteration: iteration, adoptParkedPlayer: false)
        }
        for iteration in 1...2 {
            await runCycle(iteration: iteration, adoptParkedPlayer: true)
        }

        NativeZoomSpike.log("spike complete")
        statusLabel.text = "spike: complete — see console"
    }

    /// CONTROL. Attaches a second `AVPlayerLayer` to the running player, which
    /// issue #83 measured as a 70–99 ms readiness cost. If the probe reports no
    /// readiness transition at all here, it is blind and every later "no drops"
    /// result is meaningless.
    private func runProbeControl() async {
        probe.phase = "control"
        probe.resetCounters()
        statusLabel.text = "spike: control (second layer)"
        NativeZoomSpike.log("CONTROL: attaching a second layer to the same player")

        let before = probe.readinessTransitions
        mirror.isHidden = false
        playback.mirror(from: surface, to: mirror)
        try? await Task.sleep(for: .milliseconds(600))
        probe.report("control — second layer attached")

        let observed = probe.readinessTransitions - before
        NativeZoomSpike.log(
            observed > 0
            ? "CONTROL PASSED: probe observed \(observed) readiness transition(s) — it is live"
            : "CONTROL FAILED: probe observed NO readiness transitions — TREAT ALL RESULTS AS BLIND"
        )

        // Put the render slot back on the tile before the real cycles.
        mirror.isHidden = true
        mirror.detachForReplacement()
        playback.reclaim(surface)
        _ = await waitUntilReady(surface, label: "tile")
        probe.phase = "idle"
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// One push→pop with the system zoom.
    ///
    /// `adoptParkedPlayer` picks the arm:
    /// - `false` — the destination opens its OWN player. Two live players, both
    ///   surfaces rendering. Isolates the pure rendering question: does the
    ///   system fly live layers?
    /// - `true` — production semantics. The tile's player is parked and the
    ///   destination adopts it, so ONE item crosses (issue #83 criterion 4) and
    ///   the destination's layer pays the attach cost mid-flight.
    private func runCycle(iteration: Int, adoptParkedPlayer: Bool) async {
        let arm = adoptParkedPlayer ? "adopt" : "independent"
        NativeZoomSpike.log("════ cycle \(arm) #\(iteration) ════")
        statusLabel.text = "spike: \(arm) #\(iteration)"
        probe.resetCounters()

        let destination = SpikeDestinationViewController(
            playback: playback,
            probe: probe,
            adoptsParkedPlayer: adoptParkedPlayer
        )

        // THE THING UNDER TEST. No animator, no delegate, no flight card — the
        // system is handed the source view and asked to do the rest.
        destination.preferredTransition = .zoom { [weak self] _ in self?.tile }

        // Read BEFORE parking: parking clears the tile's binding, so a read after
        // it reports `none` and the same-item comparison is vacuous.
        let playheadBefore = playback.debugPlayhead(in: surface)

        if adoptParkedPlayer {
            // `keepingSurfaceAttached` leaves the tile bound so it does not blank
            // the instant we park; the destination's attach is what ends its
            // render slot, exactly as in `ForYouViewController`.
            playback.parkPlayback(from: surface, keepingSurfaceAttached: true)
            NativeZoomSpike.log("parked the tile's player for adoption")
        }

        probe.phase = "push"
        navigationController?.pushViewController(destination, animated: true)

        // Mid-flight: the only moment the substitution question can be answered.
        try? await Task.sleep(for: .milliseconds(120))
        if let window = view.window {
            SpikeHierarchy.dump(window, tag: "mid-push (t+120ms)", highlighting: [
                ObjectIdentifier(surface): "tile surface",
                ObjectIdentifier(tile): "tile container",
                ObjectIdentifier(destination.surface): "destination surface"
            ])
        }

        try? await Task.sleep(for: .milliseconds(900))
        probe.phase = "settled"
        probe.report("cycle \(arm) #\(iteration) — push leg")
        let playheadAfter = playback.debugPlayhead(in: destination.surface)
        NativeZoomSpike.log(
            "playhead: tile \(Self.describe(playheadBefore)) → destination \(Self.describe(playheadAfter)) "
            + "(sameItem=\(playheadBefore?.item == playheadAfter?.item))"
        )

        try? await Task.sleep(for: .milliseconds(500))
        probe.resetCounters()
        probe.phase = "pop"
        navigationController?.popViewController(animated: true)

        try? await Task.sleep(for: .milliseconds(120))
        if let window = view.window {
            SpikeHierarchy.dump(window, tag: "mid-pop (t+120ms)", highlighting: [
                ObjectIdentifier(surface): "tile surface",
                ObjectIdentifier(tile): "tile container",
                ObjectIdentifier(destination.surface): "destination surface"
            ])
        }

        try? await Task.sleep(for: .milliseconds(900))
        probe.phase = "returned"
        probe.report("cycle \(arm) #\(iteration) — pop leg")

        // Restore the tile for the next cycle: after an adopt cycle its player
        // left with the destination.
        if playback.debugPlayhead(in: surface) == nil {
            await playback.play(NativeZoomSpike.mediaURL, in: surface)
            _ = await waitUntilReady(surface, label: "tile")
        }
        probe.phase = "idle"
        try? await Task.sleep(for: .milliseconds(400))
    }

    // MARK: - Helpers

    private func waitUntilReady(_ view: VideoRenderView, label: String) async -> Bool {
        for _ in 0..<200 {
            if view.isReadyForDisplay { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        NativeZoomSpike.log("timeout waiting for \(label) to become ready")
        return false
    }

    private static func describe(_ playhead: (seconds: Double, item: String)?) -> String {
        guard let playhead else { return "none" }
        return String(format: "%.3fs item=%@", playhead.seconds, playhead.item)
    }

    private static func posterImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 9, height: 16)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 9, height: 16))
        }
    }
}

// MARK: - Destination screen ("the full-screen page")

@MainActor
final class SpikeDestinationViewController: UIViewController {
    let surface = VideoRenderView()
    private let beacon = SpikeBeaconView()
    private let playback: VideoPlaybackController
    private let adoptsParkedPlayer: Bool

    init(playback: VideoPlaybackController, probe: SpikeProbe, adoptsParkedPlayer: Bool) {
        self.playback = playback
        self.adoptsParkedPlayer = adoptsParkedPlayer
        super.init(nibName: nil, bundle: nil)
        // Registered here, before the view is loaded and long before the push —
        // the probe has to predate the window under test.
        probe.register(surface, as: "dest")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.title = "destination"

        surface.frame = view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.setPoster(Self.posterImage())
        view.addSubview(surface)

        beacon.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height / 2)
        beacon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(beacon)
        beacon.palette = .cool
        beacon.startBlinking()

        // Started in `viewDidLoad`, i.e. before the flight begins — the earliest
        // a destination can possibly start, so any dip measured here is the
        // transition's, not a late start's.
        Task { await playback.play(NativeZoomSpike.mediaURL, in: surface) }
        NativeZoomSpike.log("destination loaded (adopts=\(adoptsParkedPlayer))")
    }

    private static func posterImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 9, height: 16)).image { context in
            UIColor.systemYellow.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 9, height: 16))
        }
    }
}
#endif
