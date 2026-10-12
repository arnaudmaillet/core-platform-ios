import Foundation

/// The three disk pools every disk namespace draws from (decision 1, epic
/// #890). A user limit splits its total 3:5:1 across them, so every disk byte
/// the app caches counts against the one limit Settings shows.
public enum DiskPool: String, Sendable, CaseIterable {
    case images
    case video
    case localStore

    /// The Automatic budget: images 300 MB, video 500 MB, LocalStore 100 MB.
    public var automaticBytes: Int {
        switch self {
        case .images: 300 * CacheBytes.megabyte
        case .video: 500 * CacheBytes.megabyte
        case .localStore: 100 * CacheBytes.megabyte
        }
    }

    /// The pool's share of a fixed user limit, out of 9.
    public var shareOfLimit: Int {
        switch self {
        case .images: 3
        case .video: 5
        case .localStore: 1
        }
    }
}

/// Byte units. Disk figures are decimal, like the sizes Settings and the
/// system show; memory figures are binary, like `physicalMemory`.
public enum CacheBytes {
    public static let megabyte = 1_000_000
    public static let gigabyte = 1_000_000_000
    public static let mebibyte = 1 << 20
}

/// `Int(value)` that saturates instead of trapping near `Int.max`.
func clampedInt(_ value: Double) -> Int {
    guard value.isFinite else { return value > 0 ? .max : 0 }
    if value >= Double(Int.max) { return .max }
    return max(0, Int(value))
}

/// The disk limit chosen in Settings → Storage (#899).
public enum CacheStorageLimit: Sendable, Hashable {
    /// Images 300 MB + video 500 MB + LocalStore 100 MB.
    case automatic
    /// A cap on the total of every disk namespace, split 3:5:1.
    case total(bytes: Int)

    public static let halfGigabyte = CacheStorageLimit.total(bytes: CacheBytes.gigabyte / 2)
    public static let oneGigabyte = CacheStorageLimit.total(bytes: CacheBytes.gigabyte)
    public static let twoGigabytes = CacheStorageLimit.total(bytes: 2 * CacheBytes.gigabyte)

    /// The choices Settings offers, in order.
    public static let choices: [CacheStorageLimit] = [.automatic, .halfGigabyte, .oneGigabyte, .twoGigabytes]
}

/// The Settings → Storage limit, kept on this device (#899): a device
/// preference like the playback ones, never the profile's. The app reads it
/// once to build its coordinator; Settings writes it and applies it.
public enum CacheStoragePreference {
    static let key = "device.cacheStorageLimit"

    /// The saved limit; `.automatic` when none was chosen, or when what is
    /// saved is not a positive byte count.
    public static func load(from defaults: UserDefaults = .standard) -> CacheStorageLimit {
        let bytes = defaults.integer(forKey: key)
        return bytes > 0 ? .total(bytes: bytes) : .automatic
    }

    public static func save(_ limit: CacheStorageLimit, to defaults: UserDefaults = .standard) {
        switch limit {
        case .automatic: defaults.removeObject(forKey: key)
        case .total(let bytes): defaults.set(max(1, bytes), forKey: key)
        }
    }
}

/// How short the device is of free disk space, measured with
/// `volumeAvailableCapacityForImportantUsage`.
public enum DiskPressure: Int, Sendable, Comparable {
    /// 5 GB free or more: budgets as the limit says.
    case normal
    /// Under 5 GB free: every pool halved.
    case low
    /// Under 1 GB free: the video cache off, images 50 MB, LocalStore halved.
    case critical

    public static let lowThreshold: Int64 = 5 * Int64(CacheBytes.gigabyte)
    public static let criticalThreshold: Int64 = 1 * Int64(CacheBytes.gigabyte)

    /// `nil` (the volume could not be measured) reads as `normal`: never
    /// shrink caches on a measurement that failed.
    public init(availableCapacity: Int64?) {
        guard let availableCapacity else { self = .normal; return }
        if availableCapacity < Self.criticalThreshold {
            self = .critical
        } else if availableCapacity < Self.lowThreshold {
            self = .low
        } else {
            self = .normal
        }
    }

    public static func < (lhs: DiskPressure, rhs: DiskPressure) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The bytes each disk pool may hold, after the user limit and the disk
/// pressure. Low disk shrinks budgets BELOW whatever limit applies.
public struct DiskPoolBudgets: Sendable, Equatable {
    public var images: Int
    public var video: Int
    public var localStore: Int

    /// Images under critical disk pressure.
    public static let criticalImagesBytes = 50 * CacheBytes.megabyte

    public init(images: Int, video: Int, localStore: Int) {
        self.images = images
        self.video = video
        self.localStore = localStore
    }

    public init(limit: CacheStorageLimit, pressure: DiskPressure) {
        func base(_ pool: DiskPool) -> Int {
            switch limit {
            case .automatic:
                return pool.automaticBytes
            case .total(let bytes):
                let shares = DiskPool.allCases.reduce(0) { $0 + $1.shareOfLimit }
                return max(0, bytes) / shares * pool.shareOfLimit
            }
        }
        var images = base(.images)
        var video = base(.video)
        var localStore = base(.localStore)
        switch pressure {
        case .normal:
            break
        case .low:
            images /= 2
            video /= 2
            localStore /= 2
        case .critical:
            images = min(images, Self.criticalImagesBytes)
            video = 0
            localStore /= 2
        }
        self.init(images: images, video: video, localStore: localStore)
    }

    public subscript(pool: DiskPool) -> Int {
        switch pool {
        case .images: images
        case .video: video
        case .localStore: localStore
        }
    }

    public var total: Int { images + video + localStore }
}

/// How a memory namespace's budget follows the device. Features pick a rule,
/// the coordinator turns it into bytes: no feature hard-codes a byte figure
/// that ignores the device.
public enum MemoryBudget: Sendable, Hashable {
    /// A share of physical memory, clamped.
    case physicalMemoryFraction(Double, minimum: Int, maximum: Int)
    /// A fixed figure, for small namespaces whose content does not scale with
    /// the device (e.g. a count-limited entity store with cost 1 per entry).
    case fixed(bytes: Int)

    /// Decoded images: 5% of physical memory, clamped to 64–256 MB.
    public static let decodedImages = MemoryBudget.physicalMemoryFraction(
        0.05, minimum: 64 * CacheBytes.mebibyte, maximum: 256 * CacheBytes.mebibyte
    )

    public func bytes(physicalMemory: UInt64) -> Int {
        switch self {
        case .fixed(let bytes):
            return max(0, bytes)
        case .physicalMemoryFraction(let fraction, let minimum, let maximum):
            let share = Double(physicalMemory) * fraction
            let clamped = min(max(share, Double(minimum)), Double(maximum))
            return clampedInt(clamped)
        }
    }
}

/// A disk namespace's place in the pools. Every disk namespace belongs to a
/// pool, so the user limit caps every disk byte the app caches.
///
/// - A shared namespace gets `weight` parts of what its pool has left after
///   the reservations, split with every other shared namespace of the pool.
/// - A reserved namespace (the `persistent` class: baked emotes) gets its
///   reservation first. Low disk shrinks the shared part; the reservation
///   shrinks only when the pool itself is smaller (reservations then share the
///   pool in proportion).
public struct DiskBudget: Sendable, Hashable {
    public let pool: DiskPool
    public let weight: Int
    public let reservedBytes: Int

    public init(pool: DiskPool, weight: Int = 1) {
        self.pool = pool
        self.weight = max(1, weight)
        self.reservedBytes = 0
    }

    private init(pool: DiskPool, reservedBytes: Int) {
        self.pool = pool
        self.weight = 1
        self.reservedBytes = max(0, reservedBytes)
    }

    /// A reservation of `bytes` in `pool`, served before the shared namespaces.
    public static func reserved(_ bytes: Int, in pool: DiskPool) -> DiskBudget {
        DiskBudget(pool: pool, reservedBytes: bytes)
    }

    public var isReserved: Bool { reservedBytes > 0 }

    /// The bytes of each budget in `budgets`, all of the same pool holding
    /// `poolBytes`. Reservations first, the rest by weight.
    public static func split(_ poolBytes: Int, among budgets: [DiskBudget]) -> [Int] {
        let pool = max(0, poolBytes)
        let reserved = budgets.reduce(0) { $0 + $1.reservedBytes }
        let weights = budgets.filter { !$0.isReserved }.reduce(0) { $0 + $1.weight }
        let remainder = max(0, pool - reserved)
        return budgets.map { budget in
            if budget.isReserved {
                guard reserved > pool else { return budget.reservedBytes }
                return min(pool, clampedInt(Double(pool) * Double(budget.reservedBytes) / Double(reserved)))
            }
            guard weights > 0 else { return 0 }
            return min(remainder, clampedInt(Double(remainder) * Double(budget.weight) / Double(weights)))
        }
    }
}

/// A namespace's budget rule, memory or disk.
public enum CacheBudget: Sendable, Hashable {
    case memory(MemoryBudget)
    case disk(DiskBudget)

    public var medium: CacheMedium {
        switch self {
        case .memory: .memory
        case .disk: .disk
        }
    }
}

/// The limits the coordinator hands a cache.
public struct CacheLimits: Sendable, Equatable {
    /// Every byte of the namespace, leases excluded from what can be evicted.
    public var bytes: Int
    /// The cap on unleased `speculative` bytes, so prefetching never crowds out
    /// what was seen. Always at most `bytes`.
    public var speculativeBytes: Int

    public init(bytes: Int, speculativeBytes: Int) {
        self.bytes = max(0, bytes)
        self.speculativeBytes = min(max(0, speculativeBytes), max(0, bytes))
    }

    public init(bytes: Int, speculativeShare: Double) {
        let clampedShare = min(max(speculativeShare, 0), 1)
        self.init(bytes: bytes, speculativeBytes: clampedInt(Double(max(0, bytes)) * clampedShare))
    }

    public static let unlimited = CacheLimits(bytes: .max, speculativeBytes: .max)
}
