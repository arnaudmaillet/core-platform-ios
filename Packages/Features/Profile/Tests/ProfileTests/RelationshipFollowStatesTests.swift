import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Profile

/// Follow states on the relations screen and the profile header (#726):
/// a private profile is Requested, a refused follow takes Follow away, no
/// unfollow confirmation, one-line buttons that morph.
@MainActor
struct RelationshipFollowStatesTests {
    // MARK: - End to end over the mock BFF

    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private struct Fixture {
        let profiles: ProfileRepository
        let lists: ProfileRelationshipsRepository
        let graph: SocialGraph_V1_SocialGraphServiceClient
        let social: MockSocialServices
    }

    private func makeFixture() -> Fixture {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        let social = MockSocialServices(dataset: dataset)
        social.register(on: bff)
        MockSocialGraphService(dataset: dataset, isPrivate: { social.isPrivate($0) }).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let graph = SocialGraph_V1_SocialGraphServiceClient(client: client)
        let profiles = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: graph,
            authSession: Session()
        )
        let lists = ProfileRelationshipsRepository(
            socialGraphClient: graph,
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            viewer: profiles,
            supportsFollowerRemoval: true
        )
        return Fixture(profiles: profiles, lists: lists, graph: graph, social: social)
    }

    private var viewer: ProfileID { ProfileID(MockSocialDataset.viewerProfileID) }

    /// ⚠️ A REQUEST IS NOT A FOLLOW: following a private follower back asks
    /// them, a second tap is still Requested (not "Couldn't follow"), the
    /// reloaded row says Requested, and withdrawing it works.
    @Test func followingAPrivateProfileBackIsARequest() async throws {
        let fixture = makeFixture()
        let page = try await fixture.lists.relationships(for: viewer, direction: .followers, pageToken: "", limit: 50)
        let target = try #require(page.relations.first {
            !$0.viewerFollows && !$0.isViewer && fixture.social.isPrivate($0.id.rawValue)
        }, "no private follower to follow back")

        #expect(try await fixture.lists.follow(target.id) == .requested)
        #expect(try await fixture.lists.follow(target.id) == .requested, "a pending request read as a failure")

        let reloaded = try await fixture.lists.relationships(for: viewer, direction: .followers, pageToken: "", limit: 50)
        let row = try #require(reloaded.relations.first { $0.id == target.id })
        #expect(row.viewerRequested, "the reloaded row forgot the request")
        #expect(!row.viewerFollows, "a request was folded into the follow set")

        try await fixture.lists.cancelFollowRequest(to: target.id)
        let after = try await fixture.lists.relationships(for: viewer, direction: .followers, pageToken: "", limit: 50)
        #expect(after.relations.first { $0.id == target.id }?.viewerRequested == false)
    }

    /// Someone who blocks the viewer can't be followed: the follow is
    /// refused as `cannotFollow`, and their row stops offering it.
    @Test func aRefusedFollowTakesFollowAway() async throws {
        let fixture = makeFixture()
        let page = try await fixture.lists.relationships(for: viewer, direction: .followers, pageToken: "", limit: 50)
        let blocker = try #require(page.relations.first {
            !$0.viewerFollows && !$0.isViewer && !fixture.social.isPrivate($0.id.rawValue)
        })
        var block = SocialGraph_V1_BlockRequest()
        block.actorID = blocker.id.rawValue
        block.targetID = viewer.rawValue
        _ = await fixture.graph.block(request: block, headers: [:])

        await #expect(throws: RelationshipsError.cannotFollow) {
            _ = try await fixture.lists.follow(blocker.id)
        }
        // A block tears the edges down: find them wherever they are now.
        #expect(try await fixture.profiles.relationship(for: blocker.id) == .cannotFollow,
                "their profile still offers Follow")
    }

    // MARK: - The view model

    private actor RequestingProvider: ProfileRelationshipsProviding, FollowRequestSending {
        enum Answer { case following, requested, refused }
        private let people: [ProfileRelation]
        private let answer: Answer
        private(set) var cancels: [ProfileID] = []
        private(set) var unfollows: [ProfileID] = []
        let supportsFollowerRemoval = true

        init(people: [ProfileRelation], answer: Answer) {
            self.people = people
            self.answer = answer
        }

        func relationships(for profileID: ProfileID, direction: RelationshipDirection, pageToken: String, limit: Int32)
        async throws -> RelationshipPage {
            RelationshipPage(relations: direction == .followers ? people : [], nextPageToken: "")
        }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {
            if !following { unfollows.append(profileID) }
        }
        func removeFollower(_ profileID: ProfileID) async throws {}
        func invalidateViewerCache() async {}
        func follow(_ profileID: ProfileID) async throws -> FollowOutcome {
            switch answer {
            case .following: return .following
            case .requested: return .requested
            case .refused: throw RelationshipsError.cannotFollow
            }
        }
        func cancelFollowRequest(to profileID: ProfileID) async throws { cancels.append(profileID) }
    }

    private func person(_ id: String, follows: Bool = false) -> ProfileRelation {
        ProfileRelation(id: ProfileID(id), handle: id, displayName: id.capitalized, avatarURL: nil,
                        isVerified: false, viewerFollows: follows, isViewer: false)
    }

    private func ownLists(_ provider: RequestingProvider) -> ProfileRelationshipsViewModel {
        ProfileRelationshipsViewModel(
            subject: .init(id: ProfileID("me"), handle: "me", visibility: .public, viewerFollowsSubject: true,
                           isSelf: true, followerCount: .exact(1), followingCount: .exact(0)),
            repository: provider
        )
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func aPrivateFollowBackBecomesRequestedAndATapWithdrawsIt() async {
        let provider = RequestingProvider(people: [person("xio")], answer: .requested)
        let viewModel = ownLists(provider)
        var rows: [ProfileRelationshipsViewModel.Row] = []
        viewModel.onPhaseChange = { direction, phase in
            if direction == .followers, case .content(let content, _) = phase { rows = content }
        }
        viewModel.viewDidLoad()
        #expect(await settle { rows.first?.action == .followBack })
        viewModel.toggleFollow(ProfileID("xio"))
        #expect(await settle { rows.first?.action == .requested }, "a request read as Following")
        viewModel.toggleFollow(ProfileID("xio"))
        #expect(await settle { rows.first?.action == .followBack }, "Requested did not withdraw")
        var cancels: [ProfileID] = []
        for _ in 0..<200 where cancels.isEmpty {
            cancels = await provider.cancels
            if cancels.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(cancels == [ProfileID("xio")])
    }

    @Test func aRefusedFollowLeavesNoButton() async {
        let provider = RequestingProvider(people: [person("blocker")], answer: .refused)
        let viewModel = ownLists(provider)
        var rows: [ProfileRelationshipsViewModel.Row] = []
        var notices = 0
        viewModel.onPhaseChange = { direction, phase in
            if direction == .followers, case .content(let content, _) = phase { rows = content }
        }
        viewModel.onActionResult = { _ in notices += 1 }
        viewModel.viewDidLoad()
        #expect(await settle { rows.first?.action == .followBack })
        viewModel.toggleFollow(ProfileID("blocker"))
        #expect(await settle { rows.first?.action == .inert }, "a refused follow kept offering Follow")
        #expect(notices == 0, "a refusal was reported as a failure")
    }

    /// Following unfollows at once — the screen asks nothing.
    @Test func followingUnfollowsWithoutAConfirmation() async throws {
        let provider = RequestingProvider(people: [person("kenji", follows: true)], answer: .following)
        let viewModel = ownLists(provider)
        let screen = ProfileRelationshipsViewController(viewModel: viewModel, imagePipeline: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        defer { window.isHidden = true }
        #expect(await settle {
            screen.view.layoutIfNeeded()
            return Self.firstCell(in: screen.view) != nil
        })
        let cell = try #require(Self.firstCell(in: screen.view))
        cell.onAction?()
        #expect(screen.presentedViewController == nil, "an unfollow confirmation was presented")
        var unfollows: [ProfileID] = []
        for _ in 0..<200 where unfollows.isEmpty {
            unfollows = await provider.unfollows
            if unfollows.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(unfollows == [ProfileID("kenji")], "the tap did not unfollow")
    }

    private static func firstCell(in view: UIView) -> RelationshipListCell? {
        if let cell = view as? RelationshipListCell { return cell }
        for subview in view.subviews {
            if let cell = firstCell(in: subview) { return cell }
        }
        return nil
    }

    // MARK: - The profile header

    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// A profile the viewer can't follow shows no Follow (Message stays);
    /// a change of follow state morphs the capsule.
    @Test func theHeaderHidesAnImpossibleFollowAndMorphsAChange() throws {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = true
        window.addSubview(header)
        header.frame = window.bounds

        header.configureAction(.unavailable)
        #expect(header.debugFollowTitle == nil, "an impossible follow is still offered")
        let follow = try #require(header.debugTrayButtons.first as? MorphingButton)
        #expect(follow.isHidden)
        #expect(header.debugTrayButtons[1].isHidden == false, "Message went with Follow")

        header.configureAction(.follow)
        header.layoutIfNeeded()
        #expect(!follow.isMorphing, "a first answer morphed")
        header.configureAction(.following)
        #expect(follow.isMorphing, "Follow → Following did not morph")
    }

    // MARK: - The row's button

    private func row(_ action: ProfileRelationshipsViewModel.RowAction, id: String = "ava")
    -> ProfileRelationshipsViewModel.Row {
        ProfileRelationshipsViewModel.Row(
            id: ProfileID(id), displayName: "Ava", handle: "@ava", monogram: "A",
            avatarURL: nil, isVerified: false, action: action, isViewer: false
        )
    }

    /// Every state's title fits on one line in the column the row reserves,
    /// and a change of state for the same person morphs.
    @Test func everyStateIsOneLineAndAChangeMorphs() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = true
        let cell = RelationshipListCell(frame: CGRect(x: 0, y: 0, width: 390, height: 64))
        window.addSubview(cell)
        for action in [ProfileRelationshipsViewModel.RowAction.follow, .followBack, .following, .requested] {
            cell.configure(with: row(action, id: "p-\(action)"), imagePipeline: nil)
            let button = cell.debugActionButton
            let fitting = button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            #expect(fitting.width <= cell.debugReservedActionWidth + 0.5,
                    "\(action) is wider than the column: \(fitting.width) > \(cell.debugReservedActionWidth)")
            #expect(fitting.height < 40, "\(action) wrapped: \(fitting)")
        }
        cell.configure(with: row(.followBack), imagePipeline: nil)
        cell.layoutIfNeeded()
        cell.configure(with: row(.following), imagePipeline: nil)
        #expect(cell.debugActionButton.isMorphing, "the same person's change of state did not morph")
    }
}
