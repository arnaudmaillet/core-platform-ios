import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Synchronization
import Testing
@testable import Search

/// A person row's "Following" is the VIEWER's edge (#892): the session cache
/// holding it must not outlive the viewer it was read for.
struct ProfileMetadataViewerChangeTests {
    /// Who the repository asks as. Swapped by the test the way a profile
    /// switch swaps it in the app.
    private final class ViewerBox: Sendable {
        private let id = Mutex<ProfileID?>(ProfileID("prof-a"))
        func get() -> ProfileID? { id.withLock { $0 } }
        func set(_ new: ProfileID?) { id.withLock { $0 = new } }
    }

    /// Relation reads, counted: only `prof-a` follows `prof-x`.
    private final class RelationLog: Sendable {
        private let asked = Mutex<[String]>([])
        func record(_ actor: String) { asked.withLock { $0.append(actor) } }
        var actors: [String] { asked.withLock { $0 } }
    }

    /// Holds a viewer read until opened: the read has taken WHO is asking,
    /// and answers later — after a switch, if the test switches.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var isHolding: Bool { !waiters.isEmpty }
        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private func makeRepository(
        viewer: ViewerBox, log: RelationLog, gate: Gate? = nil
    ) -> ProfileMetadataRepository {
        let bff = MockBFF()
        bff.register(path: "/profile.v1.ProfileService/GetProfileById") { (request: Profile_V1_GetProfileByIdRequest) in
            var view = Profile_V1_ProfileView()
            view.profileID = request.profileID
            view.avatarURL = "https://example.com/\(request.profileID).jpg"
            return .success(view)
        }
        bff.register(path: "/social_graph.v1.SocialGraphService/GetRelationStatus") { (request: SocialGraph_V1_GetRelationStatusRequest) in
            log.record(request.actorID)
            var view = SocialGraph_V1_RelationStatusView()
            view.status = request.actorID == "prof-a" ? .following : .none
            view.targetFollowersCount = 7
            return .success(view)
        }
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ProfileMetadataRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            viewerID: {
                let asking = viewer.get()
                await gate?.wait()
                return asking
            }
        )
    }

    private let person = ProfileID("prof-x")

    /// The repro: A follows X and the row says so; after a switch to B, the
    /// row is asked again from B's side and says "Follow".
    @Test func aViewerChangeForgetsTheFollowState() async {
        let viewer = ViewerBox()
        let log = RelationLog()
        let repository = makeRepository(viewer: viewer, log: log)

        #expect(await repository.metadata(for: [person])[person]?.isFollowed == true)
        // Cached for the session: a second ask is not a second read.
        #expect(await repository.metadata(for: [person])[person]?.isFollowed == true)
        #expect(log.actors == ["prof-a"])

        viewer.set(ProfileID("prof-b"))
        await repository.viewerDidChange(.member(AccountID("acct-1"), activeProfile: ProfileID("prof-b")))

        #expect(await repository.metadata(for: [person])[person]?.isFollowed == false,
                "the row kept the previous viewer's Following")
        #expect(log.actors == ["prof-a", "prof-b"])
    }

    /// A sign-out empties it too: a guest asks nothing from anyone's side.
    @Test func signingOutForgetsTheFollowState() async {
        let viewer = ViewerBox()
        let log = RelationLog()
        let repository = makeRepository(viewer: viewer, log: log)
        #expect(await repository.metadata(for: [person])[person]?.isFollowed == true)

        viewer.set(nil)
        await repository.viewerDidChange(.guest)

        let row = await repository.metadata(for: [person])[person]
        #expect(row?.isFollowed == false)
        #expect(row?.avatarURL != nil, "the picture is still read for a guest")
    }

    /// A read that left for the previous viewer and lands after the switch
    /// answers its own caller, but is not kept for the new viewer.
    @Test func aReadInFlightAcrossTheChangeIsNotKept() async throws {
        let viewer = ViewerBox()
        let log = RelationLog()
        let gate = Gate()
        let repository = makeRepository(viewer: viewer, log: log, gate: gate)
        let target = person

        let early = Task { await repository.metadata(for: [target])[target]?.isFollowed }
        var spins = 0
        while !(await gate.isHolding), spins < 10_000 {
            spins += 1
            await Task.yield()
        }
        #expect(await gate.isHolding, "the read never started")

        viewer.set(ProfileID("prof-b"))
        await repository.viewerDidChange(.member(AccountID("acct-1"), activeProfile: ProfileID("prof-b")))
        await gate.open()
        #expect(await early.value == true, "the early caller asked as A")
        // The late answer's bookkeeping hops back onto the repository on its
        // own task: let it land before asking, or the ask would race it.
        for _ in 0..<200 { await Task.yield() }

        #expect(await repository.metadata(for: [target])[target]?.isFollowed == false,
                "A's late answer was filed under B")
    }
}
