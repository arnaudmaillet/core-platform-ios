import CoreLocation
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Maps

/// Which countries the account has unlocked on the map, and unlocking more
/// with gems — the shell's answer to `CountryAccess`.
///
/// - The UNLOCKS are the account's (`CountryUnlockStore`, keyed by account id,
///   never by profile), plus the account's home country, always open.
/// - The GEMS are the wallet's (`WalletStore.spendGems`) — points never buy a
///   country.
/// - The STANDINGS (rank, likes, posts) are the backend's once it carries
///   them (`dev/issues/BACKEND_COUNTRY_UNLOCKS.md`). Until then, mock mode
///   builds them here: the likes and posts of the mock corpus placed in each
///   country, over a baseline from the country's population so that every
///   country has a plausible standing and the rank ladder is stable.
@MainActor
final class CountryAccessService: CountryAccess {
    let homeCountry: String
    private let accountID: String
    private let wallet: WalletStore
    private let unlocks: CountryUnlockStore
    private let byCode: [String: CountryStanding]
    private let ordered: [CountryStanding]
    private var observers: [NSObjectProtocol] = []

    init(
        accountID: String, homeCountry: String, wallet: WalletStore, unlocks: CountryUnlockStore,
        activity: [String: (likes: Int64, posts: Int)]
    ) {
        self.accountID = accountID
        self.homeCountry = homeCountry
        self.wallet = wallet
        self.unlocks = unlocks
        let ordered = Self.standings(activity: activity, homeCountry: homeCountry)
        self.ordered = ordered
        self.byCode = Dictionary(uniqueKeysWithValues: ordered.map { ($0.code, $0) })
        // Gems and unlocks change elsewhere too (a stake settling, another
        // screen): the map re-reads on either.
        for name in [WalletStore.didChangeNotification, CountryUnlockStore.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                NotificationCenter.default.post(name: .countryAccessDidChange, object: nil)
            })
        }
    }

    var gems: Int { wallet.snapshot().gems }

    func isUnlocked(_ code: String) -> Bool {
        let code = code.uppercased()
        return code == homeCountry || unlocks.unlocked(for: accountID).contains(code)
    }

    func standing(of code: String) -> CountryStanding? { byCode[code.uppercased()] }

    func standings() -> [CountryStanding] { ordered }

    func unlock(_ code: String) -> CountryUnlockOutcome {
        guard let standing = standing(of: code) else { return .unknownCountry }
        guard !isUnlocked(code) else { return .alreadyUnlocked }
        switch wallet.spendGems(standing.price) {
        case .spent(let remaining):
            unlocks.unlock(standing.code, for: accountID)
            return .unlocked(remainingGems: remaining)
        case .insufficient(let gems):
            return .insufficientGems(needed: standing.price, have: gems)
        }
    }

    /// Every country's standing, busiest first: likes rank them, the rank
    /// prices them (`CountryStanding.price(forRank:)`), and the home country
    /// costs nothing.
    static func standings(
        activity: [String: (likes: Int64, posts: Int)], homeCountry: String
    ) -> [CountryStanding] {
        let scored = CountryAtlas.shared.countries.map { country -> (code: String, likes: Int64, posts: Int) in
            // A baseline that grows with the country but not linearly — a
            // billion people are not a thousand times a million on a map.
            let root = Double(max(country.population, 0)).squareRoot()
            let real = activity[country.code] ?? (0, 0)
            return (country.code, Int64(root * 4) + real.likes, Int(root / 400) + real.posts)
        }
        .sorted { ($0.likes, $1.code) > ($1.likes, $0.code) }
        return scored.enumerated().map { index, entry in
            CountryStanding(
                code: entry.code, rank: index + 1, likes: entry.likes, posts: entry.posts,
                price: entry.code == homeCountry ? 0 : CountryStanding.price(forRank: index + 1)
            )
        }
    }

    /// The mock corpus's likes and posts per country: where each post stands,
    /// and the likes it holds.
    static func mockActivity(in backend: MockBackend) -> [String: (likes: Int64, posts: Int)] {
        var activity: [String: (likes: Int64, posts: Int)] = [:]
        for placement in backend.geoDiscovery.placements() {
            let coordinate = CLLocationCoordinate2D(latitude: placement.latitude, longitude: placement.longitude)
            guard let code = CountryAtlas.shared.country(owning: coordinate)?.code else { continue }
            let likes = backend.counterStore.likeCount(for: placement.postID)
            let current = activity[code] ?? (0, 0)
            activity[code] = (current.likes + likes, current.posts + 1)
        }
        return activity
    }
}
