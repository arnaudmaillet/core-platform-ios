import CoreModels
import CoreStorage
import DesignSystem
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed
@testable import Profile

/// A profile whose posts never come (#1770): after 10 s the gallery says
/// "Taking longer than usual" in place of its bones, and Try Again asks for
/// the posts again.
@MainActor
struct ProfileTakingLongerTests {
    private actor Profiles: ProfileProviding {
        private func kenji() -> UserProfile {
            UserProfile(
                id: ProfileID("prof-kenji"), handle: "kenji.dev", displayName: "Kenji Tanaka",
                bio: "", avatarURL: nil, websiteURL: nil, isVerified: false,
                followerCount: .exact(4), followingCount: .exact(4), reactionCount: .exact(1)
            )
        }
        func currentUserProfile() async throws -> UserProfile { kenji() }
        func profile(id: ProfileID) async throws -> UserProfile { kenji() }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
            .other(isFollowing: true, isBlocked: false)
        }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
        func updateCurrentUserProfile(
            displayName: String, bio: String, website: String, links: [ProfileLink]
        ) async throws -> UserProfile { kenji() }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { kenji() }
    }

    /// Posts that never come; counts the asks.
    private actor SilentGallery: ProfileGalleryProviding {
        private(set) var authoredReads = 0
        func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] {
            authoredReads += 1
            try await Task.sleep(for: .seconds(3600))
            return []
        }
        func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
        func posts(ids: [String]) async throws -> [GalleryPost] { [] }
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView, where match: (T) -> Bool) -> T? {
        if let found = view as? T, match(found), !found.isHidden { return found }
        for subview in view.subviews where !subview.isHidden {
            if let found = find(type, in: subview, where: match) { return found }
        }
        return nil
    }

    @Test func aGalleryThatNeverAnswersOffersTryAgain() async throws {
        let time = ManualLoadingClock()
        let gallery = SilentGallery()
        let viewModel = ProfileViewModel(
            repository: Profiles(), gallery: gallery, source: .profile(ProfileID("prof-kenji"))
        )
        let make = TestGridPages.factory()
        let screen = ProfileViewController(
            viewModel: viewModel, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            makeGridPage: { style, saves in
                let page = make(style, saves)
                (page as? ForYouGridPage)?.skeletonClock = time.clock
                return page
            },
            onLogout: nil
        )
        // Never seen: the pages show their bones while they load.
        screen.galleryPager.presence = SectionPresenceStore(
            defaults: UserDefaults(suiteName: "taking-longer-\(UUID().uuidString)")!
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        window.layoutIfNeeded()
        while await gallery.authoredReads == 0, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }

        time.advance(LoadingTiming.takingLonger)
        window.layoutIfNeeded()
        let status = find(UILabel.self, in: screen.view) { $0.text == TakingLongerCopy.title }
        #expect(status != nil, "no \"Taking longer\" on the gallery")
        let retry = try #require(find(UIButton.self, in: screen.view) {
            $0.configuration?.title == TakingLongerCopy.action
        })
        retry.sendActions(for: .primaryActionTriggered)
        for _ in 0..<200 where await gallery.authoredReads < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gallery.authoredReads == 2, "Try Again did not ask for the posts again")
    }
}
