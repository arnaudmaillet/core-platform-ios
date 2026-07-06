import Connect
import Foundation

/// Builds the two `ProtocolClient`s the app uses against the BFF edge
/// (Connect protocol, binary protobuf).
///
/// Two clients by design:
/// - the *unauthenticated* client carries no interceptor and serves only
///   AuthService (login/refresh/logout) — attaching the auth interceptor
///   there would recurse (refresh → interceptor → refresh …);
/// - the *authenticated* client attaches the edge token to everything else.
public enum ConnectClientFactory {
    public static func makeUnauthenticated(
        host: String,
        httpClient: HTTPClientInterface = URLSessionHTTPClient()
    ) -> ProtocolClientInterface {
        ProtocolClient(
            httpClient: httpClient,
            config: ProtocolClientConfig(
                host: host,
                networkProtocol: .connect,
                codec: ProtoCodec()
            )
        )
    }

    public static func makeAuthenticated(
        host: String,
        tokenProvider: AuthTokenProviding,
        httpClient: HTTPClientInterface = URLSessionHTTPClient()
    ) -> ProtocolClientInterface {
        ProtocolClient(
            httpClient: httpClient,
            config: ProtocolClientConfig(
                host: host,
                networkProtocol: .connect,
                codec: ProtoCodec(),
                interceptors: [InterceptorFactory { _ in AuthInterceptor(tokenProvider: tokenProvider) }]
            )
        )
    }
}
