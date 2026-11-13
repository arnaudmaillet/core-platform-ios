#if DEBUG
import CoreNavigation
import CoreNetworkingMocks
import DesignSystem
import UIKit

/// The mock network's runtime switch (#790), a section of the debug
/// dashboard since #2132 (it was a shake sheet of its own): takes the whole
/// mock network offline, makes it lossy or slow, fails one service, or
/// schedules an outage that ends on its own — the same switchboard the
/// `-mock-offline` / `-mock-outage` / `-mock-fail` launch arguments set at
/// launch. Mock mode only; DEBUG only.
public enum NetworkConditionsMenu {
    /// The services one can fail alone, by the RPC path they match.
    public static let services = ["TimelineService", "ProfileService", "ChatService", "Comment", "MediaService"]

    @MainActor
    public static func entry(faults: MockNetworkFaults, bff: MockBFF) -> DebugDashboard.Entry {
        DebugDashboard.Entry(title: "Mock Network", symbol: "network") {
            DebugListViewController(title: "Mock Network") { sections(faults: faults, bff: bff) }
        }
    }

    @MainActor
    private static func sections(faults: MockNetworkFaults, bff: MockBFF) -> [DebugSection] {
        // Every choice starts from a healthy network, so one never inherits
        // another's outage, lost acks or failed uploads.
        func choice(_ title: String, _ apply: @escaping () -> Void) -> DebugRow {
            .action(title, detail: nil, run: {
                faults.reset()
                bff.simulatedConditions = .none
                apply()
            })
        }
        let state = faults.isOffline ? "offline" : describe(bff.simulatedConditions)
        return [
            DebugSection(title: "Now", rows: [.info("Mock network", state)]),
            DebugSection(title: "Conditions", rows: [
                choice("Online") {},
                choice("Offline") { faults.isForcedOffline = true },
                choice("Lossy (30% of calls fail)") {
                    bff.simulatedConditions = SimulatedConditions(failures: [.init(rate: 0.3)])
                },
                choice("Slow (1.5–3 s per call)") {
                    bff.simulatedConditions = SimulatedConditions(latency: 1.5...3)
                },
                choice("Outage in 3 s, for 20 s") { faults.scheduleOutage(after: 3, lasting: 20) },
            ]),
            DebugSection(title: "One service fails", rows: services.map { service in
                choice(service) {
                    bff.simulatedConditions = SimulatedConditions(failures: [.init(pathContains: service)])
                }
            }),
        ]
    }

    public static func describe(_ conditions: SimulatedConditions) -> String {
        if conditions == .none { return "online" }
        var parts: [String] = []
        if conditions.latency.upperBound > 0 { parts.append("slow") }
        if conditions.failures.contains(where: { !$0.pathContains.isEmpty }) {
            parts.append("failing: " + conditions.failures.map(\.pathContains).filter { !$0.isEmpty }.joined(separator: ", "))
        } else if !conditions.failures.isEmpty {
            parts.append("lossy")
        }
        return parts.joined(separator: ", ")
    }
}

/// A window that reports a shake — the debug sheets' trigger.
public final class DebugShakeWindow: AppWindow {
    public var onShake: (() -> Void)?

    public override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake, let onShake else { return super.motionEnded(motion, with: event) }
        onShake()
    }
}
#endif
