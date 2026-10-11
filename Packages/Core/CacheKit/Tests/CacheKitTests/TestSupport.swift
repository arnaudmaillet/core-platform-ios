import Foundation
import Synchronization
@testable import CacheKit

/// A private folder per test, deleted when the test's suite instance goes.
final class TemporaryFolder: Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appending(path: "CacheKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func files(in relativePath: String) -> [String] {
        let folder = url.appending(path: relativePath, directoryHint: .isDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
}

/// A device whose memory and free disk a test sets.
final class FakeDevice: Sendable {
    private let free: Mutex<Int64?>
    let physicalMemory: UInt64

    init(physicalMemory: UInt64 = 4 << 30, freeDisk: Int64? = 100 * Int64(CacheBytes.gigabyte)) {
        self.physicalMemory = physicalMemory
        free = Mutex(freeDisk)
    }

    func setFreeDisk(_ bytes: Int64?) { free.withLock { $0 = bytes } }

    var device: CacheDevice {
        let memory = physicalMemory
        return CacheDevice(physicalMemory: { memory }, availableDiskCapacity: { [self] in free.withLock { $0 } })
    }
}

/// Collects what a source delivers.
final class SignalRecorder: Sendable {
    private let received = Mutex<[CacheSignal]>([])

    var signals: [CacheSignal] { received.withLock { $0 } }

    func record(_ signal: CacheSignal) { received.withLock { $0.append(signal) } }
}

let megabyte = CacheBytes.megabyte

func namespace(_ name: String, _ category: CacheCategory = .images, scope: CacheScope = .public, priorityClass: CachePriorityClass = .standard) -> CacheNamespace {
    CacheNamespace(name, category: category, scope: scope, priorityClass: priorityClass)
}

func memoryCache(
    _ name: String = "mem",
    limit: Int = 100,
    speculativeLimit: Int? = nil,
    clock: any CacheClock = ManualCacheClock(),
    scope: CacheScope = .public,
    category: CacheCategory = .images,
    priorityClass: CachePriorityClass = .standard,
    budget: MemoryBudget = .fixed(bytes: 100)
) -> MemoryCache<String, String> {
    MemoryCache(
        namespace: namespace(name, category, scope: scope, priorityClass: priorityClass),
        budget: budget,
        limits: CacheLimits(bytes: limit, speculativeBytes: speculativeLimit ?? limit),
        clock: clock
    )
}

func bytes(_ count: Int, _ fill: UInt8 = 7) -> Data { Data(repeating: fill, count: count) }

/// Polls `condition` until it holds or `timeout` passes. For fills that run on
/// the cooperative pool; touches no process-wide state.
func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
