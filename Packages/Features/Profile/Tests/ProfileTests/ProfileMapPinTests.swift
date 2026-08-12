import CoreModels
import Foundation
import MapsInterface
import Testing
@testable import Profile

/// THE PIN BUTTON'S TWO RULES.
///
/// Who may be pinned (only someone the viewer follows) and what the button
/// then shows. Both are decided in `ProfileViewModel`, deliberately: the rule
/// is a product decision about relationships, not a drawing concern, and a
/// header that re-derived it from `FollowButton` would be a second copy of it
/// to keep in step.

/// The subject of every test here: someone the viewer may or may not follow.
private let subject = UserProfile(
    id: ProfileID("prof-7"),
    handle: "lena",
    displayName: "Lena Fischer",
    bio: "",
    avatarURL: nil,
    websiteURL: nil,
    isVerified: false,
    followerCount: .exact(12),
    followingCount: .exact(9),
    reactionCount: .exact(3),
    viewCount: .exact(40)
)

/// Answers the identity and the relationship, and accepts a follow toggle —
/// everything the pin button's rule depends on and nothing else. A third copy
/// of this shape in the suite, matching what `ProfileViewModelTests` and
/// `ProfileGalleryTests` each keep private: the stubs differ in exactly the
/// dimension each suite is about, and sharing one would mean a stub that
/// answers questions its callers do not ask.
private actor StubProvider: ProfileProviding {
    private var relationship: ProfileRelationship

    init(relationship: ProfileRelationship) {
        self.relationship = relationship
    }

    func currentUserProfile() async throws -> UserProfile { subject }
    func profile(id: ProfileID) async throws -> UserProfile { subject }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { relationship }

    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {
        relationship = .other(isFollowing: following, isBlocked: false)
    }

    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [] }

    func updateCurrentUserProfile(
        displayName: String, bio: String, website: String, links: [ProfileLink]
    ) async throws -> UserProfile { subject }

    func changeHandle(_ newHandle: String) async throws -> UserProfile { subject }
}

@MainActor
struct ProfileMapPinTests {
    /// Records what it was asked and what it was told, so a test can assert on
    /// the WRITE rather than only on the button that caused it.
    private actor StubPinning: MapProfilePinning {
        private var pinned: Set<ProfileID>
        private(set) var writes: [(pinned: Bool, id: ProfileID)] = []
        private(set) var reads: [ProfileID] = []

        init(pinned: Set<ProfileID> = []) {
            self.pinned = pinned
        }

        func isPinned(_ id: ProfileID) async -> Bool {
            reads.append(id)
            return pinned.contains(id)
        }

        func setPinned(_ pinned: Bool, for id: ProfileID) async {
            writes.append((pinned, id))
            if pinned { self.pinned.insert(id) } else { self.pinned.remove(id) }
        }
    }

    private func makeViewModel(
        relationship: ProfileRelationship,
        pinning: (any MapProfilePinning)?
    ) -> ProfileViewModel {
        ProfileViewModel(
            repository: StubProvider(relationship: relationship),
            mapPinning: pinning,
            source: .profile(subject.id)
        )
    }

    private func settle(until condition: @escaping () -> Bool = { false }) async {
        await settle(untilAsync: condition)
    }

    /// The same poll for a condition that has to ASK an actor — a write landed
    /// on the stub, say. Polled rather than slept for the reason
    /// `ProfileViewModelTests` documents: a fixed sleep is a wall-clock bet
    /// that a loaded machine loses, and suites here run in parallel.
    private func settle(untilAsync condition: @escaping () async -> Bool) async {
        for _ in 0..<60 {
            await Task.yield()
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Who gets the button

    @Test("A followed profile can be pinned")
    func followedProfileOffersThePin() async {
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isBlocked: false), pinning: StubPinning()
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton != .hidden }

        #expect(viewModel.mapPinButton == .unpinned)
    }

    /// The rule the feature exists to enforce: the map's people rail is a
    /// shortcut through the people you keep up with, so a stranger's profile
    /// offers no pin at all.
    @Test("A profile the viewer does not follow offers nothing")
    func unfollowedProfileHidesThePin() async {
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: false, isBlocked: false), pinning: StubPinning()
        )
        viewModel.viewDidLoad()
        await settle()

        #expect(viewModel.mapPinButton == .hidden)
    }

    @Test("Your own profile offers nothing — you cannot follow yourself")
    func ownProfileHidesThePin() async {
        let viewModel = makeViewModel(relationship: .me, pinning: StubPinning())
        viewModel.viewDidLoad()
        await settle()

        #expect(viewModel.mapPinButton == .hidden)
    }

    /// An app wired without Maps must not show a button that cannot act.
    @Test("No pinning service, no button")
    func noServiceMeansNoButton() async {
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isBlocked: false), pinning: nil
        )
        viewModel.viewDidLoad()
        await settle()

        #expect(viewModel.mapPinButton == .hidden)
    }

    /// The button must not arrive wearing a guess: resolving the map's
    /// never-curated fallback can take a round trip, and an outline glyph that
    /// silently fills in is a worse first frame than one that appears late.
    @Test("Nothing is shown before the answer is known")
    func theButtonWaitsForItsState() {
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isBlocked: false), pinning: StubPinning()
        )
        #expect(viewModel.mapPinButton == .hidden)
    }

    // MARK: - What it shows and does

    @Test("An already-pinned profile shows the pinned state")
    func pinnedStateIsRead() async {
        let pinning = StubPinning(pinned: [subject.id])
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isBlocked: false), pinning: pinning
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton != .hidden }

        #expect(viewModel.mapPinButton == .pinned)
    }

    @Test("Tapping pins, and tapping again unpins")
    func tappingTogglesBothWays() async {
        let pinning = StubPinning()
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isBlocked: false), pinning: pinning
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton != .hidden }

        viewModel.toggleMapPin()
        // Optimistic: the button says so before the write has landed.
        #expect(viewModel.mapPinButton == .pinned)
        await settle(untilAsync: { await pinning.writes.count == 1 })
        #expect(await pinning.writes.map(\.pinned) == [true])
        #expect(await pinning.writes.map(\.id) == [subject.id])

        viewModel.toggleMapPin()
        #expect(viewModel.mapPinButton == .unpinned)
        await settle(untilAsync: { await pinning.writes.count == 2 })
        #expect(await pinning.writes.map(\.pinned) == [true, false])
    }

    /// A hidden button is not a silent one waiting to be pressed.
    @Test("A tap with no button writes nothing")
    func tappingWhileHiddenIsANoOp() async {
        let pinning = StubPinning()
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: false, isBlocked: false), pinning: pinning
        )
        viewModel.viewDidLoad()
        await settle()

        viewModel.toggleMapPin()
        await settle()

        #expect(await pinning.writes.isEmpty)
        #expect(viewModel.mapPinButton == .hidden)
    }

    // MARK: - Following and unfollowing

    /// Following someone reveals the pin without a reload — the relationship
    /// and the button move together, including through the optimistic flip.
    @Test("Following reveals the pin; unfollowing hides it again")
    func theButtonFollowsTheRelationship() async {
        let pinning = StubPinning()
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: false, isBlocked: false), pinning: pinning
        )
        viewModel.viewDidLoad()
        await settle()
        #expect(viewModel.mapPinButton == .hidden, "precondition: a stranger")

        viewModel.toggleFollow()
        await settle { viewModel.mapPinButton != .hidden }
        #expect(viewModel.mapPinButton == .unpinned)

        viewModel.toggleFollow()
        await settle { viewModel.mapPinButton == .hidden }
        #expect(viewModel.mapPinButton == .hidden)
    }

    /// ⚠️ Unfollowing hides the button; it must NOT unpin. The curated list is
    /// the viewer's, and quietly editing it because a relationship changed is
    /// the kind of loss nobody can explain afterwards.
    @Test("Unfollowing does not unpin")
    func unfollowingLeavesTheStoredPinAlone() async {
        let pinning = StubPinning(pinned: [subject.id])
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isBlocked: false), pinning: pinning
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton == .pinned }

        viewModel.toggleFollow()
        await settle { viewModel.mapPinButton == .hidden }

        #expect(await pinning.writes.isEmpty, "an unfollow wrote to the pinned list")
        #expect(await pinning.isPinned(subject.id), "the pin was silently dropped")
    }
}
