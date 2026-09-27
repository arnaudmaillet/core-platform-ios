import Foundation

/// A country's place in the world's activity, and what it costs to unlock.
public struct CountryStanding: Sendable, Equatable {
    /// ISO 3166-1 alpha-2.
    public let code: String
    /// 1 = the most active country.
    public let rank: Int
    /// Likes on the posts published there.
    public let likes: Int64
    /// Posts published there.
    public let posts: Int
    /// Gems to unlock it; 0 for the account's home country.
    public let price: Int

    public init(code: String, rank: Int, likes: Int64, posts: Int, price: Int) {
        self.code = code
        self.rank = rank
        self.likes = likes
        self.posts = posts
        self.price = price
    }

    /// The price tiers by rank: the busiest countries cost the most.
    public static func price(forRank rank: Int) -> Int {
        switch rank {
        case ...10: 50
        case ...30: 30
        default: 15
        }
    }
}

/// What unlocking a country did.
public enum CountryUnlockOutcome: Equatable, Sendable {
    case unlocked(remainingGems: Int)
    case alreadyUnlocked
    case insufficientGems(needed: Int, have: Int)
    case unknownCountry
}

/// Which countries this ACCOUNT has opened on the map, and opening more with
/// gems.
///
/// The map shows the posts of unlocked countries only; a locked country is a
/// shade, and an annotation at its centre with its rank and likes that sells
/// it. The account's home country is always unlocked, for free.
///
/// Answered by the shell: the unlocks are the account's
/// (`CoreStorage.CountryUnlockStore`), the gems the wallet's, and the
/// standings the backend's — mock until it carries them.
@MainActor
public protocol CountryAccess: AnyObject {
    /// The account's own country (ISO alpha-2), always unlocked.
    var homeCountry: String { get }
    /// Gems the account can spend.
    var gems: Int { get }
    func isUnlocked(_ code: String) -> Bool
    func standing(of code: String) -> CountryStanding?
    /// Every country's standing, busiest first — the shop's list.
    func standings() -> [CountryStanding]
    func unlock(_ code: String) -> CountryUnlockOutcome
}

public extension Notification.Name {
    /// Posted by a `CountryAccess` when an unlock or the gems changed.
    static let countryAccessDidChange = Notification.Name("countryAccess.didChange")
}
