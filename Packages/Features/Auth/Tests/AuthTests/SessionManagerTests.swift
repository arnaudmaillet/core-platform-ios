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
        response(from: .failure(.init(code: .unimplemented, message: nil)))
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

    @Test func unauthenticatedManagerVendsNilToken() async throws {
        let manager = SessionManager(
            authClient: FakeAuthClient(),
            store: InMemorySessionStore(),
            configuration: Self.config
        )
        #expect(try await manager.validAccessToken() == nil)
    }
}
