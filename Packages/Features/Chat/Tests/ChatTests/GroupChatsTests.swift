import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import FeedInterface
import Foundation
import MediaCore
import TestSupport
import Testing
import UIKit
@testable import Chat

/// Groups in Messages (#2214), on the mock's groups (`-group-chats`): the
/// inbox row, the invitation, creating one and its cap, the thread's
/// senders, the info screen's roles — and the flag off, DMs only as before.
@MainActor
struct GroupChatsTests {
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

    private func inbox(_ repository: ChatRepository) async throws -> [Conversation] {
        try await repository.loadInbox(.inbox, after: nil).conversations
    }

    // MARK: - The inbox row

    @Test func aGroupRowShowsItsPhotoNameAndSender() async throws {
        let rows = try await inbox(make())
        let hike = try #require(rows.first { $0.id == ConversationID("grp-hike") })
        let model = ConversationDisplayModel(conversation: hike)
        #expect(model.title == "Weekend hike")
        #expect(model.groupPhotoURL != nil)
        // A group with a photo draws it, its faces kept for when it has none (#2233).
        #expect(model.groupAvatar?.drawing == model.groupPhotoURL.map { GroupAvatarContent.Drawing.photo($0) }, "a group with a photo stacks faces")
        #expect(model.peerID == nil, "a group passed for a DM")
        #expect(model.invitation == nil)
        // "See you there 🥾", by a member: their first name before it.
        let sender = try #require(model.previewSender)
        #expect(!sender.contains(" "), "a first name, not \(sender)")
        #expect(model.previewLine == "\(sender): \(hike.lastMessage)")
    }

    @Test func aNamelessPhotolessGroupStacksItsMembersFaces() async throws {
        let rows = try await inbox(make())
        let studio = try #require(rows.first { $0.id == ConversationID("grp-studio") })
        let model = ConversationDisplayModel(conversation: studio)
        #expect(model.title.contains(" and "), "named by its members: \(model.title)")
        #expect(model.groupPhotoURL == nil)
        let faces = try #require(model.groupAvatar?.faces)
        #expect((1...ConversationIdentity.stackedFaces).contains(faces.count))

        let row = ConversationRowView()
        row.configure(with: model)
        #expect(row.debugStackedFaceCount == faces.count)
        #expect(row.debugPreviewText?.hasPrefix("\(model.previewSender ?? "?"): ") == true)
    }

    @Test func thePreviewSenderIsAFirstNameOrYou() {
        #expect(ConversationDisplayModel.previewSender(isMine: true, name: "Alice Martin") == "You")
        #expect(ConversationDisplayModel.previewSender(isMine: false, name: "Alice Martin") == "Alice")
        #expect(ConversationDisplayModel.previewSender(isMine: false, name: nil) == nil)
        #expect(ConversationDisplayModel.invitationLine(inviter: "Bob Ray", group: "Night photo walk")
            == "Bob invited you to Night photo walk")
        #expect(ConversationDisplayModel.invitationLine(inviter: nil, group: "Night photo walk")
            == "You're invited to Night photo walk")
    }

    /// A group's row keeps what it is once the viewer sends from its thread.
    @Test func sendingKeepsTheGroupsRow() async throws {
        let rows = try await inbox(make())
        let hike = try #require(rows.first { $0.id == ConversationID("grp-hike") })
        let sent = hike.sending(ChatMessage(
            id: "new", senderID: ProfileID("me"), body: "On my way", createdAt: Date(), isMine: true
        ))
        #expect(sent.kind == .group)
        #expect(sent.identity == hike.identity)
        #expect(ConversationDisplayModel(conversation: sent).previewLine == "You: On my way")
    }

    // MARK: - Invitations

    @Test func anInvitationIsARowWithItsInviter() async throws {
        let rows = try await inbox(make())
        let walk = try #require(rows.first { $0.id == ConversationID("grp-nightwalk") })
        let model = ConversationDisplayModel(conversation: walk)
        let line = try #require(model.invitation)
        #expect(line.hasSuffix("invited you to Night photo walk"), "\(line)")
        #expect(!line.hasPrefix("You're"), "the inviter went unnamed")
        #expect(MessageRequestCell.previewText(for: model) == line)
        #expect(ConversationDisplayModel(conversation: walk, joinedInvitation: true).invitation == nil)
    }

    @Test func acceptingAnInvitationJoinsTheGroup() async throws {
        let repository = make()
        let catalog = InboxCatalog(repository: repository)
        catalog.reload()
        await settle { catalog.snapshot.phase == .loaded }
        let id = ConversationID("grp-nightwalk")
        #expect(catalog.snapshot.active.contains { $0.id == id })

        var written: Bool?
        catalog.answerInvitation(id, accept: true) { written = $0 }
        #expect(catalog.snapshot.joinedInvitations.contains(id), "the row waited for the server")
        await settle { written != nil }
        #expect(written == true)
        #expect(try await repository.details(of: id).viewerState == .member)
    }

    @Test func decliningAnInvitationTakesTheRowAway() async throws {
        let repository = make()
        let catalog = InboxCatalog(repository: repository)
        catalog.reload()
        await settle { catalog.snapshot.phase == .loaded }
        let id = ConversationID("grp-nightwalk")

        var written: Bool?
        catalog.answerInvitation(id, accept: false) { written = $0 }
        #expect(!catalog.snapshot.active.contains { $0.id == id })
        await settle { written != nil }
        #expect(written == true)
        catalog.reload()
        await settle { catalog.snapshot.phase == .loaded }
        #expect(!catalog.snapshot.active.contains { $0.id == id })
    }

    // MARK: - Creating

    private func person(_ index: Int) -> PersonDisplayModel {
        PersonDisplayModel(id: ProfileID("prof-\(index)"), displayName: "Person \(index)", handle: "p\(index)", monogram: "P")
    }

    @Test func creatingAGroupWithItsMembers() async throws {
        let repository = make()
        let members = [person(1), person(2)]
        let creation = GroupCreationViewModel(members: members, service: repository)
        #expect(creation.placeholderName == "Person and Person")
        creation.nameChanged("  Darkroom  ")
        #expect(creation.draft.name == "Darkroom")
        var created: ConversationID?
        creation.onCreated = { created = $0 }
        creation.create()
        await settle { created != nil }
        let id = try #require(created)
        let details = try await repository.details(of: id)
        #expect(details.name == "Darkroom")
        #expect(details.viewerState == .owner)
        #expect(details.memberCount == 3)
        let group = try await repository.members(of: id)
        #expect(Set(group.map(\.profileID)).isSuperset(of: members.map(\.id)))
    }

    @Test func thePickerNeedsTwoAndStopsAtTheCap() {
        let everyone = (0..<ConversationDraft.groupCap).map(person)
        let picker = GroupMemberPickerViewModel(purpose: .create, recents: everyone, directory: nil)
        #expect(picker.cap == ConversationDraft.groupCap - 1, "the viewer is a member too")
        picker.toggle(everyone[0].id)
        #expect(!picker.state.canContinue, "one person is a DM")
        picker.toggle(everyone[1].id)
        #expect(picker.state.canContinue)

        var said: String?
        picker.onCapReached = { said = $0 }
        for person in everyone.dropFirst(2) { picker.toggle(person.id) }
        #expect(picker.state.selected.count == ConversationDraft.groupCap - 1)
        #expect(picker.state.isAtCap)
        #expect(said?.contains("500") == true, "the cap went unsaid")
        #expect(!picker.isSelected(everyone.last!.id))

        // A chip's ✕ unpicks, and makes room again.
        picker.remove(everyone[0].id)
        #expect(!picker.state.isAtCap)
    }

    @Test func addingToAGroupCountsWhoIsIn() {
        let picker = GroupMemberPickerViewModel(
            purpose: .add(memberCount: 498), recents: [person(1), person(2), person(3)], directory: nil,
            excluded: [ProfileID("prof-3")]
        )
        #expect(picker.cap == 2)
        #expect(picker.minimum == 1)
        #expect(!picker.state.sections.flatMap(\.rows).contains(ProfileID("prof-3")), "a member offered again")
        picker.toggle(ProfileID("prof-1"))
        #expect(picker.state.canContinue)
    }

    // MARK: - The thread

    @Test func theThreadSignsEachSenderByName() async throws {
        let repository = make()
        let id = ConversationID("grp-hike")
        let viewModel = ConversationViewModel(conversationID: id, repository: repository)
        let context = GroupThreadContext(
            service: repository, makeInfo: { _, _ in UIViewController() }, openProfile: { _, _ in },
            createdAt: { _ in Date(timeIntervalSince1970: 0) }, knownKind: { _ in nil }
        )
        let driver = ConversationThreadDriver(viewModel: viewModel, viewer: repository, avatars: nil, groupContext: context)
        var group: ConversationThreadGroup?
        var messages: [ConversationThreadMessage] = []
        driver.onGroupChange = { group = $0 }
        driver.onPhaseChange = { if case .content(let shown) = $0 { messages = shown } }
        driver.viewDidLoad()
        await settle { group != nil && messages.count > 1 }

        let shown = try #require(group)
        #expect(shown.name == "Weekend hike")
        #expect(shown.subtitle == "5 members")
        let senders = Set(messages.filter { !$0.isMine && !$0.isSystem }.map(\.senderID))
        #expect(senders.count >= 3, "three senders in the mock's hike")
        for sender in senders {
            #expect(shown.members[sender]?.name.isEmpty == false, "\(sender.rawValue) has no name to sign with")
        }
        // The client-side system line, first.
        #expect(messages.first?.isSystem == true)
        #expect(messages.first?.body == "You created the group")
    }

    @Test func aNamelessGroupsThreadIsNamedByItsOthers() {
        let me = ProfileID("me")
        let members = ["me", "a", "b"].map { ConversationMember(profileID: ProfileID($0), role: .member, joinedAt: Date()) }
        let profiles = [
            ProfileID("a"): ChatProfile(id: ProfileID("a"), name: "Alice"),
            ProfileID("b"): ChatProfile(id: ProfileID("b"), name: "Bob"),
            me: ChatProfile(id: me, name: "Me"),
        ]
        let group = ConversationThreadDriver.group(
            identity: ConversationIdentity(memberCount: 3), members: members, profiles: profiles, viewer: me
        )
        #expect(group.name == "Alice and Bob")
        #expect(group.subtitle == "3 members")
        #expect(ConversationThreadDriver.memberCountText(1) == "1 member")
    }

    // MARK: - The info screen's roles

    private func member(_ id: String, _ role: ConversationRole) -> ConversationMember {
        ConversationMember(profileID: ProfileID(id), role: role, joinedAt: Date())
    }

    @Test func whatEachRoleMayDo() {
        typealias Info = GroupInfoViewModel
        let me = ProfileID("me")
        // The owner manages everyone but themselves.
        #expect(Info.actions(by: .owner, viewer: me, on: member("a", .member)) == [.makeAdmin, .transferOwnership, .remove, .ban])
        #expect(Info.actions(by: .owner, viewer: me, on: member("b", .admin)) == [.removeAdmin, .transferOwnership, .remove, .ban])
        #expect(Info.actions(by: .owner, viewer: me, on: member("me", .owner)).isEmpty)
        // An admin manages plain members only.
        #expect(Info.actions(by: .admin, viewer: me, on: member("a", .member)) == [.makeAdmin, .remove, .ban])
        #expect(Info.actions(by: .admin, viewer: me, on: member("b", .admin)).isEmpty)
        #expect(Info.actions(by: .admin, viewer: me, on: member("o", .owner)).isEmpty)
        // A member manages no one.
        #expect(Info.actions(by: .member, viewer: me, on: member("a", .member)).isEmpty)
        #expect(Info.actions(by: nil, viewer: me, on: member("a", .member)).isEmpty)
        // Only the owner is held back from leaving.
        #expect(Info.leaveBlockedReason(for: .owner) != nil)
        #expect(Info.leaveBlockedReason(for: .admin) == nil)
        #expect(Info.leaveBlockedReason(for: .member) == nil)
    }

    @Test func theOwnerSeesTheirPowersAndIsToldToTransferBeforeLeaving() async throws {
        let repository = make()
        let info = GroupInfoViewModel(conversationID: ConversationID("grp-hike"), service: repository)
        info.load()
        await settle { info.state.phase == .loaded }
        #expect(info.state.viewerRole == .owner)
        #expect(info.state.canEdit && info.state.canAddMembers)
        #expect(info.state.admins.first?.role == .owner, "the owner leads the admins")
        #expect(info.state.admins.first?.isViewer == true)
        // The members, read as their list reads them (#2237): the owner
        // first, the viewer's own row opens nothing and offers nothing.
        let rows = try await info.page(of: .members, after: nil).rows
        #expect(rows.first?.opens == false)
        #expect(rows.first?.actions.isEmpty == true)
        #expect(rows.dropFirst().allSatisfy { !$0.actions.isEmpty })

        var notice: String?
        var left = false
        info.onNotice = { title, _ in notice = title }
        info.onLeft = { left = true }
        info.leave()
        #expect(notice != nil)
        #expect(!left)
    }

    @Test func theOwnerRemovesAMemberAndHandsTheGroupOver() async throws {
        let repository = make()
        let id = ConversationID("grp-hike")
        let info = GroupInfoViewModel(conversationID: id, service: repository)
        info.load()
        await settle { info.state.phase == .loaded }
        let rows = try await info.page(of: .members, after: nil).rows
        let plain = try #require(rows.first { info.member(ProfileID($0.id))?.role == .member })
        let count = info.state.memberCount
        info.perform(.remove, on: ProfileID(plain.id))
        await settle { info.state.memberCount == count - 1 }
        #expect(!(try await info.page(of: .members, after: nil).rows).contains { $0.id == plain.id })

        let admin = try #require(info.state.admins.first { $0.role == .admin })
        info.perform(.transferOwnership, on: admin.id)
        await settle { info.state.viewerRole == .admin }
        #expect(info.state.viewerRole == .admin)
        #expect(info.state.admins.first { $0.id == admin.id }?.role == .owner)
    }

    @Test func aMemberManagesNoOneAndLeaves() async throws {
        let repository = make()
        let id = ConversationID("grp-printfair")
        let info = GroupInfoViewModel(conversationID: id, service: repository)
        info.load()
        await settle { info.state.phase == .loaded }
        #expect(info.state.viewerRole == .member)
        #expect(!info.state.canEdit && !info.state.canAddMembers)
        #expect(try await info.page(of: .members, after: nil).rows.allSatisfy { $0.actions.isEmpty })

        var left = false
        info.onLeft = { left = true }
        info.leave()
        await settle { left }
        #expect(left)
        let rows = try await inbox(repository)
        #expect(!rows.contains { $0.id == id })
    }

    // MARK: - The flag off

    @Test func withTheFlagOffMessagesIsDMsOnly() async throws {
        let rows = try await inbox(make(groups: false))
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.kind == .direct })
        for row in rows {
            let model = ConversationDisplayModel(conversation: row)
            #expect(model.previewSender == nil && model.invitation == nil && model.groupPhotoURL == nil)
            #expect(model.previewLine == model.preview)
        }
        let search = InboxSearchViewModel(catalog: InboxCatalog(repository: make(groups: false)), viewer: make(groups: false),
                                          showsNewGroup: false, showsNewChannel: false)
        var phases: [InboxSearchViewModel.Phase] = []
        search.onPhaseChange = { phases.append($0) }
        search.queryChanged("")
        #expect(!phases.contains { phase in
            if case .content(let sections) = phase { sections.contains { $0.kind == .create } } else { false }
        })
    }

    @Test func withTheFlagOnTheEmptySearchOffersANewGroup() {
        let repository = make()
        let search = InboxSearchViewModel(
            catalog: InboxCatalog(repository: repository), viewer: repository, showsNewGroup: true, showsNewChannel: false
        )
        var sections: [InboxSearchViewModel.Section] = []
        search.onPhaseChange = { if case .content(let shown) = $0 { sections = shown } }
        var opened = false
        search.onNewGroup = { opened = true }
        search.queryChanged("")
        #expect(sections.first?.rows == [.newGroup])
        search.didSelect(.newGroup)
        #expect(opened)
    }
}
