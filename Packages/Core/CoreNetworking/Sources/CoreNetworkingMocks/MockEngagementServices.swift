import Connect
import CoreContracts
import Foundation
import SwiftProtobuf

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

    // MARK: Likes, the currency a like stakes (#676)

    /// Points per target ("post:<id>" / "comment:<id>") per account.
    private var stakes: [String: [String: Int64]] = [:]
    /// A comment's like count: the sum of its likes (comments have no seed).
    private var commentLikes: [String: Int64] = [:]
    /// The posts each account first staked on, newest last (#411).
    private var likedPostsInOrder: [String: [String]] = [:]

    /// The posts `account` liked, newest first: what `ListLikesByProfile`
    /// lists (#411).
    public func likedPosts(by account: String) -> [String] {
        lock.withLock { (likedPostsInOrder[account] ?? []).reversed() }
    }

    /// The account's likes on the target.
    public func myLikes(account: String, target: String) -> Int64 {
        lock.withLock { stakes[target]?[account] ?? 0 }
    }

    /// The target's count: a post's seeded likes plus every like staked,
    /// a comment's likes.
    public func likeCount(target: String) -> Int64 {
        if target.hasPrefix("post:") { return likeCount(for: String(target.dropFirst(5))) }
        return lock.withLock { commentLikes[String(target.dropFirst(8))] ?? 0 }
    }

    /// Puts `likes` of the account on the target: its total and the
    /// target's count both move.
    @discardableResult
    public func stake(_ likes: Int64, account: String, target: String) -> Int64 {
        lock.withLock {
            let mine = (stakes[target]?[account] ?? 0) + likes
            stakes[target, default: [:]][account] = mine
            if target.hasPrefix("post:") {
                let id = String(target.dropFirst(5))
                if mine == likes, likes > 0 { likedPostsInOrder[account, default: []].append(id) }
                likeCounts[id] = (likeCounts[id] ?? 0) + likes
            } else {
                let id = String(target.dropFirst(8))
                commentLikes[id] = (commentLikes[id] ?? 0) + likes
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
///
/// And its saves (#837): `SavePost` / `UnsavePost` / `ListSavedPosts`, kept
/// per profile, most recently saved first, as the backend does — a re-save
/// keeps its place (its first save time), unsaving what isn't saved is a
/// no-op, and a list is its owner's alone (no profile shows its Saved tab in
/// the mock: anyone else reads it empty).
///
/// ⚠️ The app's mock keeps the saves across launches (`persistence`), as the
/// server would: the app pushes its pile once per profile, so a mock that
/// forgot them at every launch answered an empty list and wiped the pile.
public final class MockEngagementService: @unchecked Sendable {
    private static let persistenceKey = "mock.engagement.saves"
    private let store: MockCounterStore
    /// Whose profiles a caller may save as; nil: any (tests without one).
    private let dataset: MockSocialDataset?
    private let persistence: UserDefaults?
    private let lock = NSLock()
    /// Per profile, most recently saved first.
    private var saves: [String: [String]] {
        didSet { persistence?.set(saves, forKey: Self.persistenceKey) }
    }

    public init(store: MockCounterStore, dataset: MockSocialDataset? = nil, persistence: UserDefaults? = nil) {
        self.store = store
        self.dataset = dataset
        self.persistence = persistence
        // `-reset-bookmarks` (the app's QA hook) empties the server's saves
        // too: the device's pile would otherwise come back with the list.
        if ProcessInfo.processInfo.arguments.contains("-reset-bookmarks") {
            persistence?.removeObject(forKey: Self.persistenceKey)
        }
        saves = persistence?.dictionary(forKey: Self.persistenceKey) as? [String: [String]] ?? [:]
    }

    /// The posts `profileID` saved, most recent first.
    public func savedPostIDs(of profileID: String) -> [String] {
        lock.withLock { saves[profileID] ?? [] }
    }

    public func register(on bff: MockBFF) {
        registerSaves(on: bff)
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

    private func registerSaves(on bff: MockBFF) {
        bff.register(path: "/engagement.v1.EngagementService/SavePost") { [self] (request: Engagement_V1_SavePostRequest, headers: Headers) -> Result<Engagement_V1_SavePostResponse, ConnectError> in
            if let refusal = refusal(account: request.accountID, profile: request.profileID, headers: headers) {
                return .failure(refusal)
            }
            guard !request.postID.isEmpty else {
                return .failure(ConnectError(code: .invalidArgument, message: "post_id is required"))
            }
            lock.withLock {
                var list = saves[request.profileID] ?? []
                if !list.contains(request.postID) { list.insert(request.postID, at: 0) }
                saves[request.profileID] = list
            }
            return .success(Engagement_V1_SavePostResponse())
        }
        bff.register(path: "/engagement.v1.EngagementService/UnsavePost") { [self] (request: Engagement_V1_UnsavePostRequest, headers: Headers) -> Result<Engagement_V1_UnsavePostResponse, ConnectError> in
            if let refusal = refusal(account: request.accountID, profile: request.profileID, headers: headers) {
                return .failure(refusal)
            }
            lock.withLock { saves[request.profileID]?.removeAll { $0 == request.postID } }
            return .success(Engagement_V1_UnsavePostResponse())
        }
        bff.register(path: "/engagement.v1.EngagementService/ListSavedPosts") { [self] (request: Engagement_V1_ListSavedPostsRequest, headers: Headers) -> Result<Engagement_V1_ListSavedPostsResponse, ConnectError> in
            var response = Engagement_V1_ListSavedPostsResponse()
            guard let caller = Self.account(from: headers), owns(caller, request.profileID) else {
                return .success(response)
            }
            let all = savedPostIDs(of: request.profileID)
            let limit = request.limit <= 0 ? 30 : min(Int(request.limit), 100)
            let start = Int(request.pageToken) ?? 0
            guard start >= 0, start <= all.count else {
                return .failure(ConnectError(code: .invalidArgument, message: "bad page_token"))
            }
            let end = min(start + limit, all.count)
            response.posts = all[start..<end].map { id in
                var view = Engagement_V1_SavedPostView()
                view.postID = id
                view.profileID = request.profileID
                return view
            }
            response.nextPageToken = end < all.count ? String(end) : ""
            return .success(response)
        }
    }

    /// Why a save as `account`/`profile` is refused, as the backend words
    /// it: a guest, another account, a profile not the account's.
    private func refusal(account: String, profile: String, headers: Headers) -> ConnectError? {
        guard let caller = Self.account(from: headers) else {
            return ConnectError(code: .unauthenticated, message: "sign in to save posts")
        }
        guard account == caller, owns(caller, profile) else {
            return ConnectError(code: .permissionDenied, message: "may not act as the requested account")
        }
        return nil
    }

    private func owns(_ account: String, _ profile: String) -> Bool {
        guard let dataset else { return !profile.isEmpty }
        return dataset.profileIDs(inAccount: account).contains(profile)
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

/// Fake of wallet.v1 (#676, #1098): `Stake`, `GetWallet` and `ClaimReward`
/// over one wallet per account.
///
/// **Stake**, with the server's rules (backend `crates/services/wallet/README.md`),
/// in its order: a batch over 24 h old is EXPIRED; one's own post is
/// OWN_CONTENT; a shot needs room for a whole 100; a plain batch is clamped
/// to the target's room (250 per account, ever), the balance and the hour's
/// room (1,000), and refused with the binding limit when nothing fits.
/// Replays of a key answer the first answer and spend nothing.
///
/// **The hourly claim** (charter V5.3 §4.1): 25 points × the streak multiplier
/// (1 + 0.1 a day, at most ×2), once an hour, at most 200 a UTC day, clamped
/// under `points_cap` (2,000); at the cap the claim is BALANCE_FULL with no
/// `next_claim_at` — only spending opens it again. Refusals come back
/// in-band with the whole wallet. A replayed key answers the first answer.
///
/// `startingLikes` is what a wallet opens with: the app's mock opens at the
/// charter's 250; package tests keep a generous balance so a stake rule, not
/// the balance, is what they meet. `persistence` keeps the wallets across
/// launches, as the server does.
public final class MockWalletService: @unchecked Sendable {
    public static let generousStartingLikes: Int64 = 100_000
    static let perTargetCap: Int64 = 250
    static let hourlyCap: Int64 = 1_000
    static let likesPerShot: Int64 = 100
    static let claimInterval: TimeInterval = 3_600
    static let baseClaim: Double = 25
    static let dailyClaimCap: Int64 = 200
    public static let likesCap: Int64 = 2_000
    static let starterGems: Int64 = 100
    static let stakePackPrice: Int64 = 50
    static let stakePackShots: Int32 = 3
    /// The packs on sale (#941), smallest first — the client's mock tiers.
    static let stakePacks: [(id: String, shots: Int32, price: Int64)] = [
        ("shots_3", 3, 50), ("shots_10", 10, 150), ("shots_25", 25, 325),
    ]
    /// The gem catalogue (#892): the wallet service's default
    /// `WALLET_CATALOG`, in display order; 0 = free, owned by everyone.
    static let catalog: [(id: String, price: Int64)] = [
        ("theme.pink", 0), ("theme.violet", 50), ("theme.red", 50),
        ("frame.gold", 60), ("frame.neon", 60), ("frame.aurora", 60),
        ("banner.animated", 500),
        ("card.paper", 80), ("card.night", 80), ("card.mint", 80),
        ("avatar.animated", 500),
    ]
    private static let persistenceKey = "mock.wallet.accounts"

    /// One account's wallet, as the server keeps it.
    struct Account: Codable, Equatable {
        var likes: Int64
        var gems: Int64
        var likesEarned: Int64 = 0
        var likesSpent: Int64 = 0
        var stakeShots: Int32 = 0
        var claimedToday: Int64 = 0
        /// The UTC day `claimedToday` counts ("yyyy-MM-dd").
        var claimDay: String = ""
        var streakDays: Int32 = 0
        var lastClaimAt: Date?
        /// Every target staked on, newest first stake first (#903). Optional:
        /// wallets kept before stakes were listed decode without it.
        var positions: [Position]?
        /// The wallet's history, oldest first (#400). Optional, as above.
        var ledger: [LedgerEntry]?
        /// The pack the shots came from (#941), and the catalogue items
        /// bought (#892). Optional, as above.
        var stakePackID: String?
        var owned: [String]?

        /// The mock's wallets are kept under `mock.wallet.accounts` with
        /// their "points" keys (#1397): renamed, every kept wallet would
        /// reset once.
        enum CodingKeys: String, CodingKey {
            case likes = "points"
            case gems
            case likesEarned = "pointsEarned"
            case likesSpent = "pointsSpent"
            case stakeShots, claimedToday, claimDay, streakDays, lastClaimAt, positions, ledger
            case stakePackID, owned
        }

        /// Records one movement of the gems, with the balance right after.
        mutating func recordGems(_ kind: Wallet_V1_TransactionKind, delta: Int64, at moment: Date, ref: String = "") {
            var entries = ledger ?? []
            entries.append(LedgerEntry(
                id: "tx-\(entries.count + 1)", gems: true, delta: delta, balanceAfter: gems,
                kind: kind.rawValue, at: moment, ref: ref
            ))
            ledger = entries
        }

        /// Records one movement, with the balance right after.
        mutating func record(_ kind: Wallet_V1_TransactionKind, likes delta: Int64, at moment: Date, ref: String = "") {
            var entries = ledger ?? []
            entries.append(LedgerEntry(
                id: "tx-\(entries.count + 1)", gems: false, delta: delta, balanceAfter: likes,
                kind: kind.rawValue, at: moment, ref: ref
            ))
            ledger = entries
        }
    }

    /// One ledger row (#400), as kept.
    struct LedgerEntry: Codable, Equatable {
        var id: String
        var gems: Bool
        var delta: Int64
        var balanceAfter: Int64
        var kind: Int
        var at: Date
        var ref: String
    }

    /// One target's stakes, all batches together.
    struct Position: Codable, Equatable {
        var target: String
        var likes: Int64
        var firstAt: Date
        var lastAt: Date

        enum CodingKeys: String, CodingKey {
            case target
            case likes = "points"
            case firstAt, lastAt
        }
    }

    /// Positions settle a day after their first stake (backend #886).
    static let settlementDelay: TimeInterval = 24 * 3_600

    private let store: MockCounterStore
    private let dataset: MockSocialDataset
    private let now: @Sendable () -> Date
    private let startingLikes: Int64
    private let persistence: UserDefaults?
    /// Posts a new wallet opens with stakes on, some settled — so the
    /// sheet's lists are not empty on a fresh install (the app's mock).
    private let demoPositions: [String]
    private let lock = NSLock()
    private var accounts: [String: Account] {
        didSet {
            guard let persistence, let data = try? JSONEncoder().encode(accounts) else { return }
            persistence.set(data, forKey: Self.persistenceKey)
        }
    }
    private var hourLedger: [String: [(Date, Int64)]] = [:]
    private var answers: [String: Wallet_V1_StakeResponse] = [:]
    /// A pack's or an item's answer per key (#1475): a retry charges once.
    private var spendAnswers: [String: Int] = [:]
    private var claimAnswers: [String: Wallet_V1_ClaimRewardResponse] = [:]
    /// Whether `account` may stake on `postID` at all: a post it may not
    /// read (taken down, deleted, withheld — `MockSocialServices.mayReadPost`)
    /// is not stakeable, and the points come back (#1409).
    private let mayStakeOnPost: @Sendable (_ account: String, _ postID: String) -> Bool

    public init(
        store: MockCounterStore,
        dataset: MockSocialDataset,
        startingLikes: Int64 = MockWalletService.generousStartingLikes,
        persistence: UserDefaults? = nil,
        demoPositions: [String] = [],
        now: @escaping @Sendable () -> Date = { Date() },
        mayStakeOnPost: @escaping @Sendable (_ account: String, _ postID: String) -> Bool = { _, _ in true }
    ) {
        self.mayStakeOnPost = mayStakeOnPost
        self.demoPositions = demoPositions
        self.store = store
        self.dataset = dataset
        self.startingLikes = startingLikes
        self.persistence = persistence
        self.now = now
        // `-wallet-reset` (the app's QA hook) opens every wallet afresh.
        if ProcessInfo.processInfo.arguments.contains("-wallet-reset") {
            persistence?.removeObject(forKey: Self.persistenceKey)
        }
        accounts = persistence?.data(forKey: Self.persistenceKey)
            .flatMap { try? JSONDecoder().decode([String: Account].self, from: $0) } ?? [:]
        #if DEBUG
        // `-wallet-gems N` (the app's QA hook): every wallet holds exactly N
        // gems, the server's balance now that a member's gems are its (#1475).
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-wallet-gems"), index + 1 < arguments.count,
           let gems = Int64(arguments[index + 1]) {
            debugGems = gems
            accounts = accounts.mapValues { account in
                var dressed = account
                dressed.gems = gems
                return dressed
            }
        }
        #endif
    }

    /// DEBUG `-wallet-gems N`: what a wallet opens with instead of the
    /// starter gems.
    private var debugGems: Int64?

    public func register(on bff: MockBFF) {
        bff.register(path: "/wallet.v1.WalletService/Stake") { [self] (request: Wallet_V1_StakeRequest, headers: Headers) -> Result<Wallet_V1_StakeResponse, ConnectError> in
            stake(request, caller: MockEngagementService.account(from: headers))
        }
        bff.register(path: "/wallet.v1.WalletService/GetWallet") { [self] (request: Wallet_V1_GetWalletRequest, headers: Headers) -> Result<Wallet_V1_Wallet, ConnectError> in
            if let refusal = Self.refusal(request.accountID, caller: MockEngagementService.account(from: headers)) {
                return .failure(refusal)
            }
            return .success(lock.withLock { walletLocked(request.accountID, at: now()) })
        }
        bff.register(path: "/wallet.v1.WalletService/ClaimReward") { [self] (request: Wallet_V1_ClaimRewardRequest, headers: Headers) -> Result<Wallet_V1_ClaimRewardResponse, ConnectError> in
            claim(request, caller: MockEngagementService.account(from: headers))
        }
        bff.register(path: "/wallet.v1.WalletService/ListWalletTransactions") { [self] (request: Wallet_V1_ListWalletTransactionsRequest, headers: Headers) -> Result<Wallet_V1_ListWalletTransactionsResponse, ConnectError> in
            if let refusal = Self.refusal(request.accountID, caller: MockEngagementService.account(from: headers)) {
                return .failure(refusal)
            }
            return .success(lock.withLock { transactionsLocked(request) })
        }
        bff.register(path: "/wallet.v1.WalletService/ListMyStakes") { [self] (request: Wallet_V1_ListMyStakesRequest, headers: Headers) -> Result<Wallet_V1_ListMyStakesResponse, ConnectError> in
            if let refusal = Self.refusal(request.accountID, caller: MockEngagementService.account(from: headers)) {
                return .failure(refusal)
            }
            return .success(lock.withLock { myStakesLocked(request) })
        }
        bff.register(path: "/wallet.v1.WalletService/BuyStakePack") { [self] (request: Wallet_V1_BuyStakePackRequest, headers: Headers) -> Result<Wallet_V1_BuyStakePackResponse, ConnectError> in
            buyStakePack(request, caller: MockEngagementService.account(from: headers))
        }
        bff.register(path: "/wallet.v1.WalletService/PurchaseItem") { [self] (request: Wallet_V1_PurchaseItemRequest, headers: Headers) -> Result<Wallet_V1_PurchaseItemResponse, ConnectError> in
            purchaseItem(request, caller: MockEngagementService.account(from: headers))
        }
        bff.register(path: "/wallet.v1.WalletService/ListOwnedItems") { [self] (request: Wallet_V1_ListOwnedItemsRequest, headers: Headers) -> Result<Wallet_V1_ListOwnedItemsResponse, ConnectError> in
            if let refusal = Self.refusal(request.accountID, caller: MockEngagementService.account(from: headers)) {
                return .failure(refusal)
            }
            return .success(lock.withLock { ownedItemsLocked(request.accountID) })
        }
        bff.register(path: "/wallet.v1.WalletService/ListCatalog") { (_: Wallet_V1_ListCatalogRequest, _: Headers) -> Result<Wallet_V1_ListCatalogResponse, ConnectError> in
            var response = Wallet_V1_ListCatalogResponse()
            response.items = Self.catalog.map { entry in
                var item = Wallet_V1_CatalogItem()
                item.itemID = entry.id
                item.family = Self.family(of: entry.id)
                item.price = entry.price
                return item
            }
            return .success(response)
        }
    }

    // MARK: Spending gems (#1475)

    /// The catalogue family an item id names (`<family>.<name>`).
    static func family(of itemID: String) -> Wallet_V1_ItemFamily {
        switch itemID.split(separator: ".").first {
        case "theme": .theme
        case "icon": .appIcon
        case "frame": .avatarFrame
        case "banner": .animatedBanner
        case "card": .cardStyle
        case "avatar": .animatedAvatar
        default: .unspecified
        }
    }

    /// The history row a purchase of `family` writes.
    private static func kind(of family: Wallet_V1_ItemFamily) -> Wallet_V1_TransactionKind {
        switch family {
        case .theme: .theme
        case .appIcon: .appIcon
        case .avatarFrame: .avatarFrame
        case .animatedBanner: .animatedBanner
        case .cardStyle: .cardStyle
        case .animatedAvatar: .animatedAvatar
        default: .unspecified
        }
    }

    /// A pack bought with gems: refused while the current one has shots
    /// (packs don't stack). A replayed key answers the first answer.
    func buyStakePack(_ request: Wallet_V1_BuyStakePackRequest, caller: String?) -> Result<Wallet_V1_BuyStakePackResponse, ConnectError> {
        if let refusal = Self.refusal(request.accountID, caller: caller) { return .failure(refusal) }
        guard Self.isValidKey(request.idempotencyKey) else {
            return .failure(ConnectError(code: .invalidArgument, message: "WAL-9002: idempotency_key"))
        }
        let packID = request.packID.isEmpty ? Self.stakePacks[0].id : request.packID
        guard let pack = Self.stakePacks.first(where: { $0.id == packID }) else {
            return .failure(ConnectError(code: .invalidArgument, message: "WAL-9005: pack_id"))
        }
        return .success(lock.withLock {
            let replayKey = "pack/\(request.accountID)/\(request.idempotencyKey)"
            var response = Wallet_V1_BuyStakePackResponse()
            if let outcome = spendAnswers[replayKey] {
                response.outcome = Wallet_V1_StakePackOutcome(rawValue: outcome) ?? .unspecified
            } else {
                var wallet = accountLocked(request.accountID)
                if wallet.stakeShots > 0 {
                    response.outcome = .packStillActive
                } else if wallet.gems < pack.price {
                    response.outcome = .insufficientGems
                } else {
                    wallet.gems -= pack.price
                    wallet.recordGems(.stakePack, delta: -pack.price, at: now(), ref: pack.id)
                    wallet.stakeShots = pack.shots
                    wallet.stakePackID = pack.id
                    accounts[request.accountID] = wallet
                    response.outcome = .bought
                }
                spendAnswers[replayKey] = response.outcome.rawValue
            }
            response.wallet = walletLocked(request.accountID, at: now())
            return response
        })
    }

    /// A catalogue item bought with gems, once for good; free and owned ones
    /// charge nothing. A replayed key answers the first answer.
    func purchaseItem(_ request: Wallet_V1_PurchaseItemRequest, caller: String?) -> Result<Wallet_V1_PurchaseItemResponse, ConnectError> {
        if let refusal = Self.refusal(request.accountID, caller: caller) { return .failure(refusal) }
        guard Self.isValidKey(request.idempotencyKey) else {
            return .failure(ConnectError(code: .invalidArgument, message: "WAL-9002: idempotency_key"))
        }
        return .success(lock.withLock {
            let replayKey = "item/\(request.accountID)/\(request.idempotencyKey)"
            var response = Wallet_V1_PurchaseItemResponse()
            if let outcome = spendAnswers[replayKey] {
                response.outcome = Wallet_V1_PurchaseOutcome(rawValue: outcome) ?? .unspecified
            } else {
                var wallet = accountLocked(request.accountID)
                let owned = Set(wallet.owned ?? [])
                if let item = Self.catalog.first(where: { $0.id == request.itemID }) {
                    if item.price == 0 || owned.contains(item.id) {
                        response.outcome = .alreadyOwned
                    } else if request.expectedPrice != item.price {
                        response.outcome = .priceChanged
                    } else if wallet.gems < item.price {
                        response.outcome = .insufficientGems
                    } else {
                        wallet.gems -= item.price
                        wallet.recordGems(Self.kind(of: Self.family(of: item.id)), delta: -item.price, at: now(), ref: item.id)
                        wallet.owned = (wallet.owned ?? []) + [item.id]
                        accounts[request.accountID] = wallet
                        response.outcome = .purchased
                    }
                } else {
                    response.outcome = .unknownItem
                }
                spendAnswers[replayKey] = response.outcome.rawValue
            }
            response.wallet = walletLocked(request.accountID, at: now())
            return response
        })
    }

    /// Free items first, then the bought ones, oldest first.
    private func ownedItemsLocked(_ account: String) -> Wallet_V1_ListOwnedItemsResponse {
        var response = Wallet_V1_ListOwnedItemsResponse()
        let free = Self.catalog.filter { $0.price == 0 }.map(\.id)
        let bought = accountLocked(account).owned ?? []
        response.items = (free + bought).map { id in
            var item = Wallet_V1_OwnedItem()
            item.itemID = id
            item.family = Self.family(of: id)
            return item
        }
        return response
    }

    private static func refusal(_ account: String, caller: String?) -> ConnectError? {
        guard let caller else { return ConnectError(code: .unauthenticated, message: "sign in for a wallet") }
        guard account == caller else { return ConnectError(code: .permissionDenied, message: "another account's wallet") }
        return nil
    }

    private static func isValidKey(_ key: String) -> Bool {
        (8...64).contains(key.count)
            && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// The account's likes, as the server holds them (tests).
    public func likes(of account: String) -> Int64 {
        lock.withLock { accountLocked(account).likes }
    }

    /// The welcome gift (backend #934, #1008, #943): a flat 50, credited
    /// once per device — whoever signs in on it — when a guest becomes a
    /// member (the owner, 2026-10-14, #1146: the daily growth is gone).
    /// Returns the amount.
    @discardableResult
    public func creditWelcomeGift(account: String, device: String) -> Int64 {
        lock.withLock {
            let key = "welcome:" + device
            guard accounts[key] == nil else { return 0 }
            let amount: Int64 = 50
            var wallet = accountLocked(account)
            wallet.likes += amount
            wallet.likesEarned += amount
            wallet.record(.welcomeGift, likes: amount, at: now())
            accounts[account] = wallet
            // The device's mark, kept with the wallets so it survives too.
            accounts[key] = Account(likes: 0, gems: 0)
            return amount
        }
    }

    // MARK: The wallet

    private func accountLocked(_ id: String) -> Account {
        if let account = accounts[id] { return account }
        var opened = Account(likes: startingLikes, gems: debugGems ?? Self.starterGems)
        // The wallet opens with its starter gems — and, in the mock, its
        // starting points — as the first rows of its history.
        let openedAt = now().addingTimeInterval(-7 * 86_400)
        opened.ledger = [
            LedgerEntry(id: "tx-0", gems: true, delta: Self.starterGems, balanceAfter: Self.starterGems,
                        kind: Wallet_V1_TransactionKind.starterGift.rawValue, at: openedAt, ref: ""),
            LedgerEntry(id: "tx-00", gems: false, delta: startingLikes, balanceAfter: startingLikes,
                        kind: Wallet_V1_TransactionKind.starterGift.rawValue, at: openedAt, ref: ""),
        ]
        // Demo stakes placed before the wallet "opened", seven hours apart:
        // some active, some settled — and, a few hours on, one whose day has
        // just settled shows PENDING for an hour.
        let moment = now()
        opened.positions = demoPositions.enumerated().map { index, post in
            let first = moment.addingTimeInterval(-Double(index) * 7 * 3_600 - 1_800)
            return Position(target: "post:" + post, likes: Int64(1 + index * 7 % 40), firstAt: first, lastAt: first)
        }
        return opened
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func day(_ date: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The streak a claim at `moment` continues (0: none to continue).
    private static func streak(_ account: Account, at moment: Date) -> Int32 {
        guard let last = account.lastClaimAt else { return 0 }
        let lastDay = utc.startOfDay(for: last)
        let today = utc.startOfDay(for: moment)
        let days = utc.dateComponents([.day], from: lastDay, to: today).day ?? 0
        return days <= 1 ? account.streakDays : 0
    }

    private enum ClaimState { case available(amount: Int64), tooEarly(Date), dailyCap(Date), full }

    private func claimStateLocked(_ account: Account, at moment: Date) -> ClaimState {
        let claimedToday = account.claimDay == Self.day(moment) ? account.claimedToday : 0
        if account.likes >= Self.likesCap { return .full }
        if claimedToday >= Self.dailyClaimCap {
            return .dailyCap(Self.utc.date(byAdding: .day, value: 1, to: Self.utc.startOfDay(for: moment))!)
        }
        if let last = account.lastClaimAt, moment < last.addingTimeInterval(Self.claimInterval) {
            return .tooEarly(last.addingTimeInterval(Self.claimInterval))
        }
        let continuing = Self.streak(account, at: moment)
        let isNewDay = account.lastClaimAt.map { Self.day($0) != Self.day(moment) } ?? true
        let streak = isNewDay ? continuing + 1 : max(continuing, 1)
        let multiplier = min(2, 1 + 0.1 * Double(streak - 1))
        let amount = min(Int64((Self.baseClaim * multiplier).rounded()), Self.dailyClaimCap - claimedToday, Self.likesCap - account.likes)
        return .available(amount: amount)
    }

    private func walletLocked(_ id: String, at moment: Date) -> Wallet_V1_Wallet {
        let account = accountLocked(id)
        var wallet = Wallet_V1_Wallet()
        wallet.accountID = id
        wallet.points = account.likes
        wallet.gems = account.gems
        wallet.pointsEarned = account.likesEarned
        wallet.pointsSpent = account.likesSpent
        wallet.stakeShots = account.stakeShots
        wallet.stakePackID = account.stakeShots > 0 ? account.stakePackID ?? Self.stakePacks[0].id : ""
        wallet.stakePacks = Self.stakePacks.map { pack in
            var offer = Wallet_V1_StakePackOffer()
            offer.packID = pack.id
            offer.shots = pack.shots
            offer.price = pack.price
            return offer
        }
        wallet.claimedToday = Int32(account.claimDay == Self.day(moment) ? account.claimedToday : 0)
        wallet.dailyClaimCap = Int32(Self.dailyClaimCap)
        wallet.streakDays = Self.streak(account, at: moment)
        if let last = account.lastClaimAt { wallet.lastClaimAt = Google_Protobuf_Timestamp(date: last) }
        wallet.pointsCap = Self.likesCap
        wallet.stakePackPrice = Self.stakePackPrice
        wallet.stakePackShots = Self.stakePackShots
        wallet.pointsPerShot = Int32(Self.likesPerShot)
        switch claimStateLocked(account, at: moment) {
        case .available(let amount):
            wallet.claimAvailable = true
            wallet.claimAmount = Int32(amount)
        case .tooEarly(let next), .dailyCap(let next):
            wallet.nextClaimAt = Google_Protobuf_Timestamp(date: next)
        case .full:
            break
        }
        return wallet
    }

    // MARK: The history (#400)

    /// The account's ledger, newest first, by currency, paged by offset.
    private func transactionsLocked(_ request: Wallet_V1_ListWalletTransactionsRequest) -> Wallet_V1_ListWalletTransactionsResponse {
        let entries = (accountLocked(request.accountID).ledger ?? [])
            .reversed()
            .filter { entry in
                switch request.currency {
                case .points: !entry.gems
                case .gems: entry.gems
                default: true
                }
            }
        let all = Array(entries)
        let size = request.pageSize <= 0 ? 50 : min(Int(request.pageSize), 100)
        let start = min(max(Int(request.pageToken) ?? 0, 0), all.count)
        let end = min(start + size, all.count)
        var response = Wallet_V1_ListWalletTransactionsResponse()
        response.transactions = all[start..<end].map { entry in
            var transaction = Wallet_V1_WalletTransaction()
            transaction.transactionID = entry.id
            transaction.currency = entry.gems ? .gems : .points
            transaction.delta = entry.delta
            transaction.balanceAfter = entry.balanceAfter
            transaction.kind = Wallet_V1_TransactionKind(rawValue: entry.kind) ?? .unspecified
            transaction.createdAt = Google_Protobuf_Timestamp(date: entry.at)
            transaction.refID = entry.ref
            return transaction
        }
        response.nextPageToken = end < all.count ? String(end) : ""
        return response
    }

    // MARK: The stakes (#903)

    /// The account's positions, newest first stake first, filtered by
    /// status and paged by an offset token. Settlement runs in shadow mode:
    /// a settled position has a verdict and no gems — PENDING for its first
    /// hour, then REWARDED or NOT_REWARDED (stable per target).
    private func myStakesLocked(_ request: Wallet_V1_ListMyStakesRequest) -> Wallet_V1_ListMyStakesResponse {
        let moment = now()
        let positions = (accountLocked(request.accountID).positions ?? [])
            .sorted { $0.firstAt > $1.firstAt }
            .filter { position in
                let settled = moment >= position.firstAt.addingTimeInterval(Self.settlementDelay)
                switch request.status {
                case .active: return !settled
                case .settled: return settled
                default: return true
                }
            }
        let size = request.pageSize <= 0 ? 50 : min(Int(request.pageSize), 100)
        let start = min(max(Int(request.pageToken) ?? 0, 0), positions.count)
        let end = min(start + size, positions.count)
        var response = Wallet_V1_ListMyStakesResponse()
        response.stakes = positions[start..<end].map { position in
            var stake = Wallet_V1_MyStake()
            if position.target.hasPrefix("post:") {
                stake.postID = String(position.target.dropFirst(5))
            } else {
                stake.commentID = String(position.target.dropFirst(8))
            }
            stake.points = position.likes
            stake.firstAt = Google_Protobuf_Timestamp(date: position.firstAt)
            stake.lastAt = Google_Protobuf_Timestamp(date: position.lastAt)
            let settlesAt = position.firstAt.addingTimeInterval(Self.settlementDelay)
            stake.settlesAt = Google_Protobuf_Timestamp(date: settlesAt)
            if moment >= settlesAt {
                stake.settledAt = Google_Protobuf_Timestamp(date: settlesAt)
                if moment < settlesAt.addingTimeInterval(3_600) {
                    stake.verdict = .pending
                } else {
                    let hash = position.target.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
                    stake.verdict = hash % 100 < 55 ? .rewarded : .notRewarded
                }
            }
            return stake
        }
        response.nextPageToken = end < positions.count ? String(end) : ""
        return response
    }

    // MARK: The claim

    func claim(_ request: Wallet_V1_ClaimRewardRequest, caller: String?) -> Result<Wallet_V1_ClaimRewardResponse, ConnectError> {
        if let refusal = Self.refusal(request.accountID, caller: caller) { return .failure(refusal) }
        guard Self.isValidKey(request.idempotencyKey) else {
            return .failure(ConnectError(code: .invalidArgument, message: "WAL-9002: idempotency_key"))
        }
        return .success(lock.withLock {
            let replayKey = "\(request.accountID)/\(request.idempotencyKey)"
            if var answer = claimAnswers[replayKey] {
                answer.wallet = walletLocked(request.accountID, at: now())
                return answer
            }
            let moment = now()
            var account = accountLocked(request.accountID)
            var response = Wallet_V1_ClaimRewardResponse()
            switch claimStateLocked(account, at: moment) {
            case .available(let amount):
                let today = Self.day(moment)
                let continuing = Self.streak(account, at: moment)
                let isNewDay = account.lastClaimAt.map { Self.day($0) != today } ?? true
                account.streakDays = isNewDay ? continuing + 1 : max(continuing, 1)
                account.claimedToday = (account.claimDay == today ? account.claimedToday : 0) + amount
                account.claimDay = today
                account.lastClaimAt = moment
                account.likes += amount
                account.likesEarned += amount
                account.record(.claim, likes: amount, at: moment)
                accounts[request.accountID] = account
                response.outcome = .claimed
                response.awarded = Int32(amount)
            case .tooEarly:
                response.outcome = .tooEarly
            case .dailyCap:
                response.outcome = .dailyCapReached
            case .full:
                response.outcome = .balanceFull
            }
            response.wallet = walletLocked(request.accountID, at: moment)
            claimAnswers[replayKey] = response
            return response
        })
    }

    // MARK: Stakes

    func stake(_ request: Wallet_V1_StakeRequest, caller: String?) -> Result<Wallet_V1_StakeResponse, ConnectError> {
        guard let caller else { return .failure(ConnectError(code: .unauthenticated, message: "sign in to like")) }
        guard request.accountID == caller else {
            return .failure(ConnectError(code: .permissionDenied, message: "another account's wallet"))
        }
        let key = request.idempotencyKey
        guard Self.isValidKey(key) else { return .failure(ConnectError(code: .invalidArgument, message: "idempotency_key")) }
        let target: String
        switch request.target {
        case .postID(let id): target = "post:" + id
        case .commentID(let id): target = "comment:" + id
        case nil: return .failure(ConnectError(code: .invalidArgument, message: "target"))
        }
        guard request.useStakeShot || request.points > 0 else {
            return .failure(ConnectError(code: .invalidArgument, message: "points"))
        }
        // Asked OUTSIDE the wallet's lock: the rule reaches into the social
        // services and the graph, each behind a lock of its own.
        let stakeable: Bool
        if case .postID(let id) = request.target {
            stakeable = mayStakeOnPost(caller, id)
        } else {
            stakeable = true
        }
        return .success(lock.withLock {
            if let answer = answers["\(caller)/\(key)"] { return answer }
            let answer = decideLocked(request, account: caller, target: target, stakeable: stakeable)
            answers["\(caller)/\(key)"] = answer
            return answer
        })
    }

    private func decideLocked(
        _ request: Wallet_V1_StakeRequest, account: String, target: String, stakeable: Bool = true
    ) -> Wallet_V1_StakeResponse {
        let moment = now()
        var response = Wallet_V1_StakeResponse()
        let mine = store.myLikes(account: account, target: target)
        func answer(_ outcome: Wallet_V1_StakeOutcome, spent: Int64 = 0, total: Int64? = nil) -> Wallet_V1_StakeResponse {
            response.outcome = outcome
            response.spent = Int32(spent)
            response.myTotal = Int32(total ?? mine)
            response.wallet = walletLocked(account, at: moment)
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
        if !stakeable { return answer(.targetNotStakeable) }
        var wallet = accountLocked(account)
        let balance = wallet.likes
        let recent = (hourLedger[account] ?? []).filter { moment.timeIntervalSince($0.0) < 3600 }
        let hourRoom = Self.hourlyCap - recent.reduce(0) { $0 + $1.1 }
        let room = Self.perTargetCap - mine
        let spend: Int64
        if request.useStakeShot {
            // The pack's shots are the server's (#1475): none left, none fired.
            guard wallet.stakeShots > 0 else { return answer(.noStakeShots) }
            guard room > 0 else { return answer(.targetCapReached) }
            guard room >= Self.likesPerShot else { return answer(.shotDoesNotFit) }
            guard balance >= Self.likesPerShot else { return answer(.insufficientBalance) }
            guard hourRoom >= Self.likesPerShot else { return answer(.rateLimited) }
            spend = Self.likesPerShot
        } else {
            guard room > 0 else { return answer(.targetCapReached) }
            guard balance > 0 else { return answer(.insufficientBalance) }
            guard hourRoom > 0 else { return answer(.rateLimited) }
            spend = min(Int64(request.points), room, balance, hourRoom)
        }
        wallet.likes -= spend
        wallet.likesSpent += spend
        if request.useStakeShot { wallet.stakeShots -= 1 }
        wallet.record(.stake, likes: -spend, at: moment, ref: target)
        var positions = wallet.positions ?? []
        if let index = positions.firstIndex(where: { $0.target == target }) {
            positions[index].likes += spend
            positions[index].lastAt = moment
        } else {
            positions.append(Position(target: target, likes: spend, firstAt: moment, lastAt: moment))
        }
        wallet.positions = positions
        accounts[account] = wallet
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
