import Connect
import Foundation

/// Network-realism knobs for `MockBFF`: artificial latency and injected RPC
/// failures. The default is instant success, so tests stay deterministic
/// unless they opt in.
public struct SimulatedConditions: Sendable, Equatable {
    /// Uniform random per-request delay (seconds) before a response is
    /// delivered. `0...0` delivers on the next hop of a background queue,
    /// like today.
    public var latency: ClosedRange<TimeInterval>

    /// Failure rules. The first rule whose path filter matches a request
    /// decides its fate; its `rate` then rolls whether this call fails.
    public var failures: [FailureRule]

    public struct FailureRule: Sendable, Equatable {
        /// Substring of the RPC path to match — a service ("TimelineService"),
        /// a full path ("/profile.v1.ProfileService/GetProfile"), or "" for
        /// every route.
        public var pathContains: String
        public var code: Code
        public var message: String
        /// Probability in `0...1` that a matching request fails (1 = always).
        public var rate: Double

        public init(
            pathContains: String = "",
            code: Code = .unavailable,
            message: String = "simulated failure",
            rate: Double = 1
        ) {
            self.pathContains = pathContains
            self.code = code
            self.message = message
            self.rate = rate
        }
    }

    public init(latency: ClosedRange<TimeInterval> = 0...0, failures: [FailureRule] = []) {
        self.latency = latency
        self.failures = failures
    }

    public static let none = SimulatedConditions()

    func failure(matching path: String) -> FailureRule? {
        guard let rule = failures.first(where: { $0.pathContains.isEmpty || path.contains($0.pathContains) }) else {
            return nil
        }
        return rule.rate >= 1 || Double.random(in: 0..<1) < rule.rate ? rule : nil
    }

    func randomLatency() -> TimeInterval {
        latency.upperBound > 0 ? .random(in: latency) : 0
    }
}

// MARK: - Launch arguments

extension SimulatedConditions {
    /// Builds conditions from launch arguments, so any mock-mode run (app,
    /// UI test, `verify` skill) can degrade the network without a rebuild:
    ///
    /// - `-mock-latency 300` or `-mock-latency 100-800` — per-request delay
    ///   in milliseconds (single value or uniform range);
    /// - `-mock-fail TimelineService` — fail RPCs whose path contains the
    ///   substring (`all` fails every route);
    /// - `-mock-fail-code unavailable` — Connect code for injected failures
    ///   (default `unavailable`);
    /// - `-mock-fail-rate 0.3` — fraction of matching calls that fail
    ///   (default 1, i.e. always).
    public static func fromLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> SimulatedConditions {
        var conditions = SimulatedConditions()

        if let raw = value(after: "-mock-latency", in: arguments) {
            let bounds = raw.split(separator: "-", maxSplits: 1).compactMap { Double($0) }
            if bounds.count == 2, bounds[0] <= bounds[1] {
                conditions.latency = (bounds[0] / 1000)...(bounds[1] / 1000)
            } else if let single = bounds.first {
                conditions.latency = (single / 1000)...(single / 1000)
            }
        }

        if let path = value(after: "-mock-fail", in: arguments) {
            conditions.failures = [FailureRule(
                pathContains: path == "all" ? "" : path,
                code: value(after: "-mock-fail-code", in: arguments).flatMap(code(named:)) ?? .unavailable,
                message: "simulated by -mock-fail",
                rate: value(after: "-mock-fail-rate", in: arguments).flatMap(Double.init) ?? 1
            )]
        }

        return conditions
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1),
              !arguments[index + 1].hasPrefix("-")
        else { return nil }
        return arguments[index + 1]
    }

    private static func code(named name: String) -> Code? {
        switch name.lowercased().replacingOccurrences(of: "_", with: "") {
        case "canceled": .canceled
        case "unknown": .unknown
        case "invalidargument": .invalidArgument
        case "deadlineexceeded": .deadlineExceeded
        case "notfound": .notFound
        case "alreadyexists": .alreadyExists
        case "permissiondenied": .permissionDenied
        case "resourceexhausted": .resourceExhausted
        case "failedprecondition": .failedPrecondition
        case "aborted": .aborted
        case "outofrange": .outOfRange
        case "unimplemented": .unimplemented
        case "internal", "internalerror": .internalError
        case "unavailable": .unavailable
        case "dataloss": .dataLoss
        case "unauthenticated": .unauthenticated
        default: nil
        }
    }
}
