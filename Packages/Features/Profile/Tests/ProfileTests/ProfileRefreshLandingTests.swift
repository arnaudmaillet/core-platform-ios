import CoreModels
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Profile

/// **A pull-to-refresh lands for what it brought, and nothing more.**
///
/// Filmed on a 120 Hz iPhone, 1 October 2026: releasing a pull on a profile
/// dropped frames as the refresh landed (40–98 ms main-thread turns on the
/// simulator). Every refresh blanked the grid to its bones and rebuilt it under
/// a cross-dissolve, re-posed the relationship capsule and cross-dissolved the
/// navigation bar for an identical answer; and every frame of the pull
/// measured the whole header again, twice in the scroll callback and three
/// times in the layout it caused.
///
/// Waits poll the signal (see `ProfilePushFirstFrameTests` for why no test here
/// races a clock).
@MainActor
@Suite(.timeLimit(.minutes(10)))
struct ProfileRefreshLandingTests {
    // MARK: - Fixtures

    /// Answers at once, with a follower count the test can move.
    private actor Profiles: ProfileProviding {
        private(set) var followers: Int64 = 4
        private(set) var profileReads = 0
        func setFollowers(_ count: Int64) { followers = count }

        private func kenji() -> UserProfile {
            UserProfile(
                id: ProfileID("prof-kenji"), handle: "kenji.dev", displayName: "Kenji Tanaka",
                bio: "Building small tools for small teams.", avatarURL: nil, websiteURL: nil,
                isVerified: false, followerCount: .exact(followers), followingCount: .exact(4),
                reactionCount: .exact(1_700)
            )
        }
        func currentUserProfile() async throws -> UserProfile { kenji() }
        func profile(id: ProfileID) async throws -> UserProfile {
            profileReads += 1
            return kenji()
        }
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

    /// Twelve posts, whose like counts the test can move; counts its reads.
    private actor Gallery: ProfileGalleryProviding {
        private(set) var likes: Int64 = 1
        private(set) var authoredReads = 0
        func setLikes(_ count: Int64) { likes = count }

        func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] {
            authoredReads += 1
            return (0..<12).map { index in
                var post = GalleryPost(
                    id: PostID("p-\(index)"), kind: index.isMultiple(of: 3) ? .text : .photo,
                    isRepost: false, thumbnailURL: nil, caption: "post \(index)",
                    publishedAtMS: Int64(100 - index)
                )
                post.reactionCount = likes
                return post
            }
        }
        func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
        func posts(ids: [String]) async throws -> [GalleryPost] { [] }
    }

    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
    }

    private func settle(until condition: () -> Bool) async {
        while !condition(), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Hosts a routed profile in a visible window for the length of `body`,
    /// then takes the window down — a visible window must not outlive the
    /// test (`visible-window-suite-release-crash`).
    private func hosting(
        _ profiles: Profiles, _ gallery: Gallery,
        _ body: (ProfileViewController, ProfileViewModel) async throws -> Void
    ) async rethrows {
        let viewModel = ProfileViewModel(
            repository: profiles, gallery: gallery, source: .profile(ProfileID("prof-kenji"))
        )
        let screen = ProfileViewController(
            viewModel: viewModel, imagePipeline: ImagePipeline(fetcher: SilentFetcher()), onLogout: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        // Loaded: the header, the relationship, and the grid's first page.
        // (The screen owns the view model's callbacks: none is borrowed here.)
        await settle(until: {
            viewModel.profile != nil && viewModel.isRelationshipSettled && !screen.debugIsHeaderRedacted
                && !screen.debugGalleryShowsSkeleton && screen.debugGalleryReloadCount > 0
        })
        window.layoutIfNeeded()
        try await body(screen, viewModel)
    }

    /// Releases a pull and waits for the refresh to have landed — the profile
    /// and the grid both read again, and the spinner stopped.
    private func refresh(
        _ screen: ProfileViewController, _ profiles: Profiles, _ gallery: Gallery
    ) async {
        let profileReads = await profiles.profileReads
        let galleryReads = await gallery.authoredReads
        screen.debugReleasePull()
        #expect(screen.debugIsRefreshing, "the release did not start a refresh")
        var landed = false
        while !landed, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
            let profileRead = await profiles.profileReads > profileReads
            let galleryRead = await gallery.authoredReads > galleryReads
            landed = profileRead && galleryRead && !screen.debugIsRefreshing
        }
        // The grid's answer lands a hop after its read returns.
        try? await Task.sleep(for: .milliseconds(50))
        screen.view.window?.layoutIfNeeded()
    }

    // MARK: - An identical refresh costs nothing

    /// ⚠️ THE FILMED CASE. Nothing new on the server: the header is not
    /// re-applied, no page of the grid reloads or re-dresses a cell, none
    /// falls back to its bones, and the header is not measured again.
    @Test func aRefreshThatBringsNothingNewTouchesNothing() async {
        let profiles = Profiles()
        let gallery = Gallery()
        await hosting(profiles, gallery) { screen, _ in
            let configures = screen.debugHeaderConfigureCount
            let reloads = screen.debugGalleryReloadCount
            let reconfigured = screen.debugGalleryReconfiguredItems
            let measures = screen.debugHeaderMeasureCount

            var sawBones = false
            let watch = Task { @MainActor in
                while !Task.isCancelled {
                    if screen.debugGalleryShowsSkeleton || screen.debugIsHeaderRedacted { sawBones = true }
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
            await refresh(screen, profiles, gallery)
            watch.cancel()

            #expect(!sawBones, "a refresh fell back to the skeleton")
            #expect(screen.debugHeaderConfigureCount == configures, "the header was rebuilt for the same profile")
            #expect(screen.debugGalleryReloadCount == reloads, "the grid reloaded identical pages")
            #expect(screen.debugGalleryReconfiguredItems == reconfigured)
            #expect(screen.debugHeaderMeasureCount == measures, "the header was measured again for nothing")
        }
    }

    /// The spinner stops on an identical answer too — which publishes no
    /// phase, the only place it used to be stopped.
    @Test func anIdenticalRefreshStillStopsTheSpinner() async {
        let profiles = Profiles()
        let gallery = Gallery()
        await hosting(profiles, gallery) { screen, _ in
            await refresh(screen, profiles, gallery)
            #expect(!screen.debugIsRefreshing)
        }
    }

    // MARK: - A refresh with news lands only the news

    /// New like counts on the same posts: the cells that changed are updated
    /// in place — the ones on screen by their counters alone — nothing
    /// reloads, nothing shows its bones.
    @Test func newCountsOnTheSamePostsUpdateOnlyThoseCells() async {
        let profiles = Profiles()
        let gallery = Gallery()
        await hosting(profiles, gallery) { screen, _ in
            let reloads = screen.debugGalleryReloadCount
            let updated = screen.debugGalleryReconfiguredItems
            let recounted = screen.debugGalleryRecountedItems
            await gallery.setLikes(2)

            await refresh(screen, profiles, gallery)

            #expect(screen.debugGalleryReloadCount == reloads, "a count change reloaded whole pages")
            #expect(screen.debugGalleryReconfiguredItems > updated, "the new counts were never applied")
            #expect(screen.debugGalleryRecountedItems > recounted, "the cards on screen were re-dressed for a number")
            #expect(!screen.debugGalleryShowsSkeleton)
        }
    }

    @Test func onlyCountersCountAsACountChange() {
        let post = GalleryPost(
            id: PostID("p"), kind: .photo, isRepost: false, thumbnailURL: nil, caption: "a", publishedAtMS: 1
        )
        var recounted = post
        recounted.reactionCount = 7
        recounted.commentCount = 3
        #expect(ProfileGalleryGridView.differOnlyInCounts(post, recounted))
        let recaptioned = GalleryPost(
            id: PostID("p"), kind: .photo, isRepost: false, thumbnailURL: nil, caption: "b", publishedAtMS: 1
        )
        #expect(!ProfileGalleryGridView.differOnlyInCounts(post, recaptioned))
    }

    /// A new follower count re-applies the header once — and its height,
    /// measured again because the content moved, still agrees with a fresh
    /// fitting pass.
    @Test func aNewCountReAppliesTheHeaderOnceAndItsHeightFollows() async {
        let profiles = Profiles()
        let gallery = Gallery()
        await hosting(profiles, gallery) { screen, _ in
            let configures = screen.debugHeaderConfigureCount
            await profiles.setFollowers(4_500)

            await refresh(screen, profiles, gallery)

            #expect(screen.debugHeaderConfigureCount == configures + 1)
            #expect(!screen.debugIsHeaderRedacted, "the header fell back to its bones")
            #expect(abs(screen.debugHeaderHeight - screen.debugMeasuredHeaderHeight) < 0.5)
        }
    }

    // MARK: - A scroll never measures the header

    /// ⚠️ Five fitting passes a frame, before: the header's offset and fade
    /// each asked for its travel, and the layout the move caused asked for
    /// the insets, the travel, the floor and the detents. Pulled down,
    /// scrolled up past the dock and back: not one measure — and the answer
    /// the pages were inset by is still the header's real height.
    @Test func scrollOnlyFramesNeverMeasureTheHeader() async {
        let profiles = Profiles()
        let gallery = Gallery()
        await hosting(profiles, gallery) { screen, _ in
            let measures = screen.debugHeaderMeasureCount
            let emptyStateMeasures = screen.debugEmptyStateMeasureCount
            let pull = Array(stride(from: 0.0, through: -160, by: -8))
            let travel = Array(stride(from: -160.0, through: 400, by: 16))
            for offset in pull + travel {
                screen.debugScrollFrame(to: CGFloat(offset))
            }
            screen.debugScrollFrame(to: 0)

            #expect(screen.debugHeaderMeasureCount == measures, "a scroll measured the header")
            #expect(screen.debugEmptyStateMeasureCount == emptyStateMeasures, "a scroll measured the empty state")
            #expect(abs(screen.debugHeaderHeight - screen.debugMeasuredHeaderHeight) < 0.5)
        }
    }
}

/// The header's half of it, without a screen: the same model again applies
/// nothing and does not cut short a staggered apply still landing.
@MainActor
struct ProfileHeaderApplyTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
    }

    private static func model(followers: Int64) -> ProfileDisplayModel {
        ProfileDisplayModel(profile: UserProfile(
            id: ProfileID("prof-ada"), handle: "ada", displayName: "Ada", bio: "Bio",
            avatarURL: nil, websiteURL: nil, isVerified: false,
            followerCount: .exact(followers), followingCount: .exact(1), reactionCount: .exact(1)
        ))
    }

    @Test func theSameModelAgainAppliesNothing() {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        header.configure(with: Self.model(followers: 1))
        let applied = header.debugConfigureCount
        let revision = header.layoutRevision

        header.configure(with: Self.model(followers: 1))

        #expect(header.debugConfigureCount == applied)
        #expect(header.layoutRevision == revision, "an identical model asked for the header to be measured again")
    }

    /// After the bones the labels hold ballast, not the model: the same model
    /// must be applied again in full.
    @Test func theSameModelAfterTheBonesIsAppliedAgain() {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        header.configure(with: Self.model(followers: 1))
        header.setRedacted(true)
        let applied = header.debugConfigureCount

        header.configure(with: Self.model(followers: 1))
        header.setRedacted(false)

        #expect(header.debugConfigureCount == applied + 1)
    }
}

/// The view model's half: what a refresh publishes.
@MainActor
struct ProfileRefreshPublishingTests {
    private actor Gallery: ProfileGalleryProviding {
        private(set) var likes: Int64 = 1
        private(set) var reads = 0
        func setLikes(_ count: Int64) { likes = count }
        func authoredPosts(for profileID: ProfileID) async throws -> [GalleryPost] {
            reads += 1
            var post = GalleryPost(
                id: PostID("p-1"), kind: .photo, isRepost: false, thumbnailURL: nil,
                caption: "", publishedAtMS: 1
            )
            post.reactionCount = likes
            return [post]
        }
        func taggedPosts(for profileID: ProfileID, handle: String) async throws -> [GalleryPost] { [] }
        func posts(ids: [String]) async throws -> [GalleryPost] { [] }
    }

    private actor Profiles: ProfileProviding {
        private let profile = UserProfile(
            id: ProfileID("prof-1"), handle: "ada", displayName: "Ada", bio: "",
            avatarURL: nil, websiteURL: nil, isVerified: false,
            followerCount: .exact(1), followingCount: .exact(1), reactionCount: .unavailable
        )
        func currentUserProfile() async throws -> UserProfile { profile }
        func profile(id: ProfileID) async throws -> UserProfile { profile }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
            .other(isFollowing: false, isBlocked: false)
        }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
        func updateCurrentUserProfile(
            displayName: String, bio: String, website: String, links: [ProfileLink]
        ) async throws -> UserProfile { profile }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { profile }
    }

    private func settle(until condition: () -> Bool) async {
        while !condition(), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// What the view model published, by callback.
    private final class Recorded {
        var galleries: [ProfileViewModel.GallerySnapshot] = []
        var phases = 0
        var follows = 0
        var settles = 0
    }

    private func loaded(_ gallery: Gallery) async -> (ProfileViewModel, Recorded) {
        let viewModel = ProfileViewModel(
            repository: Profiles(), gallery: gallery, source: .profile(ProfileID("prof-1"))
        )
        let recorded = Recorded()
        viewModel.onGalleryChange = { recorded.galleries.append($0) }
        viewModel.onPhaseChange = { _ in recorded.phases += 1 }
        viewModel.onFollowButtonChange = { _ in recorded.follows += 1 }
        viewModel.onLoadSettled = { recorded.settles += 1 }
        viewModel.viewDidLoad()
        await settle(until: {
            guard let last = recorded.galleries.last else { return false }
            return recorded.settles == 1 && viewModel.isRelationshipSettled && last.activity != .loading
        })
        return (viewModel, recorded)
    }

    /// Nothing new: no phase, no relationship, no gallery — the grid was read
    /// again all the same.
    @Test func anIdenticalRefreshPublishesNothing() async {
        let gallery = Gallery()
        let (viewModel, recorded) = await loaded(gallery)
        let galleries = recorded.galleries.count
        let phases = recorded.phases
        let follows = recorded.follows

        viewModel.refresh()
        var reads = 0
        while reads < 2, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
            reads = await gallery.reads
        }
        await settle(until: { recorded.settles == 2 })
        try? await Task.sleep(for: .milliseconds(50))

        #expect(recorded.galleries.count == galleries, "identical pages were published again")
        #expect(recorded.phases == phases)
        #expect(recorded.follows == follows, "an identical relationship re-posed the capsule")
    }

    /// News lands straight over what was shown — never through `.loading`.
    @Test func aRefreshNeverPublishesLoadingPages() async {
        let gallery = Gallery()
        let (viewModel, recorded) = await loaded(gallery)
        let shown = recorded.galleries.count
        await gallery.setLikes(9)

        viewModel.refresh()
        await settle(until: { recorded.galleries.count > shown })

        let published = recorded.galleries.dropFirst(shown)
        #expect(!published.contains { $0.activity == .loading }, "the refresh blanked the grid to its bones")
        guard case .content(let posts) = published.last?.activity else {
            Issue.record("the new counts never landed")
            return
        }
        #expect(posts.first?.reactionCount == 9)
    }
}
