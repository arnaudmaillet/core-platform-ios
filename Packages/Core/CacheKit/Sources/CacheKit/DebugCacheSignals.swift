#if DEBUG
import Foundation
import Synchronization
import UIKit

/// `-cache-signal <name>@<seconds>` (DEBUG, #898): fires a release signal at
/// a time after launch, so the `-cache-audit` instrument can film what each
/// one does on a simulator, which cannot turn on Low Power or Low Data Mode
/// and has no scriptable memory warning. Repeat the argument for several.
///
/// | name | what it delivers |
/// |---|---|
/// | `memoryWarning` | UIKit's memory warning notification, to every observer |
/// | `memoryCritical` | `.memoryCritical` |
/// | `lowPower` / `lowPowerOff` | `.lowPowerMode(true/false)` |
/// | `lowData` / `lowDataOff` | `.network(.wifi, isConstrained: true/false, …)` |
/// | `thermalSerious` / `thermalCritical` / `thermalNominal` | `.thermalState(…)` |
///
/// A later real signal (a path update, a power change) overrides a faked one.
public final class DebugCacheSignals: CacheSignalSource {
    public static let argument = "-cache-signal"

    struct Scheduled: Equatable {
        let name: String
        let delay: TimeInterval
    }

    private let scheduled: [Scheduled]
    private let center: NotificationCenter
    private let generation = Mutex(0)

    public init(arguments: [String] = ProcessInfo.processInfo.arguments, center: NotificationCenter = .default) {
        scheduled = Self.parse(arguments)
        self.center = center
    }

    /// The signals asked for, `<name>@<seconds>` (seconds default to 0).
    static func parse(_ arguments: [String]) -> [Scheduled] {
        var found: [Scheduled] = []
        for (index, argument) in arguments.enumerated() where argument == Self.argument && index + 1 < arguments.count {
            let parts = arguments[index + 1].split(separator: "@", maxSplits: 1).map(String.init)
            guard let name = parts.first, Self.signal(named: name) != nil || name == "memoryWarning" else { continue }
            let delay = parts.count > 1 ? (TimeInterval(parts[1]) ?? 0) : 0
            found.append(Scheduled(name: name, delay: max(0, delay)))
        }
        return found
    }

    static func signal(named name: String) -> CacheSignal? {
        switch name {
        case "memoryCritical": .memoryCritical
        case "lowPower": .lowPowerMode(true)
        case "lowPowerOff": .lowPowerMode(false)
        case "lowData": .network(.wifi, isConstrained: true, isExpensive: false)
        case "lowDataOff": .network(.wifi, isConstrained: false, isExpensive: false)
        case "thermalSerious": .thermalState(.serious)
        case "thermalCritical": .thermalState(.critical)
        case "thermalNominal": .thermalState(.nominal)
        default: nil
        }
    }

    public func start(_ deliver: @escaping @Sendable (CacheSignal) -> Void) {
        let current = generation.withLock { value -> Int in
            value += 1
            return value
        }
        let notifications = self.center
        for item in scheduled {
            DispatchQueue.main.asyncAfter(deadline: .now() + item.delay) { [weak self] in
                guard let self, generation.withLock({ $0 }) == current else { return }
                print("\(CacheAudit.prefix) debug signal \(item.name)")
                if item.name == "memoryWarning" {
                    // The real notification: the coordinator hears it through
                    // `SystemCacheSignals`, like every other observer.
                    notifications.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
                } else if let signal = Self.signal(named: item.name) {
                    deliver(signal)
                }
            }
        }
    }

    public func stop() {
        generation.withLock { $0 += 1 }
    }
}
#endif
