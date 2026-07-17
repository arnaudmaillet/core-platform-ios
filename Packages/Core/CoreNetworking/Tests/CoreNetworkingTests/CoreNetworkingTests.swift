import Connect
import CoreContracts
import CoreNetworkingMocks
import Foundation
import Testing
@testable import CoreNetworking

private struct StubTokenProvider: AuthTokenProviding {
    var token: String?
    var error: Error?

    func validAccessToken() async throws -> String? {
        if let error { throw error }
        return token
    }
}

struct CoreNetworkingTests {
    private func makeLoginRequest() -> Auth_V1_LoginRequest {
        var grant = Auth_V1_PasswordGrant()
        grant.username = MockAuthService.defaultCredentials.username
        grant.password = MockAuthService.defaultCredentials.password
        var request = Auth_V1_LoginRequest()
        request.grantType = .password
        request.credential = .password(grant)
        return request
    }

    @Test func mockBFFRoundTripsBinaryProtoOverConnect() async throws {
        let bff = MockBFF()
        MockAuthService().register(on: bff)
        let client = Auth_V1_AuthServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )

        let response = await client.login(request: makeLoginRequest(), headers: [:])

        let body = try response.result.get()
        #expect(body.accountID == MockAuthService.accountID)
        #expect(body.tokens.tokenType == "Bearer")
        #expect(bff.recordedRequests.map(\.path) == ["/auth.v1.AuthService/Login"])
    }

    @Test func unroutedPathReturnsUnimplemented() async {
        let bff = MockBFF()
        let client = Auth_V1_AuthServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )

        let response = await client.logout(request: Auth_V1_LogoutRequest(), headers: [:])

        #expect(response.error?.code == .unimplemented)
    }

    @Test func authInterceptorAttachesBearerToken() async throws {
        let bff = MockBFF()
        MockAuthService().register(on: bff)
        let client = Auth_V1_AuthServiceClient(
            client: ConnectClientFactory.makeAuthenticated(
                host: "https://mock.bff.local",
                tokenProvider: StubTokenProvider(token: "edge-token-42"),
                httpClient: bff
            )
        )

        _ = await client.login(request: makeLoginRequest(), headers: [:])

        let headers = try #require(bff.recordedRequests.first?.headers)
        #expect(headers["Authorization"] == ["Bearer edge-token-42"])
    }

    @Test func authInterceptorPassesThroughWhenUnauthenticated() async throws {
        let bff = MockBFF()
        MockAuthService().register(on: bff)
        let client = Auth_V1_AuthServiceClient(
            client: ConnectClientFactory.makeAuthenticated(
                host: "https://mock.bff.local",
                tokenProvider: StubTokenProvider(token: nil),
                httpClient: bff
            )
        )

        let response = await client.login(request: makeLoginRequest(), headers: [:])

        #expect(response.error == nil)
        let headers = try #require(bff.recordedRequests.first?.headers)
        #expect(headers["Authorization"] == nil)
    }

    @Test func authInterceptorFailsFastWhenRefreshFails() async {
        let bff = MockBFF()
        MockAuthService().register(on: bff)
        let client = Auth_V1_AuthServiceClient(
            client: ConnectClientFactory.makeAuthenticated(
                host: "https://mock.bff.local",
                tokenProvider: StubTokenProvider(error: URLError(.notConnectedToInternet)),
                httpClient: bff
            )
        )

        let response = await client.login(request: makeLoginRequest(), headers: [:])

        #expect(response.error?.code == .unauthenticated)
        // The request must never reach the wire with a missing/stale token.
        #expect(bff.recordedRequests.isEmpty)
    }

    // MARK: - Simulated conditions

    @Test func injectedFailureShortCircuitsMatchingRoute() async {
        let bff = MockBFF()
        MockAuthService().register(on: bff)
        bff.simulatedConditions = SimulatedConditions(failures: [
            .init(pathContains: "AuthService", code: .unavailable)
        ])
        let client = Auth_V1_AuthServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )

        let response = await client.login(request: makeLoginRequest(), headers: [:])

        #expect(response.error?.code == .unavailable)
        // The request still hits the transport (so interceptors are exercised).
        #expect(bff.recordedRequests.map(\.path) == ["/auth.v1.AuthService/Login"])
    }

    @Test func injectedFailureIgnoresNonMatchingRoute() async throws {
        let bff = MockBFF()
        MockAuthService().register(on: bff)
        bff.simulatedConditions = SimulatedConditions(failures: [
            .init(pathContains: "TimelineService", code: .unavailable)
        ])
        let client = Auth_V1_AuthServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )

        let response = await client.login(request: makeLoginRequest(), headers: [:])

        let body = try response.result.get()
        #expect(body.accountID == MockAuthService.accountID)
    }

    @Test func simulatedLatencyDelaysDelivery() async throws {
        let bff = MockBFF()
        MockAuthService().register(on: bff)
        bff.simulatedConditions = SimulatedConditions(latency: 0.2...0.2)
        let client = Auth_V1_AuthServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )

        let clock = ContinuousClock()
        let start = clock.now
        let response = await client.login(request: makeLoginRequest(), headers: [:])
        let elapsed = clock.now - start

        #expect(response.error == nil)
        #expect(elapsed >= .milliseconds(150))
    }

    @Test func conditionsParseFromLaunchArguments() {
        let conditions = SimulatedConditions.fromLaunchArguments([
            "app", "-mock-latency", "100-800",
            "-mock-fail", "TimelineService",
            "-mock-fail-code", "not_found",
            "-mock-fail-rate", "0.5"
        ])

        #expect(conditions.latency == 0.1...0.8)
        #expect(conditions.failures == [
            .init(pathContains: "TimelineService", code: .notFound, message: "simulated by -mock-fail", rate: 0.5)
        ])
    }

    @Test func conditionsParseDefaultsAndWildcards() {
        let conditions = SimulatedConditions.fromLaunchArguments([
            "app", "-mock-latency", "300", "-mock-fail", "all"
        ])

        #expect(conditions.latency == 0.3...0.3)
        #expect(conditions.failures == [
            .init(pathContains: "", code: .unavailable, message: "simulated by -mock-fail", rate: 1)
        ])
        #expect(SimulatedConditions.fromLaunchArguments(["app"]) == .none)
    }

    @Test func mockBackendServesTheFullSurface() async throws {
        let backend = MockBackend()
        let client = Auth_V1_AuthServiceClient(client: backend.makeRPCClient())

        let response = await client.login(request: makeLoginRequest(), headers: [:])

        let body = try response.result.get()
        #expect(body.accountID == MockAuthService.accountID)
        #expect(!backend.dataset.posts.isEmpty)
    }
}
