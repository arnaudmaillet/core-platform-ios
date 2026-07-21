import CoreModels
import Foundation
import Testing
@testable import Profile

private actor EditStubProvider: ProfileProviding {
    private let profile: UserProfile
    private let updateError: Error?
    private(set) var updateCalls: [(displayName: String, bio: String, website: String, links: [ProfileLink])] = []
    private(set) var handleCalls: [String] = []

    init(profile: UserProfile, updateError: Error? = nil) {
        self.profile = profile
        self.updateError = updateError
    }

    func currentUserProfile() async throws -> UserProfile { profile }
    func profile(id: ProfileID) async throws -> UserProfile { profile }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}

    func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile {
        updateCalls.append((displayName, bio, website, links))
        if let updateError { throw updateError }
        return profile
    }

    func changeHandle(_ newHandle: String) async throws -> UserProfile {
        handleCalls.append(newHandle)
        if let updateError { throw updateError }
        return profile
    }
}

private struct SaveError: Error {}

private func viewerProfile() -> UserProfile {
    UserProfile(
        id: ProfileID("prof-me"),
        handle: "ada",
        displayName: "Ada Lovelace",
        bio: "Countess of computing",
        avatarURL: nil,
        websiteURL: URL(string: "https://ada.example"),
        customLinks: [ProfileLink(label: "Notes", url: "https://ada.example/notes")],
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
            username: "ada",
            bio: "Countess of computing",
            website: "https://ada.example",
            links: [ProfileLink(label: "Notes", url: "https://ada.example/notes")]
        )))
    }

    @Test func exposesAvatarURLOnLoad() async {
        let viewModel = EditProfileViewModel(repository: EditStubProvider(profile: viewerProfile()), onSaved: {})
        var receivedURLCallback = false
        viewModel.onAvatarURLChange = { _ in receivedURLCallback = true }

        viewModel.viewDidLoad()
        await settle()

        #expect(receivedURLCallback)
    }

    @Test func saveMetadataTrimsFieldsAndNotifiesOnSuccess() async {
        let provider = EditStubProvider(profile: viewerProfile())
        var saved = false
        let viewModel = EditProfileViewModel(repository: provider, onSaved: { saved = true })

        viewModel.saveMetadata(.init(
            displayName: "  Ada L  ",
            username: "ada",
            bio: " hi ",
            website: " https://x.dev ",
            links: [ProfileLink(label: "  Site  ", url: " https://u.dev ")]
        ))
        await settle()

        let calls = await provider.updateCalls
        #expect(calls.count == 1)
        #expect(calls.first?.displayName == "Ada L")
        #expect(calls.first?.bio == "hi")
        #expect(calls.first?.website == "https://x.dev")
        #expect(calls.first?.links == [ProfileLink(label: "Site", url: "https://u.dev")])
        #expect(saved)
    }

    @Test func saveUsernameGoesThroughChangeHandle() async {
        let provider = EditStubProvider(profile: viewerProfile())
        var saved = false
        let viewModel = EditProfileViewModel(repository: provider, onSaved: { saved = true })

        viewModel.saveUsername("  new_handle  ")
        await settle()

        #expect(await provider.handleCalls == ["new_handle"])
        #expect(await provider.updateCalls.isEmpty)
        #expect(saved)
    }

    @Test func saveFailureSurfacesAndDoesNotNotify() async {
        let provider = EditStubProvider(profile: viewerProfile(), updateError: SaveError())
        var saved = false
        let viewModel = EditProfileViewModel(repository: provider, onSaved: { saved = true })
        var lastSaveState: EditProfileViewModel.SaveState?
        viewModel.onSaveStateChange = { lastSaveState = $0 }

        viewModel.saveMetadata(.init(displayName: "Ada", username: "ada", bio: "", website: "", links: []))
        await settle()

        #expect(!saved)
        guard case .failed = lastSaveState else {
            Issue.record("expected failed save state, got \(String(describing: lastSaveState))")
            return
        }
    }

    @Test func sequentialSavesAllRun() async {
        let provider = EditStubProvider(profile: viewerProfile())
        let viewModel = EditProfileViewModel(repository: provider, onSaved: {})

        // Serialized, not coalesced: both a metadata save and a handle change
        // queued back-to-back must each reach the repository.
        viewModel.saveMetadata(.init(displayName: "A", username: "ada", bio: "", website: "", links: []))
        viewModel.saveUsername("new_handle")
        await settle()

        #expect(await provider.updateCalls.count == 1)
        #expect(await provider.handleCalls == ["new_handle"])
    }
}
