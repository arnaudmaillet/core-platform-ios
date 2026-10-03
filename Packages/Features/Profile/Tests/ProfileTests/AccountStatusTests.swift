import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → Safety → Account Status (#390).
@MainActor
struct AccountStatusTests {
    private func enforcement(
        _ id: String,
        _ action: Moderation_V1_ActionType,
        status: Moderation_V1_EnforcementStatus = .active,
        applied: Int64,
        expires: Int64? = nil
    ) -> Moderation_V1_EnforcementView {
        var view = Moderation_V1_EnforcementView()
        view.enforcementID = id
        view.action = action
        view.status = status
        view.appliedAt.seconds = applied
        if let expires { view.expiresAt.seconds = expires }
        return view
    }

    @Test func onlyActiveRealRestrictionsNewestFirst() {
        let restrictions = AccountStatusRepository.restrictions(from: [
            enforcement("old", .warn, applied: 100),
            enforcement("over", .suspend, status: .expired, applied: 900),
            enforcement("undone", .ban, status: .reversed, applied: 800),
            enforcement("none", .noAction, applied: 700),
            enforcement("new", .restrictActor, applied: 500, expires: 600)
        ])
        #expect(restrictions.map(\.id) == ["new", "old"])
        #expect(restrictions.first?.kind == .featuresLimited)
        #expect(restrictions.first?.until == Date(timeIntervalSince1970: 600))
        #expect(restrictions.last?.until == nil)
    }

    @Test func aRestrictionWithoutAnEndIsPermanent() {
        let permanent = AccountRestriction(id: "a", kind: .banned, since: nil, until: nil)
        #expect(AccountStatusViewController.period(of: permanent) == "Permanent")
        let boxed = AccountRestriction(id: "b", kind: .featuresLimited, since: Date(timeIntervalSince1970: 0), until: Date(timeIntervalSince1970: 86_400))
        #expect(AccountStatusViewController.period(of: boxed).hasPrefix("Since "))
        #expect(AccountStatusViewController.period(of: boxed).contains(" · Until "))
    }

    @Test func theSummarySaysClearOrRestricted() {
        #expect(AccountStatusViewController.summary(for: .loaded([])).title == "No restrictions on your account")
        let one = AccountRestriction(id: "a", kind: .warning, since: nil, until: nil)
        #expect(AccountStatusViewController.summary(for: .loaded([one])).title == "Your account has restrictions")
    }

    /// End to end over the mock: the seeded restriction is filed under the
    /// ACCOUNT id, the same actor the Report flow uses.
    @Test func theMockServesTheSeededRestrictionForTheAccount() async throws {
        struct Session: AuthSessionProviding {
            func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
            func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
            func logout() async {}
        }
        let bff = MockBFF()
        MockModerationService(seedsViewerRestriction: true).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = AccountStatusRepository(
            moderationClient: Moderation_V1_ModerationServiceClient(client: client),
            authSession: Session()
        )
        let restrictions = try await repository.activeRestrictions()
        #expect(restrictions.map(\.kind) == [.featuresLimited])
        #expect(restrictions.first?.until != nil)
    }
}
