import Connect
import CoreContracts
import CoreNetworkingMocks
import Foundation
import MediaCore
import Testing
@testable import CoreNetworking

/// The mock network's fault switchboard (#790): offline everywhere at once, an
/// outage that ends on its own, and the lost ack a retried send duplicates on.
struct MockNetworkFaultsTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func bump() { lock.withLock { value += 1 } }
    }

    private func login(_ bff: MockBFF) async -> ResponseMessage<Auth_V1_LoginResponse> {
        let client = Auth_V1_AuthServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )
        var grant = Auth_V1_PasswordGrant()
        grant.username = MockAuthService.defaultCredentials.username
        grant.password = MockAuthService.defaultCredentials.password
        var request = Auth_V1_LoginRequest()
        request.grantType = .password
        request.credential = .password(grant)
        return await client.login(request: request, headers: [:])
    }

    /// Offline fails every call with `unavailable` — what URLSession answers
    /// with no network — and never reaches the handler, so nothing is written.
    @Test func offlineFailsFastWithoutReachingTheHandler() async {
        let bff = MockBFF()
        let calls = Counter()
        bff.register(path: "/auth.v1.AuthService/Login") { (_: Auth_V1_LoginRequest) in
            calls.bump()
            return .success(Auth_V1_LoginResponse())
        }
        let faults = MockNetworkFaults()
        faults.isForcedOffline = true
        bff.faults = faults

        let response = await login(bff)

        #expect(response.error?.code == .unavailable)
        #expect(calls.count == 0, "an offline call reached the server")

        faults.isForcedOffline = false
        #expect(await login(bff).error == nil, "back online, the call goes through")
    }

    /// An outage is offline inside its window and online on either side.
    @Test func anOutageEndsOnItsOwn() {
        let clock = Clock()
        let faults = MockNetworkFaults(now: { clock.now })
        faults.scheduleOutage(after: 5, lasting: 20)

        #expect(!faults.isOffline, "offline before the outage")
        clock.advance(6)
        #expect(faults.isOffline, "online during the outage")
        clock.advance(20)
        #expect(!faults.isOffline, "still offline after the outage ended")
    }

    /// The sheet's Online ends an outage in progress and clears every fault.
    @Test func resetEndsAnOutageAndClearsEveryFault() {
        let clock = Clock()
        let faults = MockNetworkFaults(now: { clock.now })
        faults.scheduleOutage(after: 0, lasting: 60)
        faults.ackLoss = [.init()]
        faults.uploadFailureRate = 1
        clock.advance(1)
        #expect(faults.isOffline)

        faults.reset()

        #expect(!faults.isOffline)
        #expect(faults.ackLoss.isEmpty)
        #expect(faults.uploadFailureRate == 0)
    }

    /// ACK LOSS: the write is applied, then the answer is lost. A client that
    /// retries without an idempotency key writes twice.
    @Test func aLostAckStillAppliesTheWrite() async {
        let bff = MockBFF()
        let writes = Counter()
        bff.register(path: "/auth.v1.AuthService/Login") { (_: Auth_V1_LoginRequest) in
            writes.bump()
            return .success(Auth_V1_LoginResponse())
        }
        let faults = MockNetworkFaults()
        faults.ackLoss = [.init(pathContains: "AuthService")]
        bff.faults = faults

        let response = await login(bff)

        #expect(response.error?.code == .deadlineExceeded)
        #expect(writes.count == 1, "the write was not applied")
    }

    /// The upload PUT bypasses the BFF; offline fails it too.
    @Test func offlineFailsTheUploadTransport() async throws {
        let store = MockBlobStore()
        let faults = MockNetworkFaults()
        faults.isForcedOffline = true
        let transport = MockMediaUploadTransport(store: store, faults: faults)
        let ticket = MediaUploadTicket(
            uploadURL: URL(string: "mock://upload/a1")!, httpMethod: "PUT", requiredHeaders: [:], maxSizeBytes: 1_000
        )

        await #expect(throws: MediaUploadError.self) {
            _ = try await transport.upload(Data([1, 2, 3]), using: ticket)
        }
    }

    @Test func faultsParseFromLaunchArguments() {
        let faults = MockNetworkFaults.fromLaunchArguments([
            "app", "-mock-offline", "-mock-ack-loss", "ChatService", "-mock-ack-loss-rate", "0.5",
            "-mock-upload-fail", "0.25"
        ])
        #expect(faults.isForcedOffline)
        #expect(faults.ackLoss == [.init(pathContains: "ChatService", rate: 0.5)])
        #expect(faults.uploadFailureRate == 0.25)
        #expect(!MockNetworkFaults.fromLaunchArguments(["app"]).isOffline)
    }

    /// `-mock-fail` repeats, and a rule may carry its own rate.
    @Test func failureRulesRepeatWithTheirOwnRates() {
        let conditions = SimulatedConditions.fromLaunchArguments([
            "app", "-mock-fail", "ChatService:0.3", "-mock-fail", "CommentsService"
        ])
        #expect(conditions.failures == [
            .init(pathContains: "ChatService", code: .unavailable, message: "simulated by -mock-fail", rate: 0.3),
            .init(pathContains: "CommentsService", code: .unavailable, message: "simulated by -mock-fail", rate: 1)
        ])
    }
}
