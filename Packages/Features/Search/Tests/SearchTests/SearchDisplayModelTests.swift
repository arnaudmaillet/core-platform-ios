import CoreModels
import Testing
@testable import Search

struct SearchDisplayModelTests {
    private func result(handle: String = "ada", name: String = "Ada Lovelace", verified: Bool = false) -> ProfileSearchResult {
        ProfileSearchResult(id: ProfileID("prof-1"), handle: handle, displayName: name, isVerified: verified)
    }

    @Test func prefixesHandleAndBuildsMonogram() {
        let model = SearchResultDisplayModel(result: result(handle: "ada", name: "Ada Lovelace"))
        #expect(model.handle == "@ada")
        #expect(model.monogram == "AL")
    }

    @Test func monogramFallsBackToHandleWhenNameBlank() {
        #expect(SearchResultDisplayModel(result: result(handle: "grace", name: "")).monogram == "G")
        #expect(SearchResultDisplayModel(result: result(handle: "cher", name: "Cher")).monogram == "C")
    }

    @Test func carriesVerifiedFlag() {
        #expect(SearchResultDisplayModel(result: result(verified: true)).isVerified)
        #expect(!SearchResultDisplayModel(result: result(verified: false)).isVerified)
    }
}
