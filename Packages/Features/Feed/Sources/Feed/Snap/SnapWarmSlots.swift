import Foundation

/// A few things built ahead, by key, at most `capacity` of them (#2059): the
/// text pages' resting comments panels around the page on screen — the next
/// one's AND the previous one's, now that the feed pages back (#2056).
///
/// ⚠️ IT WAS ONE SLOT. Forward-only, the only page a gesture could reach was
/// the next, so one panel was enough, and building another threw it away.
/// Paging back needs the previous page ready too, without discarding the
/// next — nor the page being landed on, until it mounts: the feed holds
/// three, and the oldest goes past them.
///
/// Generic and free of UIKit, so the rules are unit-tested
/// (`SnapWarmSlotsTests`).
final class SnapWarmSlots<Key: Hashable, Value: AnyObject> {
    let capacity: Int
    /// Oldest first.
    private var entries: [(key: Key, value: Value)] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var isEmpty: Bool { entries.isEmpty }
    var keys: [Key] { entries.map(\.key) }
    var values: [Value] { entries.map(\.value) }

    func contains(_ key: Key) -> Bool {
        entries.contains { $0.key == key }
    }

    /// Holds `value` for `key` — replacing what `key` held — and lets the
    /// oldest go past `capacity`.
    func insert(_ value: Value, for key: Key) {
        entries.removeAll { $0.key == key }
        entries.append((key, value))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// Hands `key`'s value over and forgets it (it is about to be mounted).
    func take(_ key: Key) -> Value? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        return entries.remove(at: index).value
    }

    /// Forgets `value`, wherever it is held.
    func remove(_ value: Value) {
        entries.removeAll { $0.value === value }
    }

    /// Lets go of every key not in `keys` — the pages that left the window.
    func keep(only keys: Set<Key>) {
        entries.removeAll { !keys.contains($0.key) }
    }

    func removeAll() {
        entries.removeAll()
    }
}
