import Connect
import Foundation

/// The mock network's fault switchboard (#790): one object the BFF, the upload
/// transport and the realtime server all ask before they answer, so "offline"
/// means offline everywhere at once — not just for unary RPCs.
///
/// `SimulatedConditions` keeps latency and probabilistic failures; this adds
/// what those cannot say:
/// - **offline** — every call fails fast with `unavailable`, what a real
///   URLSession call answers with no network;
/// - **a timed outage** — offline from `start` to `end`, then back, so a run
///   can watch the app lose the network AND recover it;
/// - **ack loss** — the write is applied, then the response is lost
///   (`deadlineExceeded`): the case a retried send duplicates on;
/// - **upload faults** — the object-store PUT fails at a rate.
///
/// Changes post `didChange` (on the main queue), including the outage's own
/// start and end, so the realtime server follows. An outage is timed from the
/// first use of the switchboard (it is built lazily), not from launch.
public final class MockNetworkFaults: @unchecked Sendable {
    public static let didChange = Notification.Name("MockNetworkFaults.didChange")

    public struct AckLossRule: Sendable, Equatable {
        /// Substring of the RPC path; "" for every route.
        public var pathContains: String
        public var rate: Double
        public init(pathContains: String = "", rate: Double = 1) {
            self.pathContains = pathContains
            self.rate = rate
        }
    }

    private let lock = NSLock()
    private var offline = false
    private var outageWindow: ClosedRange<Date>?
    private var ackLossRules: [AckLossRule] = []
    private var uploadFailRate: Double = 0
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// Offline until switched back, whatever the outage window says.
    public var isForcedOffline: Bool {
        get { lock.withLock { offline } }
        set {
            lock.withLock { offline = newValue }
            announce()
        }
    }

    /// Whether a call made now finds no network.
    public var isOffline: Bool {
        lock.withLock { offline || outageWindow.map { $0.contains(now()) } == true }
    }

    /// Schedules an outage: offline `after` seconds from now, for `duration`.
    /// Its start and end are announced like any other change.
    public func scheduleOutage(after delay: TimeInterval, lasting duration: TimeInterval) {
        let start = now().addingTimeInterval(delay)
        lock.withLock { outageWindow = start...start.addingTimeInterval(duration) }
        announce()
        for moment in [delay, delay + duration] {
            DispatchQueue.main.asyncAfter(deadline: .now() + moment + 0.01) { [weak self] in self?.announce() }
        }
    }

    /// Ends a scheduled outage now (the shake sheet's Online).
    public func cancelOutage() {
        lock.withLock { outageWindow = nil }
        announce()
    }

    /// Back to a healthy network: no offline, no outage, no lost acks, no
    /// failed uploads.
    public func reset() {
        lock.withLock {
            offline = false
            outageWindow = nil
            ackLossRules = []
            uploadFailRate = 0
        }
        announce()
    }

    public var ackLoss: [AckLossRule] {
        get { lock.withLock { ackLossRules } }
        set { lock.withLock { ackLossRules = newValue } }
    }

    /// Probability in `0...1` that an upload PUT fails.
    public var uploadFailureRate: Double {
        get { lock.withLock { uploadFailRate } }
        set { lock.withLock { uploadFailRate = newValue } }
    }

    /// Whether this call's response is lost after its write applied.
    func losesAck(for path: String) -> Bool {
        guard let rule = ackLoss.first(where: { $0.pathContains.isEmpty || path.contains($0.pathContains) }) else {
            return false
        }
        return rule.rate >= 1 || Double.random(in: 0..<1) < rule.rate
    }

    /// Whether this upload fails.
    func failsUpload() -> Bool {
        let rate = uploadFailureRate
        return rate >= 1 || (rate > 0 && Double.random(in: 0..<1) < rate)
    }

    private func announce() {
        let post: @Sendable () -> Void = { NotificationCenter.default.post(name: Self.didChange, object: self) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}

// MARK: - Launch arguments

extension MockNetworkFaults {
    /// Builds faults from launch arguments:
    ///
    /// - `-mock-offline` — offline from launch;
    /// - `-mock-outage 20+30` — offline from t=20 s for 30 s, then back;
    /// - `-mock-ack-loss <path|all>` — apply the write, lose the response
    ///   (`-mock-ack-loss-rate 0.5` for a fraction);
    /// - `-mock-upload-fail 0.5` — fraction of upload PUTs that fail.
    public static func fromLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> MockNetworkFaults {
        let faults = MockNetworkFaults()
        if arguments.contains("-mock-offline") { faults.offline = true }
        if let raw = value(after: "-mock-outage", in: arguments) {
            let parts = raw.split(separator: "+").compactMap { Double($0) }
            if parts.count == 2 { faults.scheduleOutage(after: parts[0], lasting: parts[1]) }
        }
        if let path = value(after: "-mock-ack-loss", in: arguments) {
            faults.ackLossRules = [AckLossRule(
                pathContains: path == "all" ? "" : path,
                rate: value(after: "-mock-ack-loss-rate", in: arguments).flatMap(Double.init) ?? 1
            )]
        }
        if let rate = value(after: "-mock-upload-fail", in: arguments).flatMap(Double.init) {
            faults.uploadFailRate = rate
        }
        return faults
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1),
              !arguments[index + 1].hasPrefix("-")
        else { return nil }
        return arguments[index + 1]
    }
}
