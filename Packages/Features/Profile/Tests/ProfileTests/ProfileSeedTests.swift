import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Profile

/// A person opened from a surface that showed them opens SEEDED (#1859): their
/// name, handle, avatar and frame at once, their counters as bones, nothing
/// reserved that may not exist; the full profile then fills in, in place.
@MainActor
struct ProfileSeedTests {
    private actor Provider: ProfileProviding {
        let profile: UserProfile
        init(profile: UserProfile) { self.profile = profile }
        func currentUserProfile() async throws -> UserProfile { profile }
        func profile(id: ProfileID) async throws -> UserProfile { profile }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .other(isFollowing: false, isBlocked: false) }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
        func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile { profile }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { profile }
    }

    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
    }

    private static let photo = URL(string: "https://example.test/grace.jpg")!

    private static func grace(bio: String = "", banner: URL? = nil) -> UserProfile {
        UserProfile(
            id: ProfileID("prof-7"), handle: "grace", displayName: "Grace Hopper", bio: bio,
            avatarURL: photo, bannerURL: banner, websiteURL: nil, isVerified: false,
            followerCount: .exact(1), followingCount: .exact(2), reactionCount: .exact(3)
        )
    }

    private static let stub = ProfileIdentityStub(handle: "grace", displayName: "Grace Hopper", avatarURL: photo)

    // MARK: - The view model

    @Test func aKnownPersonOpensSeededThenFillsIn() async {
        let viewModel = ProfileViewModel(
            repository: Provider(profile: Self.grace()), source: .profile(ProfileID("prof-7")), cache: ProfileCache()
        )
        viewModel.identity = Self.stub
        var phases: [ProfileViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.viewDidLoad()
        guard case .seeded(let seed)? = phases.first else {
            Issue.record("expected the seed before any await, got \(String(describing: phases.first))")
            return
        }
        #expect(seed.displayName == "Grace Hopper")
        #expect(seed.handle == "@grace")
        #expect(seed.avatarURL == Self.photo)
        for _ in 0..<200 where phases.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        guard case .content(let model)? = phases.last else {
            Issue.record("the profile never filled in: \(phases)")
            return
        }
        #expect(model.displayName == "Grace Hopper")
    }

    /// Nothing known: the skeleton, as before.
    @Test func anUnknownPersonStillOpensOnTheSkeleton() {
        let viewModel = ProfileViewModel(
            repository: Provider(profile: Self.grace()), source: .profile(ProfileID("prof-7")), cache: ProfileCache()
        )
        var phases: [ProfileViewModel.Phase] = []
        viewModel.onPhaseChange = { phases.append($0) }
        viewModel.viewDidLoad()
        #expect(phases.isEmpty)
    }

    // MARK: - The banner decision

    /// ⚠️ RESERVED ONLY WHEN CERTAIN: a photo avatar is the banner of a profile
    /// without one, so the band is there either way; without it, only a
    /// profile known to have a banner reserves it.
    @Test func theBannerIsReservedOnlyWhenCertain() {
        #expect(ProfileSeedModel.reservesBanner(avatarURL: Self.photo, hasBanner: nil))
        #expect(ProfileSeedModel.reservesBanner(avatarURL: Self.photo, hasBanner: false), "a photo avatar is a band")
        #expect(ProfileSeedModel.reservesBanner(avatarURL: nil, hasBanner: true))
        #expect(!ProfileSeedModel.reservesBanner(avatarURL: nil, hasBanner: false))
        #expect(!ProfileSeedModel.reservesBanner(avatarURL: nil, hasBanner: nil), "unknown reserved a banner")
        let sheet = URL(string: "https://example.test/ava.png#\(AnimatedAvatars.sheetFragment)")!
        #expect(AnimatedAvatars.isSheet(sheet))
        #expect(!ProfileSeedModel.reservesBanner(avatarURL: sheet, hasBanner: nil), "an animated avatar is no banner")
    }

    // MARK: - The header

    @Test func theSeedDrawsTheIdentityAndOnlyTheCountersWait() {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        header.render(.loading, profileKnown: false, animated: false)
        header.render(.seeded(ProfileSeedModel(ProfileIdentityStub(handle: "grace", displayName: "Grace"))), profileKnown: false, animated: false)
        #expect(!header.debugIsRedacted, "the identity is behind bones")
        #expect(header.debugAreCountersRedacted, "the counters are not bones")
        #expect(header.bannerFormat == .none, "a banner reserved for an unknown one")

        header.render(.content(ProfileDisplayModel(profile: Self.grace())), profileKnown: true, animated: false)
        #expect(!header.debugAreCountersRedacted, "the counters stayed bones")
    }

    /// The seed and a full profile that matches it (no bio, no link, the same
    /// photo avatar as its banner) are the same height: the card does not move.
    @Test func aProfileThatMatchesItsSeedDoesNotMoveTheHeader() {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        let width: CGFloat = 402
        func height() -> CGFloat {
            header.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
            header.layoutIfNeeded()
            return header.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height
        }
        header.render(.seeded(ProfileSeedModel(Self.stub)), profileKnown: false, animated: false)
        #expect(header.bannerFormat == .band, "a photo avatar's band not reserved")
        let seeded = height()
        header.render(.content(ProfileDisplayModel(profile: Self.grace())), profileKnown: true, animated: false)
        #expect(abs(height() - seeded) < 0.5, "the header moved from \(seeded) to \(height())")
    }
}
