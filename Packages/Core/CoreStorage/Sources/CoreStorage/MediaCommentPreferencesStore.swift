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
    /// The band's bubbles carry no fill by default (legibility comes from the
    /// page's scrim); a fill can be raised up to here.
    public static let bandBackgroundRange: ClosedRange<Double> = 0...0.8
    /// The subtitle pill's fill. 0 leaves the text bare over the media.
    public static let subtitleBackgroundRange: ClosedRange<Double> = 0...0.9
    /// The black wash over the post behind the comments screen. Below 0.5 a
    /// near-white photo drops body text under 4:1; 1 is solid black.
    public static let commentsBackdropRange: ClosedRange<Double> = 0.5...1

    public var showsReactionBand: Bool
    /// Bubble opacity, clamped to `opacityRange`.
    public var bandOpacity: Double {
        didSet { bandOpacity = Self.clamp(bandOpacity, to: Self.opacityRange) }
    }
    public var bandSpeed: BandSpeed
    /// Fill behind each band bubble, clamped to `bandBackgroundRange`.
    public var bandBackgroundOpacity: Double {
        didSet { bandBackgroundOpacity = Self.clamp(bandBackgroundOpacity, to: Self.bandBackgroundRange) }
    }
    public var showsSubtitles: Bool
    /// Fill behind the subtitle pill, clamped to `subtitleBackgroundRange`.
    public var subtitleBackgroundOpacity: Double {
        didSet { subtitleBackgroundOpacity = Self.clamp(subtitleBackgroundOpacity, to: Self.subtitleBackgroundRange) }
    }
    /// How dark the post is behind the comments screen, clamped to
    /// `commentsBackdropRange`.
    public var commentsBackdropOpacity: Double {
        didSet { commentsBackdropOpacity = Self.clamp(commentsBackdropOpacity, to: Self.commentsBackdropRange) }
    }
    /// Lowercased; a comment whose body contains one is never shown on media.
    public var mutedKeywords: [String]
    /// Lowercased handles without "@"; their comments are never shown on media.
    public var mutedHandles: [String]

    public init(
        showsReactionBand: Bool = true,
        bandOpacity: Double = 1,
        bandSpeed: BandSpeed = .normal,
        bandBackgroundOpacity: Double = 0,
        showsSubtitles: Bool = true,
        subtitleBackgroundOpacity: Double = 0.45,
        commentsBackdropOpacity: Double = 0.8,
        mutedKeywords: [String] = [],
        mutedHandles: [String] = []
    ) {
        self.showsReactionBand = showsReactionBand
        self.bandOpacity = Self.clamp(bandOpacity, to: Self.opacityRange)
        self.bandSpeed = bandSpeed
        self.bandBackgroundOpacity = Self.clamp(bandBackgroundOpacity, to: Self.bandBackgroundRange)
        self.showsSubtitles = showsSubtitles
        self.subtitleBackgroundOpacity = Self.clamp(subtitleBackgroundOpacity, to: Self.subtitleBackgroundRange)
        self.commentsBackdropOpacity = Self.clamp(commentsBackdropOpacity, to: Self.commentsBackdropRange)
        self.mutedKeywords = mutedKeywords
        self.mutedHandles = mutedHandles
    }

    private enum CodingKeys: String, CodingKey {
        case showsReactionBand, bandOpacity, bandSpeed, bandBackgroundOpacity
        case showsSubtitles, subtitleBackgroundOpacity, commentsBackdropOpacity
        case mutedKeywords, mutedHandles
    }

    /// Every key is optional: preferences saved by an older build (before a
    /// field existed) keep what they had and default the rest, instead of
    /// failing to decode and losing everything.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MediaCommentPreferences()
        self.init(
            showsReactionBand: try container.decodeIfPresent(Bool.self, forKey: .showsReactionBand) ?? defaults.showsReactionBand,
            bandOpacity: try container.decodeIfPresent(Double.self, forKey: .bandOpacity) ?? defaults.bandOpacity,
            bandSpeed: try container.decodeIfPresent(BandSpeed.self, forKey: .bandSpeed) ?? defaults.bandSpeed,
            bandBackgroundOpacity: try container.decodeIfPresent(Double.self, forKey: .bandBackgroundOpacity)
                ?? defaults.bandBackgroundOpacity,
            showsSubtitles: try container.decodeIfPresent(Bool.self, forKey: .showsSubtitles) ?? defaults.showsSubtitles,
            subtitleBackgroundOpacity: try container.decodeIfPresent(Double.self, forKey: .subtitleBackgroundOpacity)
                ?? defaults.subtitleBackgroundOpacity,
            commentsBackdropOpacity: try container.decodeIfPresent(Double.self, forKey: .commentsBackdropOpacity)
                ?? defaults.commentsBackdropOpacity,
            mutedKeywords: try container.decodeIfPresent([String].self, forKey: .mutedKeywords) ?? defaults.mutedKeywords,
            mutedHandles: try container.decodeIfPresent([String].self, forKey: .mutedHandles) ?? defaults.mutedHandles
        )
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
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
