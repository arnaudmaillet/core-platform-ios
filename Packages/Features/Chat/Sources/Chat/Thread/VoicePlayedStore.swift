import CoreStorage
import Foundation

/// Which received voice messages the viewer has played (#2104) — the
/// unplayed dot's memory, kept on the device until the backend models a
/// listened state (backend#993). The most recent `capacity` ids.
///
/// Per PROFILE (`StorageScope`, #2376): what one viewer played is not the
/// next one's. The list kept before it was scoped is adopted by the first
/// member profile that reads it, as the other stores do.
///
/// ONE instance, built by the app and handed to the chat builder (#2376):
/// every conversation reads and writes the same memory.
@MainActor
public final class VoicePlayedStore {
    static let key = "voice.playedMessageIDs"
    static let capacity = 2_000

    private let defaults: UserDefaults
    private let scope: StorageScope
    /// The key the list in memory was read under. Read on first use, not at
    /// init — the app builds the store with the chat feature, at launch — and
    /// again whenever the viewer's key changes.
    private var loadedKey: String?
    private var ids: [String] = []
    private var lookup: Set<String> = []

    public init(defaults: UserDefaults = .standard, scope: StorageScope) {
        self.defaults = defaults
        self.scope = scope
    }

    /// The viewer's list, in memory: read again when the viewer changed.
    private func load() -> String {
        let key = scope.profileKey(Self.key, adoptingLegacyIn: defaults)
        if key != loadedKey {
            loadedKey = key
            ids = defaults.stringArray(forKey: key) ?? []
            lookup = Set(ids)
        }
        return key
    }

    func isPlayed(_ messageID: String) -> Bool {
        _ = load()
        return lookup.contains(messageID)
    }

    func markPlayed(_ messageID: String) {
        let key = load()
        guard lookup.insert(messageID).inserted else { return }
        ids.append(messageID)
        if ids.count > Self.capacity {
            let dropped = ids.prefix(ids.count - Self.capacity)
            ids.removeFirst(dropped.count)
            lookup.subtract(dropped)
        }
        defaults.set(ids, forKey: key)
    }
}
