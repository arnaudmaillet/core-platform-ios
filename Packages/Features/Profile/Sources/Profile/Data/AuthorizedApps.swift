import CoreContracts
import CoreNetworking
import Foundation

/// A third-party app the holder let use their account (#485, backend #667):
/// "Sign in with" this app, and what it may do.
public struct AuthorizedApp: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let iconURL: URL?
    /// What it may do, as the server names it ("email", "profile:read").
    public let scopes: [String]
    public let grantedAt: Date?
    /// Nil until it first used the grant.
    public let lastUsedAt: Date?

    public init(id: String, name: String, iconURL: URL?, scopes: [String], grantedAt: Date?, lastUsedAt: Date?) {
        self.id = id
        self.name = name
        self.iconURL = iconURL
        self.scopes = scopes
        self.grantedAt = grantedAt
        self.lastUsedAt = lastUsedAt
    }

    init(_ app: Auth_V1_AuthorizedApp) {
        self.init(
            id: app.appID,
            name: app.displayName.isEmpty ? app.appID : app.displayName,
            iconURL: URL(string: app.iconURL).flatMap { $0.scheme == "https" ? $0 : nil },
            scopes: app.scopes,
            grantedAt: app.hasGrantedAt ? Self.date(app.grantedAt.seconds, app.grantedAt.nanos) : nil,
            lastUsedAt: app.hasLastUsedAt ? Self.date(app.lastUsedAt.seconds, app.lastUsedAt.nanos) : nil
        )
    }

    private static func date(_ seconds: Int64, _ nanos: Int32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    }

    /// The scopes in words, for the row.
    public var scopeSummary: String {
        let words = scopes.map { scope in
            switch scope {
            case "email": "Email address"
            case "profile:read": "Profile"
            case "posts:read": "Posts"
            default: scope
            }
        }
        return words.isEmpty ? "Sign-in only" : ListFormatter.localizedString(byJoining: words)
    }
}

/// Settings → Security and Login → Apps and Websites.
public protocol AuthorizedAppsManaging: Sendable {
    func authorizedApps() async throws -> [AuthorizedApp]
    /// Removes the app's access; answers the list as it is after.
    func revokeAuthorizedApp(_ appID: String) async throws -> [AuthorizedApp]
}

extension AccountSessionsRepository: AuthorizedAppsManaging {
    public func authorizedApps() async throws -> [AuthorizedApp] {
        let response = await authClient.listAuthorizedApps(request: Auth_V1_ListAuthorizedAppsRequest(), headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
        return (response.message?.apps ?? []).map(AuthorizedApp.init)
    }

    public func revokeAuthorizedApp(_ appID: String) async throws -> [AuthorizedApp] {
        var request = Auth_V1_RevokeAppAuthorizationRequest()
        request.appID = appID
        let response = await authClient.revokeAppAuthorization(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
        return (response.message?.apps ?? []).map(AuthorizedApp.init)
    }
}
