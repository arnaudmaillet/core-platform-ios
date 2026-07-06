import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Testing
@testable import Auth

/// Exercises the entire client stack — SessionManager → generated Connect
/// client → real ProtocolClient (Connect framing, binary proto codec) →
/// MockBFF — proving the slice works with production wire bytes, in-process.
struct AuthEndToEndTests {
    private func makeBFF(accessTokenLifetimeSeconds: Int64) -> MockBFF {
        let bff = MockBFF()
        MockAuthService(accessTokenLifetimeSeconds: accessTokenLifetimeSeconds).register(on: bff)
        return bff
    }

    private func makeManager(bff: MockBFF, store: InMemorySessionStore) -> SessionManager {
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return SessionManager(
            authClient: Auth_V1_AuthServiceClient(client: client),
            store: store,
            configuration: .init(deviceID: "e2e-device")
        )
    }

    private func makeStack(
        accessTokenLifetimeSeconds: Int64 = 900
    ) -> (SessionManager, InMemorySessionStore) {
        let store = InMemorySessionStore()
        let manager = makeManager(bff: makeBFF(accessTokenLifetimeSeconds: accessTokenLifetimeSeconds), store: store)
        return (manager, store)
    }

    @Test func fullLoginRefreshLogoutLifecycle() async throws {
        let (manager, store) = makeStack(accessTokenLifetimeSeconds: 0) // expires immediately

        // Login with the fixture credentials over real Connect framing.
        try await manager.login(
            username: MockAuthService.defaultCredentials.username,
            password: MockAuthService.defaultCredentials.password
        )
        #expect(await manager.currentState() == .authenticated(AccountID(MockAuthService.accountID)))
        let initialRefreshToken = try #require(try store.load()?.refreshToken)

        // The zero-lifetime access token forces a real Refresh round-trip,
        // which must rotate the refresh token per the contract.
        let refreshed = try #require(try await manager.validAccessToken())
        #expect(refreshed.hasPrefix("at-"))
        let rotated = try #require(try store.load()?.refreshToken)
        #expect(rotated != initialRefreshToken)

        await manager.logout()
        #expect(await manager.currentState() == .unauthenticated)
    }

    @Test func wrongPasswordFailsWithInvalidCredentials() async {
        let (manager, _) = makeStack()

        await #expect(throws: AuthError.invalidCredentials) {
            try await manager.login(username: "demo", password: "not-the-password")
        }
        #expect(await manager.currentState() == .unauthenticated)
    }

    @Test func replayingRotatedRefreshTokenRevokesSession() async throws {
        let bff = makeBFF(accessTokenLifetimeSeconds: 0)
        let store = InMemorySessionStore()
        let manager = makeManager(bff: bff, store: store)

        try await manager.login(
            username: MockAuthService.defaultCredentials.username,
            password: MockAuthService.defaultCredentials.password
        )
        let preRotationSession = try #require(try store.load())

        // Legitimate refresh rotates the token server-side.
        _ = try await manager.validAccessToken()
        let currentSession = try #require(try store.load())
        #expect(currentSession.refreshToken != preRotationSession.refreshToken)

        // A second client replaying the pre-rotation token (hijack or bug)
        // must be rejected AND revoke the whole session generation…
        let replayStore = InMemorySessionStore(session: preRotationSession)
        let replayManager = makeManager(bff: bff, store: replayStore)
        await #expect(throws: AuthError.sessionExpired) {
            try await replayManager.validAccessToken()
        }

        // …so even the legitimate holder of the current token is now signed out.
        let victimStore = InMemorySessionStore(session: currentSession)
        let victimManager = makeManager(bff: bff, store: victimStore)
        await #expect(throws: AuthError.sessionExpired) {
            try await victimManager.validAccessToken()
        }
        #expect(try victimStore.load() == nil)
    }
}
