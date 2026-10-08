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

    /// Whether a video in a GRID, a rail or a preview may start on its own:
    /// Power Saving (Settings → App and Device) stops them whatever Autoplay
    /// says. A post opened full screen always plays (#702) — the viewer asked
    /// for that one post — so the snap feed does not read this.
    static var autoplays: Bool {
        !PowerSavingPreference.isOn && store.preferences.autoplays(onCellular: isOnCellular())
    }
    static var preloads: Bool { store.preferences.preloads(onCellular: isOnCellular()) }
    static var peakBitRate: Double { store.preferences.peakBitRate(onCellular: isOnCellular()) }
    /// Background Play (#483): the clip being heard keeps playing off screen.
    static var playsInBackground: Bool { store.preferences.backgroundPlay }
    /// Picture in Picture (#483): the playing clip floats when the app leaves.
    static var floatsInPictureInPicture: Bool { store.preferences.pictureInPicture }
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
