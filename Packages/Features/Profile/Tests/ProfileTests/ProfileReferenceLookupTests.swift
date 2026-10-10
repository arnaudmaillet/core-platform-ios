import CoreModels
import Foundation
import ProfileInterface
import Testing
@testable import Profile

/// A `@handle` or a share link pushes the profile at once, and the profile
/// resolves it behind its skeleton (#800).
///
/// The router used to await the lookup before pushing anything, so nothing
/// moved on screen for the whole round trip; a failed lookup was a toast on
/// the screen the viewer tapped from.
@MainActor
struct ProfileReferenceLookupTests {
    @Test func aHandleStartsOnTheSkeletonThenResolvesAndLoadsThatProfile() async {
        let lookup = ScriptedLookup([.found(ProfileID("prof-7"))], held: true)
        let provider = StubProvider()
        let viewModel = ProfileViewModel(
            repository: provider, source: .lookup(.handle("ada")), lookup: { await lookup($0) }
        )
        let phases = recorder(viewModel)

        viewModel.viewDidLoad()
        await settle { await lookup.asked == [.handle("ada")] }
        // Asked, not answered: still the skeleton, and no profile fetched.
        #expect(phases().isEmpty)
        #expect(await provider.requestedIDs.isEmpty)
        #expect(viewModel.isAwaitingLookup)

        await lookup.release()
        await settle { phases().last.map(Self.isContent) == true }
        #expect(!viewModel.isAwaitingLookup)

        #expect(await provider.requestedIDs == [ProfileID("prof-7")])
        #expect(viewModel.profile?.id == ProfileID("prof-7"))
        // The relationship is read for the resolved id, as on an author's
        // profile.
        await settle { viewModel.isRelationshipSettled }
        #expect(viewModel.canMessage)
    }

    @Test func aHandleThatNamesNoOneSaysTheAccountDoesNotExist() async {
        let lookup = ScriptedLookup([.missing])
        let provider = StubProvider()
        let viewModel = ProfileViewModel(
            repository: provider, source: .lookup(.handle("gone")), lookup: { await lookup($0) }
        )
        let phases = recorder(viewModel)

        viewModel.viewDidLoad()
        await settle { !phases().isEmpty }

        #expect(phases() == [.notFound(message: "This account doesn\u{2019}t exist", detail: nil)])
        #expect(await provider.requestedIDs.isEmpty)
    }

    /// The not-found screen offers nothing that acts on a profile: there is
    /// no id to mute, follow or message.
    @Test func aHandleThatNamesNoOneOffersNoProfileAction() async {
        let lookup = ScriptedLookup([.missing])
        let viewModel = ProfileViewModel(
            repository: StubProvider(), source: .lookup(.handle("gone")), lookup: { await lookup($0) }
        )
        let phases = recorder(viewModel)

        viewModel.viewDidLoad()
        await settle { !phases().isEmpty }

        #expect(viewModel.isAwaitingLookup)
        #expect(!viewModel.canMessage)
        #expect(!viewModel.canModerate)
        #expect(viewModel.shareCard == nil)
    }

    @Test func aShareTokenThatNamesNoOneSaysTheLinkMayHaveBeenReset() async {
        let lookup = ScriptedLookup([.missing])
        let viewModel = ProfileViewModel(
            repository: StubProvider(), source: .lookup(.shareToken("tok")), lookup: { await lookup($0) }
        )
        let phases = recorder(viewModel)

        viewModel.viewDidLoad()
        await settle { !phases().isEmpty }

        #expect(phases() == [.notFound(
            message: "This account doesn\u{2019}t exist",
            detail: "This link may have been reset or turned off."
        )])
    }

    @Test func aLookupThatDidNotGetThroughFailsAndTryAgainAsksAgain() async {
        let lookup = ScriptedLookup([.unavailable, .found(ProfileID("prof-7"))])
        let provider = StubProvider()
        let viewModel = ProfileViewModel(
            repository: provider, source: .lookup(.handle("ada")), lookup: { await lookup($0) }
        )
        let phases = recorder(viewModel)

        viewModel.viewDidLoad()
        await settle { !phases().isEmpty }
        #expect(phases() == [.failed(message: "Couldn\u{2019}t open @ada")])

        // Try Again (the failed state's action, #797) asks the same question
        // again.
        viewModel.refresh()
        await settle { phases().last.map(Self.isContent) == true }

        #expect(await lookup.asked == [.handle("ada"), .handle("ada")])
        #expect(await provider.requestedIDs == [ProfileID("prof-7")])
    }

    @Test func aResolvedHandleThatFailsToLoadFailsLikeAnyProfile() async {
        let lookup = ScriptedLookup([.found(ProfileID("prof-7"))])
        let viewModel = ProfileViewModel(
            repository: StubProvider(fails: true), source: .lookup(.handle("ada")), lookup: { await lookup($0) }
        )
        let phases = recorder(viewModel)

        viewModel.viewDidLoad()
        await settle { !phases().isEmpty }

        #expect(phases() == [.failed(message: "Couldn't load this profile")])
    }

    // MARK: - Support

    private static func isContent(_ phase: ProfileViewModel.Phase) -> Bool {
        if case .content = phase { return true }
        return false
    }

    private func recorder(_ viewModel: ProfileViewModel) -> () -> [ProfileViewModel.Phase] {
        let box = PhaseBox()
        viewModel.onPhaseChange = { box.items.append($0) }
        return { box.items }
    }

    /// Polls a condition the tasks under test will make true, rather than
    /// betting on a fixed wait.
    private func settle(until condition: () async -> Bool) async {
        for _ in 0..<2_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("the condition never held")
    }
}

@MainActor
private final class PhaseBox {
    var items: [ProfileViewModel.Phase] = []
}

/// Answers lookups from a script, one answer per question, optionally holding
/// them until released — what lets a test see the screen while it asks.
private actor ScriptedLookup {
    private var answers: [ProfileLookup]
    private var isHeld: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var asked: [ProfileReference] = []

    init(_ answers: [ProfileLookup], held: Bool = false) {
        self.answers = answers
        self.isHeld = held
    }

    func callAsFunction(_ reference: ProfileReference) async -> ProfileLookup {
        asked.append(reference)
        if isHeld { await withCheckedContinuation { waiting.append($0) } }
        return answers.isEmpty ? .unavailable : answers.removeFirst()
    }

    func release() {
        isHeld = false
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

private struct SampleError: Error {}

private actor StubProvider: ProfileProviding {
    private let fails: Bool
    private(set) var requestedIDs: [ProfileID] = []

    init(fails: Bool = false) { self.fails = fails }

    func currentUserProfile() async throws -> UserProfile { throw SampleError() }

    func profile(id: ProfileID) async throws -> UserProfile {
        requestedIDs.append(id)
        if fails { throw SampleError() }
        return UserProfile(
            id: id, handle: "ada", displayName: "Ada Lovelace", bio: "",
            avatarURL: nil, websiteURL: nil, isVerified: false,
            followerCount: .exact(1), followingCount: .exact(2), reactionCount: .exact(3)
        )
    }

    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
        .other(isFollowing: false, isBlocked: false)
    }

    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }

    func updateCurrentUserProfile(
        displayName: String, bio: String, website: String, links: [ProfileLink]
    ) async throws -> UserProfile { throw SampleError() }

    func changeHandle(_ newHandle: String) async throws -> UserProfile { throw SampleError() }
}
