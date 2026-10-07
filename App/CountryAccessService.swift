import AuthInterface
import Connect
import CoreContracts
import CoreLocation
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Maps

/// Which countries the account has unlocked on the map, and unlocking more
/// with gems — the shell's answer to `CountryAccess`.
///
/// - The UNLOCKS are the account's (`CountryUnlockStore`, keyed by account id,
///   never by profile), plus the account's home country, always open — a
///   MEMBER's: a guest has neither (guest mode decision 9).
/// - The CURRENT country is the device's, while location is allowed
///   (`CurrentCountryLocating`) — open for guests and members alike, for as
///   long as the device is there, and never written to the unlocks.
/// - The GEMS are the wallet's (`WalletStore.spendGems`) — points never buy a
///   country.
/// - The STANDINGS (rank, likes, posts) are the backend's once it carries
///   them (`dev/issues/BACKEND_COUNTRY_UNLOCKS.md`). Until then, mock mode
///   builds them here: the likes and posts of the mock corpus placed in each
///   country, over a baseline from the country's population so that every
///   country has a plausible standing and the rank ladder is stable.
@MainActor
final class CountryAccessService: CountryAccess {
    /// Teen protections (#401): no country unlocks or packs for 13–17.
    var purchasesRestricted: Bool { TeenProtections.shared.restrictsPurchases }

    /// The member's home country — what `homeCountry` answers for a member.
    private let accountHomeCountry: String
    private let accountID: String
    /// Whether a member is here: a guest has no home and no unlocks.
    private let isMember: @MainActor () -> Bool
    private let locator: (any CurrentCountryLocating)?
    private let wallet: WalletStore
    private let unlocks: CountryUnlockStore
    private let byCode: [String: CountryStanding]
    private let ordered: [CountryStanding]
    /// The countries with posts of their own — the corpus's, without the
    /// standings' population baseline, which gives every country a count.
    private let postedCountries: Set<String>
    private var observers: [NSObjectProtocol] = []

    init(
        accountID: String, homeCountry: String, wallet: WalletStore, unlocks: CountryUnlockStore,
        activity: [String: (likes: Int64, posts: Int)],
        isMember: @escaping @MainActor () -> Bool = { true },
        locator: (any CurrentCountryLocating)? = nil
    ) {
        self.accountID = accountID
        self.accountHomeCountry = homeCountry
        self.isMember = isMember
        self.locator = locator
        self.wallet = wallet
        self.unlocks = unlocks
        let ordered = Self.standings(activity: activity, homeCountry: homeCountry)
        self.ordered = ordered
        self.byCode = Dictionary(uniqueKeysWithValues: ordered.map { ($0.code, $0) })
        self.postedCountries = Set(activity.filter { $0.value.posts > 0 }.keys.map { $0.uppercased() })
        // Gems and unlocks change elsewhere too (a stake settling, another
        // screen): the map re-reads on either.
        // So do the device's country and the viewer: a sign-in opens the
        // account's countries, a sign-out closes them.
        for name in [WalletStore.didChangeNotification, CountryUnlockStore.didChangeNotification,
                     .currentCountryDidChange, .viewerDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                NotificationCenter.default.post(name: .countryAccessDidChange, object: nil)
            })
        }
    }

    var homeCountry: String? { isMember() ? accountHomeCountry : nil }

    var currentCountry: String? { locator?.currentCountry }

    var gems: Int { wallet.snapshot().gems }

    func isUnlocked(_ code: String) -> Bool {
        let code = code.uppercased()
        if code == currentCountry { return true }
        guard isMember() else { return false }
        return code == accountHomeCountry || unlocks.unlocked(for: accountID).contains(code)
    }

    func standing(of code: String) -> CountryStanding? { byCode[code.uppercased()] }

    func standings() -> [CountryStanding] { ordered }

    /// The corpus's own posts, NOT the standing's count: a standing's posts
    /// carry a population baseline so every country ranks plausibly, and
    /// would say every country has some.
    func hasPosts(in code: String) -> Bool { postedCountries.contains(code.uppercased()) }

    func unlock(_ code: String) -> CountryUnlockOutcome {
        guard let standing = standing(of: code) else { return .unknownCountry }
        guard !isUnlocked(code) else { return .alreadyUnlocked }
        // The sheet refuses first (#401); never spend a teen's gems regardless.
        guard !purchasesRestricted else { return .insufficientGems(needed: standing.price, have: wallet.snapshot().gems) }
        // A guest's unlock is gated before it gets here (`.unlockCountry`);
        // a guest has no account to keep the country in.
        guard isMember() else { return .insufficientGems(needed: standing.price, have: 0) }
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

/// The device's country, as the server lets it open (backend B10, #455):
/// `geo_discovery.v1.GetCountryAccess` checks the code against the network's
/// GeoIP country (roaming tolerated). Only a granted code opens; a refusal,
/// or no answer, opens nothing. The same call with nothing sent closes the
/// country left behind on the server's side too — what filters a guest's map.
struct GeoCountryAccessVerifier: CurrentCountryVerifying {
    let geoClient: any GeoDiscovery_V1_GeoDiscoveryServiceClientInterface

    func verify(_ code: String?) async -> String? {
        var request = GeoDiscovery_V1_GetCountryAccessRequest()
        request.currentCountry = code ?? ""
        guard let response = await geoClient.getCountryAccess(request: request, headers: [:]).message,
              response.outcome == .granted, !response.currentCountry.isEmpty else { return nil }
        return response.currentCountry
    }
}
