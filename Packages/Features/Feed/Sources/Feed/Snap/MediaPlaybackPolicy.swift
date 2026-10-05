import CoreStorage
import DesignSystem
import Foundation
import Network

/// The viewer's playback preferences (#409) applied to the network the device
/// is on right now: may a video start on its own, may upcoming ones preload,
/// and how much bandwidth may a stream take.
@MainActor
enum MediaPlaybackPolicy {
    /// Swappable for tests.
    static var store = MediaPlaybackPreferencesStore.standard
    /// Swappable for tests; the live answer comes from `NWPathMonitor`.
    static var isOnCellular: () -> Bool = { CellularPathMonitor.shared.isExpensive }

    /// Power Saving (Settings → App and Device) stops every video from
    /// starting on its own, whatever Autoplay says.
    static var autoplays: Bool {
        !PowerSavingPreference.isOn && store.preferences.autoplays(onCellular: isOnCellular())
    }
    static var preloads: Bool { store.preferences.preloads(onCellular: isOnCellular()) }
    static var peakBitRate: Double { store.preferences.peakBitRate(onCellular: isOnCellular()) }
}

/// Whether the current network path is cellular or otherwise expensive
/// (a personal hotspot counts: iOS marks it expensive).
final class CellularPathMonitor: @unchecked Sendable {
    static let shared = CellularPathMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var expensive = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let value = path.isExpensive || path.usesInterfaceType(.cellular)
            lock.lock()
            expensive = value
            lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "cn.wynn.core-platform-ios.cellular-path"))
    }

    var isExpensive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expensive
    }
}
