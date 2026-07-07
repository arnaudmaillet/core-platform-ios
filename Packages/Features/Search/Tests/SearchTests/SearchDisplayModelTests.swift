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
        #expect(SearchResultDisplayModel.monogram(displayName: "", handle: "grace") == "G")
        #expect(SearchResultDisplayModel.monogram(displayName: "Cher", handle: "cher") == "C")
    }

    @Test func carriesVerifiedFlag() {
        #expect(SearchResultDisplayModel(result: result(verified: true)).isVerified)
        #expect(!SearchResultDisplayModel(result: result(verified: false)).isVerified)
    }
}
