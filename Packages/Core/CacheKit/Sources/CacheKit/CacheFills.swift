import Foundation
import Synchronization

/// How urgently a fill is wanted: the request priority classes of the feed
/// lookahead (#970). Several owners can want the same key at different
/// priorities; the fill runs at the highest one still wanted.
public enum CacheFillPriority: Int, Sendable, Comparable, CaseIterable {
    /// P2: the preload window (+2, +3, a grid's leading screens). Waits for a
    /// slot of the coordinator's global speculative allowance.
    case speculative
    /// P1: the next item (+1 page, a grid's display window). Never waits for a
    /// slot, but downloads at a lower network priority than P0.
    case next
    /// P0: on screen or playing.
    case visible

    public static func < (lhs: CacheFillPriority, rhs: CacheFillPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The matching `URLSessionTask.priority` (a hint the system honours and
    /// that can change while the task runs).
    public var urlSessionTaskPriority: Float {
        switch self {
        case .speculative: URLSessionTask.lowPriority
        case .next: URLSessionTask.defaultPriority
        case .visible: URLSessionTask.highPriority
        }
    }

    /// The `TaskPriority` a fill starts with.
    public var taskPriority: TaskPriority {
        switch self {
        case .speculative, .next: .utility
        case .visible: .userInitiated
        }
    }

    /// Whether a fill at this priority waits for the global speculative allowance.
    public var needsSlot: Bool { self == .speculative }
}

/// What a running fill can read about its own demand: the priority it is
/// wanted at now, and a hook to follow changes (to update a
/// `URLSessionTask.priority`). Cancellation arrives as ordinary task
/// cancellation when no owner wants the fill any more.
public final class CacheFillContext: Sendable {
    private struct State {
        var priority: CacheFillPriority
        var handlers: [@Sendable (CacheFillPriority) -> Void] = []
    }

    private let state: Mutex<State>

    init(priority: CacheFillPriority) {
        state = Mutex(State(priority: priority))
    }

    public var priority: CacheFillPriority { state.withLock { $0.priority } }

    /// Calls `handler` on every later priority change, on the thread that made it.
    public func onPriorityChange(_ handler: @escaping @Sendable (CacheFillPriority) -> Void) {
        state.withLock { $0.handlers.append(handler) }
    }

    func update(_ priority: CacheFillPriority) {
        let handlers: [@Sendable (CacheFillPriority) -> Void] = state.withLock { state in
            guard state.priority != priority else { return [] }
            state.priority = priority
            return state.handlers
        }
        for handler in handlers { handler(priority) }
    }
}

/// The token of one requester: a feed list, a grid, a rail. Every interest a
/// list registers goes through its owner, so:
///
/// - `revoke()` (the list left the screen) drops every interest it holds, in
///   every `CacheFills`, and cancels the fills nobody else wants; fills shared
///   with another owner keep running for it;
/// - `setPriorityCeiling(_:)` (a list hidden but still alive) caps all its
///   interests, e.g. to `.speculative`, so it never competes with the visible
///   list;
/// - asking twice for the same key in the same `CacheFills` updates the one
///   interest instead of adding a second.
///
/// `revoke()` is final: the token belongs to one stay of a list on screen,
/// and a list shown again makes a new owner. Checking "revoked?" and
/// registering an interest happen under the owner's one lock, so a `request`
/// that races a `revoke()` on another thread either lands before it (and is
/// dropped by it) or after it (and registers nothing). A request from a
/// revoked owner returns an interest whose `isActive` is `false`; it never
/// starts or joins a fill. The owner revokes itself when deallocated.
public final class CacheOwner: Sendable {
    public let name: String

    private struct Held {
        var requested: CacheFillPriority
        let reprioritize: @Sendable (CacheFillPriority) -> Void
        let release: @Sendable () -> Void
    }

    private struct State {
        var ceiling: CacheFillPriority = .visible
        var held: [UInt64: Held] = [:]
        var isRevoked = false
    }

    private let state = Mutex(State())

    public init(_ name: String) {
        self.name = name
    }

    deinit { revoke() }

    public var priorityCeiling: CacheFillPriority { state.withLock { $0.ceiling } }

    /// Interests this owner holds now.
    public var interestCount: Int { state.withLock { $0.held.count } }

    /// Whether `revoke()` ran. A revoked owner registers no interest.
    public var isRevoked: Bool { state.withLock { $0.isRevoked } }

    public func setPriorityCeiling(_ ceiling: CacheFillPriority) {
        let updates = state.withLock { state -> [(@Sendable (CacheFillPriority) -> Void, CacheFillPriority)] in
            state.ceiling = ceiling
            return state.held.values.map { ($0.reprioritize, min($0.requested, ceiling)) }
        }
        for (reprioritize, priority) in updates { reprioritize(priority) }
    }

    /// Drops every interest this owner holds, and every later request. Final.
    public func revoke() {
        let released = state.withLock { state -> [Held] in
            state.isRevoked = true
            let taken = Array(state.held.values)
            state.held.removeAll()
            return taken
        }
        for held in released { held.release() }
    }

    func effective(_ requested: CacheFillPriority) -> CacheFillPriority {
        min(requested, priorityCeiling)
    }

    /// Registers interest `id`, atomically with the revoked check. `false`
    /// (nothing registered) once the owner is revoked.
    func hold(_ id: UInt64, requested: CacheFillPriority, reprioritize: @escaping @Sendable (CacheFillPriority) -> Void, release: @escaping @Sendable () -> Void) -> Bool {
        state.withLock { state in
            guard !state.isRevoked else { return false }
            state.held[id] = Held(requested: requested, reprioritize: reprioritize, release: release)
            return true
        }
    }

    func holds(_ id: UInt64) -> Bool {
        state.withLock { $0.held[id] != nil }
    }

    /// `false` when the owner no longer holds `id` (released, revoked, or
    /// its fill finished).
    @discardableResult
    func update(_ id: UInt64, to requested: CacheFillPriority) -> Bool {
        let call = state.withLock { state -> (@Sendable (CacheFillPriority) -> Void, CacheFillPriority)? in
            guard var held = state.held[id] else { return nil }
            held.requested = requested
            state.held[id] = held
            return (held.reprioritize, min(requested, state.ceiling))
        }
        guard let (reprioritize, priority) = call else { return false }
        reprioritize(priority)
        return true
    }

    func release(_ id: UInt64) {
        let held = state.withLock { $0.held.removeValue(forKey: id) }
        held?.release()
    }

    /// The fill finished: nothing to release any more.
    func forget(_ ids: [UInt64]) {
        state.withLock { state in
            for id in ids { state.held[id] = nil }
        }
    }
}

/// A handle on one owner's interest in one key. Releasing it, or revoking the
/// owner, drops the interest; releasing twice is harmless. It does NOT release
/// itself when deallocated: the owner is what holds the interest.
public final class CacheFillInterest: Sendable {
    private let owner: CacheOwner
    private let id: UInt64

    init(owner: CacheOwner, id: UInt64) {
        self.owner = owner
        self.id = id
    }

    /// An interest that was never registered: its owner was revoked.
    static func inactive(owner: CacheOwner) -> CacheFillInterest {
        CacheFillInterest(owner: owner, id: 0)
    }

    /// Whether the interest still wants its fill: `false` once released, once
    /// the owner is revoked (including a request made by a revoked owner), or
    /// once the fill finished.
    public var isActive: Bool { owner.holds(id) }

    /// Raises or lowers this interest, e.g. to `.visible` when the prefetched
    /// item scrolls on screen. Capped by the owner's ceiling.
    public func setPriority(_ priority: CacheFillPriority) {
        owner.update(id, to: priority)
    }

    public func release() {
        owner.release(id)
    }
}

/// In-flight fills for one kind of content, deduplicated by content key.
///
/// Several independent owners (the vertical feed's lookahead, a grid's, a
/// rail's) can ask for the same key at once: they share ONE fill, which runs
/// at the highest priority still wanted and is cancelled only when no owner
/// (and no awaiting `value(for:)` call) is left.
///
/// P2 (`.speculative`) fills wait for a slot of the `CacheFillSlots` the
/// `CacheCoordinator` shares between every `CacheFills`: at most 2 at once
/// app-wide by default, fewer under Low Power / Low Data / thermal pressure,
/// none while a playing video is under-buffered. P0 and P1 never wait.
///
/// The fill closure stores its result in the cache itself (as a speculative
/// entry for a P2 fill); `CacheFills` only coordinates the work.
public final class CacheFills<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    public typealias Fill = @Sendable (CacheFillContext) async throws -> Value

    private let slots: CacheFillSlots
    private let state = Mutex(State())

    /// - Parameter slots: the coordinator's `fillSlots`.
    public init(slots: CacheFillSlots) {
        self.slots = slots
    }

    /// Registers `owner`'s interest in `key` without waiting: the prefetch
    /// call. Joins the fill in flight for `key` (its `fill` closure is then
    /// unused) or starts one. If `owner` already wants `key` here, its
    /// interest takes the new priority instead.
    ///
    /// A revoked owner registers nothing: the returned interest has
    /// `isActive == false` (see `CacheOwner`).
    @discardableResult
    public func request(_ key: Key, priority: CacheFillPriority, owner: CacheOwner, fill: @escaping Fill) -> CacheFillInterest {
        let ownerID = ObjectIdentifier(owner)
        let existing = state.withLock { $0.jobs[key]?.owners[ownerID]?.interest }
        if let existing, owner.update(existing, to: priority) {
            return CacheFillInterest(owner: owner, id: existing)
        }
        // No live interest of this owner here (none yet, or the old one was
        // just released, revoked, or finished): register a new one.
        let id = takeInterestID()
        state.withLock { _ = $0.pending.insert(id) }
        // Held by the owner BEFORE joining, atomically with its revoked check.
        // A revoke after this point drops the pending id, which cancels the
        // join below; a revoke before it makes `hold` refuse.
        let held = owner.hold(
            id,
            requested: priority,
            reprioritize: { [weak self] in self?.reprioritize(key, interest: id, to: $0) },
            release: { [weak self] in self?.drop(key, interest: id) }
        )
        guard held else {
            state.withLock { _ = $0.pending.remove(id) }
            return .inactive(owner: owner)
        }
        let effective = owner.effective(priority)
        let effects = state.withLock { state -> [Effect] in
            guard state.pending.remove(id) != nil else { return [] }
            return state.join(key, interest: id, priority: effective, fill: fill, waiter: nil, owner: owner, fills: self)
        }
        run(effects)
        return CacheFillInterest(owner: owner, id: id)
    }

    /// The value for `key`, shared with any fill already in flight. The call
    /// counts as an interest while it waits; cancelling the calling task drops
    /// it (and the fill, if nobody else wants it) and throws
    /// `CancellationError`.
    public func value(for key: Key, priority: CacheFillPriority = .visible, fill: @escaping Fill) async throws -> Value {
        let id = takeInterestID()
        state.withLock { _ = $0.pending.insert(id) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                let effects = state.withLock { state -> [Effect] in
                    guard state.pending.remove(id) != nil else {
                        // Cancelled before it could join.
                        return [.resume([continuation], .failure(CancellationError()))]
                    }
                    return state.join(key, interest: id, priority: priority, fill: fill, waiter: continuation, owner: nil, fills: self)
                }
                run(effects)
            }
        } onCancel: {
            drop(key, interest: id)
        }
    }

    /// Whether a fill for `key` is queued or running.
    public func isInFlight(_ key: Key) -> Bool {
        state.withLock { $0.jobs[key] != nil }
    }

    /// The priority `key`'s fill runs at, `nil` if none is in flight.
    public func priority(of key: Key) -> CacheFillPriority? {
        state.withLock { $0.jobs[key]?.effectivePriority }
    }

    /// Whether `key`'s fill is running (not waiting for a slot).
    public func isRunning(_ key: Key) -> Bool {
        state.withLock { $0.jobs[key]?.task != nil }
    }

    /// How many interests (owners and awaiting calls) want `key`.
    public func interestCount(for key: Key) -> Int {
        state.withLock { $0.jobs[key]?.interests.count ?? 0 }
    }

    public var inFlightCount: Int { state.withLock { $0.jobs.count } }

    // MARK: - Internals

    /// Interest ids are unique across every `CacheFills`: one owner holds
    /// interests in several (images and video), keyed by id.
    private func takeInterestID() -> UInt64 {
        CacheFillSlots.makeTicket()
    }

    private func drop(_ key: Key, interest id: UInt64) {
        let effects = state.withLock { state -> [Effect] in
            if state.pending.remove(id) != nil { return [] }
            return state.drop(key, interest: id)
        }
        run(effects)
    }

    private func reprioritize(_ key: Key, interest id: UInt64, to priority: CacheFillPriority) {
        let effects = state.withLock { state -> [Effect] in
            guard var job = state.jobs[key], job.interests[id] != nil else { return [] }
            let before = job.effectivePriority
            job.interests[id] = priority
            state.jobs[key] = job
            return state.priorityChanged(key, from: before, fills: self)
        }
        run(effects)
    }

    fileprivate func slotGranted(_ key: Key, job id: UInt64, ticket: UInt64) {
        let effects = state.withLock { state -> [Effect] in
            guard var job = state.jobs[key], job.id == id, job.task == nil else {
                // Cancelled, or went P0/P1 and started without a slot.
                return [.finishSlot(ticket)]
            }
            job.holdsSlot = true
            state.jobs[key] = job
            state.start(key, fills: self)
            return []
        }
        run(effects)
    }

    fileprivate func complete(_ key: Key, job id: UInt64, result: Result<Value, any Error>) {
        let effects = state.withLock { state -> [Effect] in
            guard let job = state.jobs[key], job.id == id else { return [] }
            state.jobs[key] = nil
            var effects: [Effect] = [.resume(Array(job.waiters.values), result)]
            if job.holdsSlot { effects.append(.finishSlot(job.ticket)) }
            for link in job.owners.values {
                if let owner = link.owner { effects.append(.forget(owner, [link.interest])) }
            }
            return effects
        }
        run(effects)
    }

    /// Side effects decided under the lock, run after it: resuming waiters,
    /// owners, and the shared slot pool (whose grants call back in).
    private func run(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case .resume(let continuations, let result):
                for continuation in continuations { continuation.resume(with: result) }
            case .finishSlot(let ticket):
                slots.finish(ticket: ticket)
            case .notify(let context, let priority):
                context.update(priority)
            case .forget(let owner, let ids):
                owner.forget(ids)
            }
        }
    }

    fileprivate enum Effect {
        case resume([CheckedContinuation<Value, any Error>], Result<Value, any Error>)
        case finishSlot(UInt64)
        case notify(CacheFillContext, CacheFillPriority)
        case forget(CacheOwner, [UInt64])
    }

    fileprivate struct OwnerLink {
        weak var owner: CacheOwner?
        let interest: UInt64
    }

    fileprivate struct Job {
        let id: UInt64
        let ticket: UInt64
        let fill: Fill
        let context: CacheFillContext
        var interests: [UInt64: CacheFillPriority] = [:]
        var waiters: [UInt64: CheckedContinuation<Value, any Error>] = [:]
        var owners: [ObjectIdentifier: OwnerLink] = [:]
        var task: Task<Void, Never>?
        var holdsSlot = false

        var effectivePriority: CacheFillPriority { interests.values.max() ?? .speculative }
    }

    fileprivate struct State {
        var jobs: [Key: Job] = [:]
        /// Interests that have an id but have not joined their job yet.
        var pending: Set<UInt64> = []
        var nextID: UInt64 = 0

        mutating func takeID() -> UInt64 {
            nextID += 1
            return nextID
        }

        mutating func join(
            _ key: Key, interest id: UInt64, priority: CacheFillPriority, fill: @escaping Fill,
            waiter: CheckedContinuation<Value, any Error>?, owner: CacheOwner?, fills: CacheFills
        ) -> [Effect] {
            if var job = jobs[key] {
                let before = job.effectivePriority
                job.interests[id] = priority
                if let waiter { job.waiters[id] = waiter }
                if let owner { job.owners[ObjectIdentifier(owner)] = OwnerLink(owner: owner, interest: id) }
                jobs[key] = job
                return priorityChanged(key, from: before, fills: fills)
            }
            let ticket = CacheFillSlots.makeTicket()
            var job = Job(id: takeID(), ticket: ticket, fill: fill, context: CacheFillContext(priority: priority))
            job.interests[id] = priority
            if let waiter { job.waiters[id] = waiter }
            if let owner { job.owners[ObjectIdentifier(owner)] = OwnerLink(owner: owner, interest: id) }
            jobs[key] = job
            if priority.needsSlot {
                // Asked under this lock, so a drop of the job (which needs the
                // lock) always reaches the pool AFTER the request: no dead
                // ticket is ever left queued. The pool never calls back under
                // its own lock, and a later grant runs outside both.
                let jobID = job.id
                let granted = fills.slots.request(ticket: ticket) { [weak fills] in
                    fills?.slotGranted(key, job: jobID, ticket: ticket)
                }
                guard granted else { return [] }
                job.holdsSlot = true
                jobs[key] = job
            }
            start(key, fills: fills)
            return []
        }

        mutating func drop(_ key: Key, interest id: UInt64) -> [Effect] {
            guard var job = jobs[key], job.interests[id] != nil else { return [] }
            let before = job.effectivePriority
            job.interests[id] = nil
            job.owners = job.owners.filter { $0.value.interest != id }
            var effects: [Effect] = []
            if let waiter = job.waiters.removeValue(forKey: id) {
                effects.append(.resume([waiter], .failure(CancellationError())))
            }
            if job.interests.isEmpty {
                jobs[key] = nil
                job.task?.cancel()
                // Frees a held slot or leaves the queue; harmless if neither.
                effects.append(.finishSlot(job.ticket))
                return effects
            }
            jobs[key] = job
            return effects + priorityChanged(key, from: before, fills: nil)
        }

        /// Reacts to a change of `key`'s highest wanted priority. `fills` is
        /// `nil` when the change can only be a drop (no start needed).
        mutating func priorityChanged(_ key: Key, from before: CacheFillPriority, fills: CacheFills?) -> [Effect] {
            guard var job = jobs[key] else { return [] }
            let after = job.effectivePriority
            guard after != before else { return [] }
            var effects: [Effect] = [.notify(job.context, after)]
            if job.task == nil {
                if !after.needsSlot, let fills {
                    // Promoted out of P2 while queued: start now, leave the queue.
                    effects.append(.finishSlot(job.ticket))
                    start(key, fills: fills)
                }
            } else if job.holdsSlot, !after.needsSlot {
                // Running and promoted: it no longer spends speculative allowance.
                job.holdsSlot = false
                jobs[key] = job
                effects.append(.finishSlot(job.ticket))
            }
            return effects
        }

        mutating func start(_ key: Key, fills: CacheFills) {
            guard var job = jobs[key], job.task == nil else { return }
            let fill = job.fill
            let context = job.context
            let id = job.id
            job.task = Task(priority: job.effectivePriority.taskPriority) {
                let result: Result<Value, any Error>
                do {
                    result = .success(try await fill(context))
                } catch {
                    result = .failure(error)
                }
                fills.complete(key, job: id, result: result)
            }
            jobs[key] = job
        }
    }
}

/// The global allowance of P2 fills running at once, shared by every
/// `CacheFills`. The `CacheCoordinator` owns one and sizes it from its
/// `PrefetchPolicy` (2 by default, 0 under Low Data / Low Power / thermal
/// pressure), and pauses it while a playing video is under-buffered, so the
/// feed's, the grids' and the rails' lookaheads together never exceed what
/// the device and the playing video allow. Waiting fills are granted oldest
/// first.
public final class CacheFillSlots: Sendable {
    private struct Waiting {
        let ticket: UInt64
        let grant: @Sendable () -> Void
    }

    private struct State {
        var limit: Int
        var isPaused = false
        var held: Set<UInt64> = []
        var waiting: [Waiting] = []

        var effectiveLimit: Int { isPaused ? 0 : limit }

        mutating func drain() -> [@Sendable () -> Void] {
            var grants: [@Sendable () -> Void] = []
            while held.count < effectiveLimit, !waiting.isEmpty {
                let chosen = waiting.removeFirst()
                held.insert(chosen.ticket)
                grants.append(chosen.grant)
            }
            return grants
        }
    }

    private static let tickets = Atomic<UInt64>(0)

    static func makeTicket() -> UInt64 {
        tickets.add(1, ordering: .relaxed).newValue
    }

    private let state: Mutex<State>

    public init(limit: Int = PrefetchPolicy.full.maxConcurrentSpeculativeFills) {
        state = Mutex(State(limit: max(0, limit)))
    }

    public var limit: Int { state.withLock { $0.limit } }
    public var isPaused: Bool { state.withLock { $0.isPaused } }
    public var runningCount: Int { state.withLock { $0.held.count } }
    public var waitingCount: Int { state.withLock { $0.waiting.count } }

    /// Fills already running keep running; a lower limit only delays grants.
    public func setLimit(_ limit: Int) {
        let grants = state.withLock { state -> [@Sendable () -> Void] in
            state.limit = max(0, limit)
            return state.drain()
        }
        for grant in grants { grant() }
    }

    /// While paused, no new P2 fill starts (a playing video is under-buffered).
    public func setPaused(_ paused: Bool) {
        let grants = state.withLock { state -> [@Sendable () -> Void] in
            state.isPaused = paused
            return state.drain()
        }
        for grant in grants { grant() }
    }

    /// Takes a slot for `ticket` now and returns `true`, or queues it and
    /// returns `false`; `grant` then runs once a slot frees up, on the thread
    /// that freed it, never under this pool's lock. Never calls `grant`
    /// itself, so a caller may hold its own lock around this call.
    func request(ticket: UInt64, grant: @escaping @Sendable () -> Void) -> Bool {
        state.withLock { state in
            if state.waiting.isEmpty, state.held.count < state.effectiveLimit {
                state.held.insert(ticket)
                return true
            }
            state.waiting.append(Waiting(ticket: ticket, grant: grant))
            return false
        }
    }

    /// Frees `ticket`'s slot, or takes it out of the queue. Idempotent.
    func finish(ticket: UInt64) {
        let grants = state.withLock { state -> [@Sendable () -> Void] in
            state.held.remove(ticket)
            state.waiting.removeAll { $0.ticket == ticket }
            return state.drain()
        }
        for grant in grants { grant() }
    }
}
