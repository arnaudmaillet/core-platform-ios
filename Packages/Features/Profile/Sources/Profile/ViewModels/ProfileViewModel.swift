import Foundation

@MainActor
public final class ProfileViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content(ProfileDisplayModel)
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?

    private let repository: any ProfileProviding
    private var phase: Phase = .loading {
        didSet { onPhaseChange?(phase) }
    }
    private var load: Task<Void, Never>?

    public init(repository: any ProfileProviding) {
        self.repository = repository
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
                let profile = try await repository.currentUserProfile()
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
}
