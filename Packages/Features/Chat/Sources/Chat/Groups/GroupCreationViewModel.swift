import CoreModels
import CoreNetworking
import Foundation

/// The new group's last step (#2214): its name — optional, the members'
/// names standing in — then "Create".
///
/// ⚠️ NO PHOTO PICKED YET. A group's photo is a URL (`ConversationDraft
/// .photoURL`), and nothing in the app uploads a picture for a conversation
/// to point at: the step shows the group's initials, or its members' faces,
/// where the photo will go. The info screen keeps the same placeholder.
@MainActor
final class GroupCreationViewModel {
    nonisolated enum Phase: Equatable, Sendable {
        case editing
        case creating
        case failed(String)
    }

    var onPhaseChange: ((Phase) -> Void)?
    /// The group exists: its id. The screen lands in its thread.
    var onCreated: ((ConversationID) -> Void)?

    private(set) var phase: Phase = .editing { didSet { onPhaseChange?(phase) } }
    let members: [PersonDisplayModel]
    private(set) var name = ""

    private let service: any ConversationManaging

    init(members: [PersonDisplayModel], service: any ConversationManaging) {
        self.members = members
        self.service = service
    }

    /// What the group is called while the field is empty: its members'
    /// names, as a nameless group is named everywhere (`memberName`).
    var placeholderName: String {
        ConversationIdentity.memberName(members.map { ChatProfile.firstName(of: $0.displayName, handle: $0.handle) })
    }

    /// The draft "Create" sends.
    var draft: ConversationDraft {
        ConversationDraft(
            kind: .group, name: name.trimmingCharacters(in: .whitespacesAndNewlines), memberIDs: members.map(\.id)
        )
    }

    func nameChanged(_ text: String) {
        name = text
        if case .failed = phase { phase = .editing }
    }

    /// Creates the group. One at a time: a second tap while the first is on
    /// its way does nothing.
    func create() {
        guard phase != .creating else { return }
        phase = .creating
        let request = draft
        let groupService = service
        Task { [weak self] in
            do {
                let id = try await groupService.create(request)
                guard let self else { return }
                self.phase = .editing
                self.onCreated?(id)
            } catch {
                self?.phase = .failed(FailureCopy.message(for: error, fallback: "Couldn't create the group. Try again."))
            }
        }
    }
}
