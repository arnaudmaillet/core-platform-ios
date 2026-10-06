import Connect
import CoreContracts
import CoreModels
import CoreStorage
import Foundation
import Testing
@testable import Auth

/// Scriptable fake of the generated auth client for unit-testing the
/// SessionManager without any transport.
private final class FakeAuthClient: Auth_V1_AuthServiceClientInterface, @unchecked Sendable {
    let lock = NSLock()
    var refreshCallCount = 0
    var refreshDelayNanoseconds: UInt64 = 0
    var refreshResult: Result<Auth_V1_RefreshResponse, ConnectError> = .failure(.init(code: .unimplemented, message: nil))
    var loginResult: Result<Auth_V1_LoginResponse, ConnectError> = .failure(.init(code: .unimplemented, message: nil))
    var lastRefreshToken: String?
    var logoutHeaders: [Connect.Headers] = []
    var guestResult: Result<Auth_V1_StartGuestSessionResponse, ConnectError> = .failure(.init(code: .unimplemented, message: nil))
    var guestRequests: [Auth_V1_StartGuestSessionRequest] = []
    var guestDelayNanoseconds: UInt64 = 0
    var challengeResult: Result<Auth_V1_StartDeviceAttestationResponse, ConnectError> = .failure(.init(code: .unimplemented, message: nil))

    func login(request: Auth_V1_LoginRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_LoginResponse> {
        response(from: lock.withLock { loginResult })
    }

    func refresh(request: Auth_V1_RefreshRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_RefreshResponse> {
        let delay = lock.withLock {
            refreshCallCount += 1
            lastRefreshToken = request.refreshToken
            return refreshDelayNanoseconds
        }
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        return response(from: lock.withLock { refreshResult })
    }

    func logout(request: Auth_V1_LogoutRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_LogoutResponse> {
        lock.withLock { logoutHeaders.append(headers) }
        var body = Auth_V1_LogoutResponse()
        body.success = true
        return response(from: .success(body))
    }

    func logoutAllSessions(request: Auth_V1_LogoutAllSessionsRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_LogoutAllSessionsResponse> {
        response(from: .failure(.init(code: .unimplemented, message: nil)))
    }

    func introspect(request: Auth_V1_IntrospectRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_IntrospectResponse> {
        response(from: .failure(.init(code: .unimplemented, message: nil)))
    }

    func listSessions(request: Auth_V1_ListSessionsRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_ListSessionsResponse> {
        response(from: .failure(.init(code: .unimplemented, message: nil)))
    }

    func startGuestSession(request: Auth_V1_StartGuestSessionRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_StartGuestSessionResponse> {
        let delay = lock.withLock {
            guestRequests.append(request)
            return guestDelayNanoseconds
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return response(from: lock.withLock { guestResult })
    }

    func changePassword(request: Auth_V1_ChangePasswordRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_ChangePasswordResponse> {
        response(from: .failure(.init(code: .unimplemented, message: nil)))
    }

    func verifyCredentials(request: Auth_V1_VerifyCredentialsRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_VerifyCredentialsResponse> {
        response(from: .failure(.init(code: .unimplemented, message: nil)))
    }

    private func response<M>(from result: Result<M, ConnectError>) -> ResponseMessage<M> {
        switch result {
        case .success(let message):
            ResponseMessage(result: .success(message))
        case .failure(let error):
            ResponseMessage(result: .failure(error))
        }
    }

    func signUp(
        request: Auth_V1_SignUpRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Auth_V1_SignUpResponse> {
        ResponseMessage(result: .success(Auth_V1_SignUpResponse()))
    }

    func startVerification(
        request: Auth_V1_StartVerificationRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Auth_V1_StartVerificationResponse> {
        ResponseMessage(result: .success(Auth_V1_StartVerificationResponse()))
    }

    func completeLogin(request: Auth_V1_CompleteLoginRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_LoginResponse> {
        response(from: .failure(.init(code: .unimplemented, message: nil)))
    }

    func startFederatedSignIn(request: Auth_V1_StartFederatedSignInRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_StartFederatedSignInResponse> {
        response(from: .failure(.init(code: .unimplemented, message: nil)))
    }

    func startDeviceAttestation(request: Auth_V1_StartDeviceAttestationRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_StartDeviceAttestationResponse> {
        response(from: lock.withLock { challengeResult })
    }

    func changeContact(request: Auth_V1_ChangeContactRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_ChangeContactResponse> {
        response(from: .failure(.init(code: .unimplemented, message: nil)))
    }

    func startMfaEnrollment(request: Auth_V1_StartMfaEnrollmentRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_StartMfaEnrollmentResponse> {
        response(from: .failure(.init(code: .unimplemented, message: nil)))
    }

    func confirmMfaEnrollment(request: Auth_V1_ConfirmMfaEnrollmentRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_BackupCodesResponse> {
        response(from: .failure(.init(code: .unimplemented, message: nil)))
    }

    func disableMfa(request: Auth_V1_DisableMfaRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_DisableMfaResponse> {
        response(from: .failure(.init(code: .unimplemented, message: nil)))
    }

    func regenerateBackupCodes(request: Auth_V1_RegenerateBackupCodesRequest, headers: Connect.Headers) async -> ResponseMessage<Auth_V1_BackupCodesResponse> {
        response(from: .failure(.init(code: .unimplemented, message: nil)))
    }
}

private func makeTokens(access: String, refresh: String, session: String = "sess-1", expiresIn: Int64 = 900) -> Auth_V1_TokenPair {
    var tokens = Auth_V1_TokenPair()
    tokens.accessToken = access
    tokens.refreshToken = refresh
    tokens.sessionID = session
    tokens.expiresIn = expiresIn
    tokens.tokenType = "Bearer"
    return tokens
}

private func expiredSession() -> AuthSession {
    AuthSession(
        accountID: AccountID("acct-1"),
        sessionID: SessionID("sess-1"),
        accessToken: "at-stale",
        accessTokenExpiry: Date(timeIntervalSince1970: 100), // long past
        refreshToken: "rt-1"
    )
}

struct SessionManagerTests {
    private static let config = SessionManager.Configuration(deviceID: "test-device")

    @Test func loginStoresSessionAndBroadcastsAuthenticated() async throws {
        let client = FakeAuthClient()
        var body = Auth_V1_LoginResponse()
        body.accountID = "acct-1"
        body.tokens = makeTokens(access: "at-1", refresh: "rt-1")
        client.loginResult = .success(body)
        let store = InMemorySessionStore()
        let manager = SessionManager(authClient: client, store: store, configuration: Self.config)

        try await manager.login(username: "demo", password: "pw")

        #expect(try store.load()?.accessToken == "at-1")
        #expect(await manager.currentState() == .authenticated(AccountID("acct-1")))
        #expect(try await manager.validAccessToken() == "at-1")
    }

    /// Step-up (#648): the fresh access token replaces the session's; the
    /// session and its refresh token stay.
    @Test func aStepUpTokenReplacesTheAccessTokenOnly() async throws {
        let client = FakeAuthClient()
        var body = Auth_V1_LoginResponse()
        body.accountID = "acct-1"
        body.tokens = makeTokens(access: "at-1", refresh: "rt-1")
        client.loginResult = .success(body)
        let store = InMemorySessionStore()
        let manager = SessionManager(authClient: client, store: store, configuration: Self.config)
        try await manager.login(username: "demo", password: "pw")

        await manager.installStepUpToken("at-stepped-up", expiresIn: 900)
        #expect(try await manager.validAccessToken() == "at-stepped-up")
        let saved = try #require(try store.load())
        #expect(saved.accessToken == "at-stepped-up")
        #expect(saved.refreshToken == "rt-1")
        #expect(saved.sessionID == SessionID(body.tokens.sessionID))
    }

    /// A login that reactivated a deactivated account (#650) is said once.
    @Test func aReactivatingLoginIsAnnouncedOnce() async throws {
        let client = FakeAuthClient()
        var body = Auth_V1_LoginResponse()
        body.accountID = "acct-1"
        body.tokens = makeTokens(access: "at-1", refresh: "rt-1")
        body.reactivated = true
        client.loginResult = .success(body)
        let manager = SessionManager(authClient: client, store: InMemorySessionStore(), configuration: Self.config)
        #expect(await !manager.consumeReactivationNotice())
        try await manager.login(username: "demo", password: "pw")
        #expect(await manager.consumeReactivationNotice())
        #expect(await !manager.consumeReactivationNotice())
    }

    @Test func invalidCredentialsSurfaceAsAuthError() async {
        let client = FakeAuthClient()
        client.loginResult = .failure(ConnectError(code: .unauthenticated, message: "nope"))
        let manager = SessionManager(
            authClient: client,
            store: InMemorySessionStore(),
            configuration: Self.config
        )

        await #expect(throws: AuthError.invalidCredentials) {
            try await manager.login(username: "demo", password: "wrong")
        }
    }

    @Test func expiredTokenTriggersExactlyOneRefreshUnderConcurrency() async throws {
        let client = FakeAuthClient()
        client.refreshDelayNanoseconds = 50_000_000 // 50ms window for racers to pile up
        var body = Auth_V1_RefreshResponse()
        body.tokens = makeTokens(access: "at-2", refresh: "rt-2")
        client.refreshResult = .success(body)
        let store = InMemorySessionStore(session: expiredSession())
        let manager = SessionManager(authClient: client, store: store, configuration: Self.config)

        let tokens = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<10 {
                group.addTask { try await manager.validAccessToken() }
            }
            return try await group.reduce(into: [String?]()) { $0.append($1) }
        }

        #expect(tokens.allSatisfy { $0 == "at-2" })
        #expect(client.lock.withLock { client.refreshCallCount } == 1)
        #expect(try store.load()?.refreshToken == "rt-2")
    }

    @Test func rejectedRefreshClearsSessionAndBroadcastsUnauthenticated() async throws {
        let client = FakeAuthClient()
        client.refreshResult = .failure(ConnectError(code: .unauthenticated, message: "reuse detected"))
        let store = InMemorySessionStore(session: expiredSession())
        let manager = SessionManager(authClient: client, store: store, configuration: Self.config)

        let updates = await manager.stateUpdates()
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .authenticated(AccountID("acct-1")))

        await #expect(throws: AuthError.sessionExpired) {
            try await manager.validAccessToken()
        }

        #expect(await iterator.next() == .unauthenticated)
        #expect(try store.load() == nil)
        #expect(await manager.currentState() == .unauthenticated)
    }

    @Test func transportRefreshFailureKeepsSessionForRetry() async throws {
        let client = FakeAuthClient()
        client.refreshResult = .failure(ConnectError(code: .unavailable, message: "offline"))
        let store = InMemorySessionStore(session: expiredSession())
        let manager = SessionManager(authClient: client, store: store, configuration: Self.config)

        await #expect(throws: AuthError.transport(message: "offline")) {
            try await manager.validAccessToken()
        }

        // Session survives a network blip; only auth rejection clears it.
        #expect(try store.load() != nil)
        #expect(await manager.currentState() == .authenticated(AccountID("acct-1")))
    }

    @Test func logoutClearsStateAndRevokesServerSide() async throws {
        let client = FakeAuthClient()
        var body = Auth_V1_LoginResponse()
        body.accountID = "acct-1"
        body.tokens = makeTokens(access: "at-1", refresh: "rt-1")
        client.loginResult = .success(body)
        let store = InMemorySessionStore()
        let manager = SessionManager(authClient: client, store: store, configuration: Self.config)

        try await manager.login(username: "demo", password: "pw")
        await manager.logout()

        #expect(await manager.currentState() == .unauthenticated)
        #expect(try store.load() == nil)
        #expect(try await manager.validAccessToken() == nil)
    }

    /// #486: the revocation carries the ending session's own bearer — the
    /// edge refuses a bare `Logout`.
    @Test func logoutSendsTheSessionsBearer() async throws {
        let client = FakeAuthClient()
        var body = Auth_V1_LoginResponse()
        body.accountID = "acct-1"
        body.tokens = makeTokens(access: "at-1", refresh: "rt-1")
        client.loginResult = .success(body)
        let manager = SessionManager(authClient: client, store: InMemorySessionStore(), configuration: Self.config)

        try await manager.login(username: "demo", password: "pw")
        await manager.logout()

        #expect(client.logoutHeaders.map { $0["Authorization"] } == [["Bearer at-1"]])
    }

    @Test func anExpiredSessionIsRefreshedToBeRevoked() async throws {
        let client = FakeAuthClient()
        var refreshed = Auth_V1_RefreshResponse()
        refreshed.tokens = makeTokens(access: "at-2", refresh: "rt-2")
        client.refreshResult = .success(refreshed)
        let store = InMemorySessionStore()
        try store.save(expiredSession())
        let manager = SessionManager(authClient: client, store: store, configuration: Self.config)

        await manager.logout()

        #expect(client.lastRefreshToken == "rt-1")
        #expect(client.logoutHeaders.map { $0["Authorization"] } == [["Bearer at-2"]])
        #expect(await manager.currentState() == .unauthenticated, "the refresh never signs the viewer back in")
    }

    @Test func aSessionTheServerForgotIsOnlyEndedLocally() async throws {
        let client = FakeAuthClient()
        client.refreshResult = .failure(ConnectError(code: .unauthenticated, message: "revoked"))
        let store = InMemorySessionStore()
        try store.save(expiredSession())
        let manager = SessionManager(authClient: client, store: store, configuration: Self.config)

        await manager.logout()

        #expect(client.logoutHeaders.isEmpty, "nothing left to revoke")
        #expect(await manager.currentState() == .unauthenticated)
    }

    /// A refresh still in flight when the viewer logs out must not hand them
    /// their session back when it lands.
    @Test func aRefreshLandingAfterLogoutDoesNotSignBackIn() async throws {
        let client = FakeAuthClient()
        client.refreshDelayNanoseconds = 100_000_000
        var refreshed = Auth_V1_RefreshResponse()
        refreshed.tokens = makeTokens(access: "at-2", refresh: "rt-2")
        client.refreshResult = .success(refreshed)
        let store = InMemorySessionStore()
        try store.save(expiredSession())
        let manager = SessionManager(authClient: client, store: store, configuration: Self.config)

        async let token = manager.validAccessToken()
        try await Task.sleep(nanoseconds: 20_000_000)
        await manager.logout()
        _ = try? await token

        #expect(await manager.currentState() == .unauthenticated)
        #expect(try store.load() == nil)
    }

    // MARK: - Guest sessions (guest mode B1)

    private struct StubAttestor: GuestAttesting {
        let proof: GuestAttestation?
        func attest(challenge: String) async -> GuestAttestation? {
            proof.map { GuestAttestation(keyID: $0.keyID, attestation: "\($0.attestation)|\(challenge)") }
        }
    }

    private func guestResponse(access: String, refresh: String = "grt-1", guestID: String = "guest-1") -> Auth_V1_StartGuestSessionResponse {
        var body = Auth_V1_StartGuestSessionResponse()
        body.guestID = guestID
        body.tokens = makeTokens(access: access, refresh: refresh, session: "guest-sess-1")
        return body
    }

    private func guestManager(
        _ client: FakeAuthClient, guestStore: InMemorySessionStore = InMemorySessionStore(),
        attestor: (any GuestAttesting)? = nil, store: InMemorySessionStore = InMemorySessionStore()
    ) -> SessionManager {
        SessionManager(
            authClient: client, store: store, configuration: Self.config,
            guest: GuestSessionContext(
                store: guestStore, locale: { "fr-FR" }, regionHint: { "FR" },
                currentCountry: { "FR" }, attestor: attestor
            )
        )
    }

    @Test func aGuestReadsWithAGuestTokenStartedOnFirstUse() async throws {
        let client = FakeAuthClient()
        client.guestResult = .success(guestResponse(access: "gt-1"))
        let guestStore = InMemorySessionStore()
        let manager = guestManager(client, guestStore: guestStore)

        #expect(try await manager.validAccessToken() == "gt-1")
        #expect(try await manager.validAccessToken() == "gt-1", "the session is reused")
        #expect(client.guestRequests.count == 1)
        let sent = try #require(client.guestRequests.first)
        #expect(sent.device.deviceID == "test-device")
        #expect(sent.locale == "fr-FR" && sent.regionHint == "FR" && sent.currentCountry == "FR")
        #expect(try guestStore.load()?.accessToken == "gt-1", "kept in its own keychain item")
        #expect(await manager.currentState() == .unauthenticated, "a guest token is no account")
    }

    @Test func concurrentFirstReadsStartOneGuestSession() async throws {
        let client = FakeAuthClient()
        client.guestDelayNanoseconds = 50_000_000
        client.guestResult = .success(guestResponse(access: "gt-1"))
        let manager = guestManager(client)

        async let a = manager.validAccessToken()
        async let b = manager.validAccessToken()
        async let c = manager.validAccessToken()
        let tokens = try await [a, b, c]

        #expect(tokens == ["gt-1", "gt-1", "gt-1"])
        #expect(client.guestRequests.count == 1)
    }

    @Test func anExpiredGuestTokenIsRefreshed() async throws {
        let client = FakeAuthClient()
        var refreshed = Auth_V1_RefreshResponse()
        refreshed.tokens = makeTokens(access: "gt-2", refresh: "grt-2", session: "guest-sess-1")
        client.refreshResult = .success(refreshed)
        let guestStore = InMemorySessionStore(session: AuthSession(
            accountID: AccountID("guest-1"), sessionID: SessionID("guest-sess-1"),
            accessToken: "gt-stale", accessTokenExpiry: Date(timeIntervalSince1970: 100), refreshToken: "grt-1"
        ))
        let manager = guestManager(client, guestStore: guestStore)

        #expect(try await manager.validAccessToken() == "gt-2")
        #expect(client.lastRefreshToken == "grt-1")
        #expect(client.guestRequests.isEmpty)
    }

    @Test func aGuestSessionTheServerForgotIsReplaced() async throws {
        let client = FakeAuthClient()
        client.refreshResult = .failure(ConnectError(code: .unauthenticated, message: "revoked"))
        client.guestResult = .success(guestResponse(access: "gt-new"))
        let guestStore = InMemorySessionStore(session: AuthSession(
            accountID: AccountID("guest-1"), sessionID: SessionID("guest-sess-1"),
            accessToken: "gt-stale", accessTokenExpiry: Date(timeIntervalSince1970: 100), refreshToken: "grt-1"
        ))
        let manager = guestManager(client, guestStore: guestStore)

        #expect(try await manager.validAccessToken() == "gt-new")
        #expect(client.guestRequests.count == 1)
    }

    @Test func noGuestSessionMeansNoToken() async throws {
        let client = FakeAuthClient()
        client.guestResult = .failure(ConnectError(code: .permissionDenied, message: "guest sessions are off"))
        let manager = guestManager(client)
        #expect(try await manager.validAccessToken() == nil)
    }

    /// A member's token wins; signing out falls back to the guest's.
    @Test func aMemberOutranksTheGuestAndLeavesItBehind() async throws {
        let client = FakeAuthClient()
        client.guestResult = .success(guestResponse(access: "gt-1"))
        var login = Auth_V1_LoginResponse()
        login.accountID = "acct-1"
        login.tokens = makeTokens(access: "at-1", refresh: "rt-1")
        client.loginResult = .success(login)
        let manager = guestManager(client)

        #expect(try await manager.validAccessToken() == "gt-1")
        try await manager.login(username: "demo", password: "pw")
        #expect(try await manager.validAccessToken() == "at-1")
        await manager.logout()
        #expect(try await manager.validAccessToken() == "gt-1")
        #expect(client.guestRequests.count == 1, "the guest session outlived the member's")
    }

    /// #523: a challenge, then an attestation bound to it, on the request.
    @Test func theGuestSessionCarriesAnAppAttestProof() async throws {
        let client = FakeAuthClient()
        var challenge = Auth_V1_StartDeviceAttestationResponse()
        challenge.challenge = "ch-1"
        client.challengeResult = .success(challenge)
        client.guestResult = .success(guestResponse(access: "gt-1"))
        let manager = guestManager(client, attestor: StubAttestor(proof: GuestAttestation(keyID: "key-1", attestation: "att")))

        _ = try await manager.validAccessToken()

        let sent = try #require(client.guestRequests.first)
        #expect(sent.attestKeyID == "key-1")
        #expect(sent.attestation == "att|ch-1")
        #expect(sent.attestChallenge == "ch-1")
    }

    /// The simulator, an old device: no proof, and the session still starts.
    @Test func noAttestationStillStartsTheSession() async throws {
        let client = FakeAuthClient()
        var challenge = Auth_V1_StartDeviceAttestationResponse()
        challenge.challenge = "ch-1"
        client.challengeResult = .success(challenge)
        client.guestResult = .success(guestResponse(access: "gt-1"))
        let manager = guestManager(client, attestor: StubAttestor(proof: nil))

        #expect(try await manager.validAccessToken() == "gt-1")
        let sent = try #require(client.guestRequests.first)
        #expect(sent.attestation.isEmpty && sent.attestKeyID.isEmpty && sent.attestChallenge.isEmpty)
    }

    @Test func unauthenticatedManagerVendsNilToken() async throws {
        let manager = SessionManager(
            authClient: FakeAuthClient(),
            store: InMemorySessionStore(),
            configuration: Self.config
        )
        #expect(try await manager.validAccessToken() == nil)
    }
}
