import CoreModels
import CoreNetworking
import Foundation

/// A new channel (#2215): its name, its description, and who may join —
/// public (anyone, at once) or on request (listed, an admin approves);
/// then "Create", which lands the creator in it.
///
/// ⚠️ NO PHOTO PICKED YET, as a group's (#2214, `GroupCreationViewModel`): a
/// channel's photo is a URL, and nothing in the app uploads a picture for a
/// conversation to point at. The step shows the channel's initials where
/// the photo will go.
@MainActor
final class ChannelCreationViewModel {
    nonisolated enum Phase: Equatable, Sendable {
        case editing
        case creating
        case failed(String)
    }

    var onPhaseChange: ((Phase) -> Void)?
    /// Whether "Create" may be tapped changed: a channel needs a name.
    var onCanCreateChange: ((Bool) -> Void)?
    /// The channel exists: its id. The host lands in its thread.
    var onCreated: ((ConversationID) -> Void)?

    private(set) var phase: Phase = .editing { didSet { onPhaseChange?(phase) } }
    private(set) var name = ""
    private(set) var description = ""
    /// Public by default: a channel is for reaching people.
    private(set) var visibility: ConversationVisibility = .public

    private let service: any ConversationManaging

    init(service: any ConversationManaging) {
        self.service = service
    }

    /// The longest name a channel takes.
    static let nameLimit = 64

    /// A channel is named — unlike a group, nobody's names stand in.
    var canCreate: Bool { !trimmedName.isEmpty && phase != .creating }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The draft "Create" sends.
    var draft: ConversationDraft {
        ConversationDraft(
            kind: .channel, name: String(trimmedName.prefix(Self.nameLimit)),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines), visibility: visibility
        )
    }

    func nameChanged(_ text: String) {
        let could = canCreate
        name = text
        if case .failed = phase { phase = .editing }
        if canCreate != could { onCanCreateChange?(canCreate) }
    }

    func descriptionChanged(_ text: String) {
        description = text
    }

    func visibilityChanged(_ choice: ConversationVisibility) {
        guard ChannelCopy.choosableVisibilities.contains(choice) else { return }
        visibility = choice
    }

    /// Creates the channel. One at a time: a second tap while the first is
    /// on its way does nothing.
    func create() {
        guard canCreate else { return }
        phase = .creating
        onCanCreateChange?(false)
        let request = draft
        let channelService = service
        Task { [weak self] in
            do {
                let id = try await channelService.create(request)
                guard let self else { return }
                self.phase = .editing
                self.onCreated?(id)
            } catch {
                guard let self else { return }
                self.phase = .failed(FailureCopy.message(for: error, fallback: "Couldn't create the channel. Try again."))
                self.onCanCreateChange?(self.canCreate)
            }
        }
    }
}
