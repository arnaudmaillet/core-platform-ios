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

    /// A count as the offer and the shop print it: "12.4K", "3.1M", "860".
    public static func compact(_ value: Int64) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: String(format: "%.0fK", Double(value) / 1_000)
        case 1_000...: String(format: "%.1fK", Double(value) / 1_000)
        default: "\(value)"
        }
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
/// it. Two countries are open for free: the account's home country, and the
/// country the device is in while location is allowed (guest mode §3.1). A
/// guest has no home and no purchases — with location off, nothing is open
/// (decision 9).
///
/// Answered by the shell: the unlocks are the account's
/// (`CoreStorage.CountryUnlockStore`), the gems the wallet's, and the
/// standings the backend's — mock until it carries them.
@MainActor
public protocol CountryAccess: AnyObject {
    /// The account's own country (ISO alpha-2), always unlocked. Nil for a
    /// guest, who has no account to have a country.
    var homeCountry: String? { get }
    /// The country the device is in, while location is allowed — open for as
    /// long as the device stays there, never stored as an unlock.
    ///
    /// ⚠️ Declared in the protocol body for the same reason as `hasPosts`.
    var currentCountry: String? { get }
    /// Gems the account can spend.
    var gems: Int { get }
    func isUnlocked(_ code: String) -> Bool
    func standing(of code: String) -> CountryStanding?
    /// Every country's standing, busiest first — the shop's list.
    func standings() -> [CountryStanding]
    func unlock(_ code: String) -> CountryUnlockOutcome
    /// Whether anything at all has been posted in `code` — not whether the
    /// map's current query brought any of it. A country with posts never
    /// wears the empty country's disc (`CountryLayer.wantsFlag`), even where
    /// none of its posts is on the map right now.
    ///
    /// ⚠️ Declared HERE, in the protocol body, so a conformer's own answer is
    /// dispatched through the existential (the default below is not).
    func hasPosts(in code: String) -> Bool
}

public extension CountryAccess {
    /// No location by default.
    var currentCountry: String? { nil }

    /// Whether nothing at all is open — a guest without location (decision
    /// 9). The map's "See posts around you" card stands then.
    var hasNoOpenCountry: Bool {
        homeCountry == nil && currentCountry == nil && !standings().contains { isUnlocked($0.code) }
    }

    /// The standing's post count — the backend's own.
    func hasPosts(in code: String) -> Bool { (standing(of: code)?.posts ?? 0) > 0 }
}

public extension Notification.Name {
    /// Posted by a `CountryAccess` when an unlock or the gems changed.
    static let countryAccessDidChange = Notification.Name("countryAccess.didChange")
}
