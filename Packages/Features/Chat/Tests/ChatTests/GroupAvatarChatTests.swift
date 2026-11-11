import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import FeedInterface
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Chat

/// A group's picture in Chat (#2233), on the mock's groups (`-group-chats`):
/// the faces the inbox row and the thread's pill draw — the other members,
/// owner first then by join date, up to four, "+N" beyond — the photo first
/// when there is one, and the flag off, nothing new.
///
/// The mock's photoless groups: grp-studio (3 members, 2 faces), grp-tram
/// (4, 3 faces), grp-zine (5, 4 faces, the viewer its owner), grp-festival
/// (40, 3 faces and "+37").
@MainActor
struct GroupAvatarChatTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func make(groups: Bool = true) -> ChatRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset, seedsGroups: true, seedsChannels: false).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ChatRepository(
            chatClient: Chat_V1_ChatServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session(),
            inboxPageSize: 100,
            proposals: ProposedChatClient(client: client),
            showsGroups: groups,
            showsChannels: false
        )
    }

    private func row(_ id: String, in repository: ChatRepository) async throws -> ConversationDisplayModel {
        let rows = try await repository.loadInbox(.inbox, after: nil).conversations
        return ConversationDisplayModel(conversation: try #require(rows.first { $0.id == ConversationID(id) }))
    }

    // MARK: - The order

    /// Stable: the owner first, then by join date — the viewer, the
    /// followers and the guests left out.
    @Test func theFacesAreTheOwnerFirstThenByJoinDate() {
        let start = Date(timeIntervalSince1970: 1_000)
        let members = [
            ConversationMember(profileID: ProfileID("late"), role: .member, joinedAt: start.addingTimeInterval(300)),
            ConversationMember(profileID: ProfileID("viewer"), role: .admin, joinedAt: start),
            ConversationMember(profileID: ProfileID("early"), role: .admin, joinedAt: start.addingTimeInterval(100)),
            ConversationMember(profileID: ProfileID("owner"), role: .owner, joinedAt: start.addingTimeInterval(500)),
            ConversationMember(profileID: ProfileID("follower"), role: .subscriber, joinedAt: start),
            ConversationMember(profileID: ProfileID("middle"), role: .member, joinedAt: start.addingTimeInterval(200)),
        ]
        let order = ConversationMember.faceOrder(members, viewer: ProfileID("viewer"))
        #expect(order.map(\.rawValue) == ["owner", "early", "middle", "late"])
        // The same members in another order: the same faces.
        #expect(ConversationMember.faceOrder(members.reversed(), viewer: ProfileID("viewer")) == order)
        // The viewer owning the group: the others by join date.
        let owned = ConversationMember.faceOrder(members, viewer: ProfileID("owner"))
        #expect(owned.first == ProfileID("viewer"))
    }

    /// At most four faces, each with its name and picture.
    @Test func atMostFourFacesWithTheirNamesAndPictures() {
        let start = Date(timeIntervalSince1970: 1_000)
        let members = (0..<7).map {
            ConversationMember(profileID: ProfileID("m\($0)"), role: .member, joinedAt: start.addingTimeInterval(Double($0)))
        }
        let faces = ConversationMember.groupFaces(members, viewer: nil) { id in
            (name: "Name \(id.rawValue)", avatarURL: id.rawValue == "m1" ? nil : URL(string: "https://example.com/\(id.rawValue)"))
        }
        #expect(faces.count == ConversationIdentity.stackedFaces)
        #expect(ConversationIdentity.stackedFaces == 4)
        #expect(faces.map(\.name) == ["Name m0", "Name m1", "Name m2", "Name m3"])
        #expect(faces[1].avatarURL == nil, "a member with no picture shows their initials")
    }

    // MARK: - The inbox row

    /// The owner's screenshot: Sofía (the owner), Tom and the viewer — two
    /// faces, Sofía's first, never "SR".
    @Test func theGroupOfThreeShowsItsTwoOtherMembers() async throws {
        let model = try await row("grp-studio", in: make())
        let picture = try #require(model.groupAvatar)
        #expect(picture.faces.map(\.name) == ["Sofía Reyes", "Tom Okafor"])
        #expect(picture.drawing == .stack(picture.faces, more: 0))
        let view = ConversationRowView()
        view.configure(with: model)
        #expect(view.debugStackedFaceCount == 2)
    }

    /// Four members: three faces; five: four; forty: three and "+37".
    @Test(arguments: [("grp-tram", 3, nil), ("grp-zine", 4, nil), ("grp-festival", 3, 37)] as [(String, Int, Int?)])
    func eachGroupsFacesAndPlus(_ id: String, _ faces: Int, _ more: Int?) async throws {
        let model = try await row(id, in: make())
        let picture = try #require(model.groupAvatar)
        guard case .stack(let drawn, let plus) = picture.drawing else {
            Issue.record("\(id) draws \(picture.drawing)")
            return
        }
        #expect(drawn.count == faces)
        #expect((plus > 0 ? plus : nil) == more)
        let view = ConversationRowView()
        view.configure(with: model)
        #expect(view.debugStackedFaceCount == faces)
        #expect(view.debugGroupAvatar?.drawnMore == more)
    }

    /// The viewer is never one of the faces, owner or not.
    @Test func theViewerIsNeverAFace() async throws {
        let repository = make()
        let viewer = try await repository.viewerProfileID()
        let zine = try await row("grp-zine", in: repository)
        let members = try await repository.members(of: ConversationID("grp-zine"))
        let others = members.map(\.profileID).filter { $0 != viewer }
        let names = await repository.profiles(others).values.map(\.name)
        #expect(members.contains { $0.profileID == viewer && $0.role == .owner }, "the viewer owns the zine")
        #expect(Set(zine.groupAvatar?.faces.map(\.name) ?? []) == Set(names))
    }

    /// A group with a photo draws it, on the row as one disc.
    @Test func aGroupWithAPhotoDrawsItsPhoto() async throws {
        let model = try await row("grp-hike", in: make())
        let photo = try #require(model.groupPhotoURL)
        #expect(model.groupAvatar?.drawing == .photo(photo))
        let view = ConversationRowView()
        view.configure(with: model)
        #expect(view.debugGroupAvatar?.drawsSingleDisc == true)
        #expect(view.debugStackedFaceCount == 0)
    }

    /// An invitation row wears the group's picture too.
    @Test func anInvitationWearsTheGroupsPicture() async throws {
        let model = try await row("grp-nightwalk", in: make())
        #expect(model.invitation != nil)
        let cell = MessageRequestCell(style: .default, reuseIdentifier: nil)
        cell.configure(with: model)
        #expect(cell.debugGroupAvatar?.content == model.groupAvatar)
    }

    /// A DM and a channel have no group picture: a DM is its peer, a
    /// channel keeps its photo or initials.
    @Test func aDirectConversationHasNoGroupPicture() async throws {
        let rows = try await make().loadInbox(.inbox, after: nil).conversations
        let direct = try #require(rows.first { $0.kind == .direct })
        #expect(ConversationDisplayModel(conversation: direct).groupAvatar == nil)
        let channel = Conversation(
            id: ConversationID("ch"), title: "Daily light", lastMessage: "", lastActivityAt: nil, kind: .channel,
            identity: ConversationIdentity(kind: .channel, name: "Daily light")
        )
        #expect(ConversationDisplayModel(conversation: channel).groupAvatar == nil)
    }

    /// The flag off: DMs only, as before — no row draws a group.
    @Test func theFlagOffChangesNothing() async throws {
        let rows = try await make(groups: false).loadInbox(.inbox, after: nil).conversations
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.memberFaces.isEmpty })
        #expect(rows.allSatisfy { ConversationDisplayModel(conversation: $0).groupAvatar == nil })
    }

    // MARK: - The thread

    /// The thread's group carries the same faces as the row, in the same
    /// order, and the group's size for the "+N".
    @Test func theThreadsGroupCarriesTheRowsFaces() async throws {
        let repository = make()
        let id = ConversationID("grp-festival")
        let identity = try await repository.details(of: id)
        let members = try await repository.members(of: id)
        let profiles = await repository.profiles(members.map(\.profileID))
        let viewer = try await repository.viewerProfileID()
        let group = ConversationThreadDriver.group(identity: identity, members: members, profiles: profiles, viewer: viewer)
        let model = try await row("grp-festival", in: repository)
        #expect(group.faces == model.groupAvatar?.faces)
        #expect(group.memberCount == 40)
        #expect(group.avatar?.drawing == model.groupAvatar?.drawing)
    }

    /// Before the details answer, the row's title and faces: the pill is the
    /// group's from the first frame.
    @Test func theRowsFacesStandInUntilTheDetailsAnswer() {
        let identity = ConversationIdentity(kind: .group, memberCount: 3)
        let faces = [GroupAvatarFace(name: "Sofía Reyes", avatarURL: nil), GroupAvatarFace(name: "Tom Okafor", avatarURL: nil)]
        let group = ConversationThreadDriver.group(identity: identity, rowTitle: "Sofía Reyes and Tom Okafor", faces: faces)
        #expect(group.name == "Sofía Reyes and Tom Okafor")
        #expect(group.avatar?.drawing == .stack(faces, more: 0))
        #expect(group.canPost)
    }

    // MARK: - The info screen and the name step

    /// The info screen's header draws the group's picture.
    @Test func theInfoHeaderDrawsTheGroupsPicture() throws {
        var state = GroupInfoViewModel.State()
        state.name = "Sofía Reyes and Tom Okafor"
        state.groupAvatar = GroupAvatarContent(
            name: state.name,
            faces: [GroupAvatarFace(name: "Sofía Reyes", avatarURL: nil), GroupAvatarFace(name: "Tom Okafor", avatarURL: nil)],
            memberCount: 3
        )
        // The header's content carries the picture (#2259's profile-style
        // header), and the page draws it in the disc.
        let header = GroupInfoViewModel.header(for: state, id: ConversationID("g-1"))
        #expect(header.groupAvatar == state.groupAvatar)
        let page = ConversationInfoPageViewController(channel: false, postsPage: ConversationStatusPage(), imagePipeline: nil)
        page.loadViewIfNeeded()
        page.apply(header)
        let disc = try #require(page.groupAvatarView)
        #expect(disc.drawnFaceCount == 2)
        #expect(disc.isAccessibilityElement == false, "the header is the element")
    }

    /// The name step shows the picked members' faces, skeletons while their
    /// pictures are looked up.
    @Test func theNameStepShowsThePickedMembersFaces() {
        let people = ["Sofía Reyes", "Tom Okafor", "Ana Lima", "Lee Park", "Mia Chen"].enumerated().map { index, name in
            PersonDisplayModel(id: ProfileID("p\(index)"), displayName: name, handle: "h\(index)", monogram: "")
        }
        let awaiting = GroupNameViewController.groupAvatar(
            members: Array(people.prefix(2)), name: "Sofía and Tom", pictures: nil, awaitsPictures: true
        )
        #expect(awaiting.faces.count == 2 && awaiting.faces.allSatisfy(\.awaitsPicture))
        let found = GroupNameViewController.groupAvatar(
            members: people, name: "Group", pictures: [ProfileID("p0"): URL(string: "https://example.com/p0")!],
            awaitsPictures: true
        )
        #expect(found.faces.allSatisfy { !$0.awaitsPicture })
        #expect(found.faces.first?.avatarURL != nil)
        // Five picked and the viewer: three faces and "+3".
        #expect(found.drawing == .stack(Array(found.faces.prefix(3)), more: 3))
    }
}
