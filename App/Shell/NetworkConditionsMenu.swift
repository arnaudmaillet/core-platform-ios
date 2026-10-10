#if DEBUG
import CoreNetworkingMocks
import UIKit

/// The mock network's runtime switch (#790): shake the device (Simulator:
/// Device ▸ Shake) for a sheet that takes the whole mock network offline,
/// makes it lossy or slow, or schedules an outage that ends on its own — the
/// same switchboard the `-mock-offline` / `-mock-outage` / `-mock-fail`
/// launch arguments set at launch. Mock mode only; DEBUG only.
enum NetworkConditionsMenu {
    @MainActor
    static func present(from presenter: UIViewController, faults: MockNetworkFaults, bff: MockBFF) {
        let state = faults.isOffline ? "offline" : describe(bff.simulatedConditions)
        let sheet = UIAlertController(title: "Mock network", message: "Now: \(state)", preferredStyle: .actionSheet)
        func add(_ title: String, _ apply: @escaping () -> Void) {
            sheet.addAction(UIAlertAction(title: title, style: .default) { _ in apply() })
        }
        // Every choice starts from a healthy network, so one never inherits
        // another's outage, lost acks or failed uploads.
        add("Online") {
            faults.reset()
            bff.simulatedConditions = .none
        }
        add("Offline") {
            faults.reset()
            faults.isForcedOffline = true
        }
        add("Lossy (30% of calls fail)") {
            faults.reset()
            bff.simulatedConditions = SimulatedConditions(failures: [.init(rate: 0.3)])
        }
        add("Slow (1.5–3 s per call)") {
            faults.reset()
            bff.simulatedConditions = SimulatedConditions(latency: 1.5...3)
        }
        add("Outage in 3 s, for 20 s") {
            faults.reset()
            bff.simulatedConditions = .none
            faults.scheduleOutage(after: 3, lasting: 20)
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = presenter.view
        presenter.present(sheet, animated: true)
    }

    private static func describe(_ conditions: SimulatedConditions) -> String {
        if conditions == .none { return "online" }
        var parts: [String] = []
        if conditions.latency.upperBound > 0 { parts.append("slow") }
        if !conditions.failures.isEmpty { parts.append("lossy") }
        return parts.joined(separator: ", ")
    }
}

/// A window that reports a shake — the debug sheets' trigger.
final class DebugShakeWindow: UIWindow {
    var onShake: (() -> Void)?

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake, let onShake else { return super.motionEnded(motion, with: event) }
        onShake()
    }
}
#endif
