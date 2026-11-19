import Foundation

/// Which received voice messages the viewer has played (#2104) — the
/// unplayed dot's memory, kept on the device until the backend models a
/// listened state (backend#993). The most recent `capacity` ids.
@MainActor
final class VoicePlayedStore {
    static let shared = VoicePlayedStore()
    static let key = "voice.playedMessageIDs"
    static let capacity = 2_000

    private let defaults: UserDefaults
    private var ids: [String]
    private var lookup: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = defaults.stringArray(forKey: Self.key) ?? []
        lookup = Set(ids)
    }

    func isPlayed(_ messageID: String) -> Bool { lookup.contains(messageID) }

    func markPlayed(_ messageID: String) {
        guard lookup.insert(messageID).inserted else { return }
        ids.append(messageID)
        if ids.count > Self.capacity {
            let dropped = ids.prefix(ids.count - Self.capacity)
            ids.removeFirst(dropped.count)
            lookup.subtract(dropped)
        }
        defaults.set(ids, forKey: Self.key)
    }
}
