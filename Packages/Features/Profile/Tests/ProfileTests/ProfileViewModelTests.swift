import CoreModels
import Foundation
import Testing
@testable import Profile

private actor StubProfileProvider: ProfileProviding {
    enum Outcome {
        case success(UserProfile)
        case failure(Error)
    }

    private let outcome: Outcome
    private(set) var callCount = 0

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    private(set) var lastRequestedID: ProfileID?

    func currentUserProfile() async throws -> UserProfile {
        try await resolve()
    }

    func profile(id: ProfileID) async throws -> UserProfile {
        lastRequestedID = id
        return try await resolve()
    }

    private func resolve() async throws -> UserProfile {
        callCount += 1
        switch outcome {
        case .success(let profile): return profile
        case .failure(let error): throw error
        }
    }
}

private struct SampleError: Error {}

private func sampleProfile() -> UserProfile {
    UserProfile(
        id: ProfileID("prof-1"),
        handle: "ada",
        displayName: "Ada Lovelace",
        bio: "Countess of computing",
        avatarURL: nil,
        websiteURL: nil,
        isVerified: true,
        followerCount: .exact(1_234),
        followingCount: .exact(56)
    )
}

@MainActor
struct ProfileViewModelTests {
    /// Collects every phase the view model publishes.
    private func recorder(_ viewModel: ProfileViewModel) -> () -> [ProfileViewModel.Phase] {
        let box = PhaseBox()
        viewModel.onPhaseChange = { box.append($0) }
        return { box.phases }
    }

    @Test func loadsProfileIntoContentPhase() async {
        let viewModel = ProfileViewModel(repository: StubProfileProvider(.success(sampleProfile())))
        let phases = recorder(viewModel)

        viewModel.viewDidLoad()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        let last = phases().last
        guard case .content(let model) = last else {
            Issue.record("expected content phase, got \(String(describing: last))")
            return
        }
        #expect(model.handle == "@ada")
        #expect(model.followerText == "1.2K")
        #expect(model.isVerified)
    }

    @Test func routedSourceLoadsThatProfileByID() async {
        let provider = StubProfileProvider(.success(sampleProfile()))
        let viewModel = ProfileViewModel(repository: provider, source: .profile(ProfileID("prof-42")))
        let phases = recorder(viewModel)

        viewModel.viewDidLoad()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await provider.lastRequestedID == ProfileID("prof-42"))
        guard case .content = phases().last else {
            Issue.record("expected content phase")
            return
        }
    }

    @Test func surfacesFailureWhenNothingLoaded() async {
        let viewModel = ProfileViewModel(repository: StubProfileProvider(.failure(SampleError())))
        let phases = recorder(viewModel)

        viewModel.viewDidLoad()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        guard case .failed = phases().last else {
            Issue.record("expected failed phase, got \(String(describing: phases().last))")
            return
        }
    }
}

/// Main-actor-isolated collector for phases emitted on the main actor.
@MainActor
private final class PhaseBox {
    private(set) var phases: [ProfileViewModel.Phase] = []
    func append(_ phase: ProfileViewModel.Phase) { phases.append(phase) }
}
