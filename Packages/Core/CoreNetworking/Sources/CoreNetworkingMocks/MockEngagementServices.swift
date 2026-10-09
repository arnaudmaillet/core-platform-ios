import Connect
import CoreContracts
import Foundation

/// Shared mutable counter state: seeded like-counts per post, mutated by the
/// engagement mock (likes) and by the demo realtime ticker, read by the
/// counter mock. One source of truth so optimistic UI, reconcile reads, and
/// live ticks all agree.
public final class MockCounterStore: @unchecked Sendable {
    private let lock = NSLock()
    private var likeCounts: [String: Int64] = [:]
    /// Views and comments are read-only projections (no mock mutates them):
    /// deterministic, varied, and shaped like reality — views a magnitude
    /// above likes, comments a fraction of them, an occasional zero.
    private let viewCounts: [String: Int64]
    private let commentCounts: [String: Int64]
    private let postsByAuthor: [String: [String]]

    public init(dataset: MockSocialDataset = MockSocialDataset()) {
        var views: [String: Int64] = [:]
        var comments: [String: Int64] = [:]
        for (index, post) in dataset.posts.enumerated() {
            // A seeded count wins (the world seed's trending posts); the rest
            // keep the array-index formula their fixtures are measured on.
            likeCounts[post.postID] = post.seededLikes ?? Int64(12 + (index * 37) % 900)
            views[post.postID] = Int64(140 + (index * 271) % 24_000)
            comments[post.postID] = Int64((index * 13) % 220)
        }
        viewCounts = views
        commentCounts = comments
        postsByAuthor = Dictionary(grouping: dataset.posts, by: \.authorProfileID)
            .mapValues { $0.map(\.postID) }
    }

    public func likeCount(for postID: String) -> Int64 {
        lock.withLock { likeCounts[postID] ?? 0 }
    }

    public func viewCount(for postID: String) -> Int64 {
        viewCounts[postID] ?? 0
    }

    public func commentCount(for postID: String) -> Int64 {
        commentCounts[postID] ?? 0
    }

    /// Profile-scoped LIKE: the sum of like counts across the author's posts —
    /// what counter.v1 projects as a profile's total received reactions. A
    /// profile with no posts truthfully reads 0.
    public func totalLikes(forAuthor profileID: String) -> Int64 {
        lock.withLock {
            (postsByAuthor[profileID] ?? []).reduce(0) { $0 + (likeCounts[$1] ?? 0) }
        }
    }

    // MARK: Likes are points (#676)

    /// Points per target ("post:<id>" / "comment:<id>") per account.
    private var stakes: [String: [String: Int64]] = [:]
    /// A comment's like count: the sum of its points (comments have no seed).
    private var commentLikes: [String: Int64] = [:]

    /// The account's points on the target.
    public func myLikes(account: String, target: String) -> Int64 {
        lock.withLock { stakes[target]?[account] ?? 0 }
    }

    /// The target's count: a post's seeded likes plus every point staked,
    /// a comment's points.
    public func likeCount(target: String) -> Int64 {
        if target.hasPrefix("post:") { return likeCount(for: String(target.dropFirst(5))) }
        return lock.withLock { commentLikes[String(target.dropFirst(8))] ?? 0 }
    }

    /// Puts `points` of the account on the target: its total and the
    /// target's count both move.
    @discardableResult
    public func stake(_ points: Int64, account: String, target: String) -> Int64 {
        lock.withLock {
            let mine = (stakes[target]?[account] ?? 0) + points
            stakes[target, default: [:]][account] = mine
            if target.hasPrefix("post:") {
                let id = String(target.dropFirst(5))
                likeCounts[id] = (likeCounts[id] ?? 0) + points
            } else {
                let id = String(target.dropFirst(8))
                commentLikes[id] = (commentLikes[id] ?? 0) + points
            }
            return mine
        }
    }

    @discardableResult
    public func incrementLikes(for postID: String, by delta: Int64) -> Int64 {
        lock.withLock {
            let next = max(0, (likeCounts[postID] ?? 0) + delta)
            likeCounts[postID] = next
            return next
        }
    }
}

/// Fake of engagement.v1's like reads (#676): `GetPostEngagement` and
/// `BatchGetLikes` over the shared store. The likes themselves are written by
/// `MockWalletService.Stake` — the reactions are gone from the contracts.
public final class MockEngagementService: @unchecked Sendable {
    private let store: MockCounterStore

    public init(store: MockCounterStore) {
        self.store = store
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/engagement.v1.EngagementService/GetPostEngagement") { [self] (request: Engagement_V1_GetPostEngagementRequest, headers: Headers) -> Result<Engagement_V1_PostEngagementView, ConnectError> in
            let target = "post:" + request.postID
            var view = Engagement_V1_PostEngagementView()
            view.postID = request.postID
            view.likeCount = store.likeCount(target: target)
            view.myLikes = Self.account(from: headers).map { store.myLikes(account: $0, target: target) } ?? 0
            view.viewCount = store.viewCount(for: request.postID)
            view.commentCount = store.commentCount(for: request.postID)
            return .success(view)
        }
        bff.register(path: "/engagement.v1.EngagementService/BatchGetLikes") { [self] (request: Engagement_V1_BatchGetLikesRequest, headers: Headers) -> Result<Engagement_V1_BatchGetLikesResponse, ConnectError> in
            guard request.targets.count <= 100 else {
                return .failure(ConnectError(code: .invalidArgument, message: "at most 100 targets"))
            }
            let account = Self.account(from: headers)
            var response = Engagement_V1_BatchGetLikesResponse()
            response.likes = request.targets.map { target in
                let key = Self.key(target)
                var view = Engagement_V1_LikeView()
                view.target = target
                view.count = store.likeCount(target: key)
                view.mine = account.map { store.myLikes(account: $0, target: key) } ?? 0
                return view
            }
            return .success(response)
        }
    }

    /// The caller's account; nil for a guest or no token (`mine` is 0).
    static func account(from headers: Headers) -> String? {
        MockEdgePolicy.caller(from: headers) == .member ? MockAuthService.accountID : nil
    }

    static func key(_ target: Engagement_V1_LikeTarget) -> String {
        switch target.target {
        case .postID(let id): "post:" + id
        case .commentID(let id): "comment:" + id
        case nil: ""
        }
    }
}

/// Fake of wallet.v1 `Stake` (#676): a like is a point. The server's rules
/// (backend `crates/services/wallet/README.md`), in its order: a batch over
/// 24 h old is EXPIRED; one's own post is OWN_CONTENT; a shot needs room for
/// a whole 100; a plain batch is clamped to the target's room (250 per
/// account, ever), the balance and the hour's room (1,000), and refused with
/// the binding limit when nothing fits. Replays of a key answer the first
/// answer and spend nothing.
///
/// The balance is generous (`startingPoints`): the app's own wallet is still
/// local (`WalletStore`), and a mock that ran out first would refund likes the
/// app had shown.
public final class MockWalletService: @unchecked Sendable {
    public static let startingPoints: Int64 = 100_000
    static let perTargetCap: Int64 = 250
    static let hourlyCap: Int64 = 1_000
    static let pointsPerShot: Int64 = 100

    private let store: MockCounterStore
    private let dataset: MockSocialDataset
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var spentPoints: [String: Int64] = [:]
    private var hourLedger: [String: [(Date, Int64)]] = [:]
    private var answers: [String: Wallet_V1_StakeResponse] = [:]

    public init(store: MockCounterStore, dataset: MockSocialDataset, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.dataset = dataset
        self.now = now
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/wallet.v1.WalletService/Stake") { [self] (request: Wallet_V1_StakeRequest, headers: Headers) -> Result<Wallet_V1_StakeResponse, ConnectError> in
            stake(request, caller: MockEngagementService.account(from: headers))
        }
    }

    func stake(_ request: Wallet_V1_StakeRequest, caller: String?) -> Result<Wallet_V1_StakeResponse, ConnectError> {
        guard let caller else { return .failure(ConnectError(code: .unauthenticated, message: "sign in to like")) }
        guard request.accountID == caller else {
            return .failure(ConnectError(code: .permissionDenied, message: "another account's wallet"))
        }
        let key = request.idempotencyKey
        guard (8...64).contains(key.count),
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return .failure(ConnectError(code: .invalidArgument, message: "idempotency_key")) }
        let target: String
        switch request.target {
        case .postID(let id): target = "post:" + id
        case .commentID(let id): target = "comment:" + id
        case nil: return .failure(ConnectError(code: .invalidArgument, message: "target"))
        }
        guard request.useStakeShot || request.points > 0 else {
            return .failure(ConnectError(code: .invalidArgument, message: "points"))
        }
        return .success(lock.withLock {
            if let answer = answers["\(caller)/\(key)"] { return answer }
            let answer = decideLocked(request, account: caller, target: target)
            answers["\(caller)/\(key)"] = answer
            return answer
        })
    }

    private func decideLocked(_ request: Wallet_V1_StakeRequest, account: String, target: String) -> Wallet_V1_StakeResponse {
        let moment = now()
        var response = Wallet_V1_StakeResponse()
        let mine = store.myLikes(account: account, target: target)
        func answer(_ outcome: Wallet_V1_StakeOutcome, spent: Int64 = 0, total: Int64? = nil) -> Wallet_V1_StakeResponse {
            response.outcome = outcome
            response.spent = Int32(spent)
            response.myTotal = Int32(total ?? mine)
            var wallet = Wallet_V1_Wallet()
            wallet.accountID = account
            wallet.points = Self.startingPoints - (spentPoints[account] ?? 0)
            response.wallet = wallet
            return response
        }
        if request.hasFirstTapAt, moment.timeIntervalSince(request.firstTapAt.date) > 24 * 3600 {
            return answer(.expired)
        }
        if case .postID(let id) = request.target,
           let post = dataset.posts.first(where: { $0.postID == id }),
           dataset.accountID(for: post.authorProfileID) == account {
            return answer(.ownContent)
        }
        let balance = Self.startingPoints - (spentPoints[account] ?? 0)
        let recent = (hourLedger[account] ?? []).filter { moment.timeIntervalSince($0.0) < 3600 }
        let hourRoom = Self.hourlyCap - recent.reduce(0) { $0 + $1.1 }
        let room = Self.perTargetCap - mine
        let spend: Int64
        if request.useStakeShot {
            guard room > 0 else { return answer(.targetCapReached) }
            guard room >= Self.pointsPerShot else { return answer(.shotDoesNotFit) }
            guard balance >= Self.pointsPerShot else { return answer(.insufficientBalance) }
            guard hourRoom >= Self.pointsPerShot else { return answer(.rateLimited) }
            spend = Self.pointsPerShot
        } else {
            guard room > 0 else { return answer(.targetCapReached) }
            guard balance > 0 else { return answer(.insufficientBalance) }
            guard hourRoom > 0 else { return answer(.rateLimited) }
            spend = min(Int64(request.points), room, balance, hourRoom)
        }
        spentPoints[account, default: 0] += spend
        hourLedger[account] = recent + [(moment, spend)]
        let total = store.stake(spend, account: account, target: target)
        return answer(.staked, spent: spend, total: total)
    }
}

/// Fake of counter.v1.BatchGetCounters over the shared store: positional
/// snapshots, LIKE metric only — post-scoped per post, profile-scoped as the
/// author's aggregate. Other metrics (follower/following/view) are never
/// answered, mirroring the fleet's unprojected read-model so clients exercise
/// their fallback/unavailable paths.
public final class MockCounterService: @unchecked Sendable {
    private let store: MockCounterStore

    public init(store: MockCounterStore) {
        self.store = store
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/counter.v1.CounterService/BatchGetCounters") { [self] (request: Counter_V1_BatchGetCountersRequest) in
            batchGetCounters(request)
        }
    }

    private func batchGetCounters(_ request: Counter_V1_BatchGetCountersRequest) -> Result<Counter_V1_BatchGetCountersResponse, ConnectError> {
        // An empty metric filter means "everything you have", per the contract.
        let wantsLike = request.metrics.isEmpty || request.metrics.contains(.like)
        let wantsView = request.metrics.isEmpty || request.metrics.contains(.view)
        let wantsComment = request.metrics.isEmpty || request.metrics.contains(.comment)

        var response = Counter_V1_BatchGetCountersResponse()
        response.snapshots = request.entities.map { entity in
            var snapshot = Counter_V1_CounterSnapshot()
            snapshot.entity = entity
            func append(_ metric: Counter_V1_CounterMetric, _ count: Int64) {
                var value = Counter_V1_CounterValue()
                value.metric = metric
                value.value = count
                value.kind = .exact
                snapshot.values.append(value)
            }
            if wantsLike {
                append(.like, entity.entityType == .profile
                    ? store.totalLikes(forAuthor: entity.id)
                    : store.likeCount(for: entity.id))
            }
            // Views and comments are projected for POSTS only, as the fleet's
            // read-model does. No client surface reads views any more (the
            // mock's sound ranking reads the store directly); they stay
            // answered so a `.view` request still gets the contract's shape.
            if entity.entityType == .post {
                if wantsView { append(.view, store.viewCount(for: entity.id)) }
                if wantsComment { append(.comment, store.commentCount(for: entity.id)) }
            }
            return snapshot
        }
        return .success(response)
    }
}
