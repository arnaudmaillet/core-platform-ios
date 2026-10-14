import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Testing
@testable import Auth

/// Signing in with a passkey (#551, backend #808), over the mock behind the
/// fleet's edge rules: a public challenge, the authenticator's signature,
/// then `Login { passkey }` — no second step.
@MainActor
struct PasskeySignInTests {
    private func makeManager(passkeysUnavailable: Bool = false) async throws -> SessionManager {
        let backend = MockBackend(enforcesEdgePolicy: true)
        MockAuthService(passkeysUnavailable: passkeysUnavailable).register(on: backend.bff)
        let manager = SessionManager(
            authClient: Auth_V1_AuthServiceClient(
                client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: backend.bff)
            ),
            store: InMemorySessionStore(),
            configuration: .init(deviceID: "e2e-device"),
            guest: GuestSessionContext(store: InMemorySessionStore())
        )
        #expect(try await manager.validAccessToken()?.hasPrefix("gt-") == true, "starts as a guest")
        return manager
    }

    private func seededAuthenticator() -> SimulatedPasskeyAuthorizer {
        SimulatedPasskeyAuthorizer(
            signInCredentialID: Data(base64URL: MockAuthService.seededPasskeyID) ?? Data(),
            signInUserHandle: Data(MockAuthService.accountID.utf8)
        )
    }

    /// Done when: a passkey signs the account in, with no second step.
    @Test func aPasskeySignsIn() async throws {
        let manager = try await makeManager()
        let request = try await manager.startPasskeySignIn()
        #expect(request.relyingPartyID == MockAuthService.passkeyRelyingParty)
        #expect(String(decoding: request.challengeData, as: UTF8.self).hasPrefix("passkey-sign-in-"))

        let assertion = try await seededAuthenticator().assertPasskey(request)
        guard case .existing(let account) = try await manager.signIn(.passkey(assertion)) else {
            Issue.record("expected the demo account")
            return
        }
        #expect(account.accountID == AccountID(MockAuthService.accountID))
        await manager.completeSignIn(account)
        #expect(await manager.currentState() == .authenticated(AccountID(MockAuthService.accountID)))

        // The challenge is single use.
        await #expect(throws: AuthError.passkeyRejected) { _ = try await manager.signIn(.passkey(assertion)) }
    }

    /// A passkey the account no longer has does not sign in.
    @Test func anUnknownPasskeyIsRejected() async throws {
        let manager = try await makeManager()
        let authenticator = seededAuthenticator()
        authenticator.signInCredentialID = Data("someone-else".utf8)
        let assertion = try await authenticator.assertPasskey(try await manager.startPasskeySignIn())
        await #expect(throws: AuthError.passkeyRejected) { _ = try await manager.signIn(.passkey(assertion)) }
    }

    /// A server without passkeys says so before any sheet.
    @Test func unavailableSaysSo() async throws {
        let manager = try await makeManager(passkeysUnavailable: true)
        await #expect(throws: AuthError.passkeysUnavailable) { _ = try await manager.startPasskeySignIn() }
    }

    /// An account is never made with a passkey.
    @Test func aPasskeyDoesNotSignUp() async throws {
        let manager = try await makeManager()
        let assertion = try await seededAuthenticator().assertPasskey(try await manager.startPasskeySignIn())
        let details = SignUpDetails(
            dateOfBirth: DateComponents(year: 1990, month: 4, day: 12),
            policyVersion: "2026-10", marketing: false, analytics: true, homeCountry: "FR"
        )
        await #expect(throws: AuthError.passkeyRejected) { _ = try await manager.signUp(.passkey(assertion), details: details) }
    }

    @Test func thePasskeyRowSitsUnderTheProvidersWhenOffered() {
        #expect(SignInMethod.offered(passkeys: false) == SignInMethod.all)
        #expect(SignInMethod.offered(passkeys: true) == [.provider(.apple), .provider(.google), .passkey, .email, .phone])
        #expect(SignInMethod.passkey.displayName == "Sign in with a passkey")
    }
}
