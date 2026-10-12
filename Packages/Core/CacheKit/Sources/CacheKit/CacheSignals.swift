import Foundation
import Network
import Synchronization
import UIKit

/// The network path the device uses now.
public enum CacheNetworkInterface: String, Sendable {
    case wifi
    case cellular
    case wired
    case other
    case offline
}

/// The device state prefetching scales with.
public struct CacheConditions: Sendable, Equatable {
    public var isLowPowerModeEnabled: Bool
    public var thermalState: ProcessInfo.ThermalState
    public var network: CacheNetworkInterface
    /// Low Data Mode (`NWPath.isConstrained`).
    public var isNetworkConstrained: Bool
    /// Cellular or a personal hotspot (`NWPath.isExpensive`).
    public var isNetworkExpensive: Bool
    /// Settings → Storage → Use Less Cellular Data (#899, Instagram's
    /// pattern): on cellular, prefetching drops to `reduced`.
    public var usesLessCellularData: Bool

    public init(
        isLowPowerModeEnabled: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal,
        network: CacheNetworkInterface = .wifi,
        isNetworkConstrained: Bool = false,
        isNetworkExpensive: Bool = false,
        usesLessCellularData: Bool = false
    ) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
        self.network = network
        self.isNetworkConstrained = isNetworkConstrained
        self.isNetworkExpensive = isNetworkExpensive
        self.usesLessCellularData = usesLessCellularData
    }

}

/// How much lookahead the device allows now (#970). Prefetchers read it from
/// the coordinator to size their windows; the coordinator applies
/// `maxConcurrentSpeculativeFills` to its shared `CacheFillSlots` itself.
/// Figures follow the research note in #970 (BytePlus, Media3, Texture) and
/// are meant to be tuned with the `-cache-audit` instrument (#900).
public struct PrefetchPolicy: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable {
        /// Critical thermal state or offline: P0 only.
        case off
        /// Low Data Mode, Low Power Mode, a serious thermal state, or
        /// cellular with Use Less Cellular Data on: P0 and P1 (the next
        /// item), no P2 network work.
        case reduced
        /// Cellular: a shorter video lookahead.
        case cellular
        /// Wi-Fi or wired.
        case full

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var level: Level
    /// Videos ahead of the playing one that are warmed (+1) or head-preloaded (+2...).
    public var videoPreloadDepth: Int
    /// Screens ahead whose images are fetched to disk without decoding (P2).
    public var preloadScreens: Double
    /// Screens ahead whose images are decoded at their size bucket (P1).
    public var displayScreens: Double
    /// P2 fills running at once, app-wide.
    public var maxConcurrentSpeculativeFills: Int

    public static let full = PrefetchPolicy(level: .full, videoPreloadDepth: 3, preloadScreens: 2.5, displayScreens: 1, maxConcurrentSpeculativeFills: 2)
    public static let cellular = PrefetchPolicy(level: .cellular, videoPreloadDepth: 2, preloadScreens: 2.5, displayScreens: 1, maxConcurrentSpeculativeFills: 2)
    public static let reduced = PrefetchPolicy(level: .reduced, videoPreloadDepth: 1, preloadScreens: 0, displayScreens: 1, maxConcurrentSpeculativeFills: 0)
    public static let off = PrefetchPolicy(level: .off, videoPreloadDepth: 0, preloadScreens: 0, displayScreens: 0.5, maxConcurrentSpeculativeFills: 0)

    public init(level: Level, videoPreloadDepth: Int, preloadScreens: Double, displayScreens: Double, maxConcurrentSpeculativeFills: Int) {
        self.level = level
        self.videoPreloadDepth = videoPreloadDepth
        self.preloadScreens = preloadScreens
        self.displayScreens = displayScreens
        self.maxConcurrentSpeculativeFills = maxConcurrentSpeculativeFills
    }

    public init(conditions: CacheConditions) {
        if conditions.thermalState == .critical || conditions.network == .offline {
            self = .off
        } else if conditions.isNetworkConstrained || conditions.isLowPowerModeEnabled || conditions.thermalState == .serious {
            self = .reduced
        } else if conditions.network == .cellular || conditions.isNetworkExpensive {
            // The user's choice caps cellular prefetch at the next item and
            // turns P2 off; Wi-Fi keeps the full lookahead.
            self = conditions.usesLessCellularData ? .reduced : .cellular
        } else {
            self = .full
        }
    }
}

/// Something that happened to the app or the device, delivered to the
/// coordinator by a `CacheSignalSource`.
public enum CacheSignal: Sendable, Equatable {
    case memoryWarning
    case memoryCritical
    case didEnterBackground
    case willEnterForeground
    case lowPowerMode(Bool)
    case thermalState(ProcessInfo.ThermalState)
    case network(CacheNetworkInterface, isConstrained: Bool, isExpensive: Bool)
    /// Logout, or an account or profile switch.
    case viewerChanged
}

/// Delivers `CacheSignal`s. Injected into the coordinator, so tests drive it
/// by hand (`ManualCacheSignals`) and never post process-wide notifications or
/// flip process-wide state.
public protocol CacheSignalSource: Sendable {
    /// Starts delivering. `deliver` may be called on any thread.
    func start(_ deliver: @escaping @Sendable (CacheSignal) -> Void)
    func stop()
}

/// A source a test (or a debug hook) drives by hand. Delivery is synchronous.
public final class ManualCacheSignals: CacheSignalSource {
    private let deliver = Mutex<(@Sendable (CacheSignal) -> Void)?>(nil)

    public init() {}

    public func start(_ deliver: @escaping @Sendable (CacheSignal) -> Void) {
        self.deliver.withLock { $0 = deliver }
    }

    public func stop() {
        deliver.withLock { $0 = nil }
    }

    public func send(_ signal: CacheSignal) {
        let current = deliver.withLock { $0 }
        current?(signal)
    }
}

/// Maps notifications of one `NotificationCenter` to signals. The app wires
/// session changes through it (e.g. `StorageScope.didChangeNotification` →
/// `.viewerChanged`), so CacheKit depends on no feature or storage package.
public final class NotificationCacheSignals: CacheSignalSource {
    public typealias Mapping = @Sendable (Notification) -> CacheSignal?

    private let center: NotificationCenter
    private let mappings: [Notification.Name: Mapping]
    private let tokens = Mutex<[Token]>([])

    /// An observer token. `NotificationCenter` removes observers from any
    /// thread, so carrying the token across one is safe.
    private struct Token: @unchecked Sendable {
        let observer: any NSObjectProtocol
    }

    public init(center: NotificationCenter = .default, mappings: [Notification.Name: Mapping]) {
        self.center = center
        self.mappings = mappings
    }

    /// Every notification of `name` delivers `signal`.
    public convenience init(center: NotificationCenter = .default, _ name: Notification.Name, signal: CacheSignal) {
        self.init(center: center, mappings: [name: { _ in signal }])
    }

    public func start(_ deliver: @escaping @Sendable (CacheSignal) -> Void) {
        stop()
        let added = mappings.map { name, map in
            Token(observer: center.addObserver(forName: name, object: nil, queue: nil) { notification in
                if let signal = map(notification) { deliver(signal) }
            })
        }
        tokens.withLock { $0 = added }
    }

    public func stop() {
        let removed = tokens.withLock { stored -> [Token] in
            let taken = stored
            stored = []
            return taken
        }
        for token in removed { center.removeObserver(token.observer) }
    }
}

/// The production source: memory warnings, background and foreground,
/// critical memory pressure, Low Power Mode, thermal state and the network
/// path. Every system entry point is injectable; tests pass a private
/// `NotificationCenter` and turn the dispatch source and path monitor off.
public final class SystemCacheSignals: CacheSignalSource {
    private let center: NotificationCenter
    private let isLowPowerModeEnabled: @Sendable () -> Bool
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState
    private let observesMemoryPressure: Bool
    private let observesNetwork: Bool
    private let notifications: NotificationCacheSignals
    private let system = Mutex<SystemObservers?>(nil)

    private struct SystemObservers {
        var pressure: (any DispatchSourceMemoryPressure)?
        var path: NWPathMonitor?
    }

    public init(
        center: NotificationCenter = .default,
        isLowPowerModeEnabled: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
        observesMemoryPressure: Bool = true,
        observesNetwork: Bool = true
    ) {
        self.center = center
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
        self.observesMemoryPressure = observesMemoryPressure
        self.observesNetwork = observesNetwork
        notifications = NotificationCacheSignals(center: center, mappings: [
            UIApplication.didReceiveMemoryWarningNotification: { _ in .memoryWarning },
            UIApplication.didEnterBackgroundNotification: { _ in .didEnterBackground },
            UIApplication.willEnterForegroundNotification: { _ in .willEnterForeground },
            Notification.Name.NSProcessInfoPowerStateDidChange: { _ in .lowPowerMode(isLowPowerModeEnabled()) },
            ProcessInfo.thermalStateDidChangeNotification: { _ in .thermalState(thermalState()) }
        ])
    }

    public func start(_ deliver: @escaping @Sendable (CacheSignal) -> Void) {
        stop()
        notifications.start(deliver)
        deliver(.lowPowerMode(isLowPowerModeEnabled()))
        deliver(.thermalState(thermalState()))
        var observers = SystemObservers()
        if observesMemoryPressure {
            // Only CRITICAL here: the warning level already arrives as
            // UIApplication's memory warning, and trimming twice for one
            // warning would cut `recent` to a quarter.
            let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .global(qos: .utility))
            source.setEventHandler { deliver(.memoryCritical) }
            source.resume()
            observers.pressure = source
        }
        if observesNetwork {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                deliver(.network(Self.interface(of: path), isConstrained: path.isConstrained, isExpensive: path.isExpensive))
            }
            monitor.start(queue: .global(qos: .utility))
            observers.path = monitor
        }
        system.withLock { $0 = observers }
    }

    public func stop() {
        notifications.stop()
        let previous = system.withLock { stored -> SystemObservers? in
            let taken = stored
            stored = nil
            return taken
        }
        previous?.pressure?.cancel()
        previous?.path?.cancel()
    }

    private static func interface(of path: NWPath) -> CacheNetworkInterface {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }
}
