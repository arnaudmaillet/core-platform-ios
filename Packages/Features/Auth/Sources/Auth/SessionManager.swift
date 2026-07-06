import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreStorage
import Foundation

/// Owns the auth session lifecycle: login, persistence, token refresh, logout.
///
/// Refresh is **single-flight by construction**: the auth.v1 contract rotates
/// refresh tokens on every use and treats reuse as compromise (revoking the
/// whole session generation), so two concurrent refreshes would sign the user
/// out. All concurrent `validAccessToken()` callers await one shared task.
public actor SessionManager {
    public struct Configuration: Sendable {
        /// Stable client-provided device identifier for session management.
        public var deviceID: String
        public var userAgent: String
        /// Tokens within this many seconds of expiry are refreshed eagerly so
        /// they don't expire mid-flight.
        public var expiryLeeway: TimeInterval

        public init(
            deviceID: String,
            userAgent: String = "core-platform-ios",
            expiryLeeway: TimeInterval = 30
        ) {
            self.deviceID = deviceID
            self.userAgent = userAgent
            self.expiryLeeway = expiryLeeway
        }
    }

    private let authClient: any Auth_V1_AuthServiceClientInterface
    private let store: any SessionStore
    private let configuration: Configuration
    private let now: @Sendable () -> Date

    private var session: AuthSession?
    private var didBootstrap = false
    private var refreshTask: Task<AuthSession, Error>?
    private var observers: [UUID: AsyncStream<AuthState>.Continuation] = [:]

    public init(
        authClient: any Auth_V1_AuthServiceClientInterface,
        store: any SessionStore,
        configuration: Configuration,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authClient = authClient
        self.store = store
        self.configuration = configuration
        self.now = now
    }

    // MARK: - Login / logout

    public func login(username: String, password: String) async throws {
        var grant = Auth_V1_PasswordGrant()
        grant.username = username
        grant.password = password

        var request = Auth_V1_LoginRequest()
        request.grantType = .password
        request.credential = .password(grant)
        request.device = deviceContext()

        let response = await authClient.login(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            let session = Self.makeSession(
                accountID: AccountID(body.accountID),
                tokens: body.tokens,
                now: now()
            )
            self.session = session
            try? store.save(session)
            broadcast(.authenticated(session.accountID))
        case .failure(let error):
            throw AuthError.loginFailure(error)
        }
    }

    public func logout() async {
        bootstrapIfNeeded()
        guard let session else { return }
        self.session = nil
        try? store.clear()
        broadcast(.unauthenticated)

        // Best-effort server-side revocation; local sign-out already happened.
        var request = Auth_V1_LogoutRequest()
        request.sessionID = session.sessionID.rawValue
        _ = await authClient.logout(request: request, headers: [:])
    }

    // MARK: - Token vending (AuthTokenProviding)

    public func validAccessToken() async throws -> String? {
        bootstrapIfNeeded()
        guard let session else { return nil }
        if session.accessTokenExpiry.timeIntervalSince(now()) > configuration.expiryLeeway {
            return session.accessToken
        }
        return try await refreshedSession().accessToken
    }

    private func refreshedSession() async throws -> AuthSession {
        if let refreshTask {
            // A refresh is already in flight; every waiter shares its outcome.
            return try await refreshTask.value
        }
        guard let current = session else { throw AuthError.notAuthenticated }

        let client = authClient
        let device = deviceContext()
        let issuedAt = now()
        let task = Task<AuthSession, Error> {
            var request = Auth_V1_RefreshRequest()
            request.refreshToken = current.refreshToken
            request.device = device

            let response = await client.refresh(request: request, headers: [:])
            switch response.result {
            case .success(let body):
                return Self.makeSession(accountID: current.accountID, tokens: body.tokens, now: issuedAt)
            case .failure(let error):
                if error.code == .unauthenticated || error.code == .permissionDenied {
                    throw AuthError.sessionExpired
                }
                throw AuthError.transport(message: error.message ?? "code \(error.code)")
            }
        }
        refreshTask = task
        defer { refreshTask = nil }

        do {
            let refreshed = try await task.value
            session = refreshed
            try? store.save(refreshed)
            return refreshed
        } catch AuthError.sessionExpired {
            // The server rejected our rotation handle; the session is gone.
            session = nil
            try? store.clear()
            broadcast(.unauthenticated)
            throw AuthError.sessionExpired
        }
    }

    // MARK: - State observation

    private func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        session = try? store.load()
    }

    private func currentAuthState() -> AuthState {
        bootstrapIfNeeded()
        return session.map { .authenticated($0.accountID) } ?? .unauthenticated
    }

    private func broadcast(_ state: AuthState) {
        for continuation in observers.values {
            continuation.yield(state)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: - Helpers

    private func deviceContext() -> Auth_V1_DeviceContext {
        var device = Auth_V1_DeviceContext()
        device.deviceID = configuration.deviceID
        device.userAgent = configuration.userAgent
        return device
    }

    private static func makeSession(
        accountID: AccountID,
        tokens: Auth_V1_TokenPair,
        now: Date
    ) -> AuthSession {
        AuthSession(
            accountID: accountID,
            sessionID: SessionID(tokens.sessionID),
            accessToken: tokens.accessToken,
            accessTokenExpiry: now.addingTimeInterval(TimeInterval(tokens.expiresIn)),
            refreshToken: tokens.refreshToken
        )
    }
}

// MARK: - Protocol conformances

extension SessionManager: AuthTokenProviding {}

extension SessionManager: AuthSessionProviding {
    public func currentState() -> AuthState {
        currentAuthState()
    }

    public func stateUpdates() -> AsyncStream<AuthState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: AuthState.self)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        observers[id] = continuation
        continuation.yield(currentAuthState())
        return stream
    }
}
