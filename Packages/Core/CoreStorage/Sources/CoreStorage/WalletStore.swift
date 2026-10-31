import Foundation

/// One reading of the viewer's wallet: everything the UI renders, resolved
/// at a single instant so two labels on one screen can never disagree about
/// what time it is.
public struct WalletSnapshot: Equatable, Sendable {
    /// Spendable likes, never negative.
    public let balance: Int
    /// Whether tapping Claim right now would pay out.
    public let claimAvailable: Bool
    /// When the next claim unlocks. `nil` exactly when `claimAvailable` —
    /// there is nothing to count down to.
    public let nextClaimAt: Date?
    /// What the NEXT claim pays (streak multiplier and daily cap applied).
    public let claimAmount: Int
    /// Likes earned via claims in the current UTC day.
    public let claimedToday: Int
    /// The day's earning ceiling — policy, surfaced so the UI never hardcodes it.
    public let dailyClaimCap: Int
    /// Consecutive UTC days with at least one claim. 0 when the chain is
    /// broken (no claim yesterday or today), not the stale last value.
    public let streakDays: Int
    /// Gems (the charter's currency B) earned by stakes that have settled —
    /// earned-only, so it is the sum of their rewards and nothing else.
    public let gems: Int
    /// Shots left in the viewer's ×100 cartridge pack (`Policy.StakePack`);
    /// 0 when no pack is active.
    public let stakeShots: Int
    /// The balance a claim never takes past — the server's (`Wallet.points_cap`,
    /// #1098); nil while the wallet is the local mock's.
    public var likesCap: Int? = nil
}

/// The viewer's wallet as the server holds it (wallet.v1 `GetWallet`, and the
/// `Wallet` every `ClaimReward` answers with, #1098): the likes and the
/// hourly claim. The server is the clock — availability and the countdown
/// are its answer, never decided on the device.
public struct WalletServerState: Codable, Equatable, Sendable {
    public var likes: Int
    public var claimAvailable: Bool
    /// When the next claim opens; nil while available, and nil at the
    /// likes cap, where no wait opens it — only spending does.
    public var nextClaimAt: Date?
    public var claimAmount: Int
    public var claimedToday: Int
    public var dailyClaimCap: Int
    public var streakDays: Int
    public var likesCap: Int
    /// The member's gems (#1475): the server's balance, the one the Shop
    /// spends — never a device count.
    public var gems: Int
    /// Shots left in the stake pack, and the pack they came from.
    public var stakeShots: Int
    public var stakePackID: String?
    /// The packs on sale (#941), smallest first; empty from a server that
    /// predates them.
    public var stakePacks: [WalletStore.Policy.StakePack.Tier]
    /// Under 18 or age unknown: no gem may be spent (`WAL-3001`).
    public var gemSpendingRestricted: Bool

    /// ⚠️ THE STORED KEYS ARE TODAY'S (#1397): the last wallet the server
    /// sent is kept as JSON and read with `try?`; a renamed key would drop
    /// it on the update. The gems' keys came later (#1475) and decode with a
    /// default, so a wallet stored before them still reads.
    enum CodingKeys: String, CodingKey {
        case likes = "points"
        case claimAvailable, nextClaimAt, claimAmount, claimedToday, dailyClaimCap, streakDays
        case likesCap = "pointsCap"
        case gems, stakeShots, stakePackID, stakePacks, gemSpendingRestricted
    }

    public init(
        likes: Int, claimAvailable: Bool, nextClaimAt: Date?, claimAmount: Int,
        claimedToday: Int, dailyClaimCap: Int, streakDays: Int, likesCap: Int,
        gems: Int = 0, stakeShots: Int = 0, stakePackID: String? = nil,
        stakePacks: [WalletStore.Policy.StakePack.Tier] = [], gemSpendingRestricted: Bool = false
    ) {
        self.likes = likes
        self.claimAvailable = claimAvailable
        self.nextClaimAt = nextClaimAt
        self.claimAmount = claimAmount
        self.claimedToday = claimedToday
        self.dailyClaimCap = dailyClaimCap
        self.streakDays = streakDays
        self.likesCap = likesCap
        self.gems = gems
        self.stakeShots = stakeShots
        self.stakePackID = stakePackID
        self.stakePacks = stakePacks
        self.gemSpendingRestricted = gemSpendingRestricted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        likes = try container.decode(Int.self, forKey: .likes)
        claimAvailable = try container.decode(Bool.self, forKey: .claimAvailable)
        nextClaimAt = try container.decodeIfPresent(Date.self, forKey: .nextClaimAt)
        claimAmount = try container.decode(Int.self, forKey: .claimAmount)
        claimedToday = try container.decode(Int.self, forKey: .claimedToday)
        dailyClaimCap = try container.decode(Int.self, forKey: .dailyClaimCap)
        streakDays = try container.decode(Int.self, forKey: .streakDays)
        likesCap = try container.decode(Int.self, forKey: .likesCap)
        gems = try container.decodeIfPresent(Int.self, forKey: .gems) ?? 0
        stakeShots = try container.decodeIfPresent(Int.self, forKey: .stakeShots) ?? 0
        stakePackID = try container.decodeIfPresent(String.self, forKey: .stakePackID)
        stakePacks = (try? container.decodeIfPresent([WalletStore.Policy.StakePack.Tier].self, forKey: .stakePacks)) ?? []
        gemSpendingRestricted = try container.decodeIfPresent(Bool.self, forKey: .gemSpendingRestricted) ?? false
    }
}

/// Where a member's wallet is read and claimed (#1098): wallet.v1, as the
/// signed-in account. The app hands its one to `WalletStore.server`; a
/// store without one (tests, previews, a guest's) keeps the local mock.
public protocol WalletServer: Sendable {
    func wallet() async throws -> WalletServerState
    /// One claim. `idempotencyKey` (8–64 of `[A-Za-z0-9_-]`) is minted once
    /// per tap and sent again with every retry of it: the server credits a
    /// key at most once. Refusals are outcomes, with the wallet as it is.
    func claim(idempotencyKey: String) async throws -> (outcome: WalletClaimOutcome, wallet: WalletServerState)
    /// The member's stakes (wallet.v1 `ListMyStakes`, #903): active and
    /// settled, newest first stake first.
    func myStakes() async throws -> [WalletStake]
    /// A page of the wallet's history (wallet.v1 `ListWalletTransactions`,
    /// #400), newest first; nil `currency` lists both.
    func transactions(currency: WalletTransaction.Currency?, after pageToken: String?) async throws -> WalletTransactionPage
    /// Buys a stake pack with the member's gems (wallet.v1 `BuyStakePack`,
    /// #1475). A retry with the same key charges at most once.
    func buyStakePack(packID: String, idempotencyKey: String) async throws
        -> (outcome: WalletStakePackPurchase, wallet: WalletServerState)
    /// Buys a catalogue item (wallet.v1 `PurchaseItem`, #1475) at the price
    /// the app showed; another price answers `priceChanged`.
    func purchaseItem(itemID: String, expectedPrice: Int, idempotencyKey: String) async throws
        -> (outcome: WalletItemPurchase, wallet: WalletServerState)
    /// The catalogue items the member owns (wallet.v1 `ListOwnedItems`).
    func ownedItems() async throws -> [String]
    /// The gem catalogue (wallet.v1 `ListCatalog`): every item's price.
    func catalog() async throws -> [WalletCatalogItem]
}

public extension WalletServer {
    /// Servers that list no stakes: the device's.
    func myStakes() async throws -> [WalletStake] { [] }
    /// Servers with no history.
    func transactions(currency: WalletTransaction.Currency?, after pageToken: String?) async throws -> WalletTransactionPage {
        WalletTransactionPage(transactions: [], nextPageToken: nil)
    }
    /// Servers that sell nothing.
    func buyStakePack(packID: String, idempotencyKey: String) async throws
        -> (outcome: WalletStakePackPurchase, wallet: WalletServerState) {
        throw WalletServerUnsupported()
    }
    func purchaseItem(itemID: String, expectedPrice: Int, idempotencyKey: String) async throws
        -> (outcome: WalletItemPurchase, wallet: WalletServerState) {
        throw WalletServerUnsupported()
    }
    func ownedItems() async throws -> [String] { throw WalletServerUnsupported() }
    func catalog() async throws -> [WalletCatalogItem] { throw WalletServerUnsupported() }
}

/// A server that does not carry what was asked.
public struct WalletServerUnsupported: Error, Equatable {
    public init() {}
}

/// One item of the gem catalogue (wallet.v1 `CatalogItem`).
public struct WalletCatalogItem: Equatable, Sendable {
    /// `<family>.<name>`, e.g. `theme.violet`.
    public let id: String
    /// In gems; 0 = free, owned by every account.
    public let price: Int

    public init(id: String, price: Int) {
        self.id = id
        self.price = price
    }
}

/// What buying a catalogue item did (wallet.v1 `PurchaseOutcome`, #1475).
public enum WalletItemPurchase: Equatable, Sendable {
    case purchased(remainingGems: Int)
    /// Owned already, or free: nothing charged.
    case alreadyOwned
    case insufficientGems(needed: Int, have: Int)
    /// The price is no longer the one shown: nothing charged. The current
    /// one when the catalogue could be read again.
    case priceChanged(price: Int?)
    /// Not on sale, or not for this account (a guest, an under-18 —
    /// `WAL-3001`): nothing charged.
    case unavailable
    /// The server could not be asked: nothing changed, and the same key goes
    /// again with a retry.
    case failed
}

/// One movement of the wallet (#400): a claim, a stake, a gift…
public struct WalletTransaction: Equatable, Sendable, Identifiable, Hashable {
    public enum Currency: Equatable, Sendable, Hashable { case likes, gems }
    public enum Kind: Equatable, Sendable, Hashable {
        case claim, starterGift, stakePack, countryUnlock, stake, welcomeGift
        /// Gem purchases from the catalogue (wallet.v1, #892); `reference`
        /// names the item, the country, the slot or the profile.
        case appIcon, theme, countryVisa, profileSlot, handleChange
        case avatarFrame, animatedBanner, cardStyle, animatedAvatar
        /// A kind this build does not know — shown plainly, never hidden.
        case other
    }

    public let id: String
    public let currency: Currency
    /// Positive: credited; negative: spent.
    public let delta: Int
    public let balanceAfter: Int
    public let kind: Kind
    public let createdAt: Date?
    /// What it was for, when it names something (a country's code).
    public let reference: String?

    public init(
        id: String, currency: Currency, delta: Int, balanceAfter: Int, kind: Kind, createdAt: Date?, reference: String?
    ) {
        self.id = id
        self.currency = currency
        self.delta = delta
        self.balanceAfter = balanceAfter
        self.kind = kind
        self.createdAt = createdAt
        self.reference = reference
    }
}

public struct WalletTransactionPage: Equatable, Sendable {
    public let transactions: [WalletTransaction]
    /// Nil on the last page.
    public let nextPageToken: String?

    public init(transactions: [WalletTransaction], nextPageToken: String?) {
        self.transactions = transactions
        self.nextPageToken = nextPageToken
    }
}

/// A stake of likes (the charter's currency A) on a post or comment, and
/// what it came to.
///
/// ⚠️ **SETTLEMENT IS DEFERRED, BY DESIGN** (charter V5.3 §33): a stake is
/// ACTIVE until `settlesAt`, and only then has an outcome — a reward in gems,
/// or none. A member's stakes are the server's (`ListMyStakes`, #903), settled
/// in shadow mode — a verdict, no gems, until backend #890. A store with no
/// server (package tests) derives the outcome here from the target and the
/// amount (`Policy.mockOutcome`) — stable, so a stake never changes its mind
/// between two readings.
public struct WalletStake: Equatable, Sendable, Identifiable {
    public enum Outcome: Equatable, Sendable {
        /// The stake was judged to have carried information: gems earned.
        case gems(Int)
        /// Settled with nothing earned — popularity alone pays nothing.
        case noReward
        /// The server's verdicts (#903), shown without gems while settlement
        /// runs in shadow mode — the app never shows gems the balance does
        /// not hold. Settled, the day's result not computed yet.
        case pending
        /// The stake was rewarded (its gems arrive once minting is live).
        case rewarded
        /// Settled, not rewarded.
        case notRewarded
    }

    /// The post (or comment) staked on.
    public let targetID: String
    /// Likes committed, all stakes on this target together.
    public let amount: Int
    /// When the first of them was placed.
    public let stakedAt: Date

    public init(targetID: String, amount: Int, stakedAt: Date, settlesAt: Date, outcome: Outcome?) {
        self.targetID = targetID
        self.amount = amount
        self.stakedAt = stakedAt
        self.settlesAt = settlesAt
        self.outcome = outcome
    }
    /// When the stake settles.
    public let settlesAt: Date
    /// Nil while the stake is still active.
    public let outcome: Outcome?

    public var id: String { targetID }
    public var isSettled: Bool { outcome != nil }
    /// The gems it earned, 0 while active or when it earned none.
    public var gems: Int {
        if case .gems(let earned) = outcome { return earned }
        return 0
    }
}

public extension WalletSnapshot {
    /// The wait toward `nextClaimAt` as (how far along, seconds left),
    /// measured against the hourly claim interval — the shape the badge's
    /// progress ring renders. Nil when nothing is pending (claim available,
    /// or no countdown at all). A capped day unlocks at UTC midnight, which
    /// can be farther than one interval away: the fraction clamps to 0
    /// until the final hour, which reads honestly as "not soon".
    var claimCountdown: (fraction: Double, remaining: TimeInterval)? {
        guard !claimAvailable, let nextClaimAt else { return nil }
        let remaining = max(0, nextClaimAt.timeIntervalSinceNow)
        guard remaining > 0 else { return nil }
        let fraction = 1 - min(1, remaining / WalletStore.Policy.claimInterval)
        return (fraction, remaining)
    }
}

/// What a claim attempt did — in-band states, not errors, because the UI
/// renders all three (the backend spec's `ClaimOutcome`, verbatim).
public enum WalletClaimOutcome: Equatable, Sendable {
    case claimed(awarded: Int)
    case tooEarly(nextClaimAt: Date)
    case dailyCapReached
    /// The balance is at the likes cap (#901): nothing was credited, and
    /// only spending likes opens the claim again.
    case balanceFull
    /// The server could not be asked (offline, or it failed): nothing
    /// changed, and the same key goes again with the retry.
    case unavailable
}

/// What a gems spend did.
public enum WalletGemSpend: Equatable, Sendable {
    case spent(remaining: Int)
    case insufficient(gems: Int)
}

/// What one stake asks the wallet for: a plain amount of likes (a tap's
/// default), or one SHOT of the ×100 cartridge pack — `Policy.StakePack.
/// likesPerShot` likes in one gesture, and one shot off the pack.
///
/// Either way the likes are the viewer's own: a shot is a CONVENIENCE bought
/// with gems (one tap instead of a hundred), never likes (charter V5.3 §34, B ─X→ A).
public enum WalletStakeSpend: Equatable, Sendable {
    case likes(Int)
    case shot
}

/// What buying a ×100 cartridge pack did.
public enum WalletStakePackPurchase: Equatable, Sendable {
    /// The gems left, and the pack's shots now loaded.
    case bought(shots: Int, remainingGems: Int)
    /// Packs don't stack: the current one still has shots, nothing changed.
    case packStillActive(shotsLeft: Int)
    case insufficientGems(needed: Int, have: Int)
    /// The server could not be asked, or refused the account (#1475):
    /// nothing changed.
    case unavailable
}

/// What a boost spend did (the backend spec's `BoostOutcome`, minus the
/// server-only cases a local ledger cannot produce).
public enum WalletBoostOutcome: Equatable, Sendable {
    /// `spent` is what actually left the wallet — a request that would
    /// overshoot the per-target cap is CLAMPED to the cap's remainder, and
    /// every receipt (float, session tally) must be written from this
    /// number, never from the requested amount.
    case boosted(newBalance: Int, targetTotal: Int, spent: Int)
    case insufficientBalance(balance: Int)
    /// The target already holds the viewer's whole allowance
    /// (`Policy.perTargetBoostCap`); nothing changed.
    case targetCapReached(targetTotal: Int)
    /// A shot was asked for with no pack loaded; nothing changed.
    case noShotsLeft
    /// A shot was asked for on a post with room for only `room` more of the
    /// viewer's likes — fewer than a shot's whole amount. A shot is never
    /// clamped (it always means `Policy.StakePack.likesPerShot`), so it is
    /// refused and kept; nothing changed. The menu's "Only N likes more fit
    /// on this post".
    case shotDoesNotFit(room: Int)
}

/// The viewer's point wallet and boost ledger.
///
/// **A mock with the real contract's shape, and it says so.** The backend has
/// no wallet service yet (`BACKEND_VIRTUAL_CURRENCY.md` is the ask); until it
/// does, this store IS the wallet — device-local, per-install, and trusting
/// the device clock, which are exactly the three lies the spec tells the
/// backend team to make impossible server-side. Every outcome enum here
/// mirrors the proposed wire contract, so binding to the real service is a
/// transport swap rather than a redesign.
///
/// Shape-wise this is `PostBookmarkStore`'s pattern (UserDefaults + lock,
/// injectable defaults, DEBUG seed hooks) with `ForYouUnreadStore`'s
/// injectable clock, because every rule in it is time-derived and the test
/// suite must never sleep to cross an hour boundary. Change fan-out is a
/// scoped `NotificationCenter` post (`MapFavoritesStore`'s contract): the
/// map badge, the feed rail, and the comments bar all watch ONE injected
/// instance, and posts carry `object: self` so parallel test suites with
/// their own stores never hear each other.
public final class WalletStore: @unchecked Sendable {

    /// The reward economics, in one place. These are the client-side stand-ins
    /// for values the real service will echo on `GetWallet`.
    public enum Policy {
        /// A claim unlocks every hour.
        public static let claimInterval: TimeInterval = 60 * 60
        /// What an un-streaked claim pays.
        public static let baseClaimAmount = 25
        /// The most claiming can earn in one UTC day.
        public static let dailyClaimCap = 200
        /// Streak bonus: +10% per consecutive day, capped at 2×.
        public static func multiplier(forStreak streak: Int) -> Double {
            min(2.0, 1.0 + 0.1 * Double(max(0, streak - 1)))
        }
        /// What ONE stake gesture commits by default — a tap on the feed
        /// rail's stake button, on the comments composer's, on a card's like
        /// chip, and the long-press menu's only plain amount. The ONE place
        /// the default lives (1 point, the user's call on 2026-10-02 — it was
        /// 10, with a Max / 100 menu, until staking several likes in one
        /// gesture became the cartridge pack's job — `StakePack`).
        public static let defaultStakeAmount = 1
        /// The ×100 cartridge pack, the shop's boost: a pack of SHOTS, each
        /// staking `likesPerShot` of the viewer's OWN likes in one tap.
        /// Bought with gems; shots never expire; packs don't stack (a new one
        /// only once the current one is empty). The ONE place its numbers
        /// live: the menus, the shop and the tests all read them here.
        ///
        /// The price, against the mock economy's gem earn rate (the rationale
        /// the ×10 pack was priced on, 2026-10-02): a settled stake earns gems
        /// about 55% of the time, 15–49% of the likes staked
        /// (`mockOutcome`) — roughly 18 gems back per 100 likes staked, so
        /// about 18 per shot. Priced near what its own stakes earn back, ten
        /// ×100 shots would cost ~180 gems: more than the seeded 100, and
        /// six times a mid-tier country. So the pack is SMALLER, not dearer
        /// per point: 3 shots move 300 likes (~53 gems back) for 50 gems —
        /// an average curator about breaks even, a good one comes out ahead,
        /// it costs what a top-10 country costs (`CountryStanding.price`:
        /// 15 / 30 / 50), and `seededGems` (100) buys two. Three shots also
        /// fit the likes a viewer actually holds: the seeded 250 fires two,
        /// a day's claims (`dailyClaimCap`, 200) the third. A post holds two
        /// shots at most (`perTargetBoostCap`, 250).
        public enum StakePack {
            /// Shots in one pack.
            public static let shots = 3
            /// Likes ONE shot stakes — named for its number ("×100").
            public static let likesPerShot = 100
            /// What a pack costs, in gems.
            public static let price = 50

            /// One size of pack: its shots, its price. Server policy once
            /// wallet.v1 sells several (backend #941); mock tiers until then.
            public struct Tier: Equatable, Sendable, Identifiable, Codable {
                public let id: String
                public let shots: Int
                public let price: Int

                public init(id: String, shots: Int, price: Int) {
                    self.id = id
                    self.shots = shots
                    self.price = price
                }
            }

            /// The packs on sale, smallest first; bigger ones cost less a shot.
            public static let tiers: [Tier] = [
                Tier(id: "shots_3", shots: shots, price: price),
                Tier(id: "shots_10", shots: 10, price: 150),
                Tier(id: "shots_25", shots: 25, price: 325),
            ]

            /// The pack wallet.v1 sells today, and the one an older call buys.
            public static var standard: Tier { tiers[0] }
        }
        /// The most of THIS viewer's likes one post (or comment) can hold
        /// — spends past it are clamped to the remainder, and a full target
        /// refuses outright.
        public static let perTargetBoostCap = 250
        /// A fresh install starts with something to spend — the boost surfaces
        /// are dead affordances on a zero balance, which is exactly the state
        /// that cannot show whether they work. Mock-only; the real wallet
        /// provisions at 0.
        public static let seededBalance = 250
        /// Gems a fresh install starts with — enough to unlock a few countries
        /// on the map (15–50 each), which is the one thing gems buy today.
        /// Mock-only, like `seededBalance`; the real wallet provisions at 0.
        public static let seededGems = 100
        /// How long a stake stays ACTIVE before it settles (charter §33's
        /// deferred settlement): a day after the first stake, as the server
        /// settles a position (backend #886, #841).
        public static let settlementDelay: TimeInterval = 24 * 60 * 60

        /// A stake's settled outcome, MOCK: stable per target and amount, so
        /// the same stake always settles the same way. About 55% earn gems —
        /// between 15% and 49% of the likes staked, at least 1 — and the rest
        /// earn nothing, which the charter insists is a normal outcome.
        public static func mockOutcome(targetID: String, amount: Int) -> WalletStake.Outcome {
            // FNV-1a: `hashValue` is seeded per process and would re-roll the
            // outcome on every launch.
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in targetID.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            guard hash % 100 < 55 else { return .noReward }
            let percent = 15 + Int((hash / 100) % 35)
            return .gems(max(1, amount * percent / 100))
        }
    }

    private enum Key {
        static let balance = "wallet.balance"
        /// The last `WalletServerState` read (#1098), JSON.
        static let serverState = "wallet.server"
        static let lifetimeEarned = "wallet.lifetimeEarned"
        static let lifetimeSpent = "wallet.lifetimeSpent"
        static let lastClaimAt = "wallet.lastClaimAt"
        static let claimedToday = "wallet.claimedToday"
        static let claimedTodayDay = "wallet.claimedTodayDay"
        static let streakDays = "wallet.streakDays"
        static let boostTotals = "wallet.boostTotals"
        /// When each target's first stake was placed (seconds since 1970).
        static let stakedAt = "wallet.stakedAt"
        static let seeded = "wallet.seeded"
        static let demoStakesSeeded = "wallet.demoStakesSeeded"
        /// Gems granted outside stakes (the seed, a debug grant) and gems
        /// spent. Gems EARNED stay derived from the settled stakes.
        static let gemsGranted = "wallet.gemsGranted"
        static let gemsSpent = "wallet.gemsSpent"
        /// Shots left in the ×100 cartridge pack.
        static let stakeShots = "wallet.stakeShots"
        /// Which pack (`Policy.StakePack.Tier.id`) those shots came from.
        static let stakePackTier = "wallet.stakePackTier"
    }

    /// Fired after every balance-affecting change, on whatever thread made
    /// it, with `object:` the store instance that changed.
    public static let didChangeNotification = Notification.Name("wallet.didChange")

    /// Fired when likes staked on a post came back to the balance because the
    /// server did not spend them — a refusal, a clamp, an expired batch
    /// (#1775): the viewer is told, never left to find a smaller stake.
    /// `userInfo`: `stakeRefundAmountKey` (Int), `stakeRefundTargetKey` (String).
    public static let stakeRefundedNotification = Notification.Name("wallet.stakeRefunded")
    public static let stakeRefundAmountKey = "amount"
    public static let stakeRefundTargetKey = "targetID"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    /// Whose wallet: the ACCOUNT's (`StorageScope`). A guest holds none —
    /// their likes are the welcome gift's — so a guest's keys are never
    /// seeded.
    private let scope: StorageScope
    /// The demo plan's posts (`seedDemoStakesIfNeeded`), kept for an account
    /// that arrives after the plan was asked for.
    private var demoStakeTargets: [String]?
    private var scopeObserver: NSObjectProtocol?

    /// Where a member's stakes go to be committed through `wallet.Stake`
    /// (#676): every stake that lands here is recorded there too, and an undo
    /// can only take back taps it has not committed yet — a committed like
    /// is final. Nil (tests, previews): the store stands alone, as before.
    public var likeOutbox: LikeOutbox?

    private var _server: (any WalletServer)?
    /// Where a member's wallet lives (#1098). Set: the balance and the claim
    /// are the server's (`refreshFromServer`, `claim(idempotencyKey:)`);
    /// nil: the local mock, as before.
    public var server: (any WalletServer)? {
        get { lock.withLock { _server } }
        set { lock.withLock { _server = newValue } }
    }

    /// `name`, in the scope's account.
    private func k(_ name: String) -> String { scope.accountKey(name, adoptingLegacyIn: defaults) }

    /// UTC everywhere, matching the spec's "UTC day" accounting — a wallet
    /// that resets on the device's local midnight would disagree with the
    /// server's ledger the day one exists.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        scope: StorageScope = .shared,
        /// The QA launch arguments (DEBUG only) — the process's own; a test
        /// hands its own.
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.defaults = defaults
        self.now = now
        self.scope = scope
        self.launchArguments = launchArguments
        applyLaunchArguments()
        seedIfNeeded()
        // A member arriving gets their own wallet, seeded the first time.
        scopeObserver = NotificationCenter.default.addObserver(
            forName: StorageScope.didChangeNotification, object: scope, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            applyLaunchArguments()
            seedIfNeeded()
            if let targets = lock.withLock({ demoStakeTargets }) { seedDemoStakesIfNeeded(targetIDs: targets) }
            postDidChange()
        }
    }

    /// The QA launch arguments (DEBUG), applied to the wallet of the scope's
    /// owner — at init, and again when the scope moves to another owner
    /// (#1388): the app's one store starts unscoped, and a signed-in member
    /// reads keys of their own that an init-time pass never wrote. Once per
    /// owner per launch, so a later scope change resets no one twice.
    private func applyLaunchArguments() {
        #if DEBUG
        let owner = k("wallet.launchArguments")
        guard lock.withLock({ launchArgumentsApplied.insert(owner).inserted }) else { return }
        let arguments = launchArguments
        // `-wallet-reset`: deterministic QA — a scripted launch always starts
        // from the seeded first-run wallet.
        if arguments.contains("-wallet-reset") {
            for key in [k(Key.balance), k(Key.lifetimeEarned), k(Key.lifetimeSpent), k(Key.lastClaimAt),
                        k(Key.claimedToday), k(Key.claimedTodayDay), k(Key.streakDays), k(Key.boostTotals),
                        k(Key.stakedAt), k(Key.seeded), k(Key.demoStakesSeeded), k(Key.gemsGranted), k(Key.gemsSpent),
                        k(Key.stakeShots), k(Key.stakePackTier)] {
                defaults.removeObject(forKey: key)
            }
        }
        // `-wallet-balance N`: a specific balance without earning it first —
        // 0 shows the insufficient-funds path, 10000 shows wide layouts.
        if let index = arguments.firstIndex(of: "-wallet-balance"),
           index + 1 < arguments.count, let balance = Int(arguments[index + 1]) {
            defaults.set(balance, forKey: k(Key.balance))
            defaults.set(true, forKey: k(Key.seeded))
        }
        // `-wallet-claim-ready`: the claim is immediately available — the
        // pulse, the enabled button, and the payout are all reachable without
        // waiting out a real hour.
        if arguments.contains("-wallet-claim-ready") {
            defaults.removeObject(forKey: k(Key.lastClaimAt))
            defaults.removeObject(forKey: k(Key.claimedToday))
            defaults.removeObject(forKey: k(Key.claimedTodayDay))
        }
        // `-wallet-streak N`: an established streak whose chain is alive
        // (last claim landed yesterday), so the next claim both continues it
        // and pays the multiplied amount.
        if let index = arguments.firstIndex(of: "-wallet-streak"),
           index + 1 < arguments.count, let streak = Int(arguments[index + 1]) {
            defaults.set(streak, forKey: k(Key.streakDays))
            let yesterday = Self.utcCalendar.date(byAdding: .day, value: -1, to: now())!
            defaults.set(yesterday.timeIntervalSince1970, forKey: k(Key.lastClaimAt))
        }
        // `-wallet-gems N`: exactly N gems to spend, whatever was earned.
        if let index = arguments.firstIndex(of: "-wallet-gems"),
           index + 1 < arguments.count, let gems = Int(arguments[index + 1]) {
            defaults.set(0, forKey: k(Key.gemsSpent))
            defaults.set(gems - stakesLocked(at: now()).reduce(0) { $0 + $1.gems }, forKey: k(Key.gemsGranted))
        }
        // `-wallet-stake-shots N`: a ×100 cartridge pack with N shots left
        // (0 empties it) — the menu's loaded face without a trip to the shop.
        if let index = arguments.firstIndex(of: "-wallet-stake-shots"),
           index + 1 < arguments.count, let shots = Int(arguments[index + 1]) {
            defaults.set(max(0, shots), forKey: k(Key.stakeShots))
        }
        #endif
    }

    private let launchArguments: [String]

    #if DEBUG
    /// The owners `applyLaunchArguments` has served this launch.
    private var launchArgumentsApplied: Set<String> = []
    #endif

    /// The first-run wallet, once per account (and once for an unscoped
    /// store): the starting balance and gems, and dates for undated boosts.
    /// Never for a guest.
    private func seedIfNeeded() {
        guard scope.holdsWallet else { return }
        lock.lock()
        defer { lock.unlock() }
        // The seeded gems, once — also for an install that predates them.
        if defaults.object(forKey: k(Key.gemsGranted)) == nil {
            defaults.set(Policy.seededGems, forKey: k(Key.gemsGranted))
        }
        // First run: seed the spendable starting balance, exactly once.
        if !defaults.bool(forKey: k(Key.seeded)) {
            defaults.set(Policy.seededBalance, forKey: k(Key.balance))
            defaults.set(true, forKey: k(Key.seeded))
        }
        // Boosts recorded before stakes had a date are dated now, as already
        // settled — once, and then they keep that date.
        let totals = defaults.dictionary(forKey: k(Key.boostTotals)) as? [String: Int] ?? [:]
        var dates = defaults.dictionary(forKey: k(Key.stakedAt)) as? [String: Double] ?? [:]
        let undated = totals.keys.filter { dates[$0] == nil }
        if !undated.isEmpty {
            let settled = now().addingTimeInterval(-Policy.settlementDelay).timeIntervalSince1970
            for target in undated { dates[target] = settled }
            defaults.set(dates, forKey: k(Key.stakedAt))
        }
    }

    // MARK: - Reads

    public var balance: Int {
        lock.withLock { defaults.integer(forKey: k(Key.balance)) }
    }

    /// What a stake control judges affordability against: the balance — and,
    /// for a guest, no limit. A guest holds no wallet (their likes are the
    /// welcome gift's), and their tap is the member gate's to answer: judged
    /// against an empty wallet, every like control greyed out and the
    /// sign-up sheet a like is meant to open never could.
    public var stakeableBalance: Int {
        scope.holdsWallet ? balance : .max
    }

    /// The wallet as of `now()` — claim availability, countdown target, next
    /// payout, and the streak the UI should show.
    public func snapshot() -> WalletSnapshot {
        lock.withLock { snapshotLocked(at: now()) }
    }

    /// Shots left in the ×100 cartridge pack; 0 when none is active.
    public var stakeShots: Int {
        lock.withLock { defaults.integer(forKey: k(Key.stakeShots)) }
    }

    /// The pack the shots left came from; nil when none is loaded.
    public var stakePackTierID: String? {
        lock.withLock {
            guard defaults.integer(forKey: k(Key.stakeShots)) > 0 else { return nil }
            return defaults.string(forKey: k(Key.stakePackTier)) ?? Policy.StakePack.standard.id
        }
    }

    /// Total likes ever boosted into one post or comment, this device.
    public func boostTotal(forTarget targetID: String) -> Int {
        lock.withLock { boostTotalsLocked()[targetID] ?? 0 }
    }

    /// Every stake, as of `now()`: the ACTIVE ones first, soonest to settle
    /// first; then the SETTLED ones, most recent first.
    public func stakes() -> [WalletStake] {
        // Read before the lock: the outbox has its own.
        let outboxTargets = Set((likeOutbox?.batches ?? []).map(\.target))
        return lock.withLock {
            let local = stakesLocked(at: now())
            // The server's list, once read for this viewer (#903) — with the
            // device's stakes it does not know yet (taps not committed) as
            // active ones on top.
            guard _server != nil, let server = _serverStakes, server.owner == scope.owner else { return local }
            let listed = Set(server.stakes.map(\.targetID))
            let unsent = local.filter {
                !$0.isSettled && !listed.contains($0.targetID) && outboxTargets.contains(.post($0.targetID))
            }
            return unsent + server.stakes
        }
    }

    /// Mock mode's demo ledger: stakes on real posts of the mock corpus, some
    /// still active and some settled, so the wallet's stake list has something
    /// to show on a fresh install. Once per install; the balance is untouched
    /// (these likes were "spent" before the install began).
    ///
    /// ⚠️ The composition root calls it in MOCK mode only, with ids it knows
    /// exist: stakes on posts no backend can resolve would be rows about
    /// nothing.
    public func seedDemoStakesIfNeeded(targetIDs: [String]) {
        let seeded: Bool = lock.withLock {
            demoStakeTargets = targetIDs
            guard scope.holdsWallet, !defaults.bool(forKey: k(Key.demoStakesSeeded)) else { return false }
            defaults.set(true, forKey: k(Key.demoStakesSeeded))
            var totals = boostTotalsLocked()
            var dates = defaults.dictionary(forKey: k(Key.stakedAt)) as? [String: Double] ?? [:]
            // Hours ago, and amounts: three active, the rest settled.
            let plan: [(hours: Double, amount: Int)] = [
                (0.5, 10), (2.5, 100), (4.75, 20), (7, 40), (20, 100), (30, 10), (52, 60), (75, 20),
            ]
            let moment = now()
            for (target, stake) in zip(targetIDs, plan) where totals[target] == nil {
                totals[target] = stake.amount
                dates[target] = moment.addingTimeInterval(-stake.hours * 3600).timeIntervalSince1970
            }
            defaults.set(totals, forKey: k(Key.boostTotals))
            defaults.set(dates, forKey: k(Key.stakedAt))
            return true
        }
        if seeded { postDidChange() }
    }

    // MARK: - The server's wallet (#1098)

    /// Reads the member's wallet from the server and takes it as the truth.
    /// Nothing for a guest — their likes are the welcome gift's, and every
    /// wallet RPC refuses a guest — or without a server. A failure leaves
    /// what was shown. Returns whether the wallet was read.
    @discardableResult
    public func refreshFromServer() async -> Bool {
        guard let server, case .member = scope.owner else { return false }
        let owner = scope.owner
        guard let state = try? await server.wallet() else { return false }
        return apply(state, readAs: owner)
    }

    /// The hourly claim, through the server: the outcome and the wallet it
    /// answers with, applied. Without a server, the local mock's claim.
    public func claim(idempotencyKey: String) async -> WalletClaimOutcome {
        guard let server, case .member = scope.owner else { return claim() }
        let owner = scope.owner
        do {
            let answer = try await server.claim(idempotencyKey: idempotencyKey)
            apply(answer.wallet, readAs: owner)
            return answer.outcome
        } catch {
            return .unavailable
        }
    }

    /// Takes the server's wallet as the truth, for the account it was read
    /// as — not for another one the viewer became meanwhile. The balance is
    /// the server's minus the likes it has not been sent yet (the outbox's),
    /// which this device already took off.
    @discardableResult
    public func apply(_ state: WalletServerState, readAs owner: StorageScope.Owner) -> Bool {
        guard case .member(let account, _) = owner else { return false }
        let unsent = (likeOutbox?.batches ?? []).filter { ($0.accountID ?? account) == account }
        let pending = unsent.reduce(0) { $0 + $1.likes }
        // The pack's shots are the server's too (#1475), minus those fired
        // and not sent yet.
        let pendingShots = unsent.filter(\.usesStakeShot).count
        let applied: Bool = lock.withLock {
            guard scope.owner == owner else { return false }
            defaults.set(max(0, state.likes - pending), forKey: k(Key.balance))
            defaults.set(max(0, state.stakeShots - pendingShots), forKey: k(Key.stakeShots))
            if let pack = state.stakePackID, !pack.isEmpty { defaults.set(pack, forKey: k(Key.stakePackTier)) }
            if let data = try? JSONEncoder().encode(state) {
                defaults.set(data, forKey: k(Key.serverState))
            }
            return true
        }
        if applied { postDidChange() }
        return applied
    }

    /// What the member owns (#1475), for the account it was listed for, and
    /// the catalogue's prices. Memory only: read again on each opening.
    private var _ownedItems: (owner: StorageScope.Owner, items: Set<String>)?
    private var _catalog: [String: Int] = [:]

    /// The member's stakes as the server last listed them (#903), with the
    /// account they belong to. Memory only: the sheet asks again on opening.
    private var _serverStakes: (owner: StorageScope.Owner, stakes: [WalletStake])?
    /// The account whose last stake listing failed: its rows stay the
    /// device's, outcomes included, rather than waiting for nothing.
    private var _serverStakesFailedOwner: StorageScope.Owner?

    /// Whether the settled stakes' outcomes are still to come from the
    /// server (#1395): a server attached, a member, and no listing read for
    /// them yet, nor failed. Until then a settled stake's OUTCOME is the
    /// device's guess. The server's verdict replaces it once listed (shadow
    /// mode: "Rewarded" where the device said "+1"), so the sheet shows the
    /// outcome as a bone meanwhile rather than a number that will flip.
    /// Whether the member's last read of the server's stakes failed, with
    /// none read before for them — the Stakes screen's failed state (#1477).
    public var stakesListingFailed: Bool {
        lock.withLock {
            guard _server != nil, case .member = scope.owner else { return false }
            return _serverStakesFailedOwner == scope.owner && _serverStakes?.owner != scope.owner
        }
    }

    public var awaitsServerStakes: Bool {
        lock.withLock {
            guard _server != nil, case .member = scope.owner else { return false }
            return _serverStakes?.owner != scope.owner && _serverStakesFailedOwner != scope.owner
        }
    }

    /// A page of the member's wallet history (#400); throws without a server
    /// or for a guest, who has no wallet to list.
    public func transactions(
        currency: WalletTransaction.Currency?, after pageToken: String?
    ) async throws -> WalletTransactionPage {
        guard let server, case .member = scope.owner else { throw WalletHistoryUnavailable() }
        return try await server.transactions(currency: currency, after: pageToken)
    }

    /// Lists the member's stakes from the server; the sheet's Active and
    /// Settled read them (`stakes()`). Returns whether it did.
    @discardableResult
    public func refreshStakesFromServer() async -> Bool {
        guard let server, case .member = scope.owner else { return false }
        let owner = scope.owner
        guard let listed = try? await server.myStakes() else {
            // Offline or refused: the device's outcomes stand, and the sheet
            // draws them rather than bones that never resolve.
            let failed: Bool = lock.withLock {
                guard scope.owner == owner, _serverStakes?.owner != owner else { return false }
                _serverStakesFailedOwner = owner
                return true
            }
            if failed { postDidChange() }
            return false
        }
        let stored: Bool = lock.withLock {
            guard scope.owner == owner else { return false }
            _serverStakes = (owner, listed)
            _serverStakesFailedOwner = nil
            return true
        }
        if stored { postDidChange() }
        return stored
    }

    /// The last server wallet read for this account, if any — while a
    /// server is attached.
    private func serverStateLocked() -> WalletServerState? {
        guard _server != nil, case .member = scope.owner,
              let data = defaults.data(forKey: k(Key.serverState)) else { return nil }
        return try? JSONDecoder().decode(WalletServerState.self, from: data)
    }

    // MARK: - The server's gems (#1475)

    /// Whether this wallet's gems are the server's: a member, with a server.
    /// Then every spend goes through it, and the balance is its answer.
    public var isServerBacked: Bool {
        lock.withLock {
            guard _server != nil, case .member = scope.owner else { return false }
            return true
        }
    }

    /// No gem may be spent by this account (under 18 or age unknown,
    /// `WAL-3001`), as the server last said.
    public var gemSpendingRestricted: Bool {
        lock.withLock { serverStateLocked()?.gemSpendingRestricted ?? false }
    }

    /// The stake packs on sale: the server's, once read; the policy's mock
    /// tiers otherwise.
    public var stakePackTiers: [Policy.StakePack.Tier] {
        lock.withLock {
            let served = serverStateLocked()?.stakePacks ?? []
            return served.isEmpty ? Policy.StakePack.tiers : served
        }
    }

    /// Buys a stake pack — through the server for a member whose gems are
    /// its (one charge per key), the device's mock otherwise.
    public func buyStakePack(_ tier: Policy.StakePack.Tier, idempotencyKey: String) async -> WalletStakePackPurchase {
        guard let server, case .member = scope.owner else { return buyStakePack(tier) }
        let owner = scope.owner
        do {
            let answer = try await server.buyStakePack(packID: tier.id, idempotencyKey: idempotencyKey)
            apply(answer.wallet, readAs: owner)
            return answer.outcome
        } catch {
            return .unavailable
        }
    }

    /// The catalogue items the member owns, as the server last listed them;
    /// nil until listed (or for a wallet that is not the server's).
    public var ownedItems: Set<String>? {
        lock.withLock {
            guard let owned = _ownedItems, owned.owner == scope.owner else { return nil }
            return owned.items
        }
    }

    /// A catalogue item's price, as the server last listed it.
    public func catalogPrice(of itemID: String) -> Int? {
        lock.withLock { _catalog[itemID] }
    }

    /// Reads what the member owns and the catalogue's prices from the
    /// server. Returns whether the ownership was read.
    @discardableResult
    public func refreshItemsFromServer() async -> Bool {
        guard let server, case .member = scope.owner else { return false }
        let owner = scope.owner
        async let owned = try? server.ownedItems()
        async let catalog = try? server.catalog()
        let (items, prices) = await (owned, catalog)
        let changed: Bool = lock.withLock {
            guard scope.owner == owner else { return false }
            if let prices { _catalog = Dictionary(prices.map { ($0.id, $0.price) }, uniquingKeysWith: { first, _ in first }) }
            if let items { _ownedItems = (owner, Set(items)) }
            return items != nil || prices != nil
        }
        if changed { postDidChange() }
        return items != nil
    }

    /// Buys a catalogue item at `price` through the server (#1475), one
    /// charge per key; the item is owned at once on success.
    public func purchaseItem(_ itemID: String, price: Int, idempotencyKey: String) async -> WalletItemPurchase {
        guard let server, case .member = scope.owner else { return .unavailable }
        let owner = scope.owner
        let answer: (outcome: WalletItemPurchase, wallet: WalletServerState)
        do {
            answer = try await server.purchaseItem(itemID: itemID, expectedPrice: price, idempotencyKey: idempotencyKey)
        } catch {
            return .failed
        }
        apply(answer.wallet, readAs: owner)
        switch answer.outcome {
        case .purchased, .alreadyOwned:
            let owned: Bool = lock.withLock {
                guard scope.owner == owner else { return false }
                var items = _ownedItems?.owner == owner ? _ownedItems?.items ?? [] : []
                items.insert(itemID)
                _ownedItems = (owner, items)
                return true
            }
            if owned { postDidChange() }
            return answer.outcome
        case .priceChanged:
            // The catalogue again, so the shelf shows the price to pay.
            await refreshItemsFromServer()
            return .priceChanged(price: catalogPrice(of: itemID))
        default:
            return answer.outcome
        }
    }

    // MARK: - Mutations

    /// Credits `amount` earned outside the claim — the welcome gift a guest
    /// redeems by signing up (`WelcomeGift`). Counts as earned; touches neither
    /// the claim clock nor the day's cap, which only the claim spends.
    public func credit(_ amount: Int) {
        guard amount > 0 else { return }
        lock.withLock {
            defaults.set(defaults.integer(forKey: k(Key.balance)) + amount, forKey: k(Key.balance))
            defaults.set(defaults.integer(forKey: k(Key.lifetimeEarned)) + amount, forKey: k(Key.lifetimeEarned))
        }
        postDidChange()
    }

    /// Attempts the periodic claim. `.claimed` credits the balance and
    /// advances the streak; the other outcomes change nothing.
    @discardableResult
    public func claim() -> WalletClaimOutcome {
        let outcome: WalletClaimOutcome = lock.withLock {
            let moment = now()
            let today = dayKey(for: moment)
            let claimedToday = claimedTodayLocked(today: today)
            guard claimedToday < Policy.dailyClaimCap else { return .dailyCapReached }
            if let last = lastClaimAtLocked(), moment < last.addingTimeInterval(Policy.claimInterval) {
                return .tooEarly(nextClaimAt: last.addingTimeInterval(Policy.claimInterval))
            }
            let streak = prospectiveStreakLocked(today: today)
            let awarded = min(
                Int((Double(Policy.baseClaimAmount) * Policy.multiplier(forStreak: streak)).rounded()),
                Policy.dailyClaimCap - claimedToday
            )
            defaults.set(defaults.integer(forKey: k(Key.balance)) + awarded, forKey: k(Key.balance))
            defaults.set(defaults.integer(forKey: k(Key.lifetimeEarned)) + awarded, forKey: k(Key.lifetimeEarned))
            defaults.set(claimedToday + awarded, forKey: k(Key.claimedToday))
            defaults.set(today, forKey: k(Key.claimedTodayDay))
            defaults.set(streak, forKey: k(Key.streakDays))
            defaults.set(moment.timeIntervalSince1970, forKey: k(Key.lastClaimAt))
            return .claimed(awarded: awarded)
        }
        if case .claimed = outcome { postDidChange() }
        return outcome
    }

    /// Spends `amount` on a post or comment — clamped to the per-target
    /// cap's remainder, refused outright on a full target. Optimistic and
    /// irreversible otherwise, like the wire contract it stands in for —
    /// no refunds.
    @discardableResult
    public func boost(targetID: String, amount: Int) -> WalletBoostOutcome {
        stake(.likes(amount), on: targetID)
    }

    /// One stake gesture: a plain amount, or one shot of the ×100 cartridge
    /// pack. A shot stakes EXACTLY `Policy.StakePack.likesPerShot` of the
    /// viewer's own likes, or nothing: where a plain amount is clamped to
    /// the cap's remainder, a shot that would not fit whole is refused
    /// (`shotDoesNotFit`, or `targetCapReached` on a full post) — the same
    /// verdicts, in the same order, as the menu (`StakeMenu.State.canShoot`):
    /// room first, then the balance. The shot is consumed ONLY when the stake
    /// lands; a refused one keeps it. Atomic: the likes and the shot move
    /// under one lock, or neither does.
    @discardableResult
    public func stake(_ spend: WalletStakeSpend, on targetID: String) -> WalletBoostOutcome {
        let outcome: WalletBoostOutcome = lock.withLock {
            switch spend {
            case .likes(let amount):
                precondition(amount > 0, "a boost spends something")
                return boostLocked(targetID: targetID, amount: amount)
            case .shot:
                let shots = defaults.integer(forKey: k(Key.stakeShots))
                guard shots > 0 else { return .noShotsLeft }
                let held = boostTotalsLocked()[targetID] ?? 0
                let room = Policy.perTargetBoostCap - held
                guard room > 0 else { return .targetCapReached(targetTotal: held) }
                guard room >= Policy.StakePack.likesPerShot else { return .shotDoesNotFit(room: room) }
                let outcome = boostLocked(targetID: targetID, amount: Policy.StakePack.likesPerShot)
                if case .boosted = outcome {
                    defaults.set(shots - 1, forKey: k(Key.stakeShots))
                }
                return outcome
            }
        }
        if case .boosted(_, _, let spent) = outcome {
            if case .member = scope.owner, let likeOutbox {
                switch spend {
                case .likes: likeOutbox.record(likes: spent, on: .post(targetID))
                case .shot: likeOutbox.recordShot(on: .post(targetID), likes: spent)
                }
            }
            postDidChange()
        }
        return outcome
    }

    /// The viewer moved on from the target: its taps are committed now
    /// rather than 10 s after the last one (#676).
    public func commitStakes(on targetID: String) {
        likeOutbox?.seal(target: .post(targetID))
    }

    /// The server's answer to a committed batch (#676): what it did not
    /// spend — clamped to the target's room, the balance or the hour's, or
    /// refused (expired, own content, not stakeable) — goes back to the
    /// balance and off the target, as the server never took it.
    public func settleCommittedStake(targetID: String, asked: Int, spent: Int) {
        let unspent = asked - max(0, spent)
        guard unspent > 0 else { return }
        guard refund(targetID: targetID, amount: unspent) != nil else { return }
        postDidChange()
        NotificationCenter.default.post(
            name: Self.stakeRefundedNotification, object: self,
            userInfo: [Self.stakeRefundAmountKey: unspent, Self.stakeRefundTargetKey: targetID]
        )
    }

    /// Buys a ×100 cartridge pack with gems: `Policy.StakePack.shots` shots
    /// for `Policy.StakePack.price` gems, all or nothing. Refused while the
    /// current pack still has shots — packs don't stack.
    @discardableResult
    public func buyStakePack(_ tier: Policy.StakePack.Tier = Policy.StakePack.standard) -> WalletStakePackPurchase {
        let outcome: WalletStakePackPurchase = lock.withLock {
            let shots = defaults.integer(forKey: k(Key.stakeShots))
            guard shots == 0 else { return .packStillActive(shotsLeft: shots) }
            let gems = gemsLocked(at: now())
            let price = tier.price
            guard gems >= price else { return .insufficientGems(needed: price, have: gems) }
            defaults.set(defaults.integer(forKey: k(Key.gemsSpent)) + price, forKey: k(Key.gemsSpent))
            defaults.set(tier.shots, forKey: k(Key.stakeShots))
            defaults.set(tier.id, forKey: k(Key.stakePackTier))
            return .bought(shots: tier.shots, remainingGems: gems - price)
        }
        if case .bought = outcome { postDidChange() }
        return outcome
    }

    /// `boost`'s arithmetic, lock held.
    private func boostLocked(targetID: String, amount: Int) -> WalletBoostOutcome {
        var totals = boostTotalsLocked()
        let held = totals[targetID] ?? 0
        let remaining = Policy.perTargetBoostCap - held
        guard remaining > 0 else { return .targetCapReached(targetTotal: held) }
        // The cap clamps BEFORE the balance is asked: a viewer 5 short
        // of the cap taps 10 and spends 5 — a partial fill, not a
        // refusal.
        let spend = min(amount, remaining)
        let balance = defaults.integer(forKey: k(Key.balance))
        guard balance >= spend else { return .insufficientBalance(balance: balance) }
        let newBalance = balance - spend
        defaults.set(newBalance, forKey: k(Key.balance))
        defaults.set(defaults.integer(forKey: k(Key.lifetimeSpent)) + spend, forKey: k(Key.lifetimeSpent))
        let targetTotal = held + spend
        totals[targetID] = targetTotal
        defaults.set(totals, forKey: k(Key.boostTotals))
        // The stake's clock starts with its FIRST likes; adding to it
        // does not restart it.
        var dates = defaults.dictionary(forKey: k(Key.stakedAt)) as? [String: Double] ?? [:]
        if dates[targetID] == nil {
            dates[targetID] = now().timeIntervalSince1970
            defaults.set(dates, forKey: k(Key.stakedAt))
        }
        return .boosted(newBalance: newBalance, targetTotal: targetTotal, spent: spend)
    }

    /// Takes back part of a target's boost — the SESSION UNDO's storage
    /// half. ⚠️ Mock-only affordance: the wire contract stays refund-free
    /// (`BACKEND_VIRTUAL_CURRENCY.md` §3), and the UI enforces the actual
    /// rule — undo exists only while the boosted post is still the active
    /// page. The store just does the arithmetic it is asked to, clamped so
    /// a stale caller can never mint likes: the refund never exceeds what
    /// this target actually holds.
    ///
    /// Returns the post-refund balance and target total, or nil when the
    /// target holds nothing (nothing changed, nothing posted).
    public func undoBoost(targetID: String, amount: Int) -> (newBalance: Int, targetTotal: Int)? {
        precondition(amount > 0, "an undo takes something back")
        var amount = amount
        // With an outbox, only taps not yet committed come back (#676).
        if let likeOutbox, case .member = scope.owner {
            amount = likeOutbox.cancel(likes: amount, on: .post(targetID))
            guard amount > 0 else { return nil }
        }
        let result = refund(targetID: targetID, amount: amount)
        if result != nil { postDidChange() }
        return result
    }

    /// Puts up to `amount` of a target's stake back in the balance; nil when
    /// the target holds nothing. Posts nothing.
    private func refund(targetID: String, amount: Int) -> (newBalance: Int, targetTotal: Int)? {
        lock.withLock {
            var totals = boostTotalsLocked()
            let held = totals[targetID] ?? 0
            let taken = min(amount, held)
            guard taken > 0 else { return nil }
            let newBalance = defaults.integer(forKey: k(Key.balance)) + taken
            defaults.set(newBalance, forKey: k(Key.balance))
            defaults.set(max(0, defaults.integer(forKey: k(Key.lifetimeSpent)) - taken), forKey: k(Key.lifetimeSpent))
            let remaining = held - taken
            if remaining > 0 {
                totals[targetID] = remaining
            } else {
                totals.removeValue(forKey: targetID)
                // Undone entirely: there is no stake left to settle.
                var dates = defaults.dictionary(forKey: k(Key.stakedAt)) as? [String: Double] ?? [:]
                dates.removeValue(forKey: targetID)
                defaults.set(dates, forKey: k(Key.stakedAt))
            }
            defaults.set(totals, forKey: k(Key.boostTotals))
            return (newBalance, remaining)
        }
    }

    // MARK: - Internals (lock held)

    private func snapshotLocked(at moment: Date) -> WalletSnapshot {
        // The server's wallet, when it has been read (#1098): its claim, its
        // clock. The balance is the device's view of it (`apply`), moved by
        // the likes not sent yet.
        if let server = serverStateLocked() {
            return WalletSnapshot(
                balance: defaults.integer(forKey: k(Key.balance)),
                claimAvailable: server.claimAvailable,
                nextClaimAt: server.claimAvailable ? nil : server.nextClaimAt,
                claimAmount: server.claimAmount,
                claimedToday: server.claimedToday,
                dailyClaimCap: server.dailyClaimCap,
                streakDays: server.streakDays,
                // The server's gems (#1475).
                gems: server.gems,
                stakeShots: defaults.integer(forKey: k(Key.stakeShots)),
                likesCap: server.likesCap
            )
        }
        let today = dayKey(for: moment)
        let claimedToday = claimedTodayLocked(today: today)
        let capped = claimedToday >= Policy.dailyClaimCap
        let intervalGate = lastClaimAtLocked().map { $0.addingTimeInterval(Policy.claimInterval) }
        let available = !capped && (intervalGate.map { moment >= $0 } ?? true)

        // The countdown target: the cap outlasts the hourly gate (UTC
        // midnight is when a capped day earns again).
        let nextClaimAt: Date?
        if available {
            nextClaimAt = nil
        } else if capped {
            nextClaimAt = Self.utcCalendar.nextDate(
                after: moment, matching: DateComponents(hour: 0), matchingPolicy: .nextTime
            )
        } else {
            nextClaimAt = intervalGate
        }

        let prospective = prospectiveStreakLocked(today: today)
        let claimAmount = max(0, min(
            Int((Double(Policy.baseClaimAmount) * Policy.multiplier(forStreak: prospective)).rounded()),
            Policy.dailyClaimCap - claimedToday
        ))
        return WalletSnapshot(
            balance: defaults.integer(forKey: k(Key.balance)),
            claimAvailable: available,
            nextClaimAt: nextClaimAt,
            claimAmount: claimAmount,
            claimedToday: claimedToday,
            dailyClaimCap: Policy.dailyClaimCap,
            streakDays: displayStreakLocked(today: today),
            gems: gemsLocked(at: moment),
            stakeShots: defaults.integer(forKey: k(Key.stakeShots))
        )
    }

    /// Gems to spend: earned by settled stakes, plus granted, minus spent.
    private func gemsLocked(at moment: Date) -> Int {
        let earned = stakesLocked(at: moment).reduce(0) { $0 + $1.gems }
        return max(0, earned + defaults.integer(forKey: k(Key.gemsGranted)) - defaults.integer(forKey: k(Key.gemsSpent)))
    }

    /// Spends `amount` gems on the device, all or nothing — the mock of a
    /// wallet that is not the server's. ⚠️ A member's gems are the server's
    /// (#1475): every spend goes through its RPC, never here — refused.
    public func spendGems(_ amount: Int) -> WalletGemSpend {
        let outcome: WalletGemSpend = lock.withLock {
            if let server = serverStateLocked() {
                assertionFailure("a member's gems are spent through the server (#1475)")
                return .insufficient(gems: server.gems)
            }
            let gems = gemsLocked(at: now())
            guard amount > 0, gems >= amount else { return .insufficient(gems: gems) }
            defaults.set(defaults.integer(forKey: k(Key.gemsSpent)) + amount, forKey: k(Key.gemsSpent))
            return .spent(remaining: gems - amount)
        }
        if case .spent = outcome { postDidChange() }
        return outcome
    }

    private func stakesLocked(at moment: Date) -> [WalletStake] {
        let dates = defaults.dictionary(forKey: k(Key.stakedAt)) as? [String: Double] ?? [:]
        let stakes = boostTotalsLocked().compactMap { target, amount -> WalletStake? in
            guard amount > 0, let stamp = dates[target] else { return nil }
            let stakedAt = Date(timeIntervalSince1970: stamp)
            let settlesAt = stakedAt.addingTimeInterval(Policy.settlementDelay)
            return WalletStake(
                targetID: target, amount: amount, stakedAt: stakedAt, settlesAt: settlesAt,
                outcome: moment >= settlesAt ? Policy.mockOutcome(targetID: target, amount: amount) : nil
            )
        }
        let active = stakes.filter { !$0.isSettled }.sorted { $0.settlesAt < $1.settlesAt }
        let settled = stakes.filter(\.isSettled).sorted { $0.settlesAt > $1.settlesAt }
        return active + settled
    }

    /// Today's claim earnings — a stored count that only counts if it was
    /// stored TODAY. The rollover is lazy (read-side), never a timer.
    private func claimedTodayLocked(today: String) -> Int {
        guard defaults.string(forKey: k(Key.claimedTodayDay)) == today else { return 0 }
        return defaults.integer(forKey: k(Key.claimedToday))
    }

    private func lastClaimAtLocked() -> Date? {
        let stored = defaults.double(forKey: k(Key.lastClaimAt))
        return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    /// The streak the NEXT claim will record: continues from yesterday,
    /// holds within today, restarts at 1 after a missed day.
    private func prospectiveStreakLocked(today: String) -> Int {
        guard let last = lastClaimAtLocked() else { return 1 }
        let stored = max(1, defaults.integer(forKey: k(Key.streakDays)))
        let lastDay = dayKey(for: last)
        if lastDay == today { return stored }
        if lastDay == dayKey(for: Self.utcCalendar.date(byAdding: .day, value: -1, to: dayStart(of: today))!) {
            return stored + 1
        }
        return 1
    }

    /// The streak the UI shows: the stored chain while it is alive (a claim
    /// today or yesterday), 0 once it has lapsed — never the stale count.
    private func displayStreakLocked(today: String) -> Int {
        guard let last = lastClaimAtLocked() else { return 0 }
        let lastDay = dayKey(for: last)
        let yesterday = dayKey(for: Self.utcCalendar.date(byAdding: .day, value: -1, to: dayStart(of: today))!)
        guard lastDay == today || lastDay == yesterday else { return 0 }
        return max(1, defaults.integer(forKey: k(Key.streakDays)))
    }

    private func boostTotalsLocked() -> [String: Int] {
        defaults.dictionary(forKey: k(Key.boostTotals)) as? [String: Int] ?? [:]
    }

    /// "2026-08-14" in UTC — the ledger's day identity.
    private func dayKey(for date: Date) -> String {
        let parts = Self.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private func dayStart(of dayKey: String) -> Date {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        return Self.utcCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    private func postDidChange() {
        // Outside the lock, `object: self` — unscoped posts break parallel
        // test suites (MapFavoritesStore's rule).
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

/// The wallet's history cannot be read: no server, or no member.
public struct WalletHistoryUnavailable: Error, Equatable {
    public init() {}
}
