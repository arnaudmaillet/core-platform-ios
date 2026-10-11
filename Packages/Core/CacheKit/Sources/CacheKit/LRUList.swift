/// An ordered set of keys, least recently used first, with O(1) append,
/// removal and move-to-back. Not thread-safe: it lives inside a cache's
/// `Mutex`-guarded state.
struct LRUList<Key: Hashable> {
    private struct Node {
        var previous: Key?
        var next: Key?
    }

    private var nodes: [Key: Node] = [:]
    /// The least recently used key.
    private(set) var first: Key?
    /// The most recently used key.
    private(set) var last: Key?

    var count: Int { nodes.count }
    var isEmpty: Bool { nodes.isEmpty }

    func contains(_ key: Key) -> Bool { nodes[key] != nil }

    /// Appends `key` as the most recently used. A key already present moves.
    mutating func append(_ key: Key) {
        if nodes[key] != nil { remove(key) }
        nodes[key] = Node(previous: last, next: nil)
        if let tail = last {
            nodes[tail]?.next = key
        } else {
            first = key
        }
        last = key
    }

    mutating func remove(_ key: Key) {
        guard let node = nodes.removeValue(forKey: key) else { return }
        if let previous = node.previous {
            nodes[previous]?.next = node.next
        } else {
            first = node.next
        }
        if let next = node.next {
            nodes[next]?.previous = node.previous
        } else {
            last = node.previous
        }
    }

    /// Marks `key` as the most recently used.
    mutating func touch(_ key: Key) {
        guard nodes[key] != nil, last != key else { return }
        append(key)
    }

    func key(after key: Key) -> Key? { nodes[key]?.next }

    mutating func removeAll() {
        nodes.removeAll()
        first = nil
        last = nil
    }

    /// Least recently used first.
    var ordered: [Key] {
        var keys: [Key] = []
        keys.reserveCapacity(nodes.count)
        var cursor = first
        while let key = cursor {
            keys.append(key)
            cursor = nodes[key]?.next
        }
        return keys
    }
}

/// One LRU list per tier, for the entries that are NOT leased. A leased entry
/// is in no list, so eviction never has to skip over it.
struct TieredLRU<Key: Hashable> {
    private var speculative = LRUList<Key>()
    private var recent = LRUList<Key>()
    private var retained = LRUList<Key>()

    /// In-place access: a `get`/`set` subscript would copy the list's table on
    /// every mutation.
    private mutating func withList<R>(_ tier: CacheTier, _ body: (inout LRUList<Key>) -> R) -> R {
        switch tier {
        case .speculative: body(&speculative)
        case .recent: body(&recent)
        case .retained: body(&retained)
        }
    }

    func list(_ tier: CacheTier) -> LRUList<Key> {
        switch tier {
        case .speculative: speculative
        case .recent: recent
        case .retained: retained
        }
    }

    mutating func append(_ key: Key, tier: CacheTier) { withList(tier) { $0.append(key) } }
    mutating func remove(_ key: Key, tier: CacheTier) { withList(tier) { $0.remove(key) } }
    mutating func touch(_ key: Key, tier: CacheTier) { withList(tier) { $0.touch(key) } }

    mutating func removeAll() {
        speculative.removeAll()
        recent.removeAll()
        retained.removeAll()
    }

    /// The next entry a budget takes: the least recently used of the lowest
    /// tier, no higher than `ceiling`, never `excluded`.
    func victim(upTo ceiling: CacheTier = .retained, excluding excluded: Key? = nil) -> Key? {
        for tier in CacheTier.allCases where tier <= ceiling {
            let tierList = list(tier)
            guard var candidate = tierList.first else { continue }
            if candidate == excluded {
                guard let next = tierList.key(after: candidate) else { continue }
                candidate = next
            }
            return candidate
        }
        return nil
    }

    /// The entries a trim of `depth` removes, in eviction order. `cost` and
    /// `isExpired` read the cache's own records.
    func victims(for depth: TrimDepth, cost: (Key) -> Int, isExpired: (Key) -> Bool) -> [Key] {
        var keys: [Key] = []
        let expiredOnly = CacheTier.allCases.flatMap { list($0).ordered.filter(isExpired) }
        switch depth {
        case .expired:
            return expiredOnly
        case .speculative:
            keys = speculative.ordered
        case .speculativeAndHalfRecent:
            keys = speculative.ordered
            let recentKeys = recent.ordered
            let recentBytes = recentKeys.reduce(0) { $0 + cost($1) }
            var freed = 0
            for key in recentKeys where freed * 2 < recentBytes {
                keys.append(key)
                freed += cost(key)
            }
        case .belowRetained:
            keys = speculative.ordered + recent.ordered
        case .allButPinned:
            keys = speculative.ordered + recent.ordered + retained.ordered
        }
        let chosen = Set(keys)
        return keys + expiredOnly.filter { !chosen.contains($0) }
    }
}
