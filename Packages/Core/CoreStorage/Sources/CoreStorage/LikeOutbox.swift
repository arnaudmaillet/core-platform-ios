import Foundation

/// The likes waiting to be sent (#676): a like is a POINT staked through
/// `wallet.v1.WalletService/Stake`, and the taps on one post are batched on
/// the device before they are committed.
///
/// ## The rules (backend #665, `crates/services/wallet/README.md`)
///
/// - Taps on a target accumulate in its OPEN batch, 1 point each.
/// - A batch is committed 10 s after its last tap (`idleCommitDelay`), when
///   the viewer moves on from the post (`seal(target:)`), or when the app goes
///   to the background (`sealAll()`). A sealed batch takes no more taps; the
///   next tap opens a new one.
/// - Every batch carries its own `idempotencyKey` and the time of its first
///   tap, and is retried with that same key until the server answers — the
///   server credits it once. A batch whose first tap is over 24 h old comes
///   back `EXPIRED`.
/// - A ×100 shot is a batch of its own, sealed at once.
///
/// Persisted (UserDefaults, JSON), so taps survive a relaunch or a lost
/// connection. Each batch remembers the account and profile that made it, so
/// a profile switch before the commit still likes as the profile that tapped.
///
/// This type only keeps the queue; `LikeOutboxSender` (Feed) commits it.
public final class LikeOutbox: @unchecked Sendable {
    /// What is liked.
    public enum Target: Codable, Hashable, Sendable {
        case post(String)
        case comment(String)
    }

    /// One batch: a run of taps on one target, or one shot.
    public struct Batch: Codable, Equatable, Sendable {
        public let target: Target
        /// Points asked (1 per tap). Ignored by the server for a shot.
        public var points: Int
        public let usesStakeShot: Bool
        /// 8–64 of `[A-Za-z0-9_-]`, one per batch, kept across retries.
        public let idempotencyKey: String
        public let firstTapAt: Date
        public var lastTapAt: Date
        /// Taking no more taps: committed, or being committed.
        public var isSealed: Bool
        /// Who tapped (`StorageScope.Owner` at the first tap); nil outside a
        /// member scope.
        public let accountID: String?
        public let profileID: String?

        public init(
            target: Target, points: Int, usesStakeShot: Bool, idempotencyKey: String,
            firstTapAt: Date, lastTapAt: Date, isSealed: Bool, accountID: String?, profileID: String?
        ) {
            self.target = target
            self.points = points
            self.usesStakeShot = usesStakeShot
            self.idempotencyKey = idempotencyKey
            self.firstTapAt = firstTapAt
            self.lastTapAt = lastTapAt
            self.isSealed = isSealed
            self.accountID = accountID
            self.profileID = profileID
        }
    }

    /// How long after a target's last tap its batch is committed.
    public static let idleCommitDelay: TimeInterval = 10

    /// Fired after every change, `object:` the outbox.
    public static let didChangeNotification = Notification.Name("likeOutbox.didChange")

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let scope: StorageScope

    public init(
        defaults: UserDefaults = .standard,
        key: String = "likes.outbox.v1",
        scope: StorageScope = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.key = key
        self.scope = scope
        self.now = now
    }

    // MARK: - Taps

    /// Adds `points` taps to the target's open batch, opening one if needed.
    public func record(points: Int, on target: Target) {
        guard points > 0 else { return }
        let moment = now()
        mutate { batches in
            if let index = batches.lastIndex(where: { $0.target == target && !$0.isSealed && !$0.usesStakeShot }) {
                batches[index].points += points
                batches[index].lastTapAt = moment
            } else {
                batches.append(makeBatch(target: target, points: points, shot: false, at: moment))
            }
        }
    }

    /// One ×100 shot on the target: a batch of its own, committed at once.
    public func recordShot(on target: Target, points: Int) {
        mutate { batches in
            var batch = makeBatch(target: target, points: points, shot: true, at: now())
            batch.isSealed = true
            batches.append(batch)
        }
    }

    /// Takes back up to `points` taps not yet committed on the target — the
    /// only undo there is: a committed like is final. Returns how many were
    /// taken back.
    @discardableResult
    public func cancel(points: Int, on target: Target) -> Int {
        var taken = 0
        mutate { batches in
            guard let index = batches.lastIndex(where: { $0.target == target && !$0.isSealed && !$0.usesStakeShot })
            else { return }
            taken = min(points, batches[index].points)
            batches[index].points -= taken
            if batches[index].points == 0 { batches.remove(at: index) }
        }
        return taken
    }

    /// The taps on the target not yet committed (what an undo can take back).
    public func pendingPoints(on target: Target) -> Int {
        load().filter { $0.target == target && !$0.isSealed && !$0.usesStakeShot }.reduce(0) { $0 + $1.points }
    }

    // MARK: - Committing

    /// The viewer moved on from the target: its open batch is committed now.
    public func seal(target: Target) {
        mutate { batches in
            for index in batches.indices where batches[index].target == target {
                batches[index].isSealed = true
            }
        }
    }

    /// The app is leaving the foreground: every open batch is committed.
    public func sealAll() {
        mutate { batches in
            for index in batches.indices { batches[index].isSealed = true }
        }
    }

    /// The batches to commit now: the sealed ones, and the open ones idle
    /// for `idleCommitDelay` — which are sealed on the way out, so a tap
    /// landing while one is in flight opens a new batch.
    public func takeDue() -> [Batch] {
        let moment = now()
        var due: [Batch] = []
        mutate { batches in
            for index in batches.indices {
                if !batches[index].isSealed,
                   moment.timeIntervalSince(batches[index].lastTapAt) >= Self.idleCommitDelay {
                    batches[index].isSealed = true
                }
                if batches[index].isSealed { due.append(batches[index]) }
            }
        }
        return due
    }

    /// When the next open batch falls due, if any.
    public var nextDueDate: Date? {
        load().filter { !$0.isSealed }.map { $0.lastTapAt.addingTimeInterval(Self.idleCommitDelay) }.min()
    }

    /// The server answered the batch: it leaves the queue.
    public func complete(_ idempotencyKey: String) {
        mutate { batches in batches.removeAll { $0.idempotencyKey == idempotencyKey } }
    }

    /// Every batch, in order.
    public var batches: [Batch] { load() }

    // MARK: - Storage

    private func makeBatch(target: Target, points: Int, shot: Bool, at moment: Date) -> Batch {
        let owner = scope.owner
        var account: String?
        var profile: String?
        if case .member(let a, let p) = owner {
            account = a
            profile = p
        }
        return Batch(
            target: target, points: points, usesStakeShot: shot,
            idempotencyKey: Self.newKey(), firstTapAt: moment, lastTapAt: moment,
            isSealed: false, accountID: account, profileID: profile
        )
    }

    /// 32 hex characters: inside the server's 8–64 `[A-Za-z0-9_-]`.
    static func newKey() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func load() -> [Batch] {
        lock.withLock { loadLocked() }
    }

    private func loadLocked() -> [Batch] {
        guard let data = defaults.data(forKey: key),
              let batches = try? JSONDecoder().decode([Batch].self, from: data)
        else { return [] }
        return batches
    }

    private func mutate(_ change: (inout [Batch]) -> Void) {
        let changed: Bool = lock.withLock {
            var batches = loadLocked()
            let before = batches
            change(&batches)
            guard batches != before else { return false }
            defaults.set(try? JSONEncoder().encode(batches), forKey: key)
            return true
        }
        if changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}
