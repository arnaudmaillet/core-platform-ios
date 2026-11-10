import CoreContracts
import CoreModels
import CoreNetworking
import Foundation

// MARK: - Groups and channels (#2213)

extension ChatRepository {
    /// The entries a folder shows (#2213): groups only with `-group-chats`;
    /// channels only with `-channels`, and only in the INBOX folder — with
    /// the DMs and the groups since #2230, where they had a folder of their
    /// own for the Channels tab (#2215). Without the flags the inbox is DMs
    /// only, as it was.
    func shownEntries(_ entries: [Chat_V1_InboxEntryView], in folder: InboxFolder) -> [Chat_V1_InboxEntryView] {
        entries.filter { entry in
            switch (folder, Self.kind(of: entry.kind)) {
            case (.inbox, .channel): showsChannels
            case (_, .channel): false
            case (_, .group): showsGroups
            case (_, .direct): true
            }
        }
    }

    /// The identities of a page's groups and channels, in one call.
    func identities(of entries: [Chat_V1_InboxEntryView], viewer: ProfileID) async -> [String: ConversationIdentity] {
        let ids = entries.filter { Self.kind(of: $0.kind) != .direct }.map(\.conversationID)
        guard !ids.isEmpty, let proposals,
              let reply = try? await proposals.call(.details(viewer: viewer.rawValue, conversationIDs: ids)) else { return [:] }
        return Dictionary(reply.details.map { ($0.conversationID, ConversationIdentity($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// One proposed call as the acting viewer; a refusal as `ChatError`.
    private func propose(
        _ write: String, _ make: (String) -> ProposedChat.Call
    ) async throws -> ProposedChat.Reply {
        let viewer = try await resolveViewerProfileID(forWrite: write)
        guard let proposals else { throw ChatError.transport(message: "groups and channels aren't available") }
        do {
            return try await proposals.call(make(viewer.rawValue))
        } catch ProposedChatClient.Failure.refused(let message) {
            throw ChatError.refused(message: message)
        } catch ProposedChatClient.Failure.transport(let message) {
            throw ChatError.transport(message: message)
        }
    }
}

extension ChatRepository: ConversationManaging {
    public func details(of conversationID: ConversationID) async throws -> ConversationIdentity {
        let reply = try await propose("details") { .details(viewer: $0, conversationIDs: [conversationID.rawValue]) }
        guard let details = reply.details.first else { throw ChatError.refused(message: "CHT-1004: conversation not found") }
        return ConversationIdentity(details)
    }

    public func members(of conversationID: ConversationID) async throws -> [ConversationMember] {
        let reply = try await propose("members") { .members(viewer: $0, conversationID: conversationID.rawValue) }
        return reply.members.map {
            ConversationMember(
                profileID: ProfileID($0.profileID), role: ConversationRole($0.role),
                joinedAt: Date(timeIntervalSince1970: TimeInterval($0.joinedAtMs) / 1000)
            )
        }
    }

    public func create(_ draft: ConversationDraft) async throws -> ConversationID {
        guard draft.kind != .direct else { throw ChatError.refused(message: "a DM opens with OpenDirectConversation") }
        if draft.kind == .group, draft.memberIDs.count + 1 > ConversationDraft.groupCap {
            throw ChatError.refused(message: "CHT-1020: a group holds at most \(ConversationDraft.groupCap) members")
        }
        let reply = try await propose("createConversation") {
            .create(
                viewer: $0, kind: draft.kind == .channel ? .channel : .group, name: draft.name,
                photoURL: draft.photoURL?.absoluteString ?? "", description: draft.description,
                visibility: draft.visibility.wire, memberIDs: draft.memberIDs.map(\.rawValue)
            )
        }
        return ConversationID(reply.conversationID)
    }

    public func editIdentity(of conversationID: ConversationID, name: String, photoURL: URL?, description: String) async throws {
        _ = try await propose("editIdentity") {
            .editIdentity(viewer: $0, conversationID: conversationID.rawValue, name: name,
                          photoURL: photoURL?.absoluteString ?? "", description: description)
        }
    }

    public func invite(_ profileIDs: [ProfileID], to conversationID: ConversationID) async throws {
        _ = try await propose("invite") {
            .invite(viewer: $0, conversationID: conversationID.rawValue, profileIDs: profileIDs.map(\.rawValue))
        }
    }

    public func answerInvitation(to conversationID: ConversationID, accept: Bool) async throws {
        _ = try await propose("answerInvitation") {
            .answerInvitation(viewer: $0, conversationID: conversationID.rawValue, accept: accept)
        }
    }

    public func requestToJoin(_ conversationID: ConversationID) async throws -> ConversationViewerState {
        let reply = try await propose("requestToJoin") { .requestToJoin(viewer: $0, conversationID: conversationID.rawValue) }
        return reply.details.first.map { ConversationViewerState($0.viewerState) } ?? .requested
    }

    public func cancelJoinRequest(_ conversationID: ConversationID) async throws {
        _ = try await propose("cancelJoinRequest") { .cancelJoinRequest(viewer: $0, conversationID: conversationID.rawValue) }
    }

    public func joinRequests(to conversationID: ConversationID) async throws -> [ConversationJoinRequest] {
        let reply = try await propose("joinRequests") { .joinRequests(viewer: $0, conversationID: conversationID.rawValue) }
        return reply.joinRequests.map {
            ConversationJoinRequest(
                profileID: ProfileID($0.profileID),
                requestedAt: Date(timeIntervalSince1970: TimeInterval($0.requestedAtMs) / 1000)
            )
        }
    }

    public func answerJoinRequest(from profileID: ProfileID, to conversationID: ConversationID, approve: Bool) async throws {
        _ = try await propose("answerJoinRequest") {
            .answerJoinRequest(viewer: $0, conversationID: conversationID.rawValue, requester: profileID.rawValue, approve: approve)
        }
    }

    public func setRole(_ role: ConversationRole, of profileID: ProfileID, in conversationID: ConversationID) async throws {
        _ = try await propose("setRole") {
            .setRole(viewer: $0, conversationID: conversationID.rawValue, member: profileID.rawValue, role: role.wire)
        }
    }

    public func remove(_ profileID: ProfileID, from conversationID: ConversationID, ban: Bool) async throws {
        _ = try await propose("removeMember") {
            .remove(viewer: $0, conversationID: conversationID.rawValue, member: profileID.rawValue, ban: ban)
        }
    }

    public func transferOwnership(of conversationID: ConversationID, to profileID: ProfileID) async throws {
        _ = try await propose("transferOwnership") {
            .transferOwnership(viewer: $0, conversationID: conversationID.rawValue, to: profileID.rawValue)
        }
    }

    public func leave(_ conversationID: ConversationID) async throws {
        _ = try await propose("leaveConversation") { .leave(viewer: $0, conversationID: conversationID.rawValue) }
    }

    public func setVisibility(_ visibility: ConversationVisibility, of conversationID: ConversationID) async throws {
        _ = try await propose("setVisibility") {
            .setVisibility(viewer: $0, conversationID: conversationID.rawValue, visibility: visibility.wire)
        }
    }

    public func subscribe(to conversationID: ConversationID) async throws {
        _ = try await propose("subscribe") { .subscribe(viewer: $0, conversationID: conversationID.rawValue) }
    }

    public func unsubscribe(from conversationID: ConversationID) async throws {
        _ = try await propose("unsubscribe") { .unsubscribe(viewer: $0, conversationID: conversationID.rawValue) }
    }
}

// MARK: - A profile's channels (#2232)

extension ChatRepository: ProfileChannelsReading {
    /// The channels `owner` owns that the viewer may see, in the server's
    /// order: nothing with the channels off, so a profile has no tab.
    public func ownedChannels(of owner: ProfileID) async throws -> [OwnedChannel] {
        guard showsChannels else { return [] }
        let reply = try await propose("ownedChannels") { .ownedChannels(viewer: $0, owner: owner.rawValue) }
        return reply.details.filter { $0.kind == .channel }.map {
            OwnedChannel(id: ConversationID($0.conversationID), identity: ConversationIdentity($0))
        }
    }
}
