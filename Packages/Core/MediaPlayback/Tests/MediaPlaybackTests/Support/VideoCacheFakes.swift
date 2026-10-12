import Foundation
import Synchronization
import Testing
@testable import MediaPlayback

/// A private folder per test, deleted when the suite instance goes.
final class VideoCacheFolder: Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appending(path: "VideoCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Deterministic bytes, so a served range can be compared with the source.
func videoBytes(_ count: Int, seed: UInt8 = 7) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

/// Serves byte ranges from memory and records every range asked for.
///
/// Automatic by default: each fetch answers on its own queue (response, the
/// body in slices, finish). `holds` keeps every fetch waiting for the test to
/// feed it (`deliver(_:bytes:)`), which is how a cancel lands mid-body.
final class FakeRangeFetcher: VideoRangeFetching, @unchecked Sendable {
    // `@unchecked`: every mutable field is behind `lock`.

    struct Request: Equatable, Sendable {
        let url: URL
        let offset: Int64
        let end: Int64?
        let speculative: Bool
    }

    final class Task: VideoRangeTask, @unchecked Sendable {
        let request: Request
        let events: VideoRangeFetchEvents
        private let state = Mutex((cancelled: false, sent: Int64(0), answered: false))

        init(request: Request, events: VideoRangeFetchEvents) {
            self.request = request
            self.events = events
        }

        var isCancelled: Bool { state.withLock { $0.cancelled } }
        var sent: Int64 { state.withLock { $0.sent } }
        func cancel() { state.withLock { $0.cancelled = true } }
        func setPriority(_ priority: Float) {}

        func markAnswered() -> Bool {
            state.withLock { state in
                defer { state.answered = true }
                return !state.answered
            }
        }

        func advance(by count: Int64) {
            state.withLock { $0.sent += count }
        }
    }

    private let lock = NSLock()
    private var files: [URL: (data: Data, mime: String)] = [:]
    private var tasks: [Task] = []
    // At the cache queue's QoS: a fake answering below it is the first thing
    // a loaded host starves, and the test then waits on the fake, not the code.
    private let queue = DispatchQueue(label: "FakeRangeFetcher", qos: .userInitiated)
    let holds: Bool
    let sliceSize: Int

    init(holds: Bool = false, sliceSize: Int = 64 * 1024) {
        self.holds = holds
        self.sliceSize = sliceSize
    }

    func serve(_ data: Data, at url: URL, mime: String = "video/mp4") {
        lock.withLock { files[url] = (data, mime) }
    }

    /// Airplane mode: every later fetch fails at once.
    private var isOffline = false
    func goOffline() { lock.withLock { isOffline = true } }

    var requests: [Request] { lock.withLock { tasks.map(\.request) } }
    var cancelledCount: Int { lock.withLock { tasks.filter(\.isCancelled).count } }
    /// The `index`-th fetch, or nil (recorded as an issue, never a trap) when
    /// fewer arrived: a miss must fail its test, not crash the test process.
    func task(_ index: Int, sourceLocation: SourceLocation = #_sourceLocation) -> Task? {
        let found = lock.withLock { tasks.indices.contains(index) ? tasks[index] : nil }
        if found == nil {
            Issue.record("fetch \(index) never arrived (\(requests.count) did)", sourceLocation: sourceLocation)
        }
        return found
    }

    func fetch(
        _ url: URL, from offset: Int64, to end: Int64?, speculative: Bool, priority: Float,
        events: VideoRangeFetchEvents
    ) -> any VideoRangeTask {
        let task = Task(request: Request(url: url, offset: offset, end: end, speculative: speculative), events: events)
        let offline = lock.withLock { tasks.append(task); return isOffline }
        if offline {
            queue.async { events.finish(VideoRangeFetchFailure(URLError(.notConnectedToInternet))) }
        } else if !holds {
            queue.async { [self] in
                deliver(task, bytes: .max)
            }
        }
        return task
    }

    /// Sends the response (once), then up to `bytes` more of the body; the
    /// finish once the range is out.
    func deliver(_ index: Int, bytes: Int64, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let found = task(index, sourceLocation: sourceLocation) else { return }
        deliver(found, bytes: bytes)
    }

    private func deliver(_ task: Task, bytes: Int64) {
        guard !task.isCancelled, let file = lock.withLock({ files[task.request.url] }) else { return }
        let total = Int64(file.data.count)
        let start = task.request.offset
        let end = min(task.request.end ?? total, total)
        if task.markAnswered() {
            task.events.response(VideoRangeResponse(offset: start, totalLength: total, mimeType: file.mime))
        }
        var budget = bytes
        while budget > 0, !task.isCancelled {
            let from = start + task.sent
            guard from < end else { break }
            let count = min(Int64(sliceSize), end - from, budget)
            task.advance(by: count)
            budget -= count
            task.events.data(file.data.subdata(in: Int(from) ..< Int(from + count)))
        }
        if !task.isCancelled, start + task.sent >= end {
            task.events.finish(nil)
        }
    }
}

/// A loading request that records what it was given. Touched on the cache's
/// queue only (read it through `VideoByteCache.queue.sync`).
final class FakeLoadingRequest: VideoLoadingRequest, @unchecked Sendable {
    let wantsContentInformation: Bool
    let dataRange: VideoDataRange?
    private(set) var info: VideoContentInfo?
    private(set) var received = Data()
    private(set) var finished = false
    private(set) var failure: (any Error)?

    init(info: Bool = false, offset: Int64, length: Int64, toEnd: Bool = false) {
        wantsContentInformation = info
        dataRange = VideoDataRange(offset: offset, length: length, toEnd: toEnd)
    }

    func fill(_ info: VideoContentInfo) { self.info = info }
    func respond(with data: Data) { received.append(data) }
    func finishLoading() { finished = true }

    func finishLoading(with error: any Error) {
        finished = true
        failure = error
    }
}

/// Waits (polling) until `condition` holds, on the caller's actor.
///
/// A LOOK budget, not a deadline (#967, #975, `TimingTolerance`): it counts
/// this test's own polls, so time the process spends descheduled on a starved
/// runner costs nothing. A fill crosses several executors (a main-actor task,
/// the cooperative pool, the cache's queue) and a busy CI host delayed one by
/// almost two minutes; a 5 s wall-clock wait failed on that alone. Every wait
/// stops as soon as its condition holds, so the budget only matters there.
@discardableResult
func eventually(
    isolation: isolated (any Actor)? = #isolation, looks: Int = 6_000, _ condition: () -> Bool
) async -> Bool {
    for _ in 0..<looks {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A lookahead clock a test ticks by hand.
@MainActor
final class ManualLookaheadClock: VideoLookaheadClock {
    private var ticks: [@MainActor () -> Bool] = []
    private(set) var now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Moves time, then ticks.
    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
        tick()
    }

    func schedule(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Bool) {
        ticks.append(tick)
    }

    func tick() {
        ticks = ticks.filter { $0() }
    }
}
