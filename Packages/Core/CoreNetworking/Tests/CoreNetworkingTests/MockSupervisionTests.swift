import Connect
import CoreContracts
import CoreNetworkingMocks
import Foundation
import Testing
@testable import CoreNetworking

/// The family supervision mock (#417, backend #670): seeds, age checks and
/// the stand-in for the other side accepting a code.
struct MockSupervisionTests {
    private final class Age: @unchecked Sendable {
        var years: Int?
        init(_ years: Int?) { self.years = years }
    }

    private func client(_ service: MockSupervisionService) -> Account_V1_AccountServiceClient {
        let bff = MockBFF()
        service.register(on: bff)
        return Account_V1_AccountServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )
    }

    private var listRequest: Account_V1_ListSupervisionsRequest {
        var request = Account_V1_ListSupervisionsRequest()
        request.accountID = MockAuthService.accountID
        return request
    }

    /// Each seed starts the viewer on its side, with the dataset's people.
    @Test func theSeedsPutTheViewerOnEachSide() async throws {
        let full = client(MockSupervisionService(dataset: MockSocialDataset(), viewerAge: { 15 }, seed: .supervisedFull))
        let supervisors = try await full.listSupervisions(request: listRequest).result.get().supervisions
        #expect(supervisors.count == 2)
        #expect(supervisors.allSatisfy { $0.otherRole == .supervisor && !$0.profiles.isEmpty })
        #expect(supervisors[0].since.date > supervisors[1].since.date, "most recent first")

        let parent = client(MockSupervisionService(dataset: MockSocialDataset(), viewerAge: { 40 }, seed: .supervisor))
        let teens = try await parent.listSupervisions(request: listRequest).result.get().supervisions
        #expect(teens.count == 2)
        #expect(teens.allSatisfy { $0.otherRole == .teen })
        #expect(Set(teens.map(\.otherAccountID)).isDisjoint(with: supervisors.map(\.otherAccountID)))
    }

    /// A code the viewer made is taken up by the other side once old enough,
    /// on the next read — the mock's second device.
    @Test func theOtherSideTakesUpTheViewersCode() async throws {
        let client = client(MockSupervisionService(dataset: MockSocialDataset(), viewerAge: { 40 }, autoAcceptDelay: 0))
        var create = Account_V1_CreateSupervisionInviteRequest()
        create.accountID = MockAuthService.accountID
        create.role = .supervisor
        let invite = try await client.createSupervisionInvite(request: create).result.get()
        #expect(invite.code.count == 10)
        let list = try await client.listSupervisions(request: listRequest).result.get().supervisions
        #expect(list.map(\.otherRole) == [.teen])
        let again = try await client.listSupervisions(request: listRequest).result.get().supervisions
        #expect(again.count == 1, "a code is used once")
    }

    /// ⚠️ ONE'S OWN CODE IS ACC-3006 WHATEVER ITS LETTERS (#1529): a "ZZ…"
    /// code the viewer issued used to answer ACC-3001, "unknown", first.
    @Test func onesOwnZZCodeIsStillOnesOwn() async throws {
        let accounts = client(MockSupervisionService(
            dataset: MockSocialDataset(), viewerAge: { 40 }, autoAcceptDelay: nil, drawCode: { "ZZ12345678" }
        ))
        var create = Account_V1_CreateSupervisionInviteRequest()
        create.accountID = MockAuthService.accountID
        create.role = .supervisor
        let invite = try await accounts.createSupervisionInvite(request: create).result.get()
        var accept = Account_V1_AcceptSupervisionInviteRequest()
        accept.accountID = MockAuthService.accountID
        accept.code = invite.code
        let error = await accounts.acceptSupervisionInvite(request: accept).result.failure
        #expect(error?.message?.hasPrefix("ACC-3006") == true, "not one's own code: \(String(describing: error?.message))")
    }

    /// A drawn code never starts with "ZZ", the mock's "unknown code" prefix.
    @Test func aDrawnCodeNeverStartsWithZZ() {
        let codes = (0..<20_000).map { _ in MockSupervisionService.randomInviteCode() }
        #expect(codes.allSatisfy { $0.count == 10 && !$0.hasPrefix("ZZ") })
    }

    /// The side follows the age: none on file fits neither (ACC-3002).
    @Test func theSideFollowsTheAge() async throws {
        let age = Age(nil)
        let client = client(MockSupervisionService(dataset: MockSocialDataset(), viewerAge: { age.years }))
        var create = Account_V1_CreateSupervisionInviteRequest()
        create.accountID = MockAuthService.accountID
        create.role = .teen
        let refused = await client.createSupervisionInvite(request: create).result
        #expect(refused.failure?.message?.hasPrefix("ACC-3002") == true)
        age.years = 16
        #expect(await client.createSupervisionInvite(request: create).result.failure == nil)
        create.role = .supervisor
        #expect(await client.createSupervisionInvite(request: create).result.failure?.message?.hasPrefix("ACC-3002") == true)
    }
}

extension MockSupervisionTests {
    /// Time is counted only under a daily limit, at most 15 minutes a report.
    @Test func screenTimeCountsOnlyUnderALimitAndFifteenMinutesAtATime() async throws {
        var report = Account_V1_ReportScreenTimeRequest()
        report.accountID = MockAuthService.accountID
        report.timezone = "Europe/Paris"
        report.minutes = 16
        let free = client(MockSupervisionService(dataset: MockSocialDataset(), viewerAge: { 15 }))
        #expect(await free.reportScreenTime(request: report).result.failure?.message?.hasPrefix("ACC-9001") == true)
        report.minutes = 5
        let uncounted = try await free.reportScreenTime(request: report).result.get()
        #expect(uncounted.usedMinutes == 0 && uncounted.limitMinutes == 0 && !uncounted.reached)

        let limited = client(MockSupervisionService(dataset: MockSocialDataset(), viewerAge: { 15 }, seed: .supervised))
        let counted = try await limited.reportScreenTime(request: report).result.get()
        #expect(counted.limitMinutes == 60)
        #expect(counted.usedMinutes >= 5)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}
