import CoreModels
import CoreNavigation
import Foundation
import Testing
@testable import Profile

@MainActor
private final class SpyRouter: Router {
    private(set) var routes: [AppRoute] = []
    func route(to route: AppRoute) { routes.append(route) }
}

private final class Box<T> {
    private(set) var items: [T] = []
    func append(_ item: T) { items.append(item) }
}

private struct SampleError: Error {}

/// A paginated fake of the two edge lists, keyed by direction, so a test can
/// state the whole graph it wants and let the view model page through it.
private actor StubRelationshipsProvider: ProfileRelationshipsProviding {
    private var people: [RelationshipDirection: [ProfileRelation]]
    private let failure: Error?
    private var followError: Error?
    private var removeError: Error?
    let supportsFollowerRemoval: Bool

    private(set) var pageRequests: [(RelationshipDirection, String)] = []
    private(set) var followCalls: [(Bool, ProfileID)] = []
    private(set) var removeCalls: [ProfileID] = []
    private(set) var invalidateCount = 0

    init(
        followers: [ProfileRelation] = [],
        following: [ProfileRelation] = [],
        failure: Error? = nil,
        followError: Error? = nil,
        removeError: Error? = nil,
        supportsFollowerRemoval: Bool = false
    ) {
        people = [.followers: followers, .following: following]
        self.failure = failure
        self.followError = followError
        self.removeError = removeError
        self.supportsFollowerRemoval = supportsFollowerRemoval
    }

    func relationships(
        for profileID: ProfileID,
        direction: RelationshipDirection,
        pageToken: String,
        limit: Int32
    ) async throws -> RelationshipPage {
        pageRequests.append((direction, pageToken))
        if let failure { throw failure }
        let all = people[direction] ?? []
        let start = Int(pageToken) ?? 0
        let end = min(start + Int(limit), all.count)
        guard start <= end else { return RelationshipPage(relations: [], nextPageToken: "") }
        return RelationshipPage(
            relations: Array(all[start..<end]),
            nextPageToken: end < all.count ? String(end) : ""
        )
    }

    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {
        followCalls.append((following, profileID))
        if let followError { throw followError }
    }

    func removeFollower(_ profileID: ProfileID) async throws {
        removeCalls.append(profileID)
        if let removeError { throw removeError }
        for direction in people.keys {
            people[direction]?.removeAll { $0.id == profileID }
        }
    }

    func invalidateViewerCache() async {
        invalidateCount += 1
    }
}

private func person(
    _ id: String,
    name: String? = nil,
    viewerFollows: Bool = false,
    isViewer: Bool = false
) -> ProfileRelation {
    ProfileRelation(
        id: ProfileID(id),
        handle: id,
        displayName: name ?? id.capitalized,
        avatarURL: nil,
        isVerified: false,
        viewerFollows: viewerFollows,
        isViewer: isViewer
    )
}

private func subject(
    handle: String = "ada",
    visibility: ProfileVisibility = .public,
    viewerFollows: Bool = false,
    isSelf: Bool = false,
    followerCount: CountEstimate = .unavailable,
    followingCount: CountEstimate = .unavailable
) -> ProfileRelationshipsViewModel.Subject {
    ProfileRelationshipsViewModel.Subject(
        id: ProfileID("prof-subject"),
        handle: handle,
        visibility: visibility,
        viewerFollowsSubject: viewerFollows,
        isSelf: isSelf,
        followerCount: followerCount,
        followingCount: followingCount
    )
}

// MARK: - Privacy policy

/// The privacy rule is a pure function precisely so it can be pinned as a
/// truth table — it is an *inference* standing in for a contract that doesn't
/// exist yet (`dev/BACKEND_GAPS.md` §13), so the shape of the guess is the
/// thing worth freezing.
struct RelationshipListAccessTests {
    @Test func publicProfileIsAlwaysVisible() {
        #expect(RelationshipListAccess.resolve(
            subjectVisibility: .public, viewerFollowsSubject: false, isSelf: false
        ) == .visible)
    }

    @Test func unspecifiedVisibilityIsTreatedAsPublic() {
        // An unset enum on the wire must never silently lock a profile down.
        #expect(RelationshipListAccess.resolve(
            subjectVisibility: .unspecified, viewerFollowsSubject: false, isSelf: false
        ) == .visible)
    }

    @Test func privateProfileHidesListsFromStrangers() {
        #expect(RelationshipListAccess.resolve(
            subjectVisibility: .private, viewerFollowsSubject: false, isSelf: false
        ) == .private)
    }

    @Test func privateProfileOpensToItsOwnFollowers() {
        #expect(RelationshipListAccess.resolve(
            subjectVisibility: .private, viewerFollowsSubject: true, isSelf: false
        ) == .visible)
    }

    @Test func yourOwnListsAreAlwaysYours() {
        // Including the moment right after you make your profile private.
        #expect(RelationshipListAccess.resolve(
            subjectVisibility: .private, viewerFollowsSubject: false, isSelf: true
        ) == .visible)
    }
}

// MARK: - View model

@MainActor
struct ProfileRelationshipsViewModelTests {
    private func phaseRecorder(_ viewModel: ProfileRelationshipsViewModel) -> () -> [ProfileRelationshipsViewModel.Phase] {
        let box = Box<ProfileRelationshipsViewModel.Phase>()
        viewModel.onPhaseChange = { box.append($0) }
        return { box.items }
    }

    private func actionRecorder(_ viewModel: ProfileRelationshipsViewModel) -> () -> [ProfileRelationshipsViewModel.ActionResult] {
        let box = Box<ProfileRelationshipsViewModel.ActionResult>()
        viewModel.onActionResult = { box.append($0) }
        return { box.items }
    }

    /// Polls rather than sleeping once: suites run in parallel and a fixed
    /// sleep is a wall-clock bet a loaded machine loses.
    private func settle(until condition: @escaping () -> Bool = { false }) async {
        for _ in 0..<60 {
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func rows(_ phases: () -> [ProfileRelationshipsViewModel.Phase]) -> [ProfileRelationshipsViewModel.Row] {
        for phase in phases().reversed() {
            if case .content(let rows, _) = phase { return rows }
        }
        return []
    }

    @Test func loadsFollowersIntoContent() async {
        let provider = StubRelationshipsProvider(followers: [person("ava"), person("kenji")])
        let viewModel = ProfileRelationshipsViewModel(subject: subject(), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })

        #expect(rows(phases).map(\.id.rawValue) == ["ava", "kenji"])
        #expect(rows(phases).first?.handle == "@ava")
    }

    @Test func firstPhaseIsLoading() async {
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(), repository: StubRelationshipsProvider(followers: [person("ava")])
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()

        #expect(phases().first == .loading)
    }

    @Test func privateSubjectRendersRestrictedAndIssuesNoRequest() async {
        // The screen must not *ask* a question it has decided it may not know
        // the answer to — a request would leak the viewer's interest and, on a
        // permissive backend, could even answer.
        let provider = StubRelationshipsProvider(followers: [person("ava")])
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(visibility: .private, viewerFollows: false), repository: provider
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle()

        guard case .restricted = phases().last else {
            Issue.record("expected restricted phase, got \(String(describing: phases().last))")
            return
        }
        #expect(await provider.pageRequests.isEmpty)
    }

    @Test func backendRefusalOverridesAPermissiveClientInference() async {
        // The client inferred "visible"; the fleet said no. The fleet wins, and
        // it lands as the private state rather than a retryable failure.
        let provider = StubRelationshipsProvider(failure: RelationshipsError.forbidden)
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(visibility: .public), repository: provider
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: {
            if case .restricted = phases().last { return true }
            return false
        })

        guard case .restricted = phases().last else {
            Issue.record("expected restricted phase, got \(String(describing: phases().last))")
            return
        }
    }

    @Test func transportFailureIsRetryable() async {
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(), repository: StubRelationshipsProvider(failure: SampleError())
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: {
            if case .failed = phases().last { return true }
            return false
        })

        guard case .failed = phases().last else {
            Issue.record("expected failed phase, got \(String(describing: phases().last))")
            return
        }
    }

    @Test func emptyListNamesTheDirectionAndTheSubject() async {
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(handle: "ada"), repository: StubRelationshipsProvider()
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: {
            if case .empty = phases().last { return true }
            return false
        })

        guard case .empty(let title, let message) = phases().last else {
            Issue.record("expected empty phase, got \(String(describing: phases().last))")
            return
        }
        #expect(title == "No Followers Yet")
        #expect(message.contains("@ada"))
    }

    @Test func ownEmptyListSpeaksInSecondPerson() async {
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(isSelf: true), repository: StubRelationshipsProvider()
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: {
            if case .empty = phases().last { return true }
            return false
        })

        guard case .empty(_, let message) = phases().last else {
            Issue.record("expected empty phase")
            return
        }
        #expect(message.contains("you"))
    }

    // MARK: Tabs

    @Test func theSecondTabIsNotLoadedUntilItIsSelected() async {
        let provider = StubRelationshipsProvider(
            followers: [person("ava")], following: [person("kenji")]
        )
        let viewModel = ProfileRelationshipsViewModel(subject: subject(), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })

        #expect(await provider.pageRequests.map(\.0) == [.followers])

        viewModel.selectDirection(.following)
        await settle(until: { rows(phases).first?.id.rawValue == "kenji" })

        #expect(await provider.pageRequests.map(\.0) == [.followers, .following])
    }

    @Test func returningToALoadedTabDoesNotRefetchIt() async {
        let provider = StubRelationshipsProvider(
            followers: [person("ava")], following: [person("kenji")]
        )
        let viewModel = ProfileRelationshipsViewModel(subject: subject(), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })
        viewModel.selectDirection(.following)
        await settle(until: { rows(phases).first?.id.rawValue == "kenji" })
        viewModel.selectDirection(.followers)
        await settle()

        #expect(await provider.pageRequests.count == 2)
        #expect(rows(phases).map(\.id.rawValue) == ["ava"])
    }

    // MARK: Paging

    @Test func pagesThroughTheCursorAndAppends() async {
        let provider = StubRelationshipsProvider(
            followers: (0..<5).map { person("p\($0)") }
        )
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(), repository: provider, pageSize: 2
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { rows(phases).count == 2 })

        viewModel.loadNextPageIfNeeded()
        await settle(until: { rows(phases).count == 4 })
        viewModel.loadNextPageIfNeeded()
        await settle(until: { rows(phases).count == 5 })

        #expect(rows(phases).map(\.id.rawValue) == ["p0", "p1", "p2", "p3", "p4"])
        // Exhausted: the empty cursor stops further requests.
        viewModel.loadNextPageIfNeeded()
        await settle()
        #expect(await provider.pageRequests.count == 3)
    }

    @Test func repeatedPagingRequestsAreCoalesced() async {
        let provider = StubRelationshipsProvider(followers: (0..<10).map { person("p\($0)") })
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(), repository: provider, pageSize: 2
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { rows(phases).count == 2 })

        // What scrolling actually produces: the runway check fires on every
        // cell that comes into view.
        for _ in 0..<5 { viewModel.loadNextPageIfNeeded() }
        await settle(until: { rows(phases).count == 4 })

        #expect(await provider.pageRequests.count == 2)
    }

    @Test func refreshResetsToTheFirstPageAndDropsTheViewerCache() async {
        let provider = StubRelationshipsProvider(followers: (0..<5).map { person("p\($0)") })
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(), repository: provider, pageSize: 2
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { rows(phases).count == 2 })
        viewModel.loadNextPageIfNeeded()
        await settle(until: { rows(phases).count == 4 })

        viewModel.refresh()
        await settle(until: { rows(phases).count == 2 })

        #expect(rows(phases).map(\.id.rawValue) == ["p0", "p1"])
        #expect(await provider.invalidateCount == 1)
    }

    // MARK: Follow

    @Test func followFlipsOptimisticallyBeforeTheServerAnswers() async {
        let provider = StubRelationshipsProvider(followers: [person("ava", viewerFollows: false)])
        let viewModel = ProfileRelationshipsViewModel(subject: subject(), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })

        viewModel.toggleFollow(ProfileID("ava"))
        // No settle: the flip must already be visible.
        #expect(rows(phases).first?.action == .following)

        await settle()
        #expect(await provider.followCalls.map(\.0) == [true])
    }

    @Test func aRejectedFollowRollsBackAndReports() async {
        let provider = StubRelationshipsProvider(
            followers: [person("ava")], followError: SampleError()
        )
        let viewModel = ProfileRelationshipsViewModel(subject: subject(), repository: provider)
        let phases = phaseRecorder(viewModel)
        let actions = actionRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })

        viewModel.toggleFollow(ProfileID("ava"))
        await settle(until: { !actions().isEmpty })

        #expect(rows(phases).first?.action == .follow)
        #expect(actions().count == 1)
    }

    @Test func aFollowFlipReachesTheOtherTabsCopyOfThePerson() async {
        // The same person routinely appears in both lists; two answers for one
        // relationship is a bug the user will find immediately.
        let provider = StubRelationshipsProvider(
            followers: [person("ava")], following: [person("ava")]
        )
        let viewModel = ProfileRelationshipsViewModel(subject: subject(), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })
        viewModel.selectDirection(.following)
        // Unconditional: both tabs hold the same person, so no row predicate
        // can tell "the Following tab has loaded" from "the Followers tab is
        // still the last content phase".
        await settle()
        viewModel.toggleFollow(ProfileID("ava"))
        #expect(rows(phases).first?.action == .following)

        viewModel.selectDirection(.followers)
        #expect(rows(phases).first?.action == .following)
    }

    @Test func theViewersOwnRowOffersNoAction() async {
        let provider = StubRelationshipsProvider(followers: [person("me", isViewer: true)])
        let viewModel = ProfileRelationshipsViewModel(subject: subject(), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })

        #expect(rows(phases).first?.action == .inert)
        viewModel.toggleFollow(ProfileID("me"))
        await settle()
        #expect(await provider.followCalls.isEmpty)
    }

    // MARK: Remove

    @Test func removeIsOfferedOnlyOnYourOwnFollowersListAndOnlyWhenSupported() async {
        let supported = StubRelationshipsProvider(
            followers: [person("ava")], following: [person("kenji")], supportsFollowerRemoval: true
        )
        let own = ProfileRelationshipsViewModel(subject: subject(isSelf: true), repository: supported)
        let ownPhases = phaseRecorder(own)
        own.viewDidLoad()
        await settle(until: { !rows(ownPhases).isEmpty })
        #expect(rows(ownPhases).first?.action == .remove)

        // Same list, other direction: Remove is a followers-list action.
        own.selectDirection(.following)
        await settle(until: { rows(ownPhases).first?.id.rawValue == "kenji" })
        #expect(rows(ownPhases).first?.action == .follow)

        // Someone else's followers: never.
        let other = ProfileRelationshipsViewModel(subject: subject(), repository: supported)
        let otherPhases = phaseRecorder(other)
        other.viewDidLoad()
        await settle(until: { !rows(otherPhases).isEmpty })
        #expect(rows(otherPhases).first?.action == .follow)
    }

    @Test func removeIsAbsentWhereTheBackendCannotHonorIt() async {
        // The fleet has no RemoveFollower RPC, so the row must not offer it.
        let provider = StubRelationshipsProvider(
            followers: [person("ava")], supportsFollowerRemoval: false
        )
        let viewModel = ProfileRelationshipsViewModel(subject: subject(isSelf: true), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })

        #expect(rows(phases).first?.action == .follow)
        viewModel.removeFollower(ProfileID("ava"))
        await settle()
        #expect(await provider.removeCalls.isEmpty)
    }

    @Test func removeDropsTheRowOnlyAfterTheServerAccepts() async {
        let provider = StubRelationshipsProvider(
            followers: [person("ava"), person("kenji")], supportsFollowerRemoval: true
        )
        let viewModel = ProfileRelationshipsViewModel(subject: subject(isSelf: true), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { rows(phases).count == 2 })

        viewModel.removeFollower(ProfileID("ava"))
        // Not optimistic: the row is still there until the command settles.
        #expect(rows(phases).count == 2)

        await settle(until: { rows(phases).count == 1 })
        #expect(rows(phases).map(\.id.rawValue) == ["kenji"])
    }

    @Test func aFailedRemoveKeepsTheRowAndReports() async {
        let provider = StubRelationshipsProvider(
            followers: [person("ava")], removeError: SampleError(), supportsFollowerRemoval: true
        )
        let viewModel = ProfileRelationshipsViewModel(subject: subject(isSelf: true), repository: provider)
        let phases = phaseRecorder(viewModel)
        let actions = actionRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })
        viewModel.removeFollower(ProfileID("ava"))
        await settle(until: { !actions().isEmpty })

        #expect(rows(phases).count == 1)
        #expect(actions().count == 1)
    }

    // MARK: Routing

    @Test func tappingARowRoutesToThatProfileWithAnIdentityStub() async {
        let provider = StubRelationshipsProvider(followers: [person("ava", name: "Ava Moreau", viewerFollows: true)])
        let router = SpyRouter()
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(), repository: provider, router: router
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })
        viewModel.rowTapped(ProfileID("ava"))

        guard case .profile(let id, let stub) = router.routes.last else {
            Issue.record("expected a profile route, got \(String(describing: router.routes.last))")
            return
        }
        #expect(id == ProfileID("ava"))
        #expect(stub?.displayName == "Ava Moreau")
        // The destination's Follow capsule composes before the push animates.
        #expect(stub?.isFollowing == true)
    }

    @Test func theViewersOwnRowRoutesAsSelf() async {
        // The flag the router branches on. Without it the route builds a
        // stranger profile, which discovers it is you a round trip later and
        // relabels itself to "Edit Profile" — a flicker, and a button with no
        // editor behind it. `isFollowing` stays nil because following yourself
        // is not a state.
        let provider = StubRelationshipsProvider(followers: [person("me", isViewer: true)])
        let router = SpyRouter()
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(), repository: provider, router: router
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })
        viewModel.rowTapped(ProfileID("me"))

        guard case .profile(_, let stub) = router.routes.last else {
            Issue.record("expected a profile route")
            return
        }
        #expect(stub?.isSelf == true)
        #expect(stub?.isFollowing == nil)
    }

    @Test func everyoneElseRoutesAsNotSelf() async {
        let provider = StubRelationshipsProvider(followers: [person("ava", viewerFollows: true)])
        let router = SpyRouter()
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(), repository: provider, router: router
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })
        viewModel.rowTapped(ProfileID("ava"))

        guard case .profile(_, let stub) = router.routes.last else {
            Issue.record("expected a profile route")
            return
        }
        #expect(stub?.isSelf == false)
        #expect(stub?.isFollowing == true)
    }

    // MARK: Display

    @Test func theViewersOwnRowIsFlaggedForTheMeBadge() async {
        let provider = StubRelationshipsProvider(followers: [
            person("ava"), person("me", isViewer: true)
        ])
        let viewModel = ProfileRelationshipsViewModel(subject: subject(), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { rows(phases).count == 2 })

        #expect(rows(phases).map(\.isViewer) == [false, true])
    }

    // MARK: Segment titles

    /// The titles are the three nouns, whatever the subject's counts are.
    ///
    /// They used to lead with the count ("142 Followers"), which stopped
    /// fitting when Friends made this a three-segment control — three counted
    /// titles truncate to "35 Follow…" / "12 Follow…", which cannot be told
    /// apart. Asserted against a subject that HAS counts, so a change that
    /// puts them back has to come through here.
    @Test func segmentTitlesAreTheBareNouns() {
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(followerCount: .exact(142), followingCount: .exact(89)),
            repository: StubRelationshipsProvider()
        )
        #expect(viewModel.segmentTitles == ["Followers", "Following", "Friends"])
    }

    @Test func segmentTitlesAreTheSameWithNoCountsAtAll() {
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(), repository: StubRelationshipsProvider()
        )
        #expect(viewModel.segmentTitles == ["Followers", "Following", "Friends"])
    }

    @Test func removingAFollowerDropsTheRow() async {
        let provider = StubRelationshipsProvider(
            followers: [person("ava"), person("kenji")], supportsFollowerRemoval: true
        )
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(isSelf: true, followerCount: .exact(142)), repository: provider
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { rows(phases).count == 2 })
        viewModel.removeFollower(ProfileID("ava"))
        await settle(until: { rows(phases).count == 1 })

        #expect(rows(phases).map(\.id.rawValue) == ["kenji"])
    }

    // MARK: Search

    @Test func searchFiltersOnNameAndHandle() async {
        let provider = StubRelationshipsProvider(followers: [
            person("ava.moreau", name: "Ava Moreau"),
            person("kenji.dev", name: "Kenji Tanaka"),
            person("zed", name: "Zed Aldrin")
        ])
        let viewModel = ProfileRelationshipsViewModel(subject: subject(), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { rows(phases).count == 3 })

        viewModel.searchQueryChanged("ken")           // display name
        #expect(rows(phases).map(\.id.rawValue) == ["kenji.dev"])

        viewModel.searchQueryChanged("moreau")        // handle
        #expect(rows(phases).map(\.id.rawValue) == ["ava.moreau"])

        viewModel.searchQueryChanged("")              // cleared
        #expect(rows(phases).count == 3)
    }

    @Test func searchIgnoresCaseAndDiacritics() async {
        // "sofia" must find "Sofía Reyes" — the seeded roster is full of them.
        let provider = StubRelationshipsProvider(followers: [person("sofia", name: "Sofía Reyes")])
        let viewModel = ProfileRelationshipsViewModel(subject: subject(), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })
        viewModel.searchQueryChanged("SOFIA")

        #expect(rows(phases).count == 1)
    }

    @Test func aSearchWithNoMatchesNamesTheQueryNotTheList() async {
        let provider = StubRelationshipsProvider(followers: [person("ava")])
        let viewModel = ProfileRelationshipsViewModel(subject: subject(), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { !rows(phases).isEmpty })
        viewModel.searchQueryChanged("zzz")

        guard case .empty(let title, let message) = phases().last else {
            Issue.record("expected empty phase, got \(String(describing: phases().last))")
            return
        }
        #expect(title == "No Results")
        #expect(message.contains("zzz"))
    }

    @Test func searchSuspendsPagingSoTheResultSetCannotGrowWhileReading() async {
        let provider = StubRelationshipsProvider(followers: (0..<10).map { person("p\($0)") })
        let viewModel = ProfileRelationshipsViewModel(
            subject: subject(), repository: provider, pageSize: 2
        )
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { rows(phases).count == 2 })
        viewModel.searchQueryChanged("p")
        viewModel.loadNextPageIfNeeded()
        await settle()

        #expect(await provider.pageRequests.count == 1)
    }

    @Test func theQuerySurvivesATabSwitch() async {
        let provider = StubRelationshipsProvider(
            followers: [person("ava"), person("kenji")],
            following: [person("ava"), person("zed")]
        )
        let viewModel = ProfileRelationshipsViewModel(subject: subject(), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { rows(phases).count == 2 })
        viewModel.searchQueryChanged("ava")
        #expect(rows(phases).map(\.id.rawValue) == ["ava"])

        viewModel.selectDirection(.following)
        await settle()
        #expect(rows(phases).map(\.id.rawValue) == ["ava"])
    }

    @Test func monogramTakesTwoInitialsFromWhicheverNameExists() async {
        let provider = StubRelationshipsProvider(followers: [
            person("ava", name: "Ava Moreau"),
            person("lena_klein", name: ""),
            person("cher", name: "Cher")
        ])
        let viewModel = ProfileRelationshipsViewModel(subject: subject(), repository: provider)
        let phases = phaseRecorder(viewModel)

        viewModel.viewDidLoad()
        await settle(until: { rows(phases).count == 3 })

        #expect(rows(phases).map(\.monogram) == ["AM", "LK", "C"])
    }
}
