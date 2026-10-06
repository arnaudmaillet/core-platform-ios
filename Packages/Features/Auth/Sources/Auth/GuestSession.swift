import CoreStorage
import CryptoKit
import DeviceCheck
import Foundation

/// What a guest session is started with (guest mode B1,
/// arnaudmaillet/core-platform#671): where it is kept, the request's context
/// beyond the device, and the App Attest proof (#523).
///
/// A guest reads public content with a token of their own — `read:public`,
/// no profile — which `SessionManager` vends when nobody is signed in. Without
/// one, the edge refuses every read.
public struct GuestSessionContext: Sendable {
    /// Its own keychain item: a sign-in never overwrites it, and a sign-out
    /// falls back to it.
    public var store: any SessionStore
    /// BCP-47, e.g. "fr-FR".
    public var locale: @Sendable () -> String
    /// The store country — a discovery hint.
    public var regionHint: @Sendable () -> String
    /// ISO alpha-2 country the device is in, when location is allowed (B10).
    /// Never a coordinate.
    public var currentCountry: @Sendable () async -> String?
    /// Nil sends no attestation (a server in `off` or `observe` mode still
    /// starts the session).
    public var attestor: (any GuestAttesting)?

    public init(
        store: any SessionStore,
        locale: @escaping @Sendable () -> String = { Locale.current.identifier(.bcp47) },
        regionHint: @escaping @Sendable () -> String = { Locale.current.region?.identifier ?? "" },
        currentCountry: @escaping @Sendable () async -> String? = { nil },
        attestor: (any GuestAttesting)? = nil
    ) {
        self.store = store
        self.locale = locale
        self.regionHint = regionHint
        self.currentCountry = currentCountry
        self.attestor = attestor
    }
}

/// Proves a guest session comes from a genuine install of the app.
public protocol GuestAttesting: Sendable {
    /// An attestation bound to `challenge`, or nil where App Attest is
    /// unavailable (the simulator, older devices) or failed.
    func attest(challenge: String) async -> GuestAttestation?
}

public struct GuestAttestation: Sendable, Equatable {
    /// The App Attest key's id, base64 as `generateKey` returns it.
    public let keyID: String
    /// The attestation object, base64.
    public let attestation: String

    public init(keyID: String, attestation: String) {
        self.keyID = keyID
        self.attestation = attestation
    }
}

/// `GuestAttesting` over `DCAppAttestService` (#523).
///
/// A fresh Secure Enclave key per attestation: a key attests once (the
/// server checks its counter is 0 and records it), and a new guest session —
/// the previous one lost — needs a new proof. The latest key's id is kept in
/// the keychain for the assertions that will follow on later requests.
///
/// Needs the `com.apple.developer.devicecheck.appattest-environment`
/// entitlement; the simulator never supports App Attest.
public struct AppAttestGuestAttestor: GuestAttesting {
    private static let keyIDKey = "auth.appAttestKeyID"
    private let keyStore: any SecureDataStore

    public init(keyStore: any SecureDataStore) {
        self.keyStore = keyStore
    }

    public func attest(challenge: String) async -> GuestAttestation? {
        let service = DCAppAttestService.shared
        guard service.isSupported else { return nil }
        do {
            let keyID = try await service.generateKey()
            try? keyStore.save(Data(keyID.utf8), forKey: Self.keyIDKey)
            let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
            let object = try await service.attestKey(keyID, clientDataHash: clientDataHash)
            return GuestAttestation(keyID: keyID, attestation: object.base64EncodedString())
        } catch {
            // No proof this time: the server decides (observe lets it
            // through, enforce answers AUT-1006).
            return nil
        }
    }
}
