import CoreModels
import DesignSystem
import FeedInterface
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Profile

/// **A FAILED FIRST LOAD HAS A WAY OUT (#797).** A profile that never loaded
/// said "Pull to retry" — but the pull lives on the gallery its failure hides,
/// so the viewer could only back out. It now shows the shared empty state with
/// Try Again; this pins that the action is there, that it reaches the view
/// model's reload, and that the profile it brings replaces the failure.
@MainActor
@Suite(.timeLimit(.minutes(10)))
struct ProfileFailedLoadRetryTests {
    /// Fails until told to answer; counts every read of the profile.
    private actor FlakyProfiles: ProfileProviding {
        private var answers = false
        private(set) var profileReads = 0
        func startAnswering() { answers = true }

        private func kenji() throws -> UserProfile {
            guard answers else { throw URLError(.notConnectedToInternet) }
            return UserProfile(
                id: ProfileID("prof-kenji"), handle: "kenji.dev", displayName: "Kenji Tanaka",
                bio: "", avatarURL: nil, websiteURL: nil, isVerified: false,
                followerCount: .exact(4), followingCount: .exact(4), reactionCount: .exact(1)
            )
        }
        func currentUserProfile() async throws -> UserProfile { try kenji() }
        func profile(id: ProfileID) async throws -> UserProfile {
            profileReads += 1
            return try kenji()
        }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
            .other(isFollowing: false, isBlocked: false)
        }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
        func updateCurrentUserProfile(
            displayName: String, bio: String, website: String, links: [ProfileLink]
        ) async throws -> UserProfile { try kenji() }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { try kenji() }
    }

    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
    }

    /// Whether `condition` came to hold within `looks` short looks — a budget
    /// of looks, not of wall-clock time, so a starved runner spends none of it.
    private func settle(looks: Int = 1_000, until condition: () async -> Bool) async -> Bool {
        for _ in 0..<looks {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// The screen's own status view: a direct subview, so a block nested in
    /// the gallery is never mistaken for it.
    private func statusView(of screen: UIViewController) -> EmptyStateView? {
        screen.view.subviews.compactMap { $0 as? EmptyStateView }.first { !$0.isHidden }
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    @Test func aFailedProfileOffersTryAgainWhichReloadsIt() async throws {
        let profiles = FlakyProfiles()
        let viewModel = ProfileViewModel(repository: profiles, source: .profile(ProfileID("prof-kenji")))
        let screen = ProfileViewController(
            viewModel: viewModel, imagePipeline: ImagePipeline(fetcher: SilentFetcher()), makeGridPage: TestGridPages.factory(), onLogout: nil
        )
        // A visible window for this test alone (`visible-window-suite-release-crash`).
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }

        try #require(await settle { statusView(of: screen) != nil }, "the failure was not shown")
        let status = try #require(statusView(of: screen))
        let button = try #require(Self.firstView(UIButton.self, in: status))
        #expect(!button.isHidden)
        #expect(button.isEnabled)
        #expect(button.configuration?.title == "Try Again")
        #expect(await profiles.profileReads == 1)

        await profiles.startAnswering()
        button.sendActions(for: .primaryActionTriggered)

        #expect(await settle { await profiles.profileReads == 2 }, "Try Again did not reload the profile")
        #expect(await settle { viewModel.profile != nil }, "the reload brought no profile")
        #expect(await settle { statusView(of: screen) == nil }, "the failure outlived the reload")
        #expect(viewModel.displayName == "Kenji Tanaka")
    }

    /// A gallery page that failed offers Try Again (#1767): it said "Pull to
    /// retry", on a page whose posts the failure had taken away.
    @Test func aFailedGalleryPageOffersTryAgain() {
        let state = ProfileGalleryPagerView.pageState(.failed(message: "Couldn't load these posts."), for: .saved)
        guard case .status(let status) = state else {
            Issue.record("a failed page drew no status")
            return
        }
        #expect(status.actionTitle == "Try Again")
    }

    /// ⚠️ THE CARD TOO (#1767): a card whose profile failed hid its header
    /// and was left blank — no message, no way to try again.
    @Test func aFailedProfileCardOffersTryAgainWhichReloadsIt() async throws {
        let profiles = FlakyProfiles()
        let viewModel = ProfileViewModel(repository: profiles, source: .profile(ProfileID("prof-kenji")))
        let card = ProfileCardViewController(
            viewModel: viewModel, imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            shareTargeting: nil, makeRelationshipsViewController: nil, identityStub: nil,
            actions: .init(openProfile: {}, push: { _ in })
        )
        card.loadViewIfNeeded()

        try #require(await settle { card.debugShowsStatus }, "the card's failure was not shown")
        let status = try #require(Self.firstView(EmptyStateView.self, in: card.view))
        let button = try #require(Self.firstView(UIButton.self, in: status))
        #expect(button.configuration?.title == "Try Again")

        await profiles.startAnswering()
        button.sendActions(for: .primaryActionTriggered)

        #expect(await settle { viewModel.profile != nil }, "Try Again brought no profile")
        #expect(await settle { !card.debugShowsStatus }, "the failure outlived the reload")
    }

    /// ⚠️ EDIT PROFILE TOO (#1767): a first load that failed showed an alert
    /// with only "OK" and left the skeleton up for good.
    @Test func aFailedEditorLoadOffersTryAgainWhichReloadsIt() async throws {
        let profiles = FlakyProfiles()
        let editor = EditProfileViewController(
            viewModel: EditProfileViewModel(repository: profiles, onSaved: {}),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }

        try #require(await settle { editor.debugShowsLoadFailure }, "the load's failure was not shown")
        #expect(editor.presentedViewController == nil, "an OK-only alert instead of a way out")
        let status = try #require(Self.firstView(EmptyStateView.self, in: editor.view))
        let button = try #require(Self.firstView(UIButton.self, in: status))
        #expect(button.configuration?.title == "Try Again")

        await profiles.startAnswering()
        button.sendActions(for: .primaryActionTriggered)

        #expect(await settle { !editor.debugShowsLoadFailure }, "Try Again left the failure up")
    }
}
