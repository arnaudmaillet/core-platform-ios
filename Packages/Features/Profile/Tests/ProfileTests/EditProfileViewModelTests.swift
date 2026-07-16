import CoreModels
import Foundation
import Testing
@testable import Profile

private actor EditStubProvider: ProfileProviding {
    private let profile: UserProfile
    private let updateError: Error?
    private(set) var updateCalls: [(displayName: String, bio: String, website: String)] = []

    init(profile: UserProfile, updateError: Error? = nil) {
        self.profile = profile
        self.updateError = updateError
    }

    func currentUserProfile() async throws -> UserProfile { profile }
    func profile(id: ProfileID) async throws -> UserProfile { profile }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}

    func updateCurrentUserProfile(displayName: String, bio: String, website: String) async throws -> UserProfile {
        updateCalls.append((displayName, bio, website))
        if let updateError { throw updateError }
        return profile
    }
}

private struct SaveError: Error {}

private func viewerProfile() -> UserProfile {
    UserProfile(
        id: ProfileID("prof-me"),
        handle: "me",
        displayName: "Ada Lovelace",
        bio: "Countess of computing",
        avatarURL: nil,
        websiteURL: URL(string: "https://ada.example"),
        isVerified: false,
        followerCount: .exact(3),
        followingCount: .exact(5),
        reactionCount: .unavailable,
        viewCount: .unavailable
    )
}

@MainActor
struct EditProfileViewModelTests {
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func prefillsFieldsFromCurrentProfile() async {
        let viewModel = EditProfileViewModel(repository: EditStubProvider(profile: viewerProfile()), onSaved: {})
        var lastPhase: EditProfileViewModel.Phase?
        viewModel.onPhaseChange = { lastPhase = $0 }

        viewModel.viewDidLoad()
        await settle()

        #expect(lastPhase == .ready(.init(
            displayName: "Ada Lovelace",
            bio: "Countess of computing",
            website: "https://ada.example"
        )))
    }

    @Test func saveTrimsFieldsAndNotifiesOnSuccess() async {
        let provider = EditStubProvider(profile: viewerProfile())
        var saved = false
        let viewModel = EditProfileViewModel(repository: provider, onSaved: { saved = true })

        viewModel.save(.init(displayName: "  Ada L  ", bio: " hi ", website: " https://x.dev "))
        await settle()

        let calls = await provider.updateCalls
        #expect(calls.count == 1)
        #expect(calls.first?.displayName == "Ada L")
        #expect(calls.first?.bio == "hi")
        #expect(calls.first?.website == "https://x.dev")
        #expect(saved)
    }

    @Test func saveFailureSurfacesAndDoesNotNotify() async {
        let provider = EditStubProvider(profile: viewerProfile(), updateError: SaveError())
        var saved = false
        let viewModel = EditProfileViewModel(repository: provider, onSaved: { saved = true })
        var lastSaveState: EditProfileViewModel.SaveState?
        viewModel.onSaveStateChange = { lastSaveState = $0 }

        viewModel.save(.init(displayName: "Ada", bio: "", website: ""))
        await settle()

        #expect(!saved)
        guard case .failed = lastSaveState else {
            Issue.record("expected failed save state, got \(String(describing: lastSaveState))")
            return
        }
    }

    @Test func concurrentSavesAreCoalesced() async {
        let provider = EditStubProvider(profile: viewerProfile())
        let viewModel = EditProfileViewModel(repository: provider, onSaved: {})

        viewModel.save(.init(displayName: "A", bio: "", website: ""))
        viewModel.save(.init(displayName: "B", bio: "", website: "")) // ignored while first in flight
        await settle()

        #expect(await provider.updateCalls.count == 1)
    }
}
