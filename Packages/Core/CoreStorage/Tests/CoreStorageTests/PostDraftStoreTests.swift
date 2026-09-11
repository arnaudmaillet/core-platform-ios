import Foundation
import Testing
@testable import CoreStorage

@MainActor
struct PostDraftStoreTests {
    /// A file of its own per test, removed before it starts: nothing here may
    /// read the app's drafts, or another test's.
    private func makeStore(_ name: String = UUID().uuidString) throws -> (PostDraftStore, String) {
        let file = "post-drafts-test-\(name)"
        try CodableFileStore<[PostDraft]>(name: file).clear()
        return (PostDraftStore(name: file), file)
    }

    @Test func aSavedDraftLeadsTheList() throws {
        let (store, _) = try makeStore()

        store.save("First", now: Date(timeIntervalSince1970: 1))
        store.save("Second", now: Date(timeIntervalSince1970: 2))

        #expect(store.drafts.map(\.text) == ["Second", "First"])
    }

    /// Editing a draft saves it IN PLACE of itself — and brings it back to the top.
    @Test func savingOverADraftReplacesIt() throws {
        let (store, _) = try makeStore()
        let first = try #require(store.save("First"))
        store.save("Second")

        store.save("First, revised", replacing: first.id)

        #expect(store.drafts.map(\.text) == ["First, revised", "Second"])
        #expect(store.drafts.first?.id == first.id)
    }

    @Test func blankTextIsNotADraft() throws {
        let (store, _) = try makeStore()

        #expect(store.save("   \n ") == nil)
        #expect(store.drafts.isEmpty)
    }

    @Test func aDeletedDraftIsGone() throws {
        let (store, _) = try makeStore()
        let draft = try #require(store.save("Gone soon"))

        store.delete(draft.id)

        #expect(store.drafts.isEmpty)
        #expect(store.draft(draft.id) == nil)
    }

    /// Drafts outlive the screen that wrote them.
    @Test func draftsSurviveANewStore() throws {
        let (store, file) = try makeStore()
        store.save("Kept")

        #expect(PostDraftStore(name: file).drafts.map(\.text) == ["Kept"])
    }
}
