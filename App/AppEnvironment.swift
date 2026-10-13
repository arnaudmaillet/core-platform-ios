import CoreNetworking
import Foundation

/// Selects where the app's RPCs go. Defaults to the in-process mock (used by
/// tests, previews, and offline dev); `-use-local-fleet` points every Connect
/// service at the local Envoy gRPC-Web gateway fronting the Docker fleet.
///
/// The realtime and media transports stay on their mocks until those backends
/// (a realtime gateway, the media service) are exposed through the gateway.
enum AppEnvironment: Equatable {
    case mock
    case localFleet

    static var current: AppEnvironment {
        ProcessInfo.processInfo.arguments.contains("-use-local-fleet") ? .localFleet : .mock
    }

    /// Single host: the mock routes by path in-process; the Envoy gateway
    /// path-routes to the per-service h2c upstreams.
    var host: String {
        switch self {
        case .mock: "https://mock.bff.local"
        case .localFleet: "http://localhost:8080"
        }
    }

    var wire: RPCWireProtocol {
        switch self {
        case .mock: .connect // MockBFF emulates the Connect protocol
        case .localFleet: .grpcWeb // Envoy exposes gRPC-Web over HTTP/1.1
        }
    }

    /// The realtime WebSocket endpoint, or nil to use the in-process mock
    /// server. The gateway is plaintext ws:// (despite the :8443 port) and
    /// takes the edge token as an `access_token` query parameter.
    var realtimeURL: URL? {
        switch self {
        case .mock: nil
        case .localFleet: URL(string: "ws://localhost:8443/ws")
        }
    }

    /// The address and code the `-mock-auto-login` dev flow signs in with
    /// (#840: no password any more). The mock answers every code with
    /// `MockAuthService.verificationCode`; the fleet's codes are random (in
    /// its auth server's log), so there it signs in by hand.
    var autoLoginCode: (email: String, code: String)? {
        switch self {
        case .mock: ("demo@example.com", "123456") // MockAuthService.demoEmail / .verificationCode
        case .localFleet: nil
        }
    }
}
