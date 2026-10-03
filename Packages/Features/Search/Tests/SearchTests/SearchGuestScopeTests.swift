import CoreModels
import CoreStorage
import Foundation
import Testing
@testable import Search

private actor QuietSearchProvider: SearchProviding {
    func searchProfiles(matching query: String, sort: SearchSortOrder, limit: Int32) async throws -> [ProfileSearchResult] { [] }
    func suggestions(forPrefix prefix: String, limit: Int32) async throws -> [SearchSuggestion] { [] }
}

/// Guest mode: someone who follows no one has nothing to narrow to.
@MainActor
struct SearchGuestScopeTests {
    private func followingSegment(isMember: Bool) throws -> SearchFilterSheetViewController.Segment {
        let store = RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 1 })
        let viewModel = SearchViewModel(repository: QuietSearchProvider(), recentSearches: store)
        let scope = try #require(viewModel.filterGroups(isMember: isMember).first { $0.id == SearchViewModel.scopeGroupID })
        return try #require(scope.segments.first { $0.id == SearchScope.following.rawValue })
    }

    @Test func aGuestCannotPickFollowing() throws {
        #expect(try followingSegment(isMember: false).isEnabled == false)
    }

    @Test func aMemberCan() throws {
        #expect(try followingSegment(isMember: true).isEnabled)
    }
}
