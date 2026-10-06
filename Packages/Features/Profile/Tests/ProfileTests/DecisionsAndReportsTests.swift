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
    /// read back from the server under review (#576, not remembered on the
    /// device), and filing again doesn't make a second.
    @Test func anAppealIsFiledOnceAndReadBackUnderReview() async throws {
        let service = MockModerationService(seedsViewerRestriction: true)
        let repository = statusRepository(service)
        let decision = MockModerationService.seededDecisionID

        await #expect(throws: AppealError.emptyStatement) {
            _ = try await repository.fileAppeal(decisionID: decision, statement: " \n ")
        }
        #expect(try await repository.myAppeals().isEmpty)

        let filedAt = try await repository.fileAppeal(decisionID: decision, statement: "  I was quoting them.  ")
        let again = try await repository.fileAppeal(decisionID: decision, statement: "Really, I was.")
        #expect(again == filedAt)
        #expect(service.filedAppeals.map(\.statement) == ["I was quoting them."])

        let appeal = try #require(DecisionDetailViewController.appeal(for: decision, in: try await repository.myAppeals()))
        #expect(appeal.status == .pending)
        #expect(!appeal.byReporter)
        #expect(DecisionDetailViewController.appealStatusText(appeal).title == "Appeal under review")

        await #expect(throws: AppealError.notFound) {
            _ = try await repository.fileAppeal(decisionID: "someone-elses", statement: "Please")
        }
    }

    /// A resolved appeal says how it ended and why (DSA Art. 20(4)–(5)).
    @Test func aResolvedAppealSaysHowItEndedAndWhy() {
        let upheld = FiledAppeal(
            id: "a", decisionID: "d", status: .upheld, filedAt: Date(), resolvedAt: Date(), reasons: "The rule applies."
        )
        #expect(DecisionDetailViewController.appealStatusText(upheld).title == "Appeal reviewed: the decision stands")
        #expect(DecisionDetailViewController.appealFooter(upheld) == "Reviewer's reasons: The rule applies.")
        var reversed = Moderation_V1_AppealView()
        reversed.status = .overturned
        #expect(FiledAppeal(reversed).status == .overturned)
        #expect(DecisionDetailViewController.appealFooter(nil).hasPrefix("If you think this decision is wrong"))
    }

    // MARK: - A reporter's appeal

    /// A decided report names its decision; its reporter appeals it, and the
    /// row follows the appeal. The seeded resolved one carries its reasons.
    @Test func aReporterAppealsTheDecisionOnTheirReport() async throws {
        let service = MockModerationService(seedsReportHistory: true)
        let statuses = statusRepository(service)
        let seeded = YourReportsViewController.reporterAppeals(try await statuses.myAppeals())
        let resolved = try #require(seeded["dec-report-post-seed-reported-1"])
        #expect(resolved.status == .upheld)
        #expect(!resolved.reasons.isEmpty)
        #expect(YourReportsViewController.appealText(resolved) == "Appeal: decision stands")

        let actioned = "dec-report-profile-seed-reported-1"
        _ = try await statuses.fileAppeal(decisionID: actioned, statement: "They're still at it.")
        let mine = YourReportsViewController.reporterAppeals(try await statuses.myAppeals())
        #expect(mine[actioned]?.status == .pending)
        #expect(mine[actioned]?.byReporter == true)

        // Still under review: nothing to appeal yet.
        await #expect(throws: AppealError.notFound) {
            _ = try await statuses.fileAppeal(decisionID: "dec-report-comment-seed-reported-1", statement: "Please")
        }
    }

    @Test func aDecidedReportCarriesItsDecision() {
        var view = Moderation_V1_ReportView()
        view.status = .noViolation
        view.decisionID = "dec-1"
        #expect(FiledReport(view).decisionID == "dec-1")
        view.decisionID = ""
        #expect(FiledReport(view).decisionID == nil)
        let report = FiledReport(view)
        #expect(YourReportsViewController.appealIntro(report, subject: "post").hasPrefix("We didn't find that this post broke our rules"))
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
        let repository = ProfileReportRepository(moderationClient: moderationClient(service))

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

    /// DSA Art. 16: a GUEST reports too — with their guest token, through an
    /// edge that, like the fleet's, lets `SubmitReport` through for a guest
    /// and refuses it to nobody-at-all (#452, backend #677).
    @Test func aGuestReportsWithTheirGuestToken() async throws {
        struct Token: AuthTokenProviding {
            let token: String?
            func validAccessToken() async throws -> String? { token }
        }
        let bff = MockBFF()
        bff.enforcesEdgePolicy = true
        MockModerationService().register(on: bff)
        func repository(token: String?) -> ProfileReportRepository {
            ProfileReportRepository(moderationClient: Moderation_V1_ModerationServiceClient(
                client: ConnectClientFactory.makeAuthenticated(
                    host: "https://mock.bff.local", tokenProvider: Token(token: token), httpClient: bff
                )
            ))
        }

        try await repository(token: "gt-1").report(.post(PostID("post-9")), reason: .spam, surface: "post_menu")
        await #expect(throws: ProfileError.self) {
            try await repository(token: nil).report(.post(PostID("post-9")), reason: .spam, surface: "post_menu")
        }
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
