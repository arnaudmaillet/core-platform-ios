import CoreModels
import CoreNavigation
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Profile

/// The profile's gallery under a screen pushed over it, and on its own way
/// out (#1914): its clips play while the screen holds half the viewport,
/// pause below, and come back at half — the rule of every screen
/// (`ViewportShare`).
@MainActor
struct ProfileViewportShareTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private actor NoProfiles: ProfileProviding {
        private func someone() -> UserProfile {
            UserProfile(
                id: ProfileID("prof-demo"), handle: "you", displayName: "Demo Viewer",
                bio: "", avatarURL: nil, websiteURL: nil, isVerified: false,
                followerCount: .exact(0), followingCount: .exact(0), reactionCount: .exact(0)
            )
        }
        func currentUserProfile() async throws -> UserProfile { someone() }
        func profile(id: ProfileID) async throws -> UserProfile { someone() }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
        func updateCurrentUserProfile(
            displayName: String, bio: String, website: String, links: [ProfileLink]
        ) async throws -> UserProfile { someone() }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { someone() }
    }

    private actor NoGallery: ProfileGalleryProviding {
        func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] { [] }
        func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
        func posts(ids: [String]) async throws -> [GalleryPost] { [] }
    }

    private func screen() -> ProfileViewController {
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: NoProfiles(), gallery: NoGallery(), source: .currentUser),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeGridPage: TestGridPages.factory(),
            onLogout: nil
        )
        screen.loadViewIfNeeded()
        return screen
    }

    /// The gate reads the share: half and above plays, below pauses.
    @Test func theGalleryPlaysAtHalfAndAbove() {
        let screen = screen()
        #expect(screen.debugViewportShare.plays)
        screen.debugViewportShare.report(0.6)
        #expect(screen.debugViewportShare.plays, "the gallery paused above half")
        screen.debugViewportShare.report(0.4)
        #expect(!screen.debugViewportShare.plays, "the gallery plays on past half")
        screen.debugViewportShare.report(0.5)
        #expect(screen.debugViewportShare.plays, "the gallery did not come back at half")
    }

    /// No transition to follow (a tab switch): stopped at once, and back once
    /// the screen has appeared, as before.
    @Test func aTabSwitchStopsAndRestartsAtOnce() {
        let screen = screen()
        screen.beginAppearanceTransition(false, animated: false)
        screen.endAppearanceTransition()
        #expect(!screen.debugViewportShare.plays)
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
        #expect(screen.debugViewportShare.plays)
    }
}
