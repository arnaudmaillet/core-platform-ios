#if DEBUG
import CoreNavigation
import MediaPlayback
import UIKit

/// `-hero-audit`: the hero machinery's census, sampled continuously and
/// published where a test can read it.
///
/// ## What it watches
///
/// Every count that must return to zero (or to its resting value) after a
/// transition settles: live animators / interruptors / grab drivers / retry
/// links (`ZoomDebugCensus`), the pools' players and their hygiene ledgers,
/// duplicate players per asset, and — because logs can read green over a
/// broken screen — a WINDOW SWEEP for flight cards that outlived every
/// transition object that could be flying them.
///
/// ## Where it publishes
///
/// Three channels, each for a different reader:
/// - an accessibility probe (`hero;seq=…`) on the key window — the XCUITest
///   channel; `seq` is monotonic, so a test can wait for "the audit sampled
///   again after my gesture" instead of sleeping;
/// - a file sink at `Documents/hero-audit.log`, recreated at launch — the
///   shell harness's channel, immune to the pty and to stale files from
///   earlier builds (the mtime is printed inside the log itself);
/// - the console, via the same lines (pair with any `*-log` argument to
///   unbuffer stdout).
///
/// ⚠️ An empty log reads exactly like a passing one, so every 20th sample is
/// an unconditional heartbeat carrying the number of checks performed —
/// "0 failures / 0 checks" is a broken harness, "0 failures / 800 checks" is
/// a pass — and the census counts are published raw rather than judged: a
/// paused neighbour clip legitimately holds an anchor at rest, and only the
/// reader knows which cycle of a soak it is looking at. The audit itself
/// flags just the states that are wrong in EVERY context: a stranded card,
/// two players on one asset at settle, a census gone negative.
@MainActor
final class HeroTransitionAudit {
    private(set) static var shared: HeroTransitionAudit?

    /// Installs under `-hero-audit`; a launch without the flag costs nothing.
    static func installIfRequested(pools: [(label: String, pool: VideoPlaybackController)]) {
        guard ProcessInfo.processInfo.arguments.contains("-hero-audit"), shared == nil else { return }
        shared = HeroTransitionAudit(pools: pools)
    }

    private let pools: [(label: String, pool: VideoPlaybackController)]
    private let probe = UIView(frame: CGRect(x: 0, y: 80, width: 2, height: 2))
    private let sinkURL: URL
    private var sink: FileHandle?
    private var timer: Timer?
    private var sequence = 0
    private var checksPerformed = 0
    private var failures = 0

    private init(pools: [(label: String, pool: VideoPlaybackController)]) {
        self.pools = pools
        sinkURL = URL.documentsDirectory.appendingPathComponent("hero-audit.log")
        // Recreated every launch, so a reader can never mistake an earlier
        // build's verdict for this one's.
        try? Data().write(to: sinkURL)
        sink = try? FileHandle(forWritingTo: sinkURL)
        probe.backgroundColor = .clear
        probe.isAccessibilityElement = true
        probe.accessibilityLabel = "hero audit"
        emit("[hero-audit] START \(Date()) sink=\(sinkURL.path)")
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // `.common`, so sampling keeps running while a finger is down on a
        // grab — the default mode pauses timers during tracking, which would
        // blind the audit during the exact windows it exists for.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        sequence += 1
        checksPerformed += 1
        attachProbeIfNeeded()

        let census = ZoomDebugCensus.liveEntries()
        let animators = census[ZoomDebugCensus.Key.animator] ?? 0
        let interruptors = census[ZoomDebugCensus.Key.interruptor] ?? 0
        let drivers = census[ZoomDebugCensus.Key.grabDriver] ?? 0
        let retries = census[ZoomDebugCensus.Key.liveMediaRetry] ?? 0
        let cards = census[ZoomDebugCensus.Key.flightCard] ?? 0
        let pins = census[ZoomDebugCensus.Key.pinCard] ?? 0
        // A grab-from-rest builds an animator too (superseded, but alive), so
        // "some transition object exists" is the honest activity signal for
        // every open/dismiss path. Landing holds count as active: the hold
        // keeps the card visible up to 0.75s AFTER the animator died, and the
        // first field run read exactly that window as `STRANDED cards=1`.
        let holds = census[ZoomDebugCensus.Key.landingHold] ?? 0
        let isActive = animators > 0 || interruptors > 0 || retries > 0 || holds > 0

        var players = 0
        var idle = 0
        var anchors = 0
        var stalls = 0
        var generations = 0
        var duplicated = 0
        for (_, pool) in pools {
            players += pool.activePlayerCount
            idle += pool.debugIdlePlayerCount
            anchors += pool.debugPausedAnchorCount
            stalls += pool.debugStallObserverCount
            generations += pool.debugGenerationEntryCount
            duplicated += pool.playerCountByURL.values.filter { $0 > 1 }.count
        }

        // The screen's own truth: a card view surviving in some window while
        // no transition object is alive to be flying it. This is the check
        // that catches what a green log cannot.
        let stranded = isActive ? 0 : strandedCardCount()

        var wrongs: [String] = []
        if stranded > 0 { wrongs.append("STRANDED cards=\(stranded)") }
        if !isActive, duplicated > 0 { wrongs.append("DUPLICATE players urls=\(duplicated)") }
        if census.values.contains(where: { $0 < 0 }) { wrongs.append("NEGATIVE census \(census)") }
        failures += wrongs.count

        let state = isActive ? "active" : "settled"
        let line = "hero;seq=\(sequence);state=\(state)"
            + ";animators=\(animators);interruptors=\(interruptors);drivers=\(drivers)"
            + ";retries=\(retries);cards=\(cards);pins=\(pins);stranded=\(stranded)"
            + ";players=\(players);idle=\(idle);dupes=\(duplicated)"
            + ";anchors=\(anchors);stalls=\(stalls);gen=\(generations)"
        probe.accessibilityIdentifier = line

        for wrong in wrongs {
            emit("[hero-audit] FAIL seq=\(sequence) \(wrong)")
        }
        // Every sample goes to the file (it is the harness's channel); the
        // heartbeat adds the denominator a silent run needs to be readable.
        emit("[hero-audit] \(line)")
        if sequence % 20 == 0 {
            emit("[hero-audit] beat checks=\(checksPerformed) failures=\(failures)")
        }
    }

    /// The probe rides the key window, which may not exist at install and can
    /// change across scene lifecycle — re-attached whenever it is loose, and
    /// kept frontmost so nothing composites over the element.
    private func attachProbeIfNeeded() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else { return }
        if probe.superview !== window {
            window.addSubview(probe)
        }
        window.bringSubviewToFront(probe)
    }

    /// Flight cards found in ANY window while nothing is flying. By class
    /// name, deliberately: the concrete card types are internal to their
    /// features, and the audit must not import what it audits.
    ///
    /// ⚠️ `PinCardView` is ALSO the resting face of every map marker (pin =
    /// cluster = flight card, by design), so one found under an annotation is
    /// the map working, not a leak — only one loose in the ordinary view
    /// hierarchy is a stranded flight twin. `PostGridFlightCard` exists only
    /// to fly, so anywhere is stranded once nothing is flying.
    private func strandedCardCount() -> Int {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        var count = 0
        var stack: [(view: UIView, underMap: Bool)] =
            windows.flatMap(\.subviews).map { ($0, false) }
        var visited = 0
        while let (view, underMap) = stack.popLast() {
            visited += 1
            // A runaway hierarchy must not turn the audit into the stall it
            // would be hunting; 4Hz over a few thousand nodes is nothing,
            // 4Hz over a pathological tree is a hang.
            guard visited < 6000 else { break }
            // Invisible views are not wreckage: a reveal legitimately RETAINS
            // its hidden stand-in while the page it opened is up (the reveal
            // family carries no census, so "settled" spans that retention).
            // Stranded means visible to the viewer, or it means nothing.
            guard !view.isHidden, view.alpha > 0.01 else { continue }
            let name = String(describing: type(of: view))
            if name.contains("FlightCard") || (name.contains("PinCardView") && !underMap) {
                count += 1
                continue // a card's own subtree is the card's business
            }
            let mapish = underMap || name.contains("Annotation") || name.contains("MKMap")
            stack.append(contentsOf: view.subviews.map { ($0, mapish) })
        }
        return count
    }

    private func emit(_ line: String) {
        print(line)
        sink?.write(Data((line + "\n").utf8))
    }
}
#endif
