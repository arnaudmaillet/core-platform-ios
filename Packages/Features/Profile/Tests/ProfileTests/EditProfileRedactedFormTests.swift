import CoreModels
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Profile

/// Edit Profile waits as its own form, redacted (#1774): the hero redacted,
/// the field rows as bones, and the privacy rows real — every section in
/// its place, so nothing moves when the profile lands.
@MainActor
struct EditProfileRedactedFormTests {
    /// A profile that never answers in the test's time.
    private struct SilentProfiles: ProfileProviding {
        func currentUserProfile() async throws -> UserProfile {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
        func profile(id: ProfileID) async throws -> UserProfile { throw CancellationError() }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [] }
        func updateCurrentUserProfile(
            displayName: String, bio: String, website: String, links: [ProfileLink]
        ) async throws -> UserProfile { throw CancellationError() }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { throw CancellationError() }
    }

    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
    }

    @Test func theLoadingFormIsTheFormRedacted() {
        let time = ManualLoadingClock()
        let editor = EditProfileViewController(
            viewModel: EditProfileViewModel(repository: SilentProfiles(), onSaved: {}),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher())
        )
        editor.skeletonClock = time.clock
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        time.advance(LoadingTiming.skeletonDelay)
        let kinds = editor.debugItemKinds
        #expect(kinds.first == "heroSkeleton", "got \(kinds)")
        #expect(kinds.filter { $0 == "rowSkeleton" }.count == 5)
        #expect(kinds.contains("privacy"), "the privacy rows show nothing that loads: they are real")
    }
}
