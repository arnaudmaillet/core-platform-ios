import Connect
import CoreContracts
import CoreNetworkingMocks
import Foundation
import Testing
@testable import CoreNetworking

/// The user-facing moderation RPCs the mock answers (backend #658/#677).
struct MockModerationTests {
    private func client(_ service: MockModerationService) -> Moderation_V1_ModerationServiceClient {
        let bff = MockBFF()
        service.register(on: bff)
        return Moderation_V1_ModerationServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )
    }

    /// The reporter is the token, a re-report keeps the first row, and
    /// `ListMyReports` shows a caller only their own reports, newest first,
    /// a page at a time.
    @Test func eachReporterListsTheirOwnReports() async throws {
        let client = client(MockModerationService(seedsReportHistory: true))
        let member: Headers = ["authorization": ["Bearer member-token"]]

        var report = Moderation_V1_SubmitReportRequest()
        report.entityType = .post
        report.entityID = "post-42"
        report.category = .spam
        let first = try await client.submitReport(request: report, headers: member).result.get()
        let again = try await client.submitReport(request: report, headers: member).result.get()
        #expect(first.reportID == again.reportID)

        var page = Moderation_V1_ListMyReportsRequest()
        page.pageSize = 2
        let one = try await client.listMyReports(request: page, headers: member).result.get()
        #expect(one.reports.map(\.entityID) == ["post-42", "comment-seed-reported-1"])
        #expect(one.reports.first?.status == .underReview)
        page.pageToken = one.nextPageToken
        let two = try await client.listMyReports(request: page, headers: member).result.get()
        #expect(two.reports.map(\.status) == [.actionTaken, .noViolation])
        #expect(two.nextPageToken.isEmpty)

        // A guest sees only a guest's reports: none here.
        let guest = try await client.listMyReports(request: Moderation_V1_ListMyReportsRequest(), headers: [:]).result.get()
        #expect(guest.reports.isEmpty)
    }

    @Test func onlyContentAndAccountsCanBeReported() async {
        let client = client(MockModerationService())
        var report = Moderation_V1_SubmitReportRequest()
        report.entityType = .chatMessage
        report.entityID = "msg-1"
        #expect(await client.submitReport(request: report, headers: [:]).error?.code == .invalidArgument)
    }

    /// The seeded restriction names its decision; only that decision has a
    /// statement, and an appeal must say why.
    @Test func theSeededDecisionIsExplainedAndAppealable() async throws {
        let service = MockModerationService(seedsViewerRestriction: true)
        let client = client(service)

        var state = Moderation_V1_GetEnforcementStateRequest()
        state.actorID = MockAuthService.accountID
        let enforcements = try await client.getEnforcementState(request: state, headers: [:]).result.get().activeEnforcements
        #expect(enforcements.map(\.decisionID) == [MockModerationService.seededDecisionID])

        var reasons = Moderation_V1_GetStatementOfReasonsRequest()
        reasons.decisionID = MockModerationService.seededDecisionID
        let statement = try await client.getStatementOfReasons(request: reasons, headers: [:]).result.get().statement
        #expect(statement.category == .harassment)
        #expect(statement.action == .restrictActor)
        reasons.decisionID = "someone-elses"
        #expect(await client.getStatementOfReasons(request: reasons, headers: [:]).error?.code == .notFound)

        var appeal = Moderation_V1_FileAppealRequest()
        appeal.decisionID = MockModerationService.seededDecisionID
        appeal.statement = "  "
        #expect(await client.fileAppeal(request: appeal, headers: [:]).error?.code == .invalidArgument)
        appeal.statement = "I was quoting them."
        #expect(try await client.fileAppeal(request: appeal, headers: [:]).result.get().appeal.status == .filed)
        #expect(service.filedAppeals.map(\.statement) == ["I was quoting them."])
    }
}
