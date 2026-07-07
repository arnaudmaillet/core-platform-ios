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

    /// Seeded first-party credentials used by the `-mock-auto-login` dev flow.
    /// The fleet IdP authenticates on the bare username (not the email).
    var demoCredentials: (username: String, password: String) {
        switch self {
        case .mock: ("demo", "password123")
        case .localFleet: ("alice", "password")
        }
    }

    /// Opt-in fallback for resolving the viewer's own profile via
    /// `GetProfileByHandle` when `ListProfilesByAccount` is unavailable (a
    /// local-fleet ProfileService CQL bug). Enabled explicitly with
    /// `-fleet-viewer-handle <handle>`; nil by default so the backend bug
    /// surfaces rather than being silently masked. Independent of the
    /// environment case — the mock's account lookup works, so it never fires
    /// there anyway.
    var viewerHandleFallback: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-fleet-viewer-handle"),
              index + 1 < arguments.count else {
            return nil
        }
        let handle = arguments[index + 1]
        return handle.isEmpty ? nil : handle
    }
}
