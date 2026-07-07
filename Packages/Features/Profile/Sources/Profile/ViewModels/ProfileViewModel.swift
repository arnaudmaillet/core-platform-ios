import CoreModels
import Foundation

@MainActor
public final class ProfileViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content(ProfileDisplayModel)
        case failed(message: String)
    }

    /// Whose profile this view model loads.
    public nonisolated enum Source: Equatable, Sendable {
        case currentUser
        case profile(ProfileID)
    }

    public var onPhaseChange: ((Phase) -> Void)?

    private let repository: any ProfileProviding
    private let source: Source
    private var phase: Phase = .loading {
        didSet { onPhaseChange?(phase) }
    }
    private var load: Task<Void, Never>?

    public init(repository: any ProfileProviding, source: Source = .currentUser) {
        self.repository = repository
        self.source = source
    }

    // MARK: - Inputs

    public func viewDidLoad() {
        reload()
    }

    /// Pull-to-refresh. Coalesced: a refresh while one is in flight is ignored.
    public func refresh() {
        guard load == nil else { return }
        reload()
    }

    // MARK: - Loading

    private func reload() {
        load?.cancel()
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let profile = try await self.fetch()
                self.phase = .content(ProfileDisplayModel(profile: profile))
            } catch is CancellationError {
                // Superseded by a newer load; leave the phase alone.
            } catch {
                // Only surface a hard failure when there is nothing on screen;
                // a failed refresh keeps the last good content.
                if case .content = self.phase {} else {
                    self.phase = .failed(message: "Couldn't load your profile. Pull to retry.")
                }
            }
            self.load = nil
        }
    }

    private func fetch() async throws -> UserProfile {
        switch source {
        case .currentUser: try await repository.currentUserProfile()
        case .profile(let id): try await repository.profile(id: id)
        }
    }
}
