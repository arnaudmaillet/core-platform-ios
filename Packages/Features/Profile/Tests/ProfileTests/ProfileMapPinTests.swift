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
        private var rails: [ProfileID: Set<MapFavoriteCategory>]
        private(set) var writes: [(categories: Set<MapFavoriteCategory>, id: ProfileID)] = []

        init(rails: [ProfileID: Set<MapFavoriteCategory>] = [:]) {
            self.rails = rails
        }

        func categories(for id: ProfileID) async -> Set<MapFavoriteCategory> {
            rails[id] ?? []
        }

        func setCategories(_ categories: Set<MapFavoriteCategory>, for id: ProfileID) async {
            writes.append((categories, id))
            rails[id] = categories
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

    @Test("A followed profile can be favorited")
    func followedProfileOffersTheStar() async {
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isBlocked: false), pinning: StubPinning()
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton != .hidden }

        #expect(viewModel.mapPinButton == .shown(categories: [], includesFriends: false))
        #expect(viewModel.mapPinButton.isFavorited == false)
    }

    /// The rule the feature exists to enforce: the map's people rails are a
    /// shortcut through the people you keep up with, so a stranger's profile
    /// offers no star at all.
    @Test("A profile the viewer does not follow offers nothing")
    func unfollowedProfileHidesTheStar() async {
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: false, isBlocked: false), pinning: StubPinning()
        )
        viewModel.viewDidLoad()
        await settle()

        #expect(viewModel.mapPinButton == .hidden)
    }

    @Test("Your own profile offers nothing — you cannot follow yourself")
    func ownProfileHidesTheStar() async {
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
    /// never-curated fallbacks can take a round trip, and an outline star that
    /// silently fills in is a worse first frame than one that appears late.
    @Test("Nothing is shown before the answer is known")
    func theButtonWaitsForItsState() {
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isBlocked: false), pinning: StubPinning()
        )
        #expect(viewModel.mapPinButton == .hidden)
    }

    // MARK: - Which rows the checklist offers

    /// A follower gets the two rails open to anyone the viewer follows — the
    /// dock and the Following row — but no Friends row.
    @Test("A follower's checklist has no Friends row")
    func aFollowerHasNoFriendsRow() async {
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isBlocked: false), pinning: StubPinning()
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton != .hidden }

        #expect(viewModel.mapPinButton.includesFriends == false)
    }

    /// A follower is not a friend, and asking for the Friends rail must not
    /// put them on it — whatever a caller (or a stale menu) says. The dock and
    /// Following parts of the same request still land.
    @Test("A follower cannot be put on the Friends rail")
    func aFollowerCannotBeAFriend() async {
        let pinning = StubPinning()
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isBlocked: false), pinning: pinning
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton != .hidden }

        viewModel.setMapCategories([.friends, .following, .dock])
        await settle(untilAsync: { await pinning.writes.count == 1 })

        #expect(viewModel.mapPinButton.categories == [.following, .dock])
        #expect(await pinning.writes.first?.categories == [.following, .dock])
    }

    @Test("A mutual's checklist includes the Friends row")
    func aMutualHasTheFriendsRow() async {
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isMutual: true, isBlocked: false),
            pinning: StubPinning()
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton != .hidden }

        #expect(viewModel.mapPinButton.includesFriends)
    }

    /// THE CHECKLIST. Each row is an independent toggle, so ticking several is
    /// how a combination is reached and unticking all is how the profile
    /// leaves the map entirely — no preset row spelling any of that again.
    @Test("Ticking rows combines rails; unticking them all clears the map")
    func theChecklistReachesEveryState() async {
        let pinning = StubPinning()
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isMutual: true, isBlocked: false),
            pinning: pinning
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton != .hidden }
        #expect(viewModel.mapPinButton.categories.isEmpty, "precondition: on neither rail")

        viewModel.toggleMapCategory(.dock)
        #expect(viewModel.mapPinButton.categories == [.dock])

        viewModel.toggleMapCategory(.friends)
        #expect(viewModel.mapPinButton.categories == [.dock, .friends])

        viewModel.toggleMapCategory(.following)
        #expect(viewModel.mapPinButton.categories == [.dock, .friends, .following], "all three")

        viewModel.toggleMapCategory(.dock)
        viewModel.toggleMapCategory(.friends)
        viewModel.toggleMapCategory(.following)
        #expect(viewModel.mapPinButton.categories.isEmpty, "unticking every row left the map")

        await settle(untilAsync: { await pinning.writes.count == 6 })
        #expect(await pinning.writes.last?.categories.isEmpty == true)
    }

    /// The rows must not disturb each other — the whole point of a checklist
    /// over presets. Ticking Friends on a profile already on Following leaves
    /// Following exactly where it was.
    @Test("Each row moves its own rail and no other")
    func theRowsAreIndependent() async {
        let pinning = StubPinning(rails: [subject.id: [.following, .dock]])
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isMutual: true, isBlocked: false),
            pinning: pinning
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton.isFavorited }

        viewModel.toggleMapCategory(.friends)

        #expect(viewModel.mapPinButton.categories == [.friends, .following, .dock])
        await settle(untilAsync: { await pinning.writes.count == 1 })
        #expect(await pinning.categories(for: subject.id) == [.friends, .following, .dock],
                "ticking Friends disturbed another rail")
    }

    /// Toggling a rail off is the same act as toggling it on — the row is one
    /// control, not an "add" that needs a different gesture to undo.
    @Test("A row toggles off as readily as on")
    func aRowTogglesOff() async {
        let pinning = StubPinning(rails: [subject.id: [.friends, .following, .dock]])
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isMutual: true, isBlocked: false),
            pinning: pinning
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton.isFavorited }

        viewModel.toggleMapCategory(.following)

        #expect(viewModel.mapPinButton.categories == [.friends, .dock])
        await settle(untilAsync: { await pinning.writes.count == 1 })
        #expect(await pinning.categories(for: subject.id) == [.friends, .dock])
    }

    /// A row tapped on a profile that offers no choice — a plain follower's
    /// Friends, say — must not write. The rule lives in the view model, so a
    /// stale menu cannot smuggle a friendship in.
    @Test("A follower's Friends row writes nothing")
    func aFollowerCannotTickFriends() async {
        let pinning = StubPinning()
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isBlocked: false), pinning: pinning
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton != .hidden }

        viewModel.toggleMapCategory(.friends)
        await settle(untilAsync: { await pinning.writes.count == 1 })

        #expect(viewModel.mapPinButton.categories.isEmpty)
        #expect(await pinning.writes.first?.categories.isEmpty == true)
        #expect(viewModel.mapPinButton.includesFriends == false, "and no row offered it")
    }

    /// A mutual already on a rail reads as favorited, and the star fills for
    /// ANY rail rather than only for both.
    @Test("The star fills for any rail")
    func theStarFillsForAnyRail() async {
        let pinning = StubPinning(rails: [subject.id: [.friends]])
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isMutual: true, isBlocked: false),
            pinning: pinning
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton != .hidden }

        #expect(viewModel.mapPinButton.isFavorited)
        #expect(viewModel.mapPinButton.categories == [.friends])
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

        viewModel.toggleMapCategory(.dock)
        viewModel.setMapCategories([.following])
        await settle()

        #expect(await pinning.writes.isEmpty)
        #expect(viewModel.mapPinButton == .hidden)
    }

    // MARK: - Following and unfollowing

    /// Following someone reveals the star without a reload — the relationship
    /// and the button move together, including through the optimistic flip.
    @Test("Following reveals the star; unfollowing hides it again")
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
        #expect(viewModel.mapPinButton.categories.isEmpty)

        viewModel.toggleFollow()
        await settle { viewModel.mapPinButton == .hidden }
        #expect(viewModel.mapPinButton == .hidden)
    }

    /// ⚠️ Unfollowing hides the button; it must NOT clear the rails. The
    /// curated lists are the viewer's, and quietly editing them because a
    /// relationship changed is the kind of loss nobody can explain afterwards.
    @Test("Unfollowing does not unfavorite")
    func unfollowingLeavesTheRailsAlone() async {
        let pinning = StubPinning(rails: [subject.id: [.following]])
        let viewModel = makeViewModel(
            relationship: .other(isFollowing: true, isBlocked: false), pinning: pinning
        )
        viewModel.viewDidLoad()
        await settle { viewModel.mapPinButton.isFavorited }

        viewModel.toggleFollow()
        await settle { viewModel.mapPinButton == .hidden }

        #expect(await pinning.writes.isEmpty, "an unfollow wrote to the rails")
        #expect(await pinning.categories(for: subject.id) == [.following], "a rail was cleared")
    }
}
