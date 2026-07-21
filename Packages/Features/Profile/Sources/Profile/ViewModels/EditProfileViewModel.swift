import Foundation

@MainActor
public final class EditProfileViewModel {
    /// Prefill lifecycle for the form.
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case ready(Fields)
        case failed(message: String)
    }

    /// The editable fields the form exposes. `displayName`, `bio`, `website`,
    /// and `links` are persisted together via `UpdateProfile`; `username`
    /// (the @handle) travels its own `ChangeHandle` RPC.
    public nonisolated struct Fields: Equatable, Sendable {
        public var displayName: String
        public var username: String
        public var bio: String
        public var website: String
        public var links: [ProfileLink]

        public init(
            displayName: String,
            username: String,
            bio: String,
            website: String,
            links: [ProfileLink]
        ) {
            self.displayName = displayName
            self.username = username
            self.bio = bio
            self.website = website
            self.links = links
        }
    }

    public nonisolated enum SaveState: Equatable, Sendable {
        case idle
        case saving
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?
    public var onSaveStateChange: ((SaveState) -> Void)?
    /// The viewer's avatar URL for the hero. Display-only (avatar edits need an
    /// upload path the contract doesn't expose), so it rides beside `Fields`
    /// rather than inside it.
    public var onAvatarURLChange: ((URL?) -> Void)?

    private let repository: any ProfileProviding
    /// Called after each successful save so the profile underneath refreshes.
    /// It does NOT dismiss the editor — edits happen per-field and the user
    /// stays on the list until they navigate back themselves.
    private let onSaved: () -> Void

    private var phase: Phase = .loading {
        didSet { onPhaseChange?(phase) }
    }
    private var saveState: SaveState = .idle {
        didSet { onSaveStateChange?(saveState) }
    }
    /// The tail of the serialized save chain. Saves are queued behind one
    /// another (never dropped) so two quick field edits both persist, in order.
    private var saveTask: Task<Void, Never>?

    public init(repository: any ProfileProviding, onSaved: @escaping () -> Void) {
        self.repository = repository
        self.onSaved = onSaved
    }

    // MARK: - Load

    public func viewDidLoad() { load() }

    /// Re-fetches authoritative state — used to recover after a failed save.
    public func reload() { load() }

    private func load() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let profile = try await self.repository.currentUserProfile()
                self.onAvatarURLChange?(profile.avatarURL)
                self.phase = .ready(Fields(
                    displayName: profile.displayName,
                    username: profile.handle,
                    bio: profile.bio,
                    website: profile.websiteURL?.absoluteString ?? "",
                    links: profile.customLinks
                ))
            } catch {
                self.phase = .failed(message: "Couldn't load your profile.")
            }
        }
    }

    // MARK: - Save

    /// Persists display name, bio, website, and links together via `UpdateProfile`.
    public func saveMetadata(_ fields: Fields) {
        performSave { repository in
            _ = try await repository.updateCurrentUserProfile(
                displayName: Self.trimmed(fields.displayName),
                bio: Self.trimmed(fields.bio),
                website: Self.trimmed(fields.website),
                links: fields.links.map { ProfileLink(label: Self.trimmed($0.label), url: Self.trimmed($0.url)) }
            )
        }
    }

    /// Persists the @handle via the dedicated `ChangeHandle` RPC.
    public func saveUsername(_ username: String) {
        performSave { repository in
            _ = try await repository.changeHandle(Self.trimmed(username))
        }
    }

    /// Serializes a save behind any in-flight one so none are dropped. On
    /// success refreshes the profile underneath; on failure surfaces `.failed`.
    private func performSave(_ operation: @escaping (any ProfileProviding) async throws -> Void) {
        let previous = saveTask
        let repository = repository
        saveState = .saving
        saveTask = Task { [weak self] in
            await previous?.value
            do {
                try await operation(repository)
                self?.saveState = .idle
                self?.onSaved()
            } catch {
                self?.saveState = .failed(message: "Couldn't save. Please try again.")
            }
        }
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
