import Testing
import UIKit
@testable import Feed

/// A comment's Block and Report are drawn only when they do something
/// (#801): there is no comment report flow yet, so today they are hidden in
/// both the row's own menu and the post page's stream menu.
@MainActor
struct CommentModerationMenuTests {
    private static func titles(_ elements: [UIMenuElement]) -> [String] {
        elements.flatMap { element -> [String] in
            if let menu = element as? UIMenu { return titles(menu.children) }
            return [element.title]
        }
    }

    /// Nothing wired: no moderation group at all, rather than rows that
    /// file nothing.
    @Test func unwiredModerationDrawsNoRows() {
        #expect(CommentRowView.moderationMenu(onBlock: nil, onReport: nil) == nil)
    }

    /// The row's own menu offers Share and nothing pretending to report.
    @Test func theRowsMenuHidesAReportThatFilesNothing() {
        let row = CommentRowView()
        let titles = Self.titles(row.menuElements())
        #expect(titles == ["Share Comment"])
        #expect(!titles.contains("Report"))
        #expect(!titles.contains("Block User"))
    }

    /// Once a report flow exists, Report appears — and only Report.
    @Test func aWiredReportIsDrawn() throws {
        let row = CommentRowView()
        row.onReport = {}
        #expect(Self.titles(row.menuElements()) == ["Share Comment", "Report"])

        let menu = try #require(CommentRowView.moderationMenu(onBlock: nil, onReport: {}))
        let report = try #require(menu.children.first as? UIAction)
        #expect(report.title == "Report")
        #expect(report.attributes.contains(.destructive))
    }
}
