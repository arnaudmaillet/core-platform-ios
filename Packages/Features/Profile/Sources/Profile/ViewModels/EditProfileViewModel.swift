import Foundation

@MainActor
public final class EditProfileViewModel {
    /// Prefill lifecycle for the form.
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case ready(Fields)
        case failed(message: String)
    }

    /// The editable fields, mirrored from `Profile_V1_UpdateProfileRequest`
    /// (the subset the form exposes).
    public nonisolated struct Fields: Equatable, Sendable {
        public var displayName: String
        public var bio: String
        public var website: String

        public init(displayName: String, bio: String, website: String) {
            self.displayName = displayName
            self.bio = bio
            self.website = website
        }
    }

    public nonisolated enum SaveState: Equatable, Sendable {
        case idle
        case saving
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?
    public var onSaveStateChange: ((SaveState) -> Void)?

    private let repository: any ProfileProviding
    /// Called after a successful save; the presenter dismisses and refreshes.
    private let onSaved: () -> Void

    private var phase: Phase = .loading {
        didSet { onPhaseChange?(phase) }
    }
    private var saveState: SaveState = .idle {
        didSet { onSaveStateChange?(saveState) }
    }
    private var saveTask: Task<Void, Never>?

    public init(repository: any ProfileProviding, onSaved: @escaping () -> Void) {
        self.repository = repository
        self.onSaved = onSaved
    }

    // MARK: - Inputs

    public func viewDidLoad() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let profile = try await self.repository.currentUserProfile()
                self.phase = .ready(Fields(
                    displayName: profile.displayName,
                    bio: profile.bio,
                    website: profile.websiteURL?.absoluteString ?? ""
                ))
            } catch {
                self.phase = .failed(message: "Couldn't load your profile.")
            }
        }
    }

    /// Saves the edited fields. Coalesced: a save while one is in flight is
    /// ignored. On success the presenter is notified via `onSaved`.
    public func save(_ fields: Fields) {
        guard saveTask == nil else { return }
        saveState = .saving
        saveTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.repository.updateCurrentUserProfile(
                    displayName: fields.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                    bio: fields.bio.trimmingCharacters(in: .whitespacesAndNewlines),
                    website: fields.website.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                self.saveState = .idle
                self.onSaved()
            } catch {
                self.saveState = .failed(message: "Couldn't save. Please try again.")
            }
            self.saveTask = nil
        }
    }
}
