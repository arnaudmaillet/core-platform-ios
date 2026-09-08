#if DEBUG
import MapKit
import MediaCore
import MediaPlayback
import QuartzCore
import UIKit

/// The animated-icon instrument, on the real map.
///
/// Reached with `-map-icon-hud`. It replaces the standalone bench screen, and
/// the swap is the point: the bench measured a synthetic lattice of 128
/// markers because the feature did not exist yet, and a synthetic lattice
/// cannot tell you what MapKit, clustering, tile loading and the app's own
/// working set cost around it. This measures the shipping screen.
///
/// ## Read the right number
///
/// `footprint` is the WHOLE PROCESS and it is dominated by things that have
/// nothing to do with icons — measured on the bench's own lattice, the floor
/// was 84 MB before a single icon existed and MapKit added 13 more. `textures`
/// is the feature's actual cost. Comparing the two is the only way to answer
/// "is this expensive", and quoting `footprint` alone has been wrong every
/// time it was tried.
///
/// ⚠️ **It cannot see the render server.** Core Animation composites out of
/// process, in `backboardd`, where MapKit's tiles live too. A perfect
/// main-thread readout over a stuttering screen is the expected failure mode
/// here, not a surprise — these numbers are blind to it BY CONSTRUCTION. Frame
/// cost, composite rate and battery need Instruments on a device, and the
/// simulator is worse than useless for that half: it does not model tile-based
/// deferred rendering, so the offscreen passes that dominate on hardware are
/// nearly free there.
@MainActor
final class MapIconDebugHUD: UIView {

    private let readout = UILabel()
    private let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
    private let policyControl = UISegmentedControl(
        items: AnimatedIconView.MotionPolicy.allCases.map(\.rawValue)
    )

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frameSamples: [Double] = []
    private var hitchThresholdMs = 1000.0 / 60 * 1.6
    private var cpuSamples: [Double] = []
    private let cpu = CPUSampler()
    private var peakFootprint: UInt64 = 0

    /// Hitches WITHIN the retained window, recomputed — not a running total.
    ///
    /// A cumulative counter is useless as a live readout: a tap, a pan or a
    /// screenshot each stall the loop and the number then carries those stalls
    /// forever. It only ever goes up, so it can never say "this is fine now",
    /// which is the one thing you stand in front of the screen to find out.
    private var hitchCount: Int { frameSamples.count { $0 > hitchThresholdMs } }

    /// What the render server is PRESENTING for one icon, which is a different
    /// question from what was asked for — and the only one worth trusting.
    /// One machine-readable line per second, under `-map-icon-hud-log`.
    ///
    /// ⚠️ It exists because SCREENSHOTS ARE THE MEASUREMENT'S ENEMY here.
    /// `simctl io screenshot` stalls the display link for tens of milliseconds,
    /// so reading the HUD by capturing it manufactures exactly the hitches the
    /// test is looking for — and during a pan, which is the case under
    /// suspicion, it would be impossible to tell the two apart.
    private let logsToConsole =
        ProcessInfo.processInfo.arguments.contains("-map-icon-hud-log")
    private var lastLogged: CFTimeInterval = 0

    private var probedTick: Double?
    private var tickTimestamps: [CFTimeInterval] = []
    private var presentedFPS: Double {
        guard let first = tickTimestamps.first, let last = tickTimestamps.last,
              tickTimestamps.count > 1, last > first else { return 0 }
        return Double(tickTimestamps.count - 1) / (last - first)
    }

    private weak var mapView: MKMapView?
    private weak var catalog: AnimatedIconCatalog?
    /// The video pool, so the readout can say how many DECODERS are running as
    /// distinct from how many surfaces are drawing.
    ///
    /// ⚠️ Those are different numbers and the difference has already misled
    /// this project once: the pool shares one player between surfaces whose
    /// asset AND scope match, the map passed no scope, and the mock gave every
    /// video pin the same url — so three "concurrent videos" were one decoder
    /// fanned out three ways. A readout that counts surfaces would have agreed
    /// with the mistake.
    private weak var previews: AnimatedIconCatalog?
    private weak var pool: VideoPlaybackController?
    var onPolicyChange: (() -> Void)?

    init(
        mapView: MKMapView, catalog: AnimatedIconCatalog?,
        previews: AnimatedIconCatalog? = nil, pool: VideoPlaybackController? = nil
    ) {
        self.mapView = mapView
        self.catalog = catalog
        self.previews = previews
        self.pool = pool
        super.init(frame: .zero)
        isUserInteractionEnabled = true

        backdrop.layer.cornerRadius = 12
        backdrop.layer.cornerCurve = .continuous
        backdrop.clipsToBounds = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        readout.numberOfLines = 0
        readout.font = .monospacedSystemFont(ofSize: 9.5, weight: .medium)
        readout.textColor = .white
        readout.translatesAutoresizingMaskIntoConstraints = false
        backdrop.contentView.addSubview(readout)

        policyControl.selectedSegmentIndex =
            AnimatedIconView.MotionPolicy.allCases.firstIndex(of: AnimatedIconView.policy) ?? 0
        policyControl.selectedSegmentTintColor = .systemBlue
        policyControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        policyControl.translatesAutoresizingMaskIntoConstraints = false
        policyControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // FORCED, because no simulator can switch on Low Power and two of
            // the three states would otherwise be untestable.
            AnimatedIconView.forcedPolicy =
                AnimatedIconView.MotionPolicy.allCases[self.policyControl.selectedSegmentIndex]
            self.onPolicyChange?()
        }, for: .valueChanged)
        backdrop.contentView.addSubview(policyControl)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            readout.topAnchor.constraint(equalTo: backdrop.contentView.topAnchor, constant: 8),
            readout.leadingAnchor.constraint(equalTo: backdrop.contentView.leadingAnchor, constant: 10),
            readout.trailingAnchor.constraint(equalTo: backdrop.contentView.trailingAnchor, constant: -10),
            policyControl.topAnchor.constraint(equalTo: readout.bottomAnchor, constant: 6),
            policyControl.leadingAnchor.constraint(equalTo: readout.leadingAnchor),
            policyControl.trailingAnchor.constraint(equalTo: readout.trailingAnchor),
            policyControl.bottomAnchor.constraint(
                equalTo: backdrop.contentView.bottomAnchor, constant: -8
            )
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func start() {
        link?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastTimestamp > 0 {
            frameSamples.append((now - lastTimestamp) * 1000)
            if frameSamples.count > 600 { frameSamples.removeFirst(frameSamples.count - 600) }
            // The threshold follows the display's OWN cadence rather than a
            // fixed 60Hz, so this reads correctly on ProMotion where the panel
            // legitimately idles down.
            let target = (link.targetTimestamp - now) * 1000
            if target > 0 { hitchThresholdMs = target * 1.6 }
        }
        lastTimestamp = now
        peakFootprint = max(peakFootprint, MemoryFootprint.current())
        probePresentedRate(at: now)
        if frameSamples.count % 10 == 0 {
            cpuSamples.append(cpu.sample())
            if cpuSamples.count > 120 { cpuSamples.removeFirst() }
            refresh()
        }
        if logsToConsole, now - lastLogged >= 1 {
            lastLogged = now
            emit()
        }
    }

    /// Watches ONE icon marker. Every icon hangs off a single shared epoch, so
    /// one is representative — but only while the catalogue is harmonic, which
    /// is why the readout says so.
    private func probePresentedRate(at now: CFTimeInterval) {
        guard let mapView else { return }
        // Pins AND clusters. At any zoom where the field is dense the engine
        // folds everything into clusters, so a probe that only looked at pins
        // reported 0 fps for a screen full of animating markers — which reads
        // exactly like the animation being broken.
        let tick = mapView.annotations.lazy
            .compactMap { annotation -> Double? in
                let view = mapView.view(for: annotation)
                return (view as? MapAnnotationView)?.presentedIconTick
                    ?? (view as? MapClusterAnnotationView)?.presentedIconTick
            }
            .first
        guard let tick else { return }
        if probedTick != tick {
            probedTick = tick
            tickTimestamps.append(now)
        }
        while let first = tickTimestamps.first, now - first > 3 { tickTimestamps.removeFirst() }
    }

    private var meanFrame: Double {
        frameSamples.isEmpty ? 0 : frameSamples.reduce(0, +) / Double(frameSamples.count)
    }
    private var p95Frame: Double {
        let sorted = frameSamples.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }
    private var meanCPU: Double {
        cpuSamples.isEmpty ? 0 : cpuSamples.reduce(0, +) / Double(cpuSamples.count)
    }

    /// Stats over the LAST TWO SECONDS, not the whole retained window.
    ///
    /// The on-screen readout averages 600 samples so it reads steadily; a
    /// navigation test needs the opposite — a pan lasts a few seconds and a
    /// ten-second average dilutes it into the idle either side of it, which is
    /// how a real regression reads as "fine on average".
    private func recent() -> (mean: Double, p95: Double, hitches: Int) {
        let window = Array(frameSamples.suffix(120))
        guard !window.isEmpty else { return (0, 0, 0) }
        let sorted = window.sorted()
        return (
            window.reduce(0, +) / Double(window.count),
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            window.count { $0 > hitchThresholdMs }
        )
    }

    private func emit() {
        guard let mapView else { return }
        let views = mapView.annotations.compactMap { mapView.view(for: $0) }
        let pins = views.compactMap { $0 as? MapAnnotationView }
        let clusters = views.compactMap { $0 as? MapClusterAnnotationView }
        let recent = recent()
        let line = [
            "MAPICONHUD",
            "pins=\(pins.count)",
            "clusters=\(clusters.count)",
            "icons=\(pins.count { $0.wearsAnimatedIcon } + clusters.count { $0.wearsAnimatedIcon })",
            // What each marker is actually DRAWING. `icons=` counts art worn, so
            // it reads 0 both when no marker wants an icon and when every icon
            // failed to resolve — the two cases this feature has to tell apart.
            "kinds=" + Dictionary(grouping: pins.map(\.debugKindName), by: { $0 })
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value.count)" }
                .joined(separator: ","),
            "faces=" + Dictionary(grouping: pins.map(\.debugFaceName) + clusters.map(\.debugFaceName),
                                  by: { $0 })
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value.count)" }
                .joined(separator: ","),
            "resident=\(catalog?.residentCount ?? 0)",
            "policy=\(AnimatedIconView.policy.rawValue)",
            String(format: "presented=%.1f", presentedFPS),
            String(format: "frame_mean=%.2f", recent.mean),
            String(format: "frame_p95=%.2f", recent.p95),
            "hitches_2s=\(recent.hitches)",
            String(format: "cpu=%.1f", meanCPU),
            String(format: "textures_mb=%.2f", Double(catalog?.residentBytes ?? 0) / 1024 / 1024),
            String(format: "footprint_mb=%.0f", Double(MemoryFootprint.current()) / 1024 / 1024),
            String(format: "span=%.4f", mapView.region.span.latitudeDelta),
            "players=\(pool?.activePlayerCount ?? 0)",
            "advancing=\(advancingSurfaces)",
            "distinct_urls=\(pool?.playerCountByURL.count ?? 0)",
            // ⚠️ BOUND FIRST, ADVANCING SECOND, and the order matters because
            // the second one has already lied. `sheets=` is `playingSheets` —
            // sheets currently ADVANCING — and a marker wearing its sprite
            // sheet perfectly while paused or off-screen counts zero there. It
            // was read as "no marker has a sheet" through several rounds of
            // fixture archaeology. `sheets_bound=` answers the question that
            // was actually being asked.
            "sheets_bound=\(pins.count { $0.wearsPreviewSheet } + clusters.count { $0.wearsPreviewSheet })",
            "sheets=\(playingSheets)",
            "sheets_advancing=\(advancingSheets)",
            churnLine(),
            "sheets_resident=\(previews?.residentCount ?? 0)",
            String(format: "sheets_mb=%.2f", Double(previews?.residentBytes ?? 0) / 1024 / 1024)
        ].joined(separator: " ")
        print(line)
    }

    /// Surfaces the pool reports as genuinely moving — not merely bound.
    private var advancingSurfaces: Int {
        guard let mapView, let pool else { return 0 }
        // Pins AND clusters — the readout has to follow the coordinator, and the
        // coordinator now hosts on either. Counting only pins reported 1 of 3
        // advancing while two cluster faces were playing, which reads as
        // "playback is broken" rather than "the probe is narrow".
        return mapView.annotations.compactMap { annotation -> VideoRenderView? in
            let view = mapView.view(for: annotation)
            return (view as? MapAnnotationView)?.videoRenderView
                ?? (view as? MapClusterAnnotationView)?.videoRenderView
        }.count { pool.isAdvancing(in: $0) }
    }

    /// What the region changes actually did to the annotation set since the
    /// last emit — the one thing every earlier instrument could not see.
    ///
    /// `bound` counts configures that passed the idempotence guard; `skipped`
    /// counts the ones that returned on the guard and cost nothing. Reporting
    /// their sum would have said "hundreds of rebinds" about a path that mostly
    /// does nothing, which is how `sheets=N` lied about assignment-vs-motion.
    private func churnLine() -> String {
        // ⚠️ Read the timing BEFORE draining — `drain()` zeroes it.
        let settle = MapChurnCounters.fromSettle
        let diff = MapChurnCounters.fromDiff
        let flush = MapChurnCounters.fromFlush
        let samePins = MapChurnCounters.withUnchangedPins
        let throttled = MapChurnCounters.settleThrottled
        let totalMs = Double(MapChurnCounters.reconcileMicros) / 1000
        let worstMs = Double(MapChurnCounters.reconcileWorstMicros) / 1000
        let c = MapChurnCounters.drain()
        return [
            "reconciles=\(c.reconciles)",
            "churn_add=\(c.added)",
            "churn_out=\(c.departed)",
            "churn_viewfor=\(c.viewFor)",
            "churn_bound=\(c.bound)",
            "churn_skipped=\(c.skipped)",
            "r_settle=\(settle)", "r_diff=\(diff)", "r_flush=\(flush)", "r_samepins=\(samePins)", "r_throttled=\(throttled)",
            String(format: "reconcile_ms=%.2f", totalMs),
            String(format: "reconcile_worst_ms=%.2f", worstMs)
        ].joined(separator: " ")
    }

    /// Sheets whose presentation layer actually MOVED since the previous emit.
    ///
    /// `playingSheets` counts `wornPreview != nil` — art handed to the view.
    /// That is bound, not advancing, and it is the same trap the video readout
    /// already carries a comment about: a field of 80 markers all reporting
    /// "playing" told me nothing about whether one frame had stepped. A tick
    /// that changed between two samples one second apart, against a 125 ms
    /// frame step, is proof the render server is stepping it.
    private var advancingSheets: Int {
        guard let mapView else { return 0 }
        var moved = 0
        var seen: [ObjectIdentifier: Double] = [:]
        for annotation in mapView.annotations {
            let view = mapView.view(for: annotation)
            guard let host = view as? MapAnnotationView ?? nil,
                  let tick = host.presentedPreviewTick else {
                guard let cluster = view as? MapClusterAnnotationView,
                      let tick = cluster.presentedPreviewTick else { continue }
                let key = ObjectIdentifier(cluster)
                seen[key] = tick
                if let previous = previousSheetTicks[key], previous != tick { moved += 1 }
                continue
            }
            let key = ObjectIdentifier(host)
            seen[key] = tick
            if let previous = previousSheetTicks[key], previous != tick { moved += 1 }
        }
        previousSheetTicks = seen
        return moved
    }

    private var previousSheetTicks: [ObjectIdentifier: Double] = [:]

    /// Markers playing a baked preview — pins and clusters alike.
    private var playingSheets: Int {
        guard let mapView else { return 0 }
        return mapView.annotations.count { annotation in
            let view = mapView.view(for: annotation)
            return (view as? MapAnnotationView)?.isPlayingPreviewSheet == true
                || (view as? MapClusterAnnotationView)?.isPlayingPreviewSheet == true
        }
    }

    private func refresh() {
        guard let mapView else { return }
        let views = mapView.annotations.compactMap { mapView.view(for: $0) }
        let pins = views.compactMap { $0 as? MapAnnotationView }
        let clusters = views.compactMap { $0 as? MapClusterAnnotationView }
        let iconPins = pins.count { $0.wearsAnimatedIcon }
        let iconClusters = clusters.count { $0.wearsAnimatedIcon }

        let resident = catalog.map {
            "\($0.residentCount) resident (\($0.residentDecomposed) decomposed)"
        } ?? "no catalogue"
        let textures = Double(catalog?.residentBytes ?? 0) / 1024 / 1024
        let footprint = Double(peakFootprint) / 1024 / 1024
        let harmonic = catalog.map { $0.isHarmonic ? "harmonic" : "⚠︎ FRAGMENTED" } ?? "-"

        readout.text = """
        MARKERS \(pins.count) pins + \(clusters.count) clusters   \
        icons \(iconPins) + \(iconClusters)
        catalogue \(resident)  \(harmonic)  \
        presented \(String(format: "%.1f", presentedFPS))fps
        main-thread frame  mean \(String(format: "%.2f", meanFrame))ms  \
        p95 \(String(format: "%.2f", p95Frame))ms   hitches \(hitchCount)
        video \(pool?.activePlayerCount ?? 0) players / \(advancingSurfaces) advancing   \
        sheets \(playingSheets) playing / \(previews?.residentCount ?? 0) resident \
        \(String(format: "%.1f", Double(previews?.residentBytes ?? 0) / 1024 / 1024)) MB
        app CPU \(String(format: "%.0f", meanCPU))%   \
        textures \(String(format: "%.2f", textures)) MB   \
        peak footprint \(String(format: "%.0f", footprint)) MB
        ⚠︎ footprint is the WHOLE process; textures is this feature
        ⚠︎ render-server cost is invisible here — Instruments, on a device
        """
    }
}

// MARK: - Metrics

/// The process's physical footprint — what jetsam actually reads.
///
/// `phys_footprint`, not `resident_size`: the latter counts pages shared with
/// other processes and file-backed pages the system can reclaim, so it reads
/// high and moves for reasons that are not this app's doing.
enum MemoryFootprint {
    static func current() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<Int32>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}

/// App CPU across all threads, as a percentage of one core.
final class CPUSampler {
    private var previous: (ticks: Double, time: CFTimeInterval)?

    func sample() -> Double {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS,
              let threads else { return 0 }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.size)
            )
        }
        var total = 0.0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            // `THREAD_BASIC_INFO_COUNT` is a C macro and does not survive
            // into Swift; the size arithmetic it expands to does.
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(infoCount)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
        }
        return total
    }
}
#endif
