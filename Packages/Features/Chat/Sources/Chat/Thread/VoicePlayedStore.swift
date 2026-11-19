import Foundation

/// Which received voice messages the viewer has played (#2104) — the
/// unplayed dot's memory, kept on the device until the backend models a
/// listened state (backend#993). The most recent `capacity` ids.
///
/// ONE instance, built by the app and handed to the chat builder (#2376):
/// every conversation reads and writes the same memory.
@MainActor
public final class VoicePlayedStore {
    static let key = "voice.playedMessageIDs"
    static let capacity = 2_000

    private let defaults: UserDefaults
    /// Read on first use, not at init: the app builds the store with the chat
    /// feature, at launch, and the list is only needed in a conversation.
    private lazy var ids: [String] = defaults.stringArray(forKey: Self.key) ?? []
    private lazy var lookup: Set<String> = Set(ids)

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
