import CoreModels
import DesignSystem
import Foundation

/// One person row in the compose picker, pre-formatted so the cell does no
/// logic.
///
/// The three sources the picker draws from — existing conversations, follow
/// suggestions, and directory search — reach it by different routes, so they
/// converge here rather than at the cell. Every route now yields the same
/// shape: name, handle, monogram. That uniformity is the point — the cell can
/// then render one row, and no section looks poorer than its neighbour.
public struct PersonDisplayModel: Equatable, Sendable, Identifiable {
    public let id: ProfileID
    public let displayName: String
    /// The handle, bare. No "@": every row on this screen is a person and the
    /// second line is always their handle, so the sigil is 100% redundant
    /// decoration repeated down the whole list.
    public let handle: String
    public let monogram: String
    public let isVerified: Bool
    /// The conversation to open, when one is already known — the picker skips
    /// the find-or-create round trip for anyone the inbox has already loaded.
    public let existingConversationID: ConversationID?

    public init(
        id: ProfileID,
        displayName: String,
        handle: String,
        monogram: String,
        isVerified: Bool = false,
        existingConversationID: ConversationID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.handle = handle
        self.monogram = monogram
        self.isVerified = isVerified
        self.existingConversationID = existingConversationID
    }
}

extension PersonDisplayModel {
    /// This model as the shared row cell renders it.
    ///
    /// The projection drops the two fields that are this feature's business
    /// and not the row's — the profile id the section keys by, and the
    /// conversation id that decides whether tapping skips a round trip.
    ///
    /// The handle goes across bare, no "@": every row on this screen is a
    /// person and the second line is always their handle, so the sigil is
    /// decoration repeated down the whole list. `PersonRowContent` renders
    /// what it is given, so that stays a decision made here.
    var rowContent: PersonRowContent {
        PersonRowContent(
            displayName: displayName,
            handle: handle,
            monogram: monogram,
            isVerified: isVerified
        )
    }

    /// A directory search hit.
    public init(person: DirectoryPerson, existingConversationID: ConversationID? = nil) {
        let name = person.displayName.trimmingCharacters(in: .whitespaces).isEmpty
            ? person.handle
            : person.displayName
        self.init(
            id: person.id,
            displayName: name,
            handle: person.handle,
            monogram: ConversationDisplayModel.monogram(name),
            isVerified: person.isVerified,
            existingConversationID: existingConversationID
        )
    }

    /// A follow suggestion. The suggestion's *reason* is dropped on purpose:
    /// this list answers "who do you want to message", and "Followed by Ava + 2"
    /// is an argument for following, not for writing to someone.
    public init(account: SuggestedAccount, existingConversationID: ConversationID? = nil) {
        let name = account.displayName.trimmingCharacters(in: .whitespaces).isEmpty
            ? account.handle
            : account.displayName
        self.init(
            id: account.id,
            displayName: name,
            handle: account.handle,
            monogram: ConversationDisplayModel.monogram(name),
            existingConversationID: existingConversationID
        )
    }

    /// An existing DM correspondent. The conversation is already in hand, which
    /// is what makes tapping a recent contact open instantly; the handle rides
    /// along from the same profile lookup that resolved the title, so a recent
    /// row is the same two-line row as everything else on the screen.
    public init?(recent conversation: Conversation) {
        guard let peer = conversation.directPeerID else { return nil }
        self.init(
            id: peer,
            displayName: conversation.title,
            handle: conversation.directPeerHandle ?? "",
            monogram: ConversationDisplayModel.monogram(conversation.title),
            existingConversationID: conversation.id
        )
    }
}
