import CoreContracts
import Foundation

/// One report the viewer made, with what became of it (Settings → Safety →
/// Your Reports, DSA Art. 16(5)).
public struct FiledReport: Hashable, Sendable {
    public enum Subject: Hashable, Sendable {
        case post, comment, profile, other
    }

    /// Coarse on purpose (backend #658): a reporter learns whether action was
    /// taken, never which sanction.
    public enum Outcome: Hashable, Sendable {
        case underReview, actionTaken, noViolation
    }

    public let id: String
    public let subject: Subject
    public let subjectID: String
    /// The policy it was reported under, e.g. "Hate speech".
    public let category: String
    public let outcome: Outcome
    public let reportedAt: Date?

    public init(id: String, subject: Subject, subjectID: String, category: String, outcome: Outcome, reportedAt: Date?) {
        self.id = id
        self.subject = subject
        self.subjectID = subjectID
        self.category = category
        self.outcome = outcome
        self.reportedAt = reportedAt
    }

    init(_ view: Moderation_V1_ReportView) {
        let subject: Subject = switch view.entityType {
        case .post: .post
        case .comment: .comment
        case .profile, .account: .profile
        default: .other
        }
        let outcome: Outcome = switch view.status {
        case .actionTaken: .actionTaken
        case .noViolation: .noViolation
        // The row is recorded before its case exists: under review.
        case .underReview, .unspecified, .UNRECOGNIZED: .underReview
        }
        self.init(
            id: view.reportID,
            subject: subject,
            subjectID: view.entityID,
            category: PolicyCategoryText.title(view.category),
            outcome: outcome,
            reportedAt: view.hasReportedAt ? view.reportedAt.date : nil
        )
    }
}

public struct FiledReportsPage: Sendable {
    public let reports: [FiledReport]
    /// Nil on the last page.
    public let nextPageToken: String?

    public init(reports: [FiledReport], nextPageToken: String?) {
        self.reports = reports
        self.nextPageToken = nextPageToken
    }
}

/// The viewer's own reports, newest first, a page at a time.
public protocol ReportHistoryProviding: Sendable {
    func myReports(pageToken: String?) async throws -> FiledReportsPage
}

extension ProfileReportRepository: ReportHistoryProviding {
    public func myReports(pageToken: String?) async throws -> FiledReportsPage {
        var request = Moderation_V1_ListMyReportsRequest()
        request.pageSize = 20
        request.pageToken = pageToken ?? ""
        let response = await moderationClient.listMyReports(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return FiledReportsPage(
                reports: body.reports.map(FiledReport.init),
                nextPageToken: body.nextPageToken.isEmpty ? nil : body.nextPageToken
            )
        case .failure(let error):
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
