import Foundation
import Testing
@testable import CacheKit

/// Budgets from the device and the user limit (decision 1, epic #890), and
/// the content-class trim order.
struct CacheBudgetTests {
    @Test func automaticIsImages300Video500LocalStore100() {
        let budgets = DiskPoolBudgets(limit: .automatic, pressure: .normal)
        #expect(budgets == DiskPoolBudgets(images: 300 * megabyte, video: 500 * megabyte, localStore: 100 * megabyte))
    }

    @Test(arguments: [
        (CacheStorageLimit.halfGigabyte, 500_000_000),
        (CacheStorageLimit.oneGigabyte, 1_000_000_000),
        (CacheStorageLimit.twoGigabytes, 2_000_000_000)
    ])
    func aFixedUserLimitSplits3To5To1(limit: CacheStorageLimit, total: Int) {
        let budgets = DiskPoolBudgets(limit: limit, pressure: .normal)
        let ninth = total / 9
        #expect(budgets.images == 3 * ninth)
        #expect(budgets.video == 5 * ninth)
        #expect(budgets.localStore == ninth)
        #expect(budgets.total <= total, "the limit caps every disk namespace together")
        #expect(total - budgets.total < 9)
    }

    @Test func settingsOffersAutomaticAndThreeFixedLimits() {
        #expect(CacheStorageLimit.choices == [.automatic, .total(bytes: 500_000_000), .total(bytes: 1_000_000_000), .total(bytes: 2_000_000_000)])
    }

    @Test func lowDiskHalvesEveryPoolBelowTheLimit() {
        #expect(DiskPoolBudgets(limit: .automatic, pressure: .low)
            == DiskPoolBudgets(images: 150 * megabyte, video: 250 * megabyte, localStore: 50 * megabyte))
        let fixed = DiskPoolBudgets(limit: .oneGigabyte, pressure: .low)
        #expect(fixed.video == DiskPoolBudgets(limit: .oneGigabyte, pressure: .normal).video / 2)
    }

    @Test func criticalDiskTurnsVideoOffAndCapsImagesAt50MB() {
        let automatic = DiskPoolBudgets(limit: .automatic, pressure: .critical)
        #expect(automatic.video == 0)
        #expect(automatic.images == 50 * megabyte)
        #expect(automatic.localStore == 50 * megabyte)
        let small = DiskPoolBudgets(limit: .total(bytes: 90 * megabyte), pressure: .critical)
        #expect(small.images == 30 * megabyte, "never above the user's own limit")
    }

    @Test func pressureLevelsFollowFreeSpace() {
        let gigabyte = Int64(CacheBytes.gigabyte)
        #expect(DiskPressure(availableCapacity: 6 * gigabyte) == .normal)
        #expect(DiskPressure(availableCapacity: 5 * gigabyte) == .normal)
        #expect(DiskPressure(availableCapacity: 5 * gigabyte - 1) == .low)
        #expect(DiskPressure(availableCapacity: gigabyte - 1) == .critical)
        #expect(DiskPressure(availableCapacity: nil) == .normal, "a failed measurement never shrinks caches")
    }

    @Test func decodedImagesTake5PercentOfMemoryClampedTo64To256MB() {
        let mebibyte = CacheBytes.mebibyte
        #expect(MemoryBudget.decodedImages.bytes(physicalMemory: 1 << 30) == 64 * mebibyte)
        #expect(MemoryBudget.decodedImages.bytes(physicalMemory: 4 << 30) == Int(Double(4 << 30) * 0.05))
        #expect(MemoryBudget.decodedImages.bytes(physicalMemory: 8 << 30) == 256 * mebibyte)
        #expect(MemoryBudget.fixed(bytes: 1_000).bytes(physicalMemory: 8 << 30) == 1_000)
    }

    @Test func reservationsAreServedBeforeSharedNamespaces() {
        let shares = DiskBudget.split(300, among: [
            .reserved(60, in: .images),
            DiskBudget(pool: .images, weight: 1),
            DiskBudget(pool: .images, weight: 2)
        ])
        #expect(shares == [60, 80, 160])
    }

    @Test func aPoolSmallerThanItsReservationsSharesItInProportion() {
        let shares = DiskBudget.split(50, among: [
            .reserved(64, in: .images),
            .reserved(36, in: .images),
            DiskBudget(pool: .images)
        ])
        #expect(shares == [32, 18, 0])
    }

    @Test func limitsCapSpeculativeBytesAsAShare() {
        let limits = CacheLimits(bytes: 300, speculativeShare: 0.2)
        #expect(limits.speculativeBytes == 60)
        #expect(CacheLimits(bytes: 10, speculativeBytes: 50).speculativeBytes == 10)
        #expect(CacheLimits(bytes: -5, speculativeBytes: 3) == CacheLimits(bytes: 0, speculativeBytes: 0))
    }

    /// The global trim order walks (tier, class) upward: no signal cuts a
    /// higher class deeper than a lower one, and every signal drops the
    /// speculative entries of every class.
    @Test(arguments: MemoryPressure.allCases)
    func noSignalCutsAHigherClassDeeper(pressure: MemoryPressure) {
        let depths = CachePriorityClass.allCases.map { $0.depth(for: pressure) }
        #expect(zip(depths, depths.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(depths.allSatisfy { $0 >= .speculative })
    }

    @Test func persistentNamespacesKeepRetainedEvenUnderCriticalMemory() {
        #expect(CachePriorityClass.persistent.depth(for: .critical) == .belowRetained)
        #expect(CachePriorityClass.persistent.depth(for: .warning) == .speculative)
        #expect(CachePriorityClass.standard.depth(for: .warning) == .speculativeAndHalfRecent)
        #expect(CachePriorityClass.standard.depth(for: .critical) == .allButPinned)
    }
}

struct CacheKeyTests {
    @Test func mediaKeyStripsSigningParametersAndTheFragment() throws {
        let signed = try #require(URL(string:
            "https://cdn.example.com/m/abc.jpg?w=640&X-Amz-Algorithm=AWS4&X-Amz-Signature=deadbeef&x-amz-date=1#frag"))
        let resigned = try #require(URL(string:
            "https://cdn.example.com/m/abc.jpg?X-Amz-Signature=cafe&w=640&X-Amz-Algorithm=AWS4"))
        #expect(CacheKey.media(signed) == "https://cdn.example.com/m/abc.jpg?w=640")
        #expect(CacheKey.media(signed) == CacheKey.media(resigned), "one key across signatures")
    }

    @Test func mediaKeyStripsCloudFrontAndGoogleSignatures() throws {
        let url = try #require(URL(string:
            "https://d.example.net/v.mp4?Expires=1&Signature=x&Key-Pair-Id=k&Policy=p&X-Goog-Signature=g"))
        #expect(CacheKey.media(url) == "https://d.example.net/v.mp4")
    }

    @Test func otherQueryItemsSelectARenditionAndStay() throws {
        let small = try #require(URL(string: "https://cdn.example.com/a.jpg?size=small"))
        let large = try #require(URL(string: "https://cdn.example.com/a.jpg?size=large"))
        #expect(CacheKey.media(small) != CacheKey.media(large))
    }

    @Test func aURLWithSigningItemsIsSigned() throws {
        let signed = try #require(URL(string: "https://cdn.example.com/a.jpg?w=1&X-Amz-Signature=x"))
        let cloudFront = try #require(URL(string: "https://d.example.net/a.jpg?Expires=1&Signature=x"))
        let rendition = try #require(URL(string: "https://cdn.example.com/a.jpg?size=small"))
        let bare = try #require(URL(string: "https://cdn.example.com/a.jpg"))
        #expect(CacheKey.isSigned(signed) && CacheKey.isSigned(cloudFront))
        #expect(!CacheKey.isSigned(rendition) && !CacheKey.isSigned(bare))
    }
}
