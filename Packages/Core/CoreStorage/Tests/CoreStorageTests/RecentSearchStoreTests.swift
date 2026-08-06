import Foundation
import Testing
@testable import CoreStorage

/// Each test gets its own suite-named `UserDefaults` so nothing leaks between
/// them or into the running app's real defaults.
private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    UserDefaults(suiteName: name)!
}

private func makeStore(
    defaults: UserDefaults = makeDefaults(),
    at stamp: Int64 = 1_000
) -> RecentSearchStore {
    RecentSearchStore(defaults: defaults, now: { stamp })
}

struct RecentSearchStoreTests {
    // MARK: - Recording

    @Test func recordingAQueryPutsItAtTheFront() {
        let store = makeStore()

        store.recordQuery("ada")
        store.recordQuery("grace")

        #expect(store.recents.map(\.text) == ["grace", "ada"])
    }

    @Test func blankQueriesAreNotRecorded() {
        let store = makeStore()

        #expect(store.recordQuery("   ") == nil)
        #expect(store.recordQuery("\n\t") == nil)
        #expect(store.recents.isEmpty)
    }

    @Test func aQueryIsTrimmedBeforeItIsStored() {
        let store = makeStore()

        store.recordQuery("  ada lovelace  ")

        #expect(store.recents.map(\.text) == ["ada lovelace"])
    }

    // MARK: - De-duplication

    @Test func researchingMovesTheEntryToTheFrontInsteadOfDuplicatingIt() {
        let store = makeStore()

        store.recordQuery("ada")
        store.recordQuery("grace")
        store.recordQuery("ada")

        #expect(store.recents.map(\.text) == ["ada", "grace"])
    }

    @Test func deduplicationIgnoresCaseAndTheNewerCasingWins() {
        let store = makeStore()

        store.recordQuery("ada")
        store.recordQuery("ADA")

        #expect(store.recents.count == 1)
        #expect(store.recents.map(\.text) == ["ADA"])
    }

    // MARK: - The storage cap

    @Test func theOldestEntriesFallOffPastTheStorageLimit() {
        let store = makeStore()

        for index in 0..<(RecentSearchStore.storageLimit + 3) {
            store.recordQuery("q\(index)")
        }

        let recents = store.recents
        #expect(recents.count == RecentSearchStore.storageLimit)
        // Newest first, and the three oldest are gone.
        #expect(recents.first?.text == "q\(RecentSearchStore.storageLimit + 2)")
        #expect(recents.last?.text == "q3")
        #expect(!recents.contains { $0.text == "q0" })
    }

    // MARK: - Removal

    @Test func removingAnEntryDropsOnlyThatOne() {
        let store = makeStore()
        store.recordQuery("ada")
        store.recordQuery("grace")

        store.remove(id: "ada")

        #expect(store.recents.map(\.text) == ["grace"])
    }

    @Test func clearingEmptiesTheWholeHistory() {
        let store = makeStore()
        store.recordQuery("ada")
        store.recordQuery("grace")

        store.clear()

        #expect(store.recents.isEmpty)
    }

    // MARK: - Change notification

    @Test func everyMutationNotifies() {
        let store = makeStore()
        var changes = 0
        store.onChange = { changes += 1 }

        store.recordQuery("ada")
        store.remove(id: "ada")
        store.clear()

        #expect(changes == 3)
    }

    @Test func removingSomethingThatIsNotThereDoesNotNotify() {
        let store = makeStore()
        store.recordQuery("ada")
        var changes = 0
        store.onChange = { changes += 1 }

        store.remove(id: "nobody-searched-this")

        #expect(changes == 0)
        #expect(store.recents.map(\.text) == ["ada"])
    }

    // MARK: - Persistence

    @Test func historySurvivesAcrossStoreInstances() {
        let defaults = makeDefaults()
        makeStore(defaults: defaults).recordQuery("ada")

        #expect(makeStore(defaults: defaults).recents.map(\.text) == ["ada"])
    }

    @Test func aCorruptEntryCostsOneRowRatherThanTheWholeHistory() throws {
        let defaults = makeDefaults()
        // Two well-formed entries with an unreadable one wedged between them —
        // what a downgrade past a future `Kind` case would look like on disk.
        let blob = """
        [
          {"id":"ada","kind":"query","text":"ada","searchedAtMS":1},
          {"id":"mystery","kind":"hologram","text":"?","searchedAtMS":2},
          {"id":"grace","kind":"query","text":"grace","searchedAtMS":3}
        ]
        """
        defaults.set(Data(blob.utf8), forKey: "search.recentQueries")

        #expect(makeStore(defaults: defaults).recents.map(\.text) == ["ada", "grace"])
    }

    @Test func anUnreadableBlobReadsAsAnEmptyHistory() {
        let defaults = makeDefaults()
        defaults.set(Data("not json at all".utf8), forKey: "search.recentQueries")

        #expect(makeStore(defaults: defaults).recents.isEmpty)
    }

    // MARK: - The display window

    private static func entries(_ count: Int) -> [RecentSearch] {
        (0..<count).compactMap { RecentSearch.query("q\($0)", searchedAtMS: Int64($0)) }
    }

    /// The shipped default, not a hand-passed one: the section's cap is a
    /// product decision (ten, 2026-08-06) and a test that always overrode it
    /// would not notice the day it changed.
    @Test func theDefaultWindowCapsAtTheCollapsedLimit() {
        let window = RecentSearchStore.window(over: Self.entries(14), expanded: false)

        #expect(window.rows.count == RecentSearchStore.collapsedLimit)
        #expect(window.hiddenCount == 14 - RecentSearchStore.collapsedLimit)
        #expect(window.showsMoreRow)
    }

    @Test func aShortHistoryFitsWithoutAMoreRow() {
        let window = RecentSearchStore.window(over: Self.entries(3), expanded: false, collapsedLimit: 5)

        #expect(window.rows.count == 3)
        #expect(window.hiddenCount == 0)
        #expect(!window.showsMoreRow)
    }

    @Test func aHistoryExactlyAtTheLimitDoesNotOfferMore() {
        let window = RecentSearchStore.window(over: Self.entries(5), expanded: false, collapsedLimit: 5)

        #expect(window.rows.count == 5)
        #expect(!window.showsMoreRow)
    }

    @Test func aLongHistoryIsCappedAndReportsWhatIsHeldBack() {
        let window = RecentSearchStore.window(over: Self.entries(12), expanded: false, collapsedLimit: 5)

        #expect(window.rows.map(\.text) == ["q0", "q1", "q2", "q3", "q4"])
        #expect(window.hiddenCount == 7)
        #expect(window.showsMoreRow)
    }

    @Test func expandingShowsEverythingAndRetiresTheMoreRow() {
        let window = RecentSearchStore.window(over: Self.entries(12), expanded: true, collapsedLimit: 5)

        #expect(window.rows.count == 12)
        #expect(window.hiddenCount == 0)
        #expect(!window.showsMoreRow)
    }

    @Test func anEmptyHistoryWindowsToNothing() {
        let window = RecentSearchStore.window(over: [], expanded: false, collapsedLimit: 5)

        #expect(window.rows.isEmpty)
        #expect(!window.showsMoreRow)
    }
}

/// Profile entries — the half of `RecentSearch.Kind` that only started being
/// written when tapping a person began opening them directly instead of
/// running their name as a search.
struct RecentProfileSearchTests {
    private func makeStore() -> RecentSearchStore {
        RecentSearchStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { 7 })
    }

    @Test func recordingAProfileKeepsItsIdentityAndHandle() throws {
        let store = makeStore()

        store.recordProfile(id: "prof-1", displayName: "Ada Lovelace", handle: "ada")

        let entry = try #require(store.recents.first)
        #expect(entry.kind == .profile)
        #expect(entry.text == "Ada Lovelace")
        #expect(entry.subtitle == "ada")
        #expect(entry.profileID == "prof-1")
    }

    /// Keyed on the id, so the same person opened twice is one row — even
    /// after they rename themselves.
    @Test func theSamePersonIsOneEntryEvenAfterARename() {
        let store = makeStore()

        store.recordProfile(id: "prof-1", displayName: "Ada", handle: "ada")
        store.recordProfile(id: "prof-1", displayName: "Ada Lovelace", handle: "ada")

        #expect(store.recents.count == 1)
        #expect(store.recents.map(\.text) == ["Ada Lovelace"])
    }

    /// A person and a query that read the same must not collide — that is what
    /// the `"profile:"` prefix on the key is for.
    @Test func aProfileAndAQueryOfTheSameTextCoexist() {
        let store = makeStore()

        store.recordQuery("ada")
        store.recordProfile(id: "prof-1", displayName: "ada", handle: "ada")

        #expect(store.recents.count == 2)
        #expect(store.recents.map(\.kind) == [.profile, .query])
    }

    @Test func aProfileWithNoNameFallsBackToItsHandle() throws {
        let store = makeStore()

        store.recordProfile(id: "prof-1", displayName: "   ", handle: "ada")

        #expect(try #require(store.recents.first).text == "ada")
    }

    /// Nothing to route back to.
    @Test func aProfileWithNoIdIsNotRecorded() {
        let store = makeStore()

        #expect(store.recordProfile(id: "", displayName: "Ada", handle: "ada") == nil)
        #expect(store.recents.isEmpty)
    }

    /// The handle is the second line, so repeating it there when it is also
    /// the first would be the same word twice.
    @Test func aHandleThatEqualsTheNameIsNotAlsoTheSubtitle() throws {
        let store = makeStore()

        store.recordProfile(id: "prof-1", displayName: "ada", handle: "ada")

        #expect(try #require(store.recents.first).subtitle == nil)
    }

    @Test func profileEntriesSurviveAReload() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        RecentSearchStore(defaults: defaults, now: { 7 })
            .recordProfile(id: "prof-1", displayName: "Ada", handle: "ada")

        let reloaded = RecentSearchStore(defaults: defaults, now: { 7 }).recents

        #expect(reloaded.map(\.profileID) == ["prof-1"])
        #expect(reloaded.map(\.kind) == [.profile])
    }
}
