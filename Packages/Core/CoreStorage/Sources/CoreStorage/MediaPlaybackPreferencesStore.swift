import Foundation

/// How videos play on THIS device (Settings → App Preferences, #409).
public struct MediaPlaybackPreferences: Codable, Equatable, Sendable {
    public enum Autoplay: String, Codable, CaseIterable, Sendable {
        case always, wifiOnly, never
    }

    public var autoplay: Autoplay
    /// Whether a full-screen video starts with its sound. The in-feed mute
    /// button still toggles it for the session.
    public var startsWithSound: Bool
    /// On cellular: cap the stream quality and don't preload upcoming videos.
    public var dataSaver: Bool

    public init(autoplay: Autoplay = .always, startsWithSound: Bool = true, dataSaver: Bool = false) {
        self.autoplay = autoplay
        self.startsWithSound = startsWithSound
        self.dataSaver = dataSaver
    }

    /// Whether a video may start on its own, given the network it is on.
    public func autoplays(onCellular: Bool) -> Bool {
        switch autoplay {
        case .always: true
        case .wifiOnly: !onCellular
        case .never: false
        }
    }

    /// Whether upcoming videos may be loaded ahead of time.
    public func preloads(onCellular: Bool) -> Bool {
        !(dataSaver && onCellular)
    }

    /// The stream's peak bit rate (bits per second, 0 = uncapped). Only an
    /// adaptive stream with several qualities can honour it.
    public func peakBitRate(onCellular: Bool) -> Double {
        dataSaver && onCellular ? Self.dataSaverPeakBitRate : 0
    }

    public static let dataSaverPeakBitRate: Double = 800_000
}

extension Notification.Name {
    /// Posted after `MediaPlaybackPreferencesStore.update` writes a change.
    public static let mediaPlaybackPreferencesDidChange = Notification.Name("cn.wynn.core-platform-ios.mediaPlaybackPreferencesDidChange")
}

/// Reads and writes `MediaPlaybackPreferences` in `UserDefaults`.
public final class MediaPlaybackPreferencesStore: @unchecked Sendable {
    public static let standard = MediaPlaybackPreferencesStore()

    private let defaults: UserDefaults
    private let key = "mediaPlaybackPreferences"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var preferences: MediaPlaybackPreferences {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(MediaPlaybackPreferences.self, from: data)
        else { return MediaPlaybackPreferences() }
        return decoded
    }

    public func update(_ mutate: (inout MediaPlaybackPreferences) -> Void) {
        lock.lock()
        var current = preferences
        let before = current
        mutate(&current)
        let changed = current != before
        if changed, let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: key)
        }
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: .mediaPlaybackPreferencesDidChange, object: self)
        }
    }
}
