import Foundation

/// The emotes shown most recently, kept across launches (#1504): what a
/// launch reads into memory before the first screen asks
/// (`EmoteEngine.warmHotSet`), so the art a viewer saw last appears in the
/// first layout pass — no empty square, no skeleton.
///
/// Small on purpose: a 64 px sheet is about a megabyte decoded, and the
/// resident budget is 32–64 MB (`EmoteEngine.memoryBudget`). Written only
/// when the SET changes, not on every view: a caption scrolled back into
/// view moves its emote to the front in memory and costs no write.
@MainActor
final class EmoteHotSet {
    struct Entry: Equatable {
        let id: String
        let pixelSide: Int
        let still: Bool

        var stored: String { "\(id)|\(pixelSide)|\(still ? 1 : 0)" }

        init(id: String, pixelSide: Int, still: Bool) {
            self.id = id
            self.pixelSide = pixelSide
            self.still = still
        }

        init?(stored: String) {
            let parts = stored.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, let side = Int(parts[1]) else { return nil }
            self.init(id: String(parts[0]), pixelSide: side, still: parts[2] == "1")
        }
    }

    static let capacity = 16
    static let key = "emote.hotSet.v1"

    private let defaults: UserDefaults
    /// Most recent first.
    private(set) var entries: [Entry]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        entries = (defaults.stringArray(forKey: Self.key) ?? []).compactMap(Entry.init(stored:))
    }

    /// `id` at this size was shown: to the front, and written if it was not
    /// in the set already.
    func note(_ id: String, pixelSide: Int, still: Bool) {
        let entry = Entry(id: id, pixelSide: pixelSide, still: still)
        let wasIn = entries.contains(entry)
        entries.removeAll { $0 == entry }
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        guard !wasIn else { return }
        defaults.set(entries.map(\.stored), forKey: Self.key)
    }
}
