import Foundation

/// How much an entry is worth keeping, relative to the others in its
/// namespace. Eviction takes the lowest tier first, least recently used first
/// within a tier.
///
/// `pinned` is not a tier an entry is stored with: it is a lease
/// (`CacheLease`). A leased entry is never evicted by a budget or a trim,
/// whatever its tier, and goes back to its tier when the last lease ends.
public enum CacheTier: String, Sendable, Codable, CaseIterable, Comparable {
    /// Prefetched, never shown. Evicted first; expires on its own after
    /// `CacheTier.speculativeLifetime` unless it is promoted by a use or a lease.
    case speculative
    /// Seen. Ordinary LRU within the namespace budget.
    case recent
    /// The viewer's own content, the first page of each tab, the last open
    /// conversations. Survives memory trims; goes only to a budget or a wipe.
    case retained

    /// How long a speculative entry that nobody used stays valid: 24 h.
    public static let speculativeLifetime: TimeInterval = 24 * 60 * 60

    var rank: Int {
        switch self {
        case .speculative: 0
        case .recent: 1
        case .retained: 2
        }
    }

    public static func < (lhs: CacheTier, rhs: CacheTier) -> Bool { lhs.rank < rhs.rank }
}

/// Whose data a namespace holds, which decides what a logout or an account or
/// profile switch wipes (decision 4, epic #890).
public enum CacheScope: String, Sendable, Codable {
    /// Public, content-addressed media: the same bytes for every viewer. Kept.
    case `public`
    /// Copies of server data seen through the current viewer. Wiped.
    case viewer
    /// Media behind a signed URL: only this viewer was allowed to fetch it. Wiped.
    case signed
}

/// The groups Settings → Storage shows and clears (#899).
public enum CacheCategory: String, Sendable, CaseIterable {
    case images
    case videos
    case messages
    case other
}

/// Where a namespace keeps its entries.
public enum CacheMedium: String, Sendable {
    case memory
    case disk
}

/// The content class of a namespace: how much the whole namespace is worth
/// keeping relative to the OTHER namespaces, set by the consumer that
/// registers it. Tiers order entries inside a namespace; classes order
/// namespaces under pressure.
///
/// The global trim order walks (tier, class) from the lowest up: every
/// speculative entry of every class goes before any recent entry, recent
/// entries of a lower class before those of a higher one, and `pinned`
/// (leased) is never touched. Each memory signal cuts every class at a point
/// of that order, never deeper for a higher class:
///
/// | Signal          | expendable      | standard                   | preferred                  | persistent     |
/// |-----------------|-----------------|----------------------------|----------------------------|----------------|
/// | memory warning  | below retained  | speculative + half recent  | speculative                | speculative    |
/// | background      | below retained  | below retained             | speculative + half recent  | speculative    |
/// | memory critical | all but pinned  | all but pinned             | all but pinned             | below retained |
///
/// On disk, a class's floor is a reservation (`DiskBudget.reserved`) carved
/// out of its pool before the shared namespaces: low disk shrinks the others,
/// and a reservation shrinks only when the pool itself falls below it
/// (critical disk, the last resort) or on an explicit Settings clear. Its cap
/// is the namespace budget.
public enum CachePriorityClass: Int, Sendable, CaseIterable, Comparable {
    /// Cheap to get again (raster previews rebuilt from local data).
    case expendable
    /// Shown feed media: images, posters, played video ranges.
    case standard
    /// Small and repeated across screens: avatars and small thumbnails
    /// (#894), structured data (#893).
    case preferred
    /// UI assets: baked emote sheets, stickers, animated icons (#971). Small,
    /// reused on every screen, expensive to rebuild.
    case persistent

    public static func < (lhs: CachePriorityClass, rhs: CachePriorityClass) -> Bool { lhs.rawValue < rhs.rawValue }

    /// How deep a memory signal cuts a namespace of this class.
    public func depth(for pressure: MemoryPressure) -> TrimDepth {
        switch (self, pressure) {
        case (.expendable, .warning): .belowRetained
        case (.standard, .warning): .speculativeAndHalfRecent
        case (.preferred, .warning), (.persistent, .warning): .speculative
        case (.expendable, .background), (.standard, .background): .belowRetained
        case (.preferred, .background): .speculativeAndHalfRecent
        case (.persistent, .background): .speculative
        case (.expendable, .critical), (.standard, .critical), (.preferred, .critical): .allButPinned
        case (.persistent, .critical): .belowRetained
        }
    }
}

/// The memory signals the coordinator turns into trims.
public enum MemoryPressure: Sendable, CaseIterable {
    case warning
    case background
    case critical
}

/// The identity of a cache the coordinator manages: a name unique per medium,
/// the Settings category it is counted in, whose data it holds, and its
/// priority class.
public struct CacheNamespace: Sendable, Hashable {
    public let name: String
    public let category: CacheCategory
    public let scope: CacheScope
    public let priorityClass: CachePriorityClass

    public init(_ name: String, category: CacheCategory, scope: CacheScope, priorityClass: CachePriorityClass = .standard) {
        self.name = name
        self.category = category
        self.scope = scope
        self.priorityClass = priorityClass
    }

    /// Wiped on logout or on an account or profile switch.
    public var isWipedOnViewerChange: Bool { scope != .public }
}

/// How deep a trim cuts. The coordinator picks one per signal; every managed
/// cache applies it to its own entries. A trim never removes a leased entry.
public enum TrimDepth: Int, Sendable, CaseIterable, Comparable {
    /// Only entries past their expiry.
    case expired
    /// Expired entries and every speculative one.
    case speculative
    /// The above, plus the least recently used half (in bytes) of `recent`.
    /// The memory-warning cut.
    case speculativeAndHalfRecent
    /// Everything below `retained`. The background cut.
    case belowRetained
    /// Everything not leased. The critical-memory cut.
    case allButPinned

    public static func < (lhs: TrimDepth, rhs: TrimDepth) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What a cache holds right now.
public struct CacheUsage: Sendable, Equatable {
    /// Every byte the cache accounts for, leased entries included.
    public var bytes: Int
    public var count: Int
    /// Bytes held by leases: never evictable while the leases last.
    public var pinnedBytes: Int
    /// Unleased bytes per tier.
    public var bytesByTier: [CacheTier: Int]
    /// The budget the coordinator set (`Int.max` while unregistered).
    public var byteLimit: Int

    public init(bytes: Int = 0, count: Int = 0, pinnedBytes: Int = 0, bytesByTier: [CacheTier: Int] = [:], byteLimit: Int = .max) {
        self.bytes = bytes
        self.count = count
        self.pinnedBytes = pinnedBytes
        self.bytesByTier = bytesByTier
        self.byteLimit = byteLimit
    }
}

/// Lookup and eviction counters, for the `-cache-audit` instrument (#900).
public struct CacheStatistics: Sendable, Equatable {
    public var hits = 0
    public var misses = 0
    /// Entries removed to fit a budget or by a trim (not by a wipe or a remove).
    public var evictions = 0
    /// Entries dropped because they expired.
    public var expirations = 0

    public init() {}
}
