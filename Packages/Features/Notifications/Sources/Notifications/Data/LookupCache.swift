import Foundation

/// What a lookup answered, kept for the next load (#897): bounded, the
/// oldest answer going first, and a FAILED lookup (nil) forgotten after
/// `failureLifetime`, so a profile or a post that could not be read is asked
/// again rather than drawn without a name for the life of the process.
struct LookupCache<Key: Hashable, Value> {
    let capacity: Int
    let failureLifetime: TimeInterval

    private struct Entry {
        var value: Value?
        var storedAt: Date
    }

    private var entries: [Key: Entry] = [:]
    /// Keys oldest answer first: the next to go when the cache is full.
    private var order: [Key] = []

    init(capacity: Int, failureLifetime: TimeInterval) {
        self.capacity = max(1, capacity)
        self.failureLifetime = failureLifetime
    }

    var count: Int { entries.count }

    /// Whether `key` has an answer still worth trusting: a value, or a
    /// failure younger than `failureLifetime`.
    func isKnown(_ key: Key, now: Date) -> Bool {
        guard let entry = entries[key] else { return false }
        return entry.value != nil || now.timeIntervalSince(entry.storedAt) < failureLifetime
    }

    /// The value known for `key`; nil for a failure or no answer.
    func value(for key: Key) -> Value? {
        entries[key]?.value ?? nil
    }

    /// Records `value` (nil: the lookup failed) as the newest answer.
    mutating func record(_ value: Value?, for key: Key, now: Date) {
        if entries.updateValue(Entry(value: value, storedAt: now), forKey: key) != nil {
            order.removeAll { $0 == key }
        }
        order.append(key)
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
    }
}
