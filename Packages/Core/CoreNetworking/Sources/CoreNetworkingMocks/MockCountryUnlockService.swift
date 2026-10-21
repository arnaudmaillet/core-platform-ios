import Connect
import CoreContracts
import Foundation

/// The member's countries, as geo_discovery.v1 keeps them (#1475, backend
/// #910): `GetCountryUnlocks` and `UnlockCountry`, paid with the mock
/// wallet's gems (`MockWalletService`), which records the spend in its
/// history — as the fleet's geo service spends through the wallet.
///
/// A wallet opens with its home country and the world seed's countries, "as
/// if bought" (`MockWorldSeed.unlockedCountryCodes`, `-countries-no-seed`
/// skips them); `-countries-reset` forgets every unlock. ⚠️ The price is
/// the one the app showed: the mock has no ranking of its own to move it,
/// so it never answers PRICE_CHANGED.
public final class MockCountryUnlockService: @unchecked Sendable {
    private static let persistenceKey = "mock.countries.unlocks"

    private let wallet: MockWalletService
    private let homeCountry: String
    private let seed: Set<String>
    private let persistence: UserDefaults?
    private let lock = NSLock()
    private var unlocks: [String: [String]] {
        didSet {
            guard let persistence, let data = try? JSONEncoder().encode(unlocks) else { return }
            persistence.set(data, forKey: Self.persistenceKey)
        }
    }

    public init(
        wallet: MockWalletService, homeCountry: String = "FR",
        seed: Set<String> = MockWorldSeed.unlockedCountryCodes, persistence: UserDefaults? = nil
    ) {
        self.wallet = wallet
        self.homeCountry = homeCountry
        let arguments = ProcessInfo.processInfo.arguments
        self.seed = arguments.contains("-countries-no-seed") ? [] : seed
        self.persistence = persistence
        if arguments.contains("-countries-reset") {
            persistence?.removeObject(forKey: Self.persistenceKey)
        }
        unlocks = persistence?.data(forKey: Self.persistenceKey)
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/geo_discovery.v1.GeoDiscoveryService/GetCountryUnlocks") { [self] (request: GeoDiscovery_V1_GetCountryUnlocksRequest, headers: Headers) -> Result<GeoDiscovery_V1_GetCountryUnlocksResponse, ConnectError> in
            if let refusal = Self.refusal(request.accountID, caller: MockEngagementService.account(from: headers)) {
                return .failure(refusal)
            }
            var response = GeoDiscovery_V1_GetCountryUnlocksResponse()
            response.homeCountry = homeCountry
            response.unlockedCountries = lock.withLock { unlockedLocked(request.accountID) }
            response.gems = wallet.gems(of: request.accountID)
            return .success(response)
        }
        bff.register(path: "/geo_discovery.v1.GeoDiscoveryService/UnlockCountry") { [self] (request: GeoDiscovery_V1_UnlockCountryRequest, headers: Headers) -> Result<GeoDiscovery_V1_UnlockCountryResponse, ConnectError> in
            if let refusal = Self.refusal(request.accountID, caller: MockEngagementService.account(from: headers)) {
                return .failure(refusal)
            }
            let code = request.countryCode.uppercased()
            guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                return .failure(ConnectError(code: .invalidArgument, message: "GEO-9001: country_code"))
            }
            return lock.withLock {
                // Adults only (WAL-3001, #1517), as the wallet's own spends:
                // a restricted account's unlock is refused with nothing
                // debited. A country already open spends nothing, so it is
                // still answered.
                if !unlockedLocked(request.accountID).contains(code),
                   let refusal = wallet.spendingRefusal(request.accountID) {
                    return .failure(refusal)
                }
                return .success(unlockLocked(request.accountID, code: code, price: request.expectedPrice))
            }
        }
    }

    /// The account's countries, home included, oldest first.
    private func unlockedLocked(_ account: String) -> [String] {
        if let kept = unlocks[account] { return kept }
        let opened = [homeCountry] + seed.subtracting([homeCountry]).sorted()
        unlocks[account] = opened
        return opened
    }

    private func unlockLocked(_ account: String, code: String, price: Int64) -> GeoDiscovery_V1_UnlockCountryResponse {
        var response = GeoDiscovery_V1_UnlockCountryResponse()
        response.priceGems = price
        var owned = unlockedLocked(account)
        if owned.contains(code) {
            response.outcome = .alreadyUnlocked
        } else if let left = wallet.spendGems(account: account, amount: price, kind: .countryUnlock, ref: code) {
            owned.append(code)
            unlocks[account] = owned
            response.outcome = .unlocked
            response.gems = left
        } else {
            response.outcome = .insufficientGems
        }
        response.unlockedCountries = owned
        if response.outcome != .unlocked { response.gems = wallet.gems(of: account) }
        return response
    }

    private static func refusal(_ account: String, caller: String?) -> ConnectError? {
        guard let caller else { return ConnectError(code: .unauthenticated, message: "sign in for your countries") }
        guard account == caller else { return ConnectError(code: .permissionDenied, message: "another account's countries") }
        return nil
    }
}
