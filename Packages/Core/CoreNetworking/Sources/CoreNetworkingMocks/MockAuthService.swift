import Connect
import CoreContracts
import Foundation

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
    }

    public static let defaultCredentials = Credentials(username: "demo", password: "password123")
    public static let accountID = "acct-demo-0001"

    private let credentials: Credentials
    private let accessTokenLifetime: Int64

    private let lock = NSLock()
    private var sessions: [String: SessionRecord] = [:]
    private var tokenCounter = 0

    public init(
        credentials: Credentials = MockAuthService.defaultCredentials,
        accessTokenLifetimeSeconds: Int64 = 900
    ) {
        self.credentials = credentials
        self.accessTokenLifetime = accessTokenLifetimeSeconds
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/auth.v1.AuthService/Login") { [self] (request: Auth_V1_LoginRequest) in
            login(request)
        }
        bff.register(path: "/auth.v1.AuthService/Refresh") { [self] (request: Auth_V1_RefreshRequest) in
            refresh(request)
        }
        bff.register(path: "/auth.v1.AuthService/Logout") { [self] (request: Auth_V1_LogoutRequest) in
            logout(request)
        }
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
                issuedRefreshTokens: [refreshToken]
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

    private func logout(_ request: Auth_V1_LogoutRequest) -> Result<Auth_V1_LogoutResponse, ConnectError> {
        lock.withLock {
            if request.sessionID.isEmpty {
                for id in sessions.keys {
                    sessions[id]?.revoked = true
                }
            } else {
                sessions[request.sessionID]?.revoked = true
            }
            var response = Auth_V1_LogoutResponse()
            response.success = true
            return .success(response)
        }
    }

    private func makeTokenPair(sessionID: String, refreshToken: String) -> Auth_V1_TokenPair {
        var tokens = Auth_V1_TokenPair()
        tokens.accessToken = "at-\(tokenCounter)"
        tokens.refreshToken = refreshToken
        tokens.tokenType = "Bearer"
        tokens.expiresIn = accessTokenLifetime
        tokens.sessionID = sessionID
        return tokens
    }
}
