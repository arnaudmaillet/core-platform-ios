import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Profile

/// The chrome the profile's child screens ask for.
///
/// Both of these are somewhere you GO — a form you fill in, a settings list you
/// come back from — rather than a place the app keeps four doors open onto. The
/// flag says so, and it is a single line that a refactor drops without anything
/// failing to compile and without any screenshot of the screen itself looking
/// wrong: the tab bar is simply still there, at the bottom, offering four ways
/// to abandon a half-finished form.
///
/// It is stated in each screen's own init rather than at the push site so that
/// it holds wherever the screen is pushed from, which is the property these
/// assert — they construct the screens directly, with no profile in sight.
@MainActor
struct ProfileChildChromeTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private actor StubAccount: AccountProviding {
        func currentAccount() async throws -> AccountDetails {
            AccountDetails(
                email: "ada@example.com",
                emailVerified: true,
                phone: "",
                phoneVerified: false,
                country: "FR"
            )
        }
    }

    private struct StubProfiles: ProfileProviding {
        func currentUserProfile() async throws -> UserProfile { throw CancellationError() }
        func profile(id: ProfileID) async throws -> UserProfile { throw CancellationError() }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [] }
        func updateCurrentUserProfile(
            displayName: String, bio: String, website: String, links: [ProfileLink]
        ) async throws -> UserProfile { throw CancellationError() }
        func changeHandle(_ newHandle: String) async throws -> UserProfile {
            throw CancellationError()
        }
    }

    @Test func theProfileEditorHidesTheTabBar() {
        let editor = EditProfileViewController(
            viewModel: EditProfileViewModel(repository: StubProfiles(), onSaved: {}),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher())
        )
        #expect(editor.hidesBottomBarWhenPushed)
    }

    @Test func accountSettingsHidesTheTabBar() {
        let settings = AccountSettingsViewController(account: StubAccount(), onLogout: {})
        #expect(settings.hidesBottomBarWhenPushed)
    }

    /// ⚠️ The profile itself must NOT — it is a tab root when it is the tab, and
    /// a root that hid the bar would take the app's own navigation away with it.
    /// The flag is only for the pushed context, which is what `trayPlacement`
    /// distinguishes.
    @Test func theProfileTabRootKeepsTheTabBar() {
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: StubProfiles()),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            onLogout: nil,
            trayPlacement: .aboveBottomSafeArea
        )
        #expect(screen.hidesBottomBarWhenPushed == false)
    }
}
