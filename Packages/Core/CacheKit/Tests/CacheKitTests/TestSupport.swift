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

/// A look budget, not a deadline (#1057): it counts this test's own polls,
/// so time a starved runner spends elsewhere costs nothing, and it stops as
/// soon as `condition` holds. Only for state the test or a running thread
/// writes next: a P1/P2 fill runs at utility QoS and can start long after
/// any budget, so its start, end or cancellation is AWAITED (`FillProbe`),
/// never polled (#1049). Touches no process-wide state.
func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<6_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Waiters for a count to reach a target, resumed by whoever moves it.
struct CountWaiters {
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Queues `continuation` unless `count` already reached `target`; `true`
    /// when the caller resumes it itself.
    mutating func wait(for target: Int, count: Int, _ continuation: CheckedContinuation<Void, Never>) -> Bool {
        guard count < target else { return true }
        waiters.append((target, continuation))
        return false
    }

    /// Takes out the waiters `count` satisfies, to resume outside the lock.
    mutating func reached(_ count: Int) -> [CheckedContinuation<Void, Never>] {
        var ready: [CheckedContinuation<Void, Never>] = []
        var waiting: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if count >= waiter.target { ready.append(waiter.continuation) } else { waiting.append(waiter) }
        }
        waiters = waiting
        return ready
    }
}
