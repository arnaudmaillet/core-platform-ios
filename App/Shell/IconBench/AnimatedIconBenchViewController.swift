#if DEBUG
import MapKit
import OSLog
import UIKit

/// The worst case, on screen, with every optimisation switchable.
///
/// Reached with `-icon-bench`. It stands alone ahead of auth, so it needs no
/// account, no fleet and no mock BFF.
///
/// ## What it draws
///
/// `MapClusterEngine` guarantees no two markers are within 64pt of each other
/// (`clusterCellPoints = MapAnnotationView.side + 8`). The viewport is therefore
/// a packed 64pt lattice, and this screen fills it exactly:
///
///     columns = ceil(width / 64) + 1      rows = ceil(height / 64) + 1
///     440x956pt -> 8 x 16 = 128 markers
///     375x667pt -> 7 x 12 =  84 markers
///
/// The lattice SATURATES: for any corpus denser than a viewport's worth,
/// clustering fills it rather than thinning it. So this is not a stress test
/// standing in for a rare peak — it is what a populated city looks like.
///
/// ## Driving it
///
/// Every knob is a launch argument as well as an on-screen control, because a
/// measurement you cannot re-run identically is an anecdote. `-icon-bench-report
/// <seconds>` measures a defined window AFTER the field has finished dressing,
/// prints one machine-readable line, and (with `-icon-bench-exit`) quits — so a
/// whole matrix runs from a shell loop with no taps at all.
///
///     -icon-bench -icon-bench-variety 1 -icon-bench-report 6 -icon-bench-exit
///
/// ## What it can and cannot tell you
///
/// **It CAN answer, in process, honestly:**
/// - Does the app's main thread stay asleep? (`cpu`, `frame_mean`)
/// - Is the texture actually shared? (`footprint_mb` against `variety`, which is
///   the single load-bearing assumption of the whole design)
/// - What does a cold field look like while its sheets are still loading?
///   (`dress_s`)
/// - Does it LOOK good? — a real question, and the cheapest one to answer badly
///   by reasoning about it instead of looking at it.
///
/// **It CANNOT answer:** anything about the render server. Core Animation
/// composites out of process, in `backboardd`, where MapKit's tiles live too. A
/// perfect main-thread readout over a stuttering screen is the expected failure
/// mode here, not a surprise — these numbers are blind to it BY CONSTRUCTION.
/// Frame cost, composite rate and battery need Instruments on a real device
/// (Core Animation + GPU + Energy). **The simulator is worse than useless for
/// that half**: it does not model tile-based deferred rendering, so the
/// offscreen passes that dominate on hardware are nearly free there — which is
/// exactly the trap that would make an unshippable design look fine.
final class AnimatedIconBenchViewController: UIViewController {

    // MARK: - Configuration

    /// Every knob, resolvable from launch arguments so a run is reproducible.
    struct Config {
        var variety = 16                     // -1 means "one per marker"
        var mode: IconPlayback.Mode = .quantised
        var framesPerSecond: Double = 30
        var maxFrames = 24
        var usesShadowPath = true
        var masksOnCard = false
        var sharesTexture = true
        var wireFormat: IconAtlasStore.WireFormat = .sheet
        var latency: TimeInterval = 0.35
        var showsMap = true
        var autoPans = false
        var reportWindow: TimeInterval?
        var exitsAfterReport = false

        static func fromLaunchArguments() -> Config {
            let arguments = ProcessInfo.processInfo.arguments
            func value(_ flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            var config = Config()
            if let raw = value("-icon-bench-variety") {
                config.variety = raw == "all" ? -1 : (Int(raw) ?? 16)
            }
            if let raw = value("-icon-bench-clock") { config.mode = raw == "free" ? .freeRunning : .quantised }
            if let raw = value("-icon-bench-fps"), let fps = Double(raw) { config.framesPerSecond = fps }
            // Lets the frame cap be lifted, so "what would REAL 60fps cost?" is a
            // measurement rather than arithmetic.
            if let raw = value("-icon-bench-max-frames"), let cap = Int(raw) { config.maxFrames = cap }
            if let raw = value("-icon-bench-shadow") { config.usesShadowPath = raw != "none" }
            if let raw = value("-icon-bench-mask") { config.masksOnCard = raw == "clip" }
            if let raw = value("-icon-bench-texture") { config.sharesTexture = raw != "distinct" }
            if let raw = value("-icon-bench-wire"), let wire = IconAtlasStore.WireFormat(rawValue: raw) {
                config.wireFormat = wire
            }
            if let raw = value("-icon-bench-latency"), let latency = TimeInterval(raw) { config.latency = latency }
            if let raw = value("-icon-bench-ground") { config.showsMap = raw != "plain" }
            config.autoPans = arguments.contains("-icon-bench-pan")
            if let raw = value("-icon-bench-report"), let window = TimeInterval(raw) { config.reportWindow = window }
            config.exitsAfterReport = arguments.contains("-icon-bench-exit")
            return config
        }
    }

    // MARK: - Model

    final class BenchAnnotation: NSObject, MKAnnotation {
        dynamic var coordinate: CLLocationCoordinate2D
        let iconID: Int
        let phase: Int
        init(coordinate: CLLocationCoordinate2D, iconID: Int, phase: Int) {
            self.coordinate = coordinate
            self.iconID = iconID
            self.phase = phase
        }
    }

    /// Warm-up is not politeness — it is the difference between measuring the
    /// steady state and measuring 128 first-time bakes.
    private enum Stage { case dressing, measuring, done }

    // MARK: - Surfaces

    let mapView = MKMapView()
    /// Plain ground, for the control case: how much of the cost is MapKit's?
    let plainBackdrop = UIView()
    let hud = UILabel()
    let hudBackdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
    let controls = UIStackView()
    let controlsScroll = UIScrollView()
    let toggleControlsButton = UIButton(type: .system)

    private let store = IconAtlasStore()
    var config = Config.fromLaunchArguments()
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "icon-bench")

    private var markerCount = 0
    private var latticeColumns = 0
    private var latticeRows = 0

    // MARK: - Metrics

    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var frameSamples: [Double] = []
    private var hitchThresholdMs: Double = 1000.0 / 60 * 1.6

    /// Hitches WITHIN the retained sample window, recomputed — not a running
    /// total.
    ///
    /// It was a cumulative counter and that made it useless as a live readout: a
    /// tap, a swipe or a `simctl io screenshot` each stall the loop, and the
    /// number then carried those stalls forever. It only ever went up, so it
    /// could never say "this configuration is fine now" — the one thing you
    /// stand in front of the screen to find out.
    private var hitchCount: Int { frameSamples.count { $0 > hitchThresholdMs } }
    private var resolvedIcons = 0
    private var dressStartedAt: CFTimeInterval = 0
    var dressCompletedIn: Double?
    private var stage: Stage = .dressing
    private var measurementStartedAt: CFTimeInterval = 0
    private var peakFootprint: UInt64 = 0
    private var cpuSamples: [Double] = []
    private let cpuSampler = CPUSampler()

    /// Measures the frame rate the screen is ACTUALLY presenting, by watching one
    /// marker's presentation layer and counting how often its frame changes.
    ///
    /// Worth the twenty lines: a configured fps is an intention, and the gap
    /// between intention and what the render server presents is exactly where
    /// this kind of feature dies quietly. It also catches the reverse failure —
    /// an animation that was silently removed reads as 0, where every other
    /// number on this screen would stay green.
    ///
    /// Sampled on the display link, so it can observe at most the display's own
    /// rate: honest for 8/12/24, and aliased at 60 on a 60Hz panel.
    private var probedFrame: CGRect?
    private var iconChangeTimestamps: [CFTimeInterval] = []
    private var presentedFPS: Double {
        guard let first = iconChangeTimestamps.first, iconChangeTimestamps.count > 1,
              let last = iconChangeTimestamps.last, last > first else { return 0 }
        return Double(iconChangeTimestamps.count - 1) / (last - first)
    }

    /// Resolved variety, with `-1` ("all") expanded once the lattice is known.
    private var effectiveVariety: Int { config.variety < 0 ? max(1, markerCount) : max(1, config.variety) }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        applyConfig()

        plainBackdrop.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.18)
        plainBackdrop.isHidden = config.showsMap
        [plainBackdrop, mapView].forEach {
            $0.frame = view.bounds
            $0.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview($0)
        }
        mapView.alpha = config.showsMap ? 1 : 0

        mapView.delegate = self
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        mapView.register(BenchMarkerView.self, forAnnotationViewWithReuseIdentifier: BenchMarkerView.reuseIdentifier)
        mapView.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
                latitudinalMeters: 4_000, longitudinalMeters: 4_000
            ),
            animated: false
        )

        setUpHUD()
        setUpControls()

        NotificationCenter.default.addObserver(
            self, selector: #selector(reinstallAnimations),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if markerCount == 0 { rebuildLattice() }
        startDisplayLink()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
    }

    private func applyConfig() {
        store.framesPerSecond = config.framesPerSecond
        store.maxFrames = config.maxFrames
        store.sharesTexture = config.sharesTexture
        store.wireFormat = config.wireFormat
        store.simulatedLatency = config.latency
        BenchMarkerView.usesShadowPath = config.usesShadowPath
        BenchMarkerView.masksOnCard = config.masksOnCard
    }

    // MARK: - The lattice

    /// Fills the viewport with the densest arrangement the cluster engine can
    /// ever produce, and not one marker more.
    func rebuildLattice() {
        applyConfig()
        store.purge()
        mapView.removeAnnotations(mapView.annotations)

        let cell: CGFloat = 64                       // MapsViewController.clusterCellPoints
        let bounds = view.bounds
        latticeColumns = Int(ceil(bounds.width / cell)) + 1
        latticeRows = Int(ceil(bounds.height / cell)) + 1
        markerCount = latticeColumns * latticeRows

        let variety = effectiveVariety
        var annotations: [BenchAnnotation] = []
        annotations.reserveCapacity(markerCount)
        for row in 0..<latticeRows {
            for column in 0..<latticeColumns {
                let point = CGPoint(x: CGFloat(column) * cell, y: CGFloat(row) * cell)
                let index = row * latticeColumns + column
                annotations.append(BenchAnnotation(
                    coordinate: mapView.convert(point, toCoordinateFrom: mapView),
                    iconID: index % variety,
                    // Phase is a pure function of identity, so a hero flight
                    // card could reproduce the exact frame by copying one Int.
                    phase: index
                ))
            }
        }

        resetMeasurement()
        mapView.addAnnotations(annotations)
        updateHUD()
    }

    func resetMeasurement() {
        resolvedIcons = 0
        dressCompletedIn = nil
        dressStartedAt = CACurrentMediaTime()
        frameSamples.removeAll()
        cpuSamples.removeAll()
        peakFootprint = 0
        stage = .dressing
    }

    @objc private func reinstallAnimations() {
        for annotation in mapView.annotations {
            (mapView.view(for: annotation) as? BenchMarkerView)?.reinstallIfNeeded()
        }
    }

    // MARK: - Metrics

    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFrameTimestamp = 0
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp

        if config.autoPans {
            var region = mapView.region
            region.center.longitude += region.span.longitudeDelta * 0.0022
            mapView.setRegion(region, animated: false)
        }

        // Enter the measurement window once the field is fully dressed and has
        // had a beat to settle. Everything before that is cold-start cost, which
        // is worth reporting (`dress_s`) but must not pollute the steady state.
        if stage == .dressing, dressCompletedIn != nil, now - dressStartedAt > (dressCompletedIn ?? 0) + 1.0 {
            stage = .measuring
            measurementStartedAt = now
            frameSamples.removeAll()
            cpuSamples.removeAll()
            lastFrameTimestamp = 0
        }

        if lastFrameTimestamp > 0 {
            let delta = (now - lastFrameTimestamp) * 1000
            frameSamples.append(delta)
            if frameSamples.count > 600 { frameSamples.removeFirst(frameSamples.count - 600) }
            // The hitch threshold follows the display's OWN cadence rather than a
            // fixed 60Hz, so this reads correctly on a ProMotion device where the
            // panel legitimately idles down.
            let target = (link.targetTimestamp - now) * 1000
            if target > 0 { hitchThresholdMs = target * 1.6 }
        }
        lastFrameTimestamp = now

        peakFootprint = max(peakFootprint, MemoryFootprint.current())
        probePresentedFrameRate(at: now)

        if frameSamples.count % 10 == 0 {
            cpuSamples.append(cpuSampler.sample())
            if cpuSamples.count > 120 { cpuSamples.removeFirst() }
            updateHUD()
        }

        if stage == .measuring, let window = config.reportWindow, now - measurementStartedAt >= window {
            stage = .done
            emitReport()
        }
    }

    /// Watches ONE marker — every icon shares a single `beginTime` epoch, so one
    /// is representative by construction.
    private func probePresentedFrameRate(at now: CFTimeInterval) {
        guard let annotation = mapView.annotations.first,
              let marker = mapView.view(for: annotation) as? BenchMarkerView,
              let frame = marker.presentedFrame else { return }
        if let previous = probedFrame, previous == frame { return }
        probedFrame = frame
        iconChangeTimestamps.append(now)
        // A rolling three seconds, so the readout tracks the live configuration
        // rather than averaging over every setting tried since launch.
        while let first = iconChangeTimestamps.first, now - first > 3 {
            iconChangeTimestamps.removeFirst()
        }
    }

    /// Frame counts actually baked, as a range — one number when they agree,
    /// "lo-hi" when the assets disagree, which real files always do.
    private var residentFrames: String {
        let frames = store.residentProfile(ids: 0..<effectiveVariety).frames
        guard let low = frames.first, let high = frames.last else { return "-" }
        return low == high ? "\(low)" : "\(low)-\(high)"
    }

    private var meanFrame: Double { frameSamples.isEmpty ? 0 : frameSamples.reduce(0, +) / Double(frameSamples.count) }
    private var p95Frame: Double {
        let sorted = frameSamples.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }
    private var meanCPU: Double { cpuSamples.isEmpty ? 0 : cpuSamples.reduce(0, +) / Double(cpuSamples.count) }
    private var residentAtlasBytes: Int {
        (0..<effectiveVariety).reduce(0) { $0 + (store.cached($1)?.byteCost ?? 0) }
    }

    /// One machine-readable line, so a matrix run is a shell loop and a
    /// spreadsheet rather than a screenshot and a memory.
    private func emitReport() {
        let line = [
            "ICONBENCH",
            "markers=\(markerCount)",
            "lattice=\(latticeColumns)x\(latticeRows)",
            "variety=\(effectiveVariety)",
            "clock=\(config.mode == .quantised ? "quantised" : "free")",
            "fps=\(Int(config.framesPerSecond))",
            "frames_asked=\(store.frameCount)",
            "frames_real=\(residentFrames)",
            "steps=\(store.residentProfile(ids: 0..<effectiveVariety).distinctSteps)",
            "compressed=\(store.isTimeCompressed)",
            String(format: "presented_fps=%.1f", presentedFPS),
            "shadow=\(config.usesShadowPath ? "path" : "none")",
            "mask=\(config.masksOnCard ? "clip" : "baked")",
            "texture=\(config.sharesTexture ? "shared" : "distinct")",
            "wire=\(config.wireFormat.rawValue)",
            "ground=\(config.showsMap ? "map" : "plain")",
            "pan=\(config.autoPans)",
            String(format: "frame_mean=%.2f", meanFrame),
            String(format: "frame_p95=%.2f", p95Frame),
            "hitches=\(hitchCount)",
            String(format: "cpu=%.1f", meanCPU),
            String(format: "footprint_mb=%.1f", Double(peakFootprint) / 1024 / 1024),
            String(format: "atlas_mb=%.1f", Double(residentAtlasBytes) / 1024 / 1024),
            String(format: "dress_s=%.2f", dressCompletedIn ?? -1)
        ].joined(separator: " ")

        print(line)
        logger.notice("\(line, privacy: .public)")
        if config.exitsAfterReport {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
    }

    private func updateHUD() {
        let footprint = Double(MemoryFootprint.current()) / 1024 / 1024
        let dress = dressCompletedIn.map { String(format: "%.2fs", $0) } ?? "\(resolvedIcons)/\(markerCount)…"
        let stageLabel = switch stage {
        case .dressing: "warming"
        case .measuring: "MEASURING"
        case .done: "done"
        }

        hud.text = """
        MARKERS \(markerCount) (\(latticeColumns)x\(latticeRows) @64pt)  variety \(effectiveVariety)  [\(stageLabel)]
        clock \(config.mode == .quantised ? "quantised" : "free")  \
        \(Int(config.framesPerSecond))fps asked / \(String(format: "%.1f", presentedFPS)) presented  \
        \(residentFrames) frames\(store.isTimeCompressed ? " CAPPED" : "")  \
        \(store.residentProfile(ids: 0..<effectiveVariety).distinctSteps) distinct steps  \
        shadow \(config.usesShadowPath ? "path" : "NONE")  mask \(config.masksOnCard ? "CLIP" : "baked")  \
        tex \(config.sharesTexture ? "shared" : "DISTINCT")  wire \(config.wireFormat.rawValue)
        main-thread frame  mean \(String(format: "%.2f", meanFrame))ms  p95 \(String(format: "%.2f", p95Frame))ms
        hitches \(hitchCount)   app CPU \(String(format: "%.0f", meanCPU))%
        footprint \(String(format: "%.1f", footprint)) MB   \
        atlases \(String(format: "%.1f", Double(residentAtlasBytes) / 1024 / 1024)) MB
        cold dress \(dress)   motion \(IconPlayback.motionAllowed ? "on" : "GATED")
        ⚠︎ render-server cost is invisible here — Instruments, on a device
        """
    }

}

// MARK: - MKMapViewDelegate

extension AnimatedIconBenchViewController: MKMapViewDelegate {

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        guard let bench = annotation as? BenchAnnotation else { return nil }
        let view = mapView.dequeueReusableAnnotationView(
            withIdentifier: BenchMarkerView.reuseIdentifier, for: annotation
        ) as! BenchMarkerView
        view.store = store
        view.mode = config.mode
        view.onIconResolved = { [weak self] in
            guard let self, self.stage == .dressing else { return }
            self.resolvedIcons += 1
            if self.resolvedIcons >= self.markerCount, self.dressCompletedIn == nil {
                self.dressCompletedIn = CACurrentMediaTime() - self.dressStartedAt
            }
        }
        view.bind(iconID: bench.iconID, phase: bench.phase)
        return view
    }
}
#endif
