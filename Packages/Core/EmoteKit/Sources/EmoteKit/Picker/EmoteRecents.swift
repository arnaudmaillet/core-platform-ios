import Foundation

/// The emotes a person used last, most recent first, kept across launches.
///
/// ⚠️ **IDS, NOT EMOTES, ARE STORED.** A build that drops an emote simply
/// skips its id when reading; nothing is migrated and nothing crashes.
@MainActor
public final class EmoteRecents {
    public static let shared = EmoteRecents(defaults: .standard)

    /// How many are kept — one generous row of the picker, two of the strip.
    public static let limit = 24

    private let defaults: UserDefaults
    private let key: String
    public private(set) var ids: [String]

    public init(defaults: UserDefaults, key: String = "emote.recents.v1") {
        self.defaults = defaults
        self.key = key
        self.ids = Array((defaults.stringArray(forKey: key) ?? []).prefix(Self.limit))
    }

    /// Moves `emote` to the front, dropping the oldest past `limit`.
    public func record(_ emote: Emote) {
        var next = ids.filter { $0 != emote.id }
        next.insert(emote.id, at: 0)
        ids = Array(next.prefix(Self.limit))
        defaults.set(ids, forKey: key)
    }

    /// The recents this build still knows, in order.
    public func emotes(in catalog: EmoteCatalog) -> [Emote] {
        ids.compactMap { catalog.emote(id: $0) }
    }

    public func removeAll() {
        ids = []
        defaults.removeObject(forKey: key)
    }
}
