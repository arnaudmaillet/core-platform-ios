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
///
/// **Guests read with a token of their own** (guest mode B1): with nobody
/// signed in, `validAccessToken()` vends a guest session's token — started on
/// first use, refreshed like a member's, and kept when a member signs out.
/// The viewer stays `.unauthenticated`: a guest token is a read pass, not an
/// account.
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

    let authClient: any Auth_V1_AuthServiceClientInterface
    let store: any SessionStore
    private let configuration: Configuration
    let now: @Sendable () -> Date

    var session: AuthSession?
    /// Nil keeps the pre-guest behaviour: no token without a member session.
    let guest: GuestSessionContext?
    /// The guest's session. Its `accountID` holds the GUEST id — there is no
    /// account; nothing outside this type ever reads it.
    var guestSession: AuthSession?
    /// Single-flight, like the member refresh: a start or a refresh of the
    /// guest session in flight that every reader awaits.
    private var guestTask: Task<AuthSession?, Never>?
    private var didBootstrap = false
    private var refreshTask: Task<AuthSession, Error>?
    private var observers: [UUID: AsyncStream<AuthState>.Continuation] = [:]
    /// The last login resumed a self-deactivated account (#650), and nobody
    /// has said "welcome back" yet.
    var pendingReactivationNotice = false
    /// The last session came from a sign-up (#666), and nobody has asked
    /// the new member about notifications yet.
    var pendingSignUpNotice = false

    public init(
        authClient: any Auth_V1_AuthServiceClientInterface,
        store: any SessionStore,
        configuration: Configuration,
        guest: GuestSessionContext? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authClient = authClient
        self.store = store
        self.guest = guest
        self.configuration = configuration
        self.now = now
    }

    // MARK: - Login / logout

    /// Signs in with a password. With two-step sign-in on (#383) the password
    /// is proven but no session exists yet: `.needsSecondStep`, and
    /// `completeLogin` finishes with the holder's code.
    public func login(username: String, password: String) async throws -> LoginOutcome {
        var grant = Auth_V1_PasswordGrant()
        grant.username = username
        grant.password = password

        var request = Auth_V1_LoginRequest()
        request.grantType = .password
        request.credential = .password(grant)
        request.device = deviceContext()

        let response = await authClient.login(request: request, headers: [:])
        switch response.result {
        case .success(let body) where body.mfaRequired:
            return .needsSecondStep(Self.secondStepChallenge(body))
        case .success(let body):
            adopt(body)
            return .signedIn
        case .failure(let error):
            throw AuthError.loginFailure(error)
        }
    }

    /// The second step of a password sign-in: the authenticator's six digits
    /// or a backup code (`auth.v1.CompleteLogin`). A wrong code leaves the
    /// challenge usable.
    public func completeLogin(_ challenge: SecondStepChallenge, code: String) async throws {
        adopt(try await secondStep(challenge, code: code))
    }

    /// A finished sign-in becomes the session.
    private func adopt(_ body: Auth_V1_LoginResponse) {
        let session = Self.makeSession(
            accountID: AccountID(body.accountID),
            tokens: body.tokens,
            now: now()
        )
        self.session = session
        try? store.save(session)
        pendingReactivationNotice = body.reactivated
        pendingSignUpNotice = false
        broadcast(.authenticated(session.accountID))
    }

    /// `auth.v1.CompleteLogin`.
    func secondStep(_ challenge: SecondStepChallenge, code: String) async throws -> Auth_V1_LoginResponse {
        var request = Auth_V1_CompleteLoginRequest()
        request.mfaToken = challenge.token
        request.code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = await authClient.completeLogin(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return body
        case .failure(let error):
            throw AuthError.secondStepFailure(error)
        }
    }

    static func secondStepChallenge(_ body: Auth_V1_LoginResponse) -> SecondStepChallenge {
        SecondStepChallenge(token: body.mfaToken, expiresIn: TimeInterval(body.mfaExpiresIn))
    }

    /// True once after a login that reactivated a self-deactivated account,
    /// so the shell can welcome the holder back exactly once.
    public func consumeReactivationNotice() -> Bool {
        defer { pendingReactivationNotice = false }
        return pendingReactivationNotice
    }

    /// True once after a sign-up, so the shell can ask the new member about
    /// notifications exactly once (#666). A sign-in never sets it.
    public func consumeSignUpNotice() -> Bool {
        defer { pendingSignUpNotice = false }
        return pendingSignUpNotice
    }

    /// Step-up (`auth.v1.VerifyCredentials`, #648): the server re-proved the
    /// holder and minted a fresh access token for THIS session, which
    /// step-up-gated RPCs (deactivation, deletion, contact changes) accept
    /// for a few minutes. It replaces the access token; the session and its
    /// refresh token are unchanged.
    public func installStepUpToken(_ accessToken: String, expiresIn: Int64) {
        bootstrapIfNeeded()
        guard let current = session, !accessToken.isEmpty else { return }
        let updated = AuthSession(
            accountID: current.accountID,
            sessionID: current.sessionID,
            accessToken: accessToken,
            accessTokenExpiry: now().addingTimeInterval(TimeInterval(expiresIn)),
            refreshToken: current.refreshToken
        )
        session = updated
        try? store.save(updated)
    }

    public func logout() async {
        bootstrapIfNeeded()
        guard let session else { return }
        self.session = nil
        try? store.clear()
        broadcast(.unauthenticated)

        // Best-effort server-side revocation; local sign-out already happened.
        //
        // ⚠️ WITH THE SESSION'S OWN BEARER (#486). `authClient` is the
        // unauthenticated client (it must be, for Login and Refresh), and the
        // edge exposes only those two publicly: a bare `Logout` was refused,
        // and the session stayed live on the server until it expired. The
        // token is the one being ended — refreshed first if it already
        // expired, which the rotation contract allows since the session ends
        // here anyway.
        guard let accessToken = await revocationToken(for: session) else { return }
        var request = Auth_V1_LogoutRequest()
        request.sessionID = session.sessionID.rawValue
        _ = await authClient.logout(request: request, headers: ["Authorization": ["Bearer \(accessToken)"]])
    }

    /// A token the server will accept for `ending`: its access token while
    /// that is still good, else a refreshed one. Nil when the server no
    /// longer knows the session — nothing is left to revoke.
    private func revocationToken(for ending: AuthSession) async -> String? {
        if ending.accessTokenExpiry.timeIntervalSince(now()) > configuration.expiryLeeway {
            return ending.accessToken
        }
        var request = Auth_V1_RefreshRequest()
        request.refreshToken = ending.refreshToken
        request.device = deviceContext()
        guard case .success(let body) = await authClient.refresh(request: request, headers: [:]).result else {
            return nil
        }
        return body.tokens.accessToken
    }

    // MARK: - Token vending (AuthTokenProviding)

    public func validAccessToken() async throws -> String? {
        bootstrapIfNeeded()
        guard let session else { return await guestAccessToken() }
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
            // A logout (or another sign-in) landed while the refresh was in
            // flight: its outcome belongs to a session that is over, and
            // adopting it would sign the viewer back in.
            guard session?.sessionID == current.sessionID else { return refreshed }
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

    // MARK: - Guest session

    /// The guest's token: the session's while it's good; else a refreshed one;
    /// else a new session. Nil when guest sessions are off (no context, or the
    /// server refused one) — the call then goes without a token, as before.
    private func guestAccessToken() async -> String? {
        guard let guest else { return nil }
        if let current = guestSession,
           current.accessTokenExpiry.timeIntervalSince(now()) > configuration.expiryLeeway {
            return current.accessToken
        }
        if let guestTask { return await guestTask.value?.accessToken }

        let current = guestSession
        let client = authClient
        let device = deviceContext()
        let issuedAt = now()
        let task = Task<AuthSession?, Never> {
            if let current, let refreshed = await Self.refreshGuest(current, client: client, device: device, now: issuedAt) {
                return refreshed
            }
            return await Self.startGuest(guest, client: client, device: device, now: issuedAt)
        }
        guestTask = task
        defer { guestTask = nil }
        let renewed = await task.value
        guestSession = renewed
        if let renewed { try? guest.store.save(renewed) } else { try? guest.store.clear() }
        return renewed?.accessToken
    }

    /// Nil when the server no longer honours the session's refresh token — a
    /// new session is started instead.
    private static func refreshGuest(
        _ current: AuthSession, client: any Auth_V1_AuthServiceClientInterface,
        device: Auth_V1_DeviceContext, now: Date
    ) async -> AuthSession? {
        var request = Auth_V1_RefreshRequest()
        request.refreshToken = current.refreshToken
        request.device = device
        guard case .success(let body) = await client.refresh(request: request, headers: [:]).result else {
            return nil
        }
        return makeSession(accountID: current.accountID, tokens: body.tokens, now: now)
    }

    /// `StartGuestSession`, with an App Attest proof when the device can give
    /// one (#523): a single-use challenge first, then the attestation bound to
    /// it.
    private static func startGuest(
        _ guest: GuestSessionContext, client: any Auth_V1_AuthServiceClientInterface,
        device: Auth_V1_DeviceContext, now: Date
    ) async -> AuthSession? {
        var request = Auth_V1_StartGuestSessionRequest()
        request.device = device
        request.locale = guest.locale()
        request.regionHint = guest.regionHint()
        request.currentCountry = await guest.currentCountry() ?? ""
        if let attestor = guest.attestor,
           case .success(let challenge) = await client.startDeviceAttestation(
               request: Auth_V1_StartDeviceAttestationRequest(), headers: [:]
           ).result,
           let proof = await attestor.attest(challenge: challenge.challenge) {
            request.attestKeyID = proof.keyID
            request.attestation = proof.attestation
            request.attestChallenge = challenge.challenge
        }
        guard case .success(let body) = await client.startGuestSession(request: request, headers: [:]).result else {
            return nil
        }
        return makeSession(accountID: AccountID(body.guestID), tokens: body.tokens, now: now)
    }

    // MARK: - State observation

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        session = try? store.load()
        guestSession = try? guest?.store.load()
    }

    private func currentAuthState() -> AuthState {
        bootstrapIfNeeded()
        return session.map { .authenticated($0.accountID) } ?? .unauthenticated
    }

    func broadcast(_ state: AuthState) {
        for continuation in observers.values {
            continuation.yield(state)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: - Helpers

    func deviceContext() -> Auth_V1_DeviceContext {
        var device = Auth_V1_DeviceContext()
        device.deviceID = configuration.deviceID
        device.userAgent = configuration.userAgent
        return device
    }

    static func makeSession(
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
