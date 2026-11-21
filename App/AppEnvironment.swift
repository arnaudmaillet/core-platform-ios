
import CoreNetworking
import Foundation
import LaunchArguments

/// Selects where the app's RPCs go: the BACKEND FACTORY's one decision (#2391).
///
/// - **A mock build** (`MOCK_BACKEND`: Debug, and Demo — the mock target in
///   Release) defaults to the in-process mock; `-use-local-fleet` points every
///   Connect service at the configured backend instead.
/// - **The production build** (`core-platform-ios-production`) has no mock: it
///   links neither `CoreNetworkingMocks` nor its media, so `.mock` does not
///   exist there and every RPC goes to the configured backend.
///
/// ⚠️ A `case .mock` BRANCH IS `#if MOCK_BACKEND`, and so is every name from
/// `CoreNetworkingMocks` (`RepoGuards/MockBackendGuardTests`): the production
/// target does not link the module, so a mock type it reaches is a link error.
enum AppEnvironment: Equatable {
    #if MOCK_BACKEND
    case mock
    #endif
    case remote(BackendEndpoint)

    static var current: AppEnvironment {
        #if MOCK_BACKEND
        if !DebugFlags.isOn("-use-local-fleet") { return .mock }
        #endif
        return .remote(.configured)
    }

    /// Single host: the mock routes by path in-process; the backend's gateway
    /// path-routes to the per-service upstreams.
    var host: String {
        switch self {
        #if MOCK_BACKEND
        case .mock: return "https://mock.bff.local"
        #endif
        case .remote(let endpoint): return endpoint.host
        }
    }

    var wire: RPCWireProtocol {
        switch self {
        #if MOCK_BACKEND
        case .mock: return .connect // MockBFF emulates the Connect protocol
        #endif
        case .remote(let endpoint): return endpoint.wire
        }
    }

    /// Whether the app runs on the in-process mock. False on a real backend:
    /// a mock build's `-use-local-fleet`, and every production build.
    var isMock: Bool {
        #if MOCK_BACKEND
        if case .mock = self { return true }
        #endif
        return false
    }

    #if MOCK_BACKEND
    /// The address and code the `-mock-auto-login` dev flow signs in with
    /// (#840: no password any more). The mock answers every code with
    /// `MockAuthService.verificationCode`; the fleet's codes are random (in
    /// its auth server's log), so there it signs in by hand.
    var autoLoginCode: (email: String, code: String)? {
        switch self {
        case .mock: ("demo@example.com", "123456") // MockAuthService.demoEmail / .verificationCode
        case .remote: nil
        }
    }
    #endif
}

/// A real backend: where its RPCs and its realtime socket go (#2391).
struct BackendEndpoint: Equatable {
    /// The gateway every Connect service is reached through.
    let host: String
    /// The local fleet's Envoy exposes gRPC-Web over HTTP/1.1.
    let wire: RPCWireProtocol
    /// The realtime WebSocket, or nil: realtime then stays off.
    let realtimeURL: URL?

    /// The local Docker fleet behind its Envoy gRPC-Web gateway. The gateway
    /// is plaintext ws:// for realtime (despite the :8443 port) and takes the
    /// edge token as an `access_token` query parameter.
    static let localFleet = BackendEndpoint(
        host: "http://localhost:8080",
        wire: .grpcWeb,
        realtimeURL: URL(string: "ws://localhost:8443/ws")
    )

    /// The backend this build was configured for: the `BFF_HOST` and
    /// `REALTIME_URL` build settings, read through Info.plist (`BFFHost`,
    /// `RealtimeURL`). Both default to the local fleet's. An empty
    /// `REALTIME_URL` means no realtime; an empty `BFF_HOST`, the local fleet.
    static var configured: BackendEndpoint {
        let info = Bundle.main.infoDictionary ?? [:]
        let host = (info["BFFHost"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? localFleet.host
        let realtime = (info["RealtimeURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return BackendEndpoint(host: host, wire: .grpcWeb, realtimeURL: realtime)
    }
}
