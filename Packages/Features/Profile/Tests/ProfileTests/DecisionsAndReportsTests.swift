import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Account Status → a restriction's reasons and appeal (#390, DSA Art. 17/20),
/// and Safety → Your Reports (#399, DSA Art. 16(5)).
@MainActor
struct DecisionsAndReportsTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func logout() async {}
    }

    private func moderationClient(_ service: MockModerationService) -> Moderation_V1_ModerationServiceClient {
        let bff = MockBFF()
        service.register(on: bff)
        return Moderation_V1_ModerationServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )
    }

    private func statusRepository(_ service: MockModerationService) -> AccountStatusRepository {
        AccountStatusRepository(moderationClient: moderationClient(service), authSession: Session())
    }

    /// A scratch store, so the appeals this suite files don't land in the
    /// test host's standard defaults.
    private func isolateFiledAppeals() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "DecisionsAndReportsTests-\(UUID().uuidString)")!
        FiledAppeals.defaults = defaults
        return defaults
    }

    // MARK: - Statement of reasons

    @Test func aRestrictionCarriesTheDecisionThatImposedIt() async throws {
        var named = Moderation_V1_EnforcementView()
        named.enforcementID = "a"
        named.action = .warn
        named.status = .active
        named.decisionID = "dec-a"
        var unnamed = named
        unnamed.enforcementID = "b"
        unnamed.decisionID = ""
        let restrictions = AccountStatusRepository.restrictions(from: [named, unnamed])
        #expect(restrictions.map(\.decisionID) == ["dec-a", nil])

        let seeded = try await statusRepository(MockModerationService(seedsViewerRestriction: true)).activeRestrictions()
        #expect(seeded.first?.decisionID == MockModerationService.seededDecisionID)
    }

    @Test func theStatementSaysWhatRuleWasBrokenAndWhoDecided() async throws {
        let repository = statusRepository(MockModerationService(seedsViewerRestriction: true))
        let statement = try await repository.statementOfReasons(decisionID: MockModerationService.seededDecisionID)
        #expect(statement.policy == "Harassment or bullying")
        #expect(statement.action == .featuresLimited)
        #expect(!statement.facts.isEmpty)
        #expect(!statement.legalGround.isEmpty)
        #expect(statement.decidedAt != nil)
        #expect(DecisionDetailViewController.decidedBy(automated: statement.automated) == "A member of our safety team")
        #expect(DecisionDetailViewController.decidedBy(automated: true) == "An automated system")

        await #expect(throws: (any Error).self) {
            _ = try await repository.statementOfReasons(decisionID: "someone-elses")
        }
    }

    @Test func theFooterSaysARestrictionOpens() {
        #expect(AccountStatusViewController.footer(canOpenAll: true).hasPrefix("Tap a restriction"))
        #expect(AccountStatusViewController.footer(canOpenAll: false).contains("Contact support"))
    }

    // MARK: - Appeal

    /// An empty appeal is refused before it's sent; a real one is filed,
    /// and this iPhone remembers it so a second isn't offered.
    @Test func anAppealIsFiledOnceWithItsReasons() async throws {
        _ = isolateFiledAppeals()
        defer { FiledAppeals.defaults = .standard }
        let service = MockModerationService(seedsViewerRestriction: true)
        let repository = statusRepository(service)
        let decision = MockModerationService.seededDecisionID

        await #expect(throws: AppealError.emptyStatement) {
            _ = try await repository.fileAppeal(decisionID: decision, statement: " \n ")
        }
        #expect(service.filedAppeals.isEmpty)
        #expect(FiledAppeals.filedAt(decisionID: decision) == nil)

        let filedAt = try await repository.fileAppeal(decisionID: decision, statement: "  I was quoting them.  ")
        #expect(service.filedAppeals.map(\.statement) == ["I was quoting them."])
        #expect(FiledAppeals.filedAt(decisionID: decision) == filedAt)

        await #expect(throws: AppealError.notFound) {
            _ = try await repository.fileAppeal(decisionID: "someone-elses", statement: "Please")
        }
    }

    @Test func theComposerWaitsForReasonsAndSaysWhyAnAppealFailed() {
        #expect(!AppealComposerViewController.canSend(""))
        #expect(!AppealComposerViewController.canSend("   "))
        #expect(AppealComposerViewController.canSend("It was a joke between friends."))
        #expect(!AppealComposerViewController.canSend(String(repeating: "a", count: AppealComposerViewController.maximumLength + 1)))
        #expect(AppealComposerViewController.failure(AppealError.windowClosed).title == "Too Late to Appeal")
        #expect(AppealComposerViewController.failure(AppealError.notAppealable).title == "This Decision Can't Be Appealed")
        #expect(AppealComposerViewController.failure(AppealError.transport(message: "x")).title == "Couldn't Send Your Appeal")
    }

    // MARK: - Your Reports

    /// Filed through `SubmitReport`, a report comes back from `ListMyReports`
    /// under review; reporting it again doesn't list it twice.
    @Test func aReportShowsUpInYourReports() async throws {
        let service = MockModerationService()
        let repository = ProfileReportRepository(moderationClient: moderationClient(service), authSession: Session())

        try await repository.report(.profile(ProfileID("prof-7")), reason: .harassment, surface: "profile_menu")
        try await repository.report(.post(PostID("post-9")), reason: .spam, surface: "post_menu")
        try await repository.report(.profile(ProfileID("prof-7")), reason: .harassment, surface: "profile_menu")

        let page = try await repository.myReports(pageToken: nil)
        #expect(page.reports.map(\.subjectID) == ["post-9", "prof-7"])
        #expect(page.reports.map(\.subject) == [.post, .profile])
        #expect(page.reports.map(\.category) == ["Spam or scam", "Harassment or bullying"])
        #expect(page.reports.allSatisfy { $0.outcome == .underReview })
        #expect(page.nextPageToken == nil)
    }

    @Test func eachOutcomeReadsPlainly() {
        var view = Moderation_V1_ReportView()
        view.reportID = "r"
        view.entityType = .account
        view.category = .hate
        view.status = .unspecified
        let report = FiledReport(view)
        // Recorded before its case exists: still under review.
        #expect(report.outcome == .underReview)
        #expect(report.subject == .profile)
        #expect(YourReportsViewController.title(of: report) == "Account")
        #expect(YourReportsViewController.detail(of: report) == "Hate speech")
        #expect(YourReportsViewController.outcome(.actionTaken).text == "Action Taken")
        #expect(YourReportsViewController.outcome(.noViolation).text == "No Violation")
        // The reporter never learns which sanction applied.
        #expect(YourReportsViewController.explanation.contains("we don't say how"))
    }
}
