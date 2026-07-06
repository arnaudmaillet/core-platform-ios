import Connect
import Foundation

/// The wire protocol a client speaks. Kept as our own enum so callers don't
/// need to import Connect just to pick one.
///
/// - `connect`: the Connect protocol (what the in-process MockBFF emulates).
/// - `grpcWeb`: gRPC-Web over HTTP/1.1 — what the local Envoy gateway exposes
///   in front of the h2c gRPC fleet (URLSession can't reach h2c/raw gRPC).
public enum RPCWireProtocol: Sendable {
    case connect
    case grpcWeb

    var networkProtocol: NetworkProtocol {
        switch self {
        case .connect: .connect
        case .grpcWeb: .grpcWeb
        }
    }
}

/// Builds the two `ProtocolClient`s the app uses against the edge (binary
/// protobuf, either Connect or gRPC-Web).
///
/// Two clients by design:
/// - the *unauthenticated* client carries no interceptor and serves only
///   AuthService (login/refresh/logout) — attaching the auth interceptor
///   there would recurse (refresh → interceptor → refresh …);
/// - the *authenticated* client attaches the edge token to everything else.
public enum ConnectClientFactory {
    public static func makeUnauthenticated(
        host: String,
        wire: RPCWireProtocol = .connect,
        httpClient: HTTPClientInterface = URLSessionHTTPClient()
    ) -> ProtocolClientInterface {
        ProtocolClient(
            httpClient: httpClient,
            config: ProtocolClientConfig(
                host: host,
                networkProtocol: wire.networkProtocol,
                codec: ProtoCodec()
            )
        )
    }

    public static func makeAuthenticated(
        host: String,
        tokenProvider: AuthTokenProviding,
        wire: RPCWireProtocol = .connect,
        httpClient: HTTPClientInterface = URLSessionHTTPClient()
    ) -> ProtocolClientInterface {
        ProtocolClient(
            httpClient: httpClient,
            config: ProtocolClientConfig(
                host: host,
                networkProtocol: wire.networkProtocol,
                codec: ProtoCodec(),
                interceptors: [InterceptorFactory { _ in AuthInterceptor(tokenProvider: tokenProvider) }]
            )
        )
    }
}
