import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → Safety → Hidden Words (#404, backend #728), end to end over the
/// mock BFF.
@MainActor
struct HiddenWordsTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private struct Fixture {
        let profiles: ProfileRepository
        let comments: Comment_V1_CommentServiceClient
        let dataset: MockSocialDataset
    }

    private func makeFixture() -> Fixture {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let social = MockSocialServices(dataset: dataset)
        social.register(on: bff)
        MockSocialGraphService(dataset: dataset).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        MockCommentService(dataset: dataset, hiddenWords: { social.hiddenWords(of: $0) }).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return Fixture(
            profiles: ProfileRepository(
                profileClient: Profile_V1_ProfileServiceClient(client: client),
                counterClient: Counter_V1_CounterServiceClient(client: client),
                socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
                authSession: Session()
            ),
            comments: Comment_V1_CommentServiceClient(client: client),
            dataset: dataset
        )
    }

    /// The offensive filter is on by default; words are stored the server's
    /// way (trimmed, lowercased, de-duplicated, sorted).
    @Test func filtersRoundTripNormalised() async throws {
        let fixture = makeFixture()
        #expect(try await fixture.profiles.commentFilters() == CommentFilterSettings(hiddenWords: [], filtersOffensive: true))

        let saved = try await fixture.profiles.setCommentFilters(
            CommentFilterSettings(hiddenWords: ["  Spoiler ", "the end", "spoiler"], filtersOffensive: false)
        )
        #expect(saved == CommentFilterSettings(hiddenWords: ["spoiler", "the end"], filtersOffensive: false))
        #expect(try await fixture.profiles.commentFilters() == saved)
    }

    @Test func tooManyWordsAreRefused() async throws {
        let fixture = makeFixture()
        let many = (0...CommentFilterSettings.maximumWords).map { "word\($0)" }
        await #expect(throws: CommentFiltersError.tooMany) {
            _ = try await fixture.profiles.setCommentFilters(CommentFilterSettings(hiddenWords: many))
        }
    }

    /// Done when: a comment with a hidden word is hidden from the owner's view.
    @Test func aCommentWithAHiddenWordIsHidden() async throws {
        let fixture = makeFixture()
        let viewer = MockSocialDataset.viewerProfileID
        let post = try #require(fixture.dataset.posts.first { $0.authorProfileID == viewer })
        var list = Comment_V1_ListTopLevelRequest()
        list.postID = post.postID
        let before = try await fixture.comments.listTopLevel(request: list, headers: [:]).result.get().comments
        let target = try #require(before.first { $0.authorID != viewer && $0.body.contains { $0.isLetter } })
        let word = try #require(target.body.split { !$0.isLetter }.map(String.init).first { $0.count > 2 })

        _ = try await fixture.profiles.setCommentFilters(CommentFilterSettings(hiddenWords: [word]))
        let after = try await fixture.comments.listTopLevel(request: list, headers: [:]).result.get().comments
        #expect(!after.map(\.commentID).contains(target.commentID))
        #expect(after.count < before.count)
    }

    @Test func theScreenSplitsAndExplains() {
        #expect(HiddenWordsViewController.words(fromInput: "spoiler, the end,\n ,🤮") == ["spoiler", "the end", "🤮"])
        #expect(HiddenWordsViewController.footer(.words).contains("aren't told"))
    }
}
