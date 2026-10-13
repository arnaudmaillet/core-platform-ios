import Connect
import CoreContracts
import Foundation
import SwiftProtobuf

/// Fake of auth.v1 `ListAuthorizedApps` / `RevokeAppAuthorization` (#485,
/// backend #667): the third-party apps the demo account let use it. None by
/// default — the ordinary case; `-mock-authorized-apps` (or `seeded`) opens
/// with two. Member only, like every route the edge does not open.
public final class MockAuthorizedAppsService: @unchecked Sendable {
    private let lock = NSLock()
    private var apps: [Auth_V1_AuthorizedApp]

    public init(seeded: Bool = ProcessInfo.processInfo.arguments.contains("-mock-authorized-apps"), now: Date = Date()) {
        apps = seeded ? Self.demoApps(now: now) : []
    }

    static func demoApps(now: Date) -> [Auth_V1_AuthorizedApp] {
        func app(_ id: String, _ name: String, scopes: [String], granted days: Double, used hours: Double?) -> Auth_V1_AuthorizedApp {
            var app = Auth_V1_AuthorizedApp()
            app.appID = id
            app.displayName = name
            app.scopes = scopes
            app.grantedAt = Google_Protobuf_Timestamp(date: now.addingTimeInterval(-days * 86_400))
            if let hours { app.lastUsedAt = Google_Protobuf_Timestamp(date: now.addingTimeInterval(-hours * 3_600)) }
            return app
        }
        return [
            app("app-trailmap", "TrailMap", scopes: ["email", "profile:read"], granted: 40, used: 5),
            app("app-snapframe", "SnapFrame Studio", scopes: ["profile:read"], granted: 3, used: nil),
        ]
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/auth.v1.AuthService/ListAuthorizedApps") { [self] (_: Auth_V1_ListAuthorizedAppsRequest) in
            var response = Auth_V1_ListAuthorizedAppsResponse()
            response.apps = lock.withLock { apps }
            return .success(response)
        }
        // Answers the list as it is after; removing what is not there is not
        // an error (idempotent, as on the fleet).
        bff.register(path: "/auth.v1.AuthService/RevokeAppAuthorization") { [self] (request: Auth_V1_RevokeAppAuthorizationRequest) in
            var response = Auth_V1_ListAuthorizedAppsResponse()
            response.apps = lock.withLock {
                apps.removeAll { $0.appID == request.appID }
                return apps
            }
            return .success(response)
        }
    }
}
