import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
import UIKit
@testable import Chat

// Messages → Suggestions reads social_graph's SuggestProfiles (#644).

private struct Viewer: ViewerIdentityProviding {
    func viewerProfileID() async throws -> ProfileID { ProfileID(MockSocialDataset.viewerProfileID) }
}

// MARK: - The repository, against the mock fleet

struct SuggestProfilesRepositoryTests {
    private func makeRepository(
        isPrivate: @escaping @Sendable (String) -> Bool = { _ in false },
        isSuggestible: @escaping @Sendable (String) -> Bool = { _ in true }
    ) -> (SocialConnectionsRepository, MockBFF) {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockSocialGraphService(dataset: dataset, isPrivate: isPrivate, isSuggestible: isSuggestible).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = SocialConnectionsRepository(
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            viewer: Viewer(),
            pageSize: 200
        )
        return (repository, bff)
    }

    /// One ranked call, one read of who follows the viewer — and none of
    /// the eight `ListFollowing` the client used to fan out to.
    @Test func suggestionsAreTheServersRankingWithNoFanOut() async throws {
        let (repository, bff) = makeRepository()

        let suggestions = try await repository.suggestions(limit: 20)

        try #require(!suggestions.isEmpty, "guard: the mock viewer has friends of friends")
        let paths = bff.recordedRequests.map(\.path)
        #expect(paths.filter { $0.hasSuffix("/SuggestProfiles") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("/ListFollowing") }.isEmpty, "the fan-out is back: \(paths)")
        #expect(paths.filter { $0.hasSuffix("/ListFollowers") }.count <= 1)
        #expect(suggestions.count <= 20)
        #expect(Set(suggestions.map(\.id)).count == suggestions.count, "a profile twice")
        // Every row says why: it follows the viewer, or how many of the
        // viewer's follows follow it.
        for suggestion in suggestions {
            switch suggestion.reason {
            case .followsYou: break
            case .followedBy(let names, let total): #expect(names.isEmpty && total > 0, "\(suggestion.reason)")
            case .suggestedForYou: Issue.record("a friend of a friend with no mutuals: \(suggestion.id)")
            }
        }
    }

    /// What the server leaves out — a private profile, one that turned
    /// "appear in suggestions" off — never reaches the list.
    @Test func aProfileTheServerExcludesNeverAppears() async throws {
        let (baseline, _) = makeRepository()
        let all = try await baseline.suggestions(limit: 50).map(\.id.rawValue)
        try #require(all.count >= 3, "guard: enough suggestions to take two away")
        let hidden = all[0]
        let optedOut = all[1]

        let (repository, _) = makeRepository(
            isPrivate: { $0 == hidden },
            isSuggestible: { $0 != optedOut }
        )
        let shown = try await repository.suggestions(limit: 50).map(\.id.rawValue)

        #expect(!shown.contains(hidden), "a private profile was suggested")
        #expect(!shown.contains(optedOut), "a profile that opted out was suggested")
        #expect(shown == all.filter { $0 != hidden && $0 != optedOut }, "the rest moved")
    }

    /// Every page of `limit`, following the token until it is empty.
    private func walk(_ repository: SocialConnectionsRepository, limit: Int) async throws -> (ids: [String], pages: Int) {
        var ids: [String] = []
        var token: String?
        var pages = 0
        repeat {
            let page = try await repository.suggestions(limit: limit, after: token)
            ids += page.accounts.map(\.id.rawValue)
            token = page.nextPageToken
            pages += 1
        } while token != nil && pages < 200
        return (ids, pages)
    }

    /// ⚠️ ACROSS A PAGE BOUNDARY (#644): the first page carries a token, the
    /// next one resumes right after it, and the token is empty on the last —
    /// the same list, in the same order, whatever the page size.
    @Test func thePagesFollowTheTokenAcrossABoundary() async throws {
        let (repository, bff) = makeRepository()

        let first = try await repository.suggestions(limit: 3, after: nil)
        try #require(first.accounts.count == 3, "guard: the mock has more than one page")
        let token = try #require(first.nextPageToken, "a full first page carried no token")
        let second = try await repository.suggestions(limit: 3, after: token)
        #expect(!second.accounts.isEmpty)
        #expect(Set(second.accounts.map(\.id)).isDisjoint(with: first.accounts.map(\.id)), "a page repeated the last")

        let small = try await walk(repository, limit: 3)
        let large = try await walk(repository, limit: 50)
        #expect(small.ids == large.ids, "the pages skipped or reordered someone")
        #expect(Array(small.ids.prefix(6)) == (first.accounts + second.accounts).map(\.id.rawValue))
        #expect(Set(small.ids).count == small.ids.count, "a profile twice")
        #expect(small.pages > large.pages)
        // The two pages above, then each walk's — one ask per page.
        let asks = bff.recordedRequests.filter { $0.path.hasSuffix("/SuggestProfiles") }
        #expect(asks.count == 2 + small.pages + large.pages)
        // Who follows the viewer is read with each first page and reused by
        // the pages after it: three paging runs, three reads.
        let followerReads = bff.recordedRequests.filter { $0.path.hasSuffix("/ListFollowers") }
        #expect(followerReads.count == 3, "followers read per page: \(followerReads.count)")
    }

    /// ⚠️ A PAGE THE SERVER FILTERED DOWN TO NOTHING STILL CARRIES ITS
    /// TOKEN: what it examined was all excluded, and more follow.
    @Test func aPageFilteredToNothingComesBackEmptyWithItsToken() async throws {
        let (baseline, _) = makeRepository()
        let firstThree = Set(try await baseline.suggestions(limit: 3, after: nil).accounts.map(\.id.rawValue))
        try #require(firstThree.count == 3, "guard: three to take away")

        let (repository, _) = makeRepository(isPrivate: { firstThree.contains($0) })
        let empty = try await repository.suggestions(limit: 3, after: nil)
        #expect(empty.accounts.isEmpty)
        let token = try #require(empty.nextPageToken, "an empty page ended the list")
        let next = try await repository.suggestions(limit: 3, after: token)
        #expect(!next.accounts.isEmpty)
        #expect(firstThree.isDisjoint(with: next.accounts.map(\.id.rawValue)))
    }

    /// A conversation's @handle (#752) comes from the same profile read as
    /// its face: one `GetProfileById` for both.
    @Test func theHandleAndTheFaceShareOneProfileRead() async throws {
        let (baseline, _) = makeRepository()
        let known = try #require(try await baseline.suggestions(limit: 1).first, "guard: a profile to read")

        let (repository, bff) = makeRepository()
        _ = await repository.avatarURLs(for: [known.id])
        let handles = await repository.handles(for: [known.id, ProfileID("nobody")])

        #expect(handles == [known.id: known.handle])
        let reads = bff.recordedRequests.map(\.path).filter { $0.hasSuffix("/GetProfileById") }
        #expect(reads.count == 2, "one read per profile, cached for the handle: \(reads)")
    }
}

// MARK: - The view model: page by page, following the token

/// Pages answered by token (nil: the first), every ask recorded; can fail
/// the next ask, and change a page between asks.
private actor PagedSuggestions: SuggestionsProviding {
    private var pages: [String: SuggestionsPage]
    /// For a token no page names: what answers it (default: the end).
    private let otherwise: @Sendable (String) -> SuggestionsPage
    private(set) var asked: [String?] = []
    private(set) var limits: [Int] = []
    private var failsNext = false
    /// Why the next ask fails (#794); nil is a server fault.
    private var nextFailure: NetworkFailure?

    init(
        _ pages: [String: SuggestionsPage],
        otherwise: @escaping @Sendable (String) -> SuggestionsPage = { _ in SuggestionsPage(accounts: [], nextPageToken: nil) }
    ) {
        self.pages = pages
        self.otherwise = otherwise
    }

    func failNext(_ failure: NetworkFailure? = nil) {
        failsNext = true
        nextFailure = failure
    }

    func set(_ token: String, to page: SuggestionsPage) { pages[token] = page }

    func suggestions(limit: Int) async throws -> [SuggestedAccount] {
        try await suggestions(limit: limit, after: nil).accounts
    }

    func suggestions(limit: Int, after pageToken: String?) async throws -> SuggestionsPage {
        asked.append(pageToken)
        limits.append(limit)
        if failsNext {
            failsNext = false
            throw SuggestionsError.transport(message: "down", failure: nextFailure)
        }
        let key = pageToken ?? ""
        return pages[key] ?? otherwise(key)
    }

    func follow(_ profileID: ProfileID) async throws {}
    func unfollow(_ profileID: ProfileID) async throws {}
}

private func people(_ indexes: some Sequence<Int>) -> [SuggestedAccount] {
    indexes.map { index in
        SuggestedAccount(
            id: ProfileID("p\(index)"), handle: "p\(index)", displayName: "P \(index)",
            avatarURL: nil, reason: .followedBy(names: [], total: 1)
        )
    }
}

private func page(_ indexes: some Sequence<Int>, next: String?) -> SuggestionsPage {
    SuggestionsPage(accounts: people(indexes), nextPageToken: next)
}

@MainActor
struct SuggestionsPagingTests {
    /// Whether `condition` came to hold within `looks` looks — a budget of
    /// looks, not wall-clock time, so a starved runner spends none of it.
    private func settle(looks: Int = 2_000, until condition: () async -> Bool) async -> Bool {
        for _ in 0..<looks {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func rows(_ viewModel: SuggestionsViewModel) -> [String] {
        guard case .content(let models) = viewModel.phase else { return [] }
        return models.map(\.id.rawValue)
    }

    private func names(_ indexes: some Sequence<Int>) -> [String] { indexes.map { "p\($0)" } }

    /// ⚠️ ONE PAGE PER APPROACH TO THE END, FOLLOWING THE TOKEN, UNTIL IT IS
    /// EMPTY (#644): 20 first, then 50 at a time, and nothing once the
    /// server said the list ended.
    @Test func theNextPageLoadsAtTheEndAndTheListStopsWhenTheTokenIsEmpty() async throws {
        let source = PagedSuggestions([
            "": page(0..<20, next: "a"),
            "a": page(20..<70, next: "b"),
            "b": page(70..<75, next: nil),
        ])
        let viewModel = SuggestionsViewModel(repository: source, limit: 20, pageLimit: 50)

        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 20 })
        #expect(viewModel.hasMore)

        viewModel.loadMore()
        try #require(await settle { self.rows(viewModel).count == 70 })
        #expect(viewModel.hasMore)
        viewModel.loadMore()
        try #require(await settle { self.rows(viewModel).count == 75 })
        #expect(rows(viewModel) == names(0..<75), "a page reordered the rows above it")
        #expect(!viewModel.hasMore, "an empty token did not end the list")

        viewModel.loadMore()
        for _ in 0..<50 { await Task.yield() }
        #expect(await source.asked == [nil, "a", "b"])
        #expect(await source.limits == [20, 50, 50])
    }

    /// The ranking is recomputed per page, so a profile can come back: it
    /// is shown once, in the place it first took.
    @Test func aProfileOnTwoPagesIsShownOnceInItsFirstPlace() async throws {
        let source = PagedSuggestions([
            "": page(0..<5, next: "a"),
            "a": page([4, 5, 2, 6], next: nil),
        ])
        let viewModel = SuggestionsViewModel(repository: source, limit: 5, pageLimit: 5)

        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 5 })
        viewModel.loadMore()
        try #require(await settle { self.rows(viewModel).count == 7 })

        #expect(rows(viewModel) == names(0..<7))
    }

    /// ⚠️ A SHORT OR EMPTY PAGE WITH A TOKEN IS NOT THE END. An empty one
    /// adds no row to reach the end and ask again, so the next page is asked
    /// at once; a short one keeps the list open for the next approach.
    @Test func anEmptyPageWithATokenKeepsPaging() async throws {
        let source = PagedSuggestions([
            "": page(0..<5, next: "a"),
            "a": page([], next: "b"),
            "b": page([5], next: "c"),
            "c": page([6], next: nil),
        ])
        let viewModel = SuggestionsViewModel(repository: source, limit: 5, pageLimit: 5)

        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 5 })
        viewModel.loadMore()
        try #require(await settle { self.rows(viewModel).count == 6 })
        #expect(await source.asked == [nil, "a", "b"], "the empty page ended the walk")
        #expect(viewModel.hasMore, "a short page with a token ended the list")

        viewModel.loadMore()
        try #require(await settle { self.rows(viewModel).count == 7 })
        #expect(!viewModel.hasMore)
    }

    /// A page of profiles already shown adds nothing either: walked through.
    @Test func aPageOfRepeatsIsWalkedThroughLikeAnEmptyOne() async throws {
        let source = PagedSuggestions([
            "": page(0..<3, next: "a"),
            "a": page([1, 2], next: "b"),
            "b": page([3], next: nil),
        ])
        let viewModel = SuggestionsViewModel(repository: source, limit: 3, pageLimit: 3)

        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 3 })
        viewModel.loadMore()
        try #require(await settle { self.rows(viewModel).count == 4 })

        #expect(rows(viewModel) == names(0..<4))
        #expect(await source.asked == [nil, "a", "b"])
    }

    /// Empty pages in a row are bounded: `maxEmptyPagesInARow`, then the
    /// walk waits for the next approach — which goes on from the cursor.
    @Test func emptyPagesInARowAreBoundedAndTheNextApproachGoesOn() async throws {
        let source = PagedSuggestions(["": page(0..<5, next: "e0")]) { token in
            let index = Int(token.dropFirst()) ?? 0
            return SuggestionsPage(accounts: [], nextPageToken: "e\(index + 1)")
        }
        let viewModel = SuggestionsViewModel(repository: source, limit: 5, pageLimit: 5)
        let bound = SuggestionsViewModel.maxEmptyPagesInARow

        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 5 })
        viewModel.loadMore()
        try #require(await settle { await source.asked.count == 1 + bound })
        for _ in 0..<50 { await Task.yield() }
        #expect(await source.asked.count == 1 + bound, "the walk did not stop")
        #expect(viewModel.hasMore)

        viewModel.loadMore()
        try #require(await settle { await source.asked.count == 1 + 2 * bound })
        #expect(await source.asked.last == "e\(2 * bound - 1)", "the next approach started over")
        #expect(rows(viewModel) == names(0..<5))
    }

    /// A first page filtered down to nothing is not an empty list.
    @Test func anEmptyFirstPageWithATokenKeepsPaging() async throws {
        let source = PagedSuggestions([
            "": page([], next: "a"),
            "a": page(0..<3, next: nil),
        ])
        let viewModel = SuggestionsViewModel(repository: source, limit: 5, pageLimit: 5)

        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 3 })
        #expect(await source.asked == [nil, "a"])
        #expect(!viewModel.hasMore)
    }

    /// ⚠️ THE SLOT IS FREE WHEN THE ROWS LAND (`paging-slot-before-render`):
    /// a page that lands wholly on screen asks for the next one from its
    /// rows' `willDisplay`, inside the very emit that drew them.
    @Test func theNextAskIsTakenWhileTheRowsAreLanding() async throws {
        let source = PagedSuggestions([
            "": page(0..<5, next: "a"),
            "a": page(5..<10, next: "b"),
            "b": page([10], next: nil),
        ])
        let viewModel = SuggestionsViewModel(repository: source, limit: 5, pageLimit: 5)
        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 5 })

        viewModel.onPhaseChange = { [weak viewModel] phase in
            if case .content(let models) = phase, models.count == 10 { viewModel?.loadMore() }
        }
        viewModel.loadMore()

        try #require(await settle { self.rows(viewModel).count == 11 }, "the ask from the landing rows was turned away")
        #expect(await source.asked == [nil, "a", "b"])
    }

    /// Coming back to the page refreshes the first page — and keeps the
    /// later pages' rows below it and the cursor past them, so it never
    /// takes back what the viewer scrolled to.
    @Test func aRefreshReplacesTheFirstPageAndKeepsTheLaterOnes() async throws {
        let source = PagedSuggestions([
            "": page(0..<5, next: "a"),
            "a": page(5..<10, next: "b"),
            "b": page([10], next: nil),
        ])
        let viewModel = SuggestionsViewModel(repository: source, limit: 5, pageLimit: 5)
        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 5 })
        viewModel.loadMore()
        try #require(await settle { self.rows(viewModel).count == 10 })

        await source.set("", to: page([0, 1, 2, 3, 42], next: "a"))
        viewModel.refresh()
        try #require(await settle { self.rows(viewModel).contains("p42") })

        #expect(rows(viewModel) == names([0, 1, 2, 3, 42] + Array(5..<10)))
        #expect(viewModel.hasMore, "the refresh lost the cursor past the later pages")
        viewModel.loadMore()
        try #require(await settle { self.rows(viewModel).count == 11 })
        #expect(await source.asked == [nil, "a", nil, "b"])
    }

    /// A first page that failed offline says so; a server fault keeps
    /// "Couldn't load suggestions." (#794).
    @Test(arguments: [
        (NetworkFailure.offline, FailureCopy.offline),
        (NetworkFailure.server(code: "unavailable"), "Couldn't load suggestions."),
    ])
    func aFailedFirstPageIsWordedByWhyItFailed(failure: NetworkFailure, expected: String) async throws {
        let source = PagedSuggestions(["": page(0..<20, next: "a")])
        await source.failNext(failure)
        let viewModel = SuggestionsViewModel(repository: source, limit: 20, pageLimit: 50)

        viewModel.loadIfNeeded()
        try #require(await settle { if case .failed = viewModel.phase { true } else { false } })

        #expect(viewModel.phase == .failed(message: expected))
    }

    /// A failed ask at the end keeps the place: the next approach asks
    /// again, from the same cursor.
    @Test func aFailedAskAtTheEndIsAskedAgain() async throws {
        let source = PagedSuggestions([
            "": page(0..<20, next: "a"),
            "a": page(20..<50, next: nil),
        ])
        let viewModel = SuggestionsViewModel(repository: source, limit: 20, pageLimit: 50)
        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 20 })

        await source.failNext()
        viewModel.loadMore()
        try #require(await settle { await source.asked.count == 2 })
        for _ in 0..<50 { await Task.yield() }
        #expect(rows(viewModel).count == 20, "a failed ask took rows away")
        #expect(viewModel.hasMore)

        viewModel.loadMore()
        try #require(await settle { self.rows(viewModel).count == 50 })
        #expect(await source.asked == [nil, "a", "a"])
    }

    /// ⚠️ TWO ASKS AT ONCE ARE ONE REQUEST: the end coming into view twice
    /// while a page is on its way does not ask for it twice.
    @Test func twoAsksAtOnceMakeOneRequest() async throws {
        let source = PagedSuggestions([
            "": page(0..<5, next: "a"),
            "a": page(5..<10, next: nil),
        ])
        let viewModel = SuggestionsViewModel(repository: source, limit: 5, pageLimit: 5)
        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 5 })

        viewModel.loadMore()
        viewModel.loadMore()
        try #require(await settle { self.rows(viewModel).count == 10 })
        viewModel.loadMore()
        for _ in 0..<50 { await Task.yield() }

        #expect(await source.asked == [nil, "a"])
    }

    /// ⚠️ A FIRST LOAD PAST THE EMPTY-PAGE BOUND IS NOT AN EMPTY LIST: with
    /// no row yet, nothing can reach the end to ask, so it walks on to the
    /// first row.
    @Test func aFirstLoadWalksPastTheEmptyPageBoundToItsFirstRow() async throws {
        let empties = SuggestionsViewModel.maxEmptyPagesInARow + 2
        let source = PagedSuggestions(["": page([], next: "e0")]) { token in
            let index = Int(token.dropFirst()) ?? 0
            return index + 1 < empties ? SuggestionsPage(accounts: [], nextPageToken: "e\(index + 1)") : page([7], next: nil)
        }
        let viewModel = SuggestionsViewModel(repository: source, limit: 5, pageLimit: 5)

        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel) == ["p7"] }, "the list ended on its empty pages: \(viewModel.phase)")
        #expect(await source.asked.count == empties + 1)
    }

    /// Only empty pages, endlessly: the list says it is empty once
    /// `maxEmptyPagesWithNothingShown` of them came in a row.
    @Test func endlessEmptyPagesEndInTheEmptyState() async throws {
        let source = PagedSuggestions([:]) { token in
            let index = Int(token.dropFirst()) ?? 0
            return SuggestionsPage(accounts: [], nextPageToken: "e\(index + 1)")
        }
        let viewModel = SuggestionsViewModel(repository: source, limit: 5, pageLimit: 5)

        viewModel.loadIfNeeded()
        try #require(await settle { viewModel.phase == .empty })
        for _ in 0..<50 { await Task.yield() }
        #expect(await source.asked.count == SuggestionsViewModel.maxEmptyPagesWithNothingShown)
        #expect(!viewModel.canPageOnItsOwn)
    }

    /// Dismissing every row shown leaves none to reach the end: the next page
    /// is asked for, not the empty state shown.
    @Test func dismissingEveryRowShownBringsTheNextPage() async throws {
        let source = PagedSuggestions([
            "": page(0..<2, next: "a"),
            "a": page([2], next: nil),
        ])
        let viewModel = SuggestionsViewModel(repository: source, limit: 2, pageLimit: 2)
        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 2 })

        viewModel.dismiss(ProfileID("p0"))
        viewModel.dismiss(ProfileID("p1"))

        try #require(await settle { self.rows(viewModel) == ["p2"] }, "the list went empty with more to come: \(viewModel.phase)")
        #expect(await source.asked == [nil, "a"])
    }

    /// The toast's Undo (#957) brings a dismissed row back at its place.
    @Test func undoingADismissalBringsTheRowBackInPlace() async throws {
        let source = PagedSuggestions(["": page(0..<3, next: nil)])
        let viewModel = SuggestionsViewModel(repository: source, limit: 3, pageLimit: 3)
        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 3 })

        viewModel.dismiss(ProfileID("p1"))
        #expect(rows(viewModel) == ["p0", "p2"])
        viewModel.undoDismiss(ProfileID("p1"))
        #expect(rows(viewModel) == ["p0", "p1", "p2"])
        viewModel.undoDismiss(ProfileID("p1")) // idempotent
        #expect(rows(viewModel) == ["p0", "p1", "p2"])
    }

    /// A failed ask with no row shown is said, with its retry — not asked
    /// again at once, over and over.
    @Test func aFailedAskWithNothingShownIsSaid() async throws {
        let source = PagedSuggestions([
            "": page([0], next: "a"),
            "a": page([1], next: nil),
        ])
        let viewModel = SuggestionsViewModel(repository: source, limit: 1, pageLimit: 1)
        viewModel.loadIfNeeded()
        try #require(await settle { self.rows(viewModel).count == 1 })

        await source.failNext(.offline)
        viewModel.dismiss(ProfileID("p0"))

        try #require(await settle { if case .failed = viewModel.phase { true } else { false } })
        #expect(viewModel.phase == .failed(message: FailureCopy.offline))
        #expect(!viewModel.canPageOnItsOwn, "a failed ask would be asked again at once")
        for _ in 0..<50 { await Task.yield() }
        #expect(await source.asked == [nil, "a"])
    }
}

// MARK: - The screen: an end already in view asks again

@MainActor
struct SuggestionsScreenPagingTests {
    private func settle(looks: Int = 2_000, until condition: () async -> Bool) async -> Bool {
        for _ in 0..<looks {
            await Task.yield()
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// ⚠️ ROWS ALREADY ON SCREEN NEVER ASK AGAIN from `willDisplay`: every
    /// row fits, the first ask walked only empty pages, and the list must
    /// still go on to the page after them rather than sit under its footer.
    @Test func anEndAlreadyInViewAsksAgainAfterAWalkOfEmptyPages() async throws {
        let bound = SuggestionsViewModel.maxEmptyPagesInARow
        let source = PagedSuggestions(["": page(0..<3, next: "e0")]) { token in
            let index = Int(token.dropFirst()) ?? 0
            return index < bound ? SuggestionsPage(accounts: [], nextPageToken: "e\(index + 1)") : page([3], next: nil)
        }
        let viewModel = SuggestionsViewModel(repository: source, limit: 3, pageLimit: 3)
        let controller = SuggestionsViewController(viewModel: viewModel, imagePipeline: nil)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()

        viewModel.loadIfNeeded()

        let reached = await settle {
            if case .content(let models) = viewModel.phase { models.count == 4 } else { false }
        }
        #expect(reached, "the list stalled under its footer: \(viewModel.phase)")
        #expect(await source.asked.count == 1 + bound + 1)
    }
}
