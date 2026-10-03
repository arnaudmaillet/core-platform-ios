import Connect
import CoreContracts
import Foundation
import SwiftProtobuf

/// Deterministic fake of auth.v1.AuthService implementing the contract's
/// real semantics: password-grant login, single-use rotating refresh tokens,
/// and reuse-detection that revokes the whole session (so client bugs around
/// refresh rotation fail loudly in development, exactly as they would in prod).
public final class MockAuthService: @unchecked Sendable {
    public struct Credentials: Sendable {
        public let username: String
        public let password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    private struct SessionRecord {
        var currentRefreshToken: String
        /// Every refresh token this session has ever been issued, for
        /// reuse detection.
        var issuedRefreshTokens: Set<String>
        var revoked = false
        /// What the client said it was at login, for device-management lists.
        var device = Auth_V1_DeviceContext()
        var issuedAt = Date()
    }

    /// Two sessions on other devices, so "Where you're logged in" has more
    /// than the current row to show and to revoke. Their refresh tokens are
    /// never handed out, so they can only ever be listed and revoked.
    private static func seededOtherSessions(now: Date) -> [String: SessionRecord] {
        func record(_ userAgent: String, daysAgo: Double) -> SessionRecord {
            var device = Auth_V1_DeviceContext()
            device.userAgent = userAgent
            device.deviceID = "seed-device-\(userAgent.count)"
            return SessionRecord(
                currentRefreshToken: "rt-seed-\(userAgent.count)",
                issuedRefreshTokens: [],
                device: device,
                issuedAt: now.addingTimeInterval(-daysAgo * 86_400)
            )
        }
        return [
            "sess-seed-ipad": record("core-platform-ios/1.0 (iPad; iOS 26.4)", daysAgo: 3),
            "sess-seed-web": record("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_6) Safari/605.1.15", daysAgo: 12)
        ]
    }

    public static let defaultCredentials = Credentials(username: "demo", password: "password123")
    public static let accountID = "acct-demo-0001"

    private let credentials: Credentials
    private let accessTokenLifetime: Int64

    private let lock = NSLock()
    private var sessions: [String: SessionRecord]
    /// Access token → session, so a request's bearer token says which session
    /// is calling ("this device" in ListSessions, `Logout` with no id).
    private var sessionByAccessToken: [String: String] = [:]
    private var generation: Int64 = 1
    private var tokenCounter = 0

    public init(
        credentials: Credentials = MockAuthService.defaultCredentials,
        accessTokenLifetimeSeconds: Int64 = 900
    ) {
        self.credentials = credentials
        self.accessTokenLifetime = accessTokenLifetimeSeconds
        self.sessions = Self.seededOtherSessions(now: Date())
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/auth.v1.AuthService/Login") { [self] (request: Auth_V1_LoginRequest) in
            login(request)
        }
        bff.register(path: "/auth.v1.AuthService/Refresh") { [self] (request: Auth_V1_RefreshRequest) in
            refresh(request)
        }
        bff.register(path: "/auth.v1.AuthService/Logout") { [self] (request: Auth_V1_LogoutRequest, headers: Headers) in
            logout(request, callerSession: callerSession(headers))
        }
        bff.register(path: "/auth.v1.AuthService/ListSessions") { [self] (_: Auth_V1_ListSessionsRequest, headers: Headers) in
            listSessions(callerSession: callerSession(headers))
        }
        bff.register(path: "/auth.v1.AuthService/LogoutAllSessions") { [self] (_: Auth_V1_LogoutAllSessionsRequest) in
            logoutAllSessions()
        }
    }

    /// The session behind a request's bearer token, if any.
    private func callerSession(_ headers: Headers) -> String? {
        let bearer = headers.first { $0.key.lowercased() == "authorization" }?.value.first ?? ""
        let token = bearer.hasPrefix("Bearer ") ? String(bearer.dropFirst("Bearer ".count)) : bearer
        return lock.withLock { sessionByAccessToken[token] }
    }

    // MARK: - Handlers

    private func login(_ request: Auth_V1_LoginRequest) -> Result<Auth_V1_LoginResponse, ConnectError> {
        guard request.grantType == .password,
              case .password(let grant) = request.credential else {
            return .failure(ConnectError(code: .invalidArgument, message: "expected password grant"))
        }
        guard grant.username == credentials.username, grant.password == credentials.password else {
            return .failure(ConnectError(code: .unauthenticated, message: "invalid credentials"))
        }

        return lock.withLock {
            tokenCounter += 1
            let sessionID = "sess-\(UUID().uuidString.prefix(8))"
            let refreshToken = "rt-\(tokenCounter)"
            sessions[sessionID] = SessionRecord(
                currentRefreshToken: refreshToken,
                issuedRefreshTokens: [refreshToken],
                device: request.device
            )

            var response = Auth_V1_LoginResponse()
            response.accountID = Self.accountID
            response.tokens = makeTokenPair(sessionID: sessionID, refreshToken: refreshToken)
            return .success(response)
        }
    }

    private func refresh(_ request: Auth_V1_RefreshRequest) -> Result<Auth_V1_RefreshResponse, ConnectError> {
        lock.withLock {
            guard let (sessionID, record) = sessions.first(where: { _, record in
                record.issuedRefreshTokens.contains(request.refreshToken)
            }), !record.revoked else {
                return .failure(ConnectError(code: .unauthenticated, message: "unknown or revoked refresh token"))
            }

            guard record.currentRefreshToken == request.refreshToken else {
                // Contract: presenting an already-rotated token is treated as
                // compromise and revokes the entire session generation.
                sessions[sessionID]?.revoked = true
                return .failure(ConnectError(code: .unauthenticated, message: "refresh token reuse detected; session revoked"))
            }

            tokenCounter += 1
            let rotated = "rt-\(tokenCounter)"
            sessions[sessionID]?.currentRefreshToken = rotated
            sessions[sessionID]?.issuedRefreshTokens.insert(rotated)

            var response = Auth_V1_RefreshResponse()
            response.tokens = makeTokenPair(sessionID: sessionID, refreshToken: rotated)
            return .success(response)
        }
    }

    private func logout(_ request: Auth_V1_LogoutRequest, callerSession: String?) -> Result<Auth_V1_LogoutResponse, ConnectError> {
        lock.withLock {
            // Contract: an empty id means the caller's current session.
            if let id = request.sessionID.isEmpty ? callerSession : request.sessionID {
                sessions[id]?.revoked = true
            }
            var response = Auth_V1_LogoutResponse()
            response.success = true
            return .success(response)
        }
    }

    private func listSessions(callerSession: String?) -> Result<Auth_V1_ListSessionsResponse, ConnectError> {
        lock.withLock {
            var response = Auth_V1_ListSessionsResponse()
            response.sessions = sessions
                .filter { !$0.value.revoked }
                .sorted { $0.value.issuedAt > $1.value.issuedAt }
                .map { id, record in
                    var view = Auth_V1_SessionView()
                    view.sessionID = id
                    view.status = .active
                    view.generation = generation
                    view.device = record.device
                    view.issuedAt = .init(date: record.issuedAt)
                    view.current = id == callerSession
                    return view
                }
            return .success(response)
        }
    }

    private func logoutAllSessions() -> Result<Auth_V1_LogoutAllSessionsResponse, ConnectError> {
        lock.withLock {
            let live = sessions.filter { !$0.value.revoked }.keys
            for id in live {
                sessions[id]?.revoked = true
            }
            generation += 1
            var response = Auth_V1_LogoutAllSessionsResponse()
            response.success = true
            response.generation = generation
            response.sessionsRevoked = Int32(live.count)
            return .success(response)
        }
    }

    private func makeTokenPair(sessionID: String, refreshToken: String) -> Auth_V1_TokenPair {
        var tokens = Auth_V1_TokenPair()
        tokens.accessToken = "at-\(tokenCounter)"
        sessionByAccessToken[tokens.accessToken] = sessionID
        tokens.refreshToken = refreshToken
        tokens.tokenType = "Bearer"
        tokens.expiresIn = accessTokenLifetime
        tokens.sessionID = sessionID
        return tokens
    }
}
