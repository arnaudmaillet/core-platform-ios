import CoreModels
import Foundation
import PostGrid
import Testing
@testable import Feed

private func post(_ id: String, caption: String, kind: GalleryPost.Kind = .photo) -> GalleryPost {
    GalleryPost(
        id: PostID(id),
        kind: kind,
        isRepost: false,
        thumbnailURL: nil,
        caption: caption,
        publishedAtMS: 0,
        reactionCount: nil
    )
}

struct ContentContextTests {
    private let corpus = [
        post("a", caption: "Shipped the refactor today"),
        post("b", caption: "Sunset over the bay"),
        post("c", caption: "Ranked game went to overtime"),
        post("d", caption: "Deep work morning, no notifications")
    ]

    @Test func entertainmentFiltersNothing() {
        // The default must be the WHOLE corpus, not a keyword-shaped slice of
        // it — a viewer who never opens the menu should not be silently reading
        // a filtered feed.
        #expect(ContentContext.entertainment.filtering(corpus).count == corpus.count)
    }

    @Test func entertainmentAdmitsAPostThatMatchesNoKeywordAnywhere() {
        let unrelated = [post("x", caption: "")]
        #expect(ContentContext.entertainment.filtering(unrelated).count == 1)
    }

    @Test func eachContextAdmitsItsOwnCaptions() {
        #expect(ContentContext.gaming.filtering(corpus).map(\.id.rawValue) == ["c"])
        #expect(ContentContext.work.filtering(corpus).map(\.id.rawValue).contains("a"))
        #expect(ContentContext.focus.filtering(corpus).map(\.id.rawValue).contains("d"))
    }

    /// ⚠️ Contexts OVERLAP, and that is the stand-in showing through rather
    /// than a bug to fix in the keyword lists.
    ///
    /// "Deep work morning" lands in both Work (the word "work") and Focus (the
    /// phrase "deep work"), because a caption search cannot tell which sense
    /// was meant. A real classifier on the server would assign a post its
    /// subject; until then this is what "filtered by context" honestly means,
    /// and a test that asserted exclusivity would be asserting a precision the
    /// mechanism does not have.
    @Test func contextsOverlapBecauseCaptionsAreNotCategories() {
        let ambiguous = [post("d", caption: "Deep work morning, no notifications")]
        #expect(ContentContext.work.filtering(ambiguous).count == 1)
        #expect(ContentContext.focus.filtering(ambiguous).count == 1)
    }

    @Test func matchingIsCaseInsensitive() {
        let shouty = [post("s", caption: "SHIPPED THE REFACTOR")]
        #expect(ContentContext.work.filtering(shouty).count == 1)
    }

    @Test func aContextWithNoMatchesYieldsNothingRatherThanEverything() {
        // The failure that would matter: a filter that quietly falls back to
        // the unfiltered corpus looks like it works and silently ignores the
        // viewer's choice.
        let none = [post("n", caption: "Sunset over the bay")]
        #expect(ContentContext.work.filtering(none).isEmpty)
    }

    @Test func everyContextHasATitleAndASymbol() {
        for context in ContentContext.allCases {
            #expect(context.title.isEmpty == false)
            #expect(context.symbol.isEmpty == false)
        }
    }
}

struct ContentContextStoreTests {
    private func makeStore() -> (ContentContextStore, UserDefaults, String) {
        let name = "foryou.context.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        return (ContentContextStore(defaults: suite, key: "test.context"), suite, name)
    }

    @Test func theDefaultIsEntertainment() {
        let (store, _, name) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: name) }
        #expect(store.context == .entertainment)
    }

    @Test func aChoiceSurvivesANewStoreOverTheSameDefaults() {
        let name = "foryou.context.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let first = ContentContextStore(defaults: suite, key: "test.context")
        first.context = .gaming
        let relaunched = ContentContextStore(defaults: suite, key: "test.context")
        #expect(relaunched.context == .gaming)
    }

    @Test func anUnrecognisedStoredValueDegradesToTheDefault() {
        let name = "foryou.context.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { UserDefaults().removePersistentDomain(forName: name) }
        // A downgrade reading a context a later build wrote. Anything but a
        // clean fallback here is an empty screen with no way out.
        suite.set("astrophotography", forKey: "test.context")
        let store = ContentContextStore(defaults: suite, key: "test.context")
        #expect(store.context == .entertainment)
    }
}

// MARK: - Through the view model

@MainActor
struct ForYouContextTests {
    private let corpus = [
        post("w", caption: "Shipped the refactor"),
        post("p", caption: "Sunset over the bay"),
        post("t", caption: "Standup notes", kind: .text)
    ]

    private func makeModel() -> (ForYouViewModel, () -> [ForYouViewModel.Snapshot]) {
        let provider = StubContextProvider(first: ForYouPage(posts: corpus, nextPageToken: nil))
        let model = ForYouViewModel(repository: provider)
        var snapshots: [ForYouViewModel.Snapshot] = []
        model.onSnapshotChange = { snapshots.append($0) }
        return (model, { snapshots })
    }

    @Test func theContextNarrowsBothTabsAtOnce() async {
        let (model, snapshots) = makeModel()
        model.viewDidLoad()
        for _ in 0..<12 { await Task.yield() }

        model.setContext(.work)
        let last = snapshots().last!
        // Discover (media) keeps only the work-captioned photo; Following (the
        // unfiltered page) keeps the work photo AND the work text post. Both
        // moved — a context that narrowed one tab and not the other would read
        // as a broken filter rather than as a scope anyone chose.
        #expect(last.media == .content([corpus[0]]))
        #expect(last.activity == .content([corpus[0], corpus[2]]))
    }

    @Test func widensAgainWhenTheContextIsCleared() async {
        let (model, snapshots) = makeModel()
        model.viewDidLoad()
        for _ in 0..<12 { await Task.yield() }
        model.setContext(.work)
        model.setContext(.entertainment)
        // The corpus is filtered on READ, never narrowed in place — so going
        // back to Entertainment restores everything without a refetch. Storing
        // the narrowed corpus would have made this unrecoverable.
        //
        // Compared as a SET: the page is in DISPLAY order, which the active
        // ordering decides (all these fixtures tie on reactions and time, so
        // `.trending` breaks the tie on id). Asserting the fixture's own order
        // would be testing the sort, which `DiscoverySourceTests` already owns.
        guard case .content(let restored) = snapshots().last?.activity else {
            Issue.record("expected content after clearing the context")
            return
        }
        #expect(Set(restored.map(\.id.rawValue)) == Set(corpus.map(\.id.rawValue)))
    }

    @Test func anEmptyContextSaysWhyItIsEmpty() {
        let message = ForYouViewModel.emptyMessage(format: .media, source: .trending, context: .work)
        #expect(message.contains("Work"))
        // A blank page with no explanation reads as a broken feed; naming the
        // lens turns it into a menu tap.
        #expect(message.hasSuffix("Showing Work only."))
    }

    @Test func theDefaultContextAddsNothingToTheMessage() {
        let message = ForYouViewModel.emptyMessage(format: .media, source: .trending)
        #expect(message == "No trending media yet.")
    }

    @Test func repeatingTheActiveContextIsANoOp() async {
        let (model, snapshots) = makeModel()
        model.viewDidLoad()
        for _ in 0..<12 { await Task.yield() }
        let before = snapshots().count
        model.setContext(.entertainment)
        #expect(snapshots().count == before)
    }
}

private final class StubContextProvider: ForYouProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let first: ForYouPage

    init(first: ForYouPage) { self.first = first }

    func firstPage() async throws -> ForYouPage { lock.withLock { first } }
    func page(after token: String) async throws -> ForYouPage {
        ForYouPage(posts: [], nextPageToken: nil)
    }
}
