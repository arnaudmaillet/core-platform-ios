import CoreModels
import CoreStorage
import DesignSystem
import Foundation
import Testing
@testable import Search

/// How a row *looks* is decided in one place, from what the row IS.
///
/// These exist because it was once decided in two: a row carried a `symbolName`
/// alongside an `action`, so the same person rendered as a 48pt avatar in the
/// Suggestions list and a 22pt `person` glyph in Recent. The rule now is that
/// a row which opens a profile wears a person's disc, and every other row wears
/// a glyph — and nothing can set one without the other.
struct SearchRowRepresentationTests {
    private func historyRow(_ entry: RecentSearch) -> SearchRowDisplayModel {
        SearchRowDisplayModel(entry: entry)
    }

    // MARK: - People wear avatars

    @Test func aRememberedPersonIsDrawnAsAPerson() throws {
        let entry = try #require(RecentSearch.profile(
            id: "prof-1", displayName: "Ada Lovelace", handle: "ada",
            avatarURL: "https://example.com/a.jpg", searchedAtMS: 1
        ))

        let row = historyRow(entry)

        #expect(row.subject == .person)
        #expect(row.monogram == "AL")
        #expect(row.avatarURL == URL(string: "https://example.com/a.jpg"))
        #expect(row.rowContent.subject == .person)
        #expect(row.rowContent.displayName == "Ada Lovelace")
        #expect(row.rowContent.handle == "ada")
    }

    /// A person with no stored picture is still a PERSON — the disc falls back
    /// to initials rather than to a glyph.
    @Test func aRememberedPersonWithoutAPictureKeepsTheirInitials() throws {
        let entry = try #require(RecentSearch.profile(
            id: "prof-1", displayName: "Ada Lovelace", handle: "ada", searchedAtMS: 1
        ))

        let row = historyRow(entry)

        #expect(row.subject == .person)
        #expect(row.avatarURL == nil)
        #expect(row.monogram == "AL")
    }

    @Test func aProfileCompletionIsDrawnAsAPerson() {
        let row = SearchRowDisplayModel(
            suggestion: SearchSuggestion(text: "ada", kind: .profile, id: "prof-1")
        )

        #expect(row.subject == .person)
        #expect(row.monogram == "A")
    }

    // MARK: - Everything else wears a glyph

    @Test func aRememberedQueryIsDrawnWithAClock() throws {
        let entry = try #require(RecentSearch.query("swift", searchedAtMS: 1))

        #expect(historyRow(entry).subject == .symbol("clock"))
    }

    @Test func aHashtagCompletionIsDrawnWithANumberSign() {
        let row = SearchRowDisplayModel(
            suggestion: SearchSuggestion(text: "swift", kind: .hashtag, id: "")
        )

        #expect(row.subject == .symbol("number"))
    }

    @Test func aPlainCompletionIsDrawnWithAMagnifier() {
        let row = SearchRowDisplayModel(
            suggestion: SearchSuggestion(text: "swift", kind: .other, id: "")
        )

        #expect(row.subject == .symbol("magnifyingglass"))
    }

    /// A profile completion the index answered without an id cannot be opened,
    /// so it is not drawn as one — the look follows the behaviour.
    @Test func aProfileCompletionWithoutAnIdIsDrawnAsASearch() {
        let row = SearchRowDisplayModel(
            suggestion: SearchSuggestion(text: "ada", kind: .profile, id: "")
        )

        #expect(row.subject == .symbol("magnifyingglass"))
        #expect(row.action == .search)
    }

    // MARK: - The invariant itself

    /// The rule, stated once: opening a profile and wearing a person's disc are
    /// the same fact. Nothing may set one without the other.
    @Test func theDiscAlwaysAgreesWithWhatTheRowDoes() throws {
        let rows = [
            historyRow(try #require(RecentSearch.query("swift", searchedAtMS: 1))),
            historyRow(try #require(RecentSearch.profile(
                id: "prof-1", displayName: "Ada", handle: "ada", searchedAtMS: 1
            ))),
            SearchRowDisplayModel(suggestion: SearchSuggestion(text: "ada", kind: .profile, id: "p")),
            SearchRowDisplayModel(suggestion: SearchSuggestion(text: "swift", kind: .hashtag, id: "")),
            SearchRowDisplayModel(suggestion: SearchSuggestion(text: "x", kind: .profile, id: ""))
        ]

        for row in rows {
            let opensProfile = if case .openProfile = row.action { true } else { false }
            let isPerson = row.subject == .person
            #expect(opensProfile == isPerson, "\(row.id) draws as person=\(isPerson) but opens=\(opensProfile)")
        }
    }

    // MARK: - Trailing action

    /// The ✕ belongs to the history and only the history — a completion is not
    /// remembered, so there is nothing to forget.
    @Test func onlyHistoryRowsCarryTheDeleteAffordance() throws {
        let remembered = historyRow(try #require(RecentSearch.query("swift", searchedAtMS: 1)))
        let completion = SearchRowDisplayModel(
            suggestion: SearchSuggestion(text: "swift", kind: .hashtag, id: "")
        )

        #expect(remembered.isRemovable)
        #expect(!completion.isRemovable)
    }
}
