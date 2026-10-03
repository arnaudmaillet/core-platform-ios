import Foundation

/// How comments ride on media pages, on THIS device (Settings → App
/// Preferences, #410): the reaction band (danmaku) and the subtitle zone.
public struct MediaCommentPreferences: Codable, Equatable, Sendable {
    public enum BandSpeed: String, Codable, CaseIterable, Sendable {
        case slow, normal, fast

        /// Multiplier on the band's lane speeds.
        public var scale: Double {
            switch self {
            case .slow: 0.7
            case .normal: 1
            case .fast: 1.4
            }
        }
    }

    public static let opacityRange: ClosedRange<Double> = 0.3...1

    public var showsReactionBand: Bool
    /// Bubble opacity, clamped to `opacityRange`.
    public var bandOpacity: Double {
        didSet { bandOpacity = min(max(bandOpacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound) }
    }
    public var bandSpeed: BandSpeed
    public var showsSubtitles: Bool
    /// Lowercased; a comment whose body contains one is never shown on media.
    public var mutedKeywords: [String]
    /// Lowercased handles without "@"; their comments are never shown on media.
    public var mutedHandles: [String]

    public init(
        showsReactionBand: Bool = true,
        bandOpacity: Double = 1,
        bandSpeed: BandSpeed = .normal,
        showsSubtitles: Bool = true,
        mutedKeywords: [String] = [],
        mutedHandles: [String] = []
    ) {
        self.showsReactionBand = showsReactionBand
        self.bandOpacity = min(max(bandOpacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        self.bandSpeed = bandSpeed
        self.showsSubtitles = showsSubtitles
        self.mutedKeywords = mutedKeywords
        self.mutedHandles = mutedHandles
    }

    /// Whether a comment must stay off media: its body contains a muted
    /// keyword (case-insensitive), or its author's handle is muted.
    public func mutes(body: String, authorHandle: String) -> Bool {
        let handle = Self.normalizedHandle(authorHandle)
        if !handle.isEmpty, mutedHandles.contains(handle) { return true }
        let lowered = body.lowercased()
        return mutedKeywords.contains { !$0.isEmpty && lowered.contains($0) }
    }

    public static func normalizedKeyword(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func normalizedHandle(_ raw: String) -> String {
        var handle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while handle.hasPrefix("@") { handle.removeFirst() }
        return handle
    }
}

extension Notification.Name {
    /// Posted after `MediaCommentPreferencesStore.update` writes a change.
    public static let mediaCommentPreferencesDidChange = Notification.Name("cn.wynn.core-platform-ios.mediaCommentPreferencesDidChange")
}

/// Reads and writes `MediaCommentPreferences` in `UserDefaults`, and
/// announces each change so the feed can rebuild its comment streams.
public final class MediaCommentPreferencesStore: @unchecked Sendable {
    /// The app's store. The feed's comment surfaces and Settings share it.
    public static let standard = MediaCommentPreferencesStore()

    private let defaults: UserDefaults
    private let key = "mediaCommentPreferences"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var preferences: MediaCommentPreferences {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(MediaCommentPreferences.self, from: data)
        else { return MediaCommentPreferences() }
        return decoded
    }

    public func update(_ mutate: (inout MediaCommentPreferences) -> Void) {
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
            NotificationCenter.default.post(name: .mediaCommentPreferencesDidChange, object: self)
        }
    }
}
