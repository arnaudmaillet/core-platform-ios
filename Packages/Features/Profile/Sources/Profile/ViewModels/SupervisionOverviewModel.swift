import CoreNetworking
import Foundation

/// A teen's overview (#417, backend #670 part 3): the limits and the last
/// days of screen time. A supervisor reads it for one of their teens; a teen
/// reads exactly the same thing about themselves (`teenAccountID` nil).
///
/// Writes are never optimistic: the limits shown are the ones the server
/// returned, so a refusal leaves them as they were.
@MainActor
final class SupervisionOverviewModel {
    enum Phase: Equatable {
        case loading
        case loaded(SupervisionOverview)
        case failed
    }

    private(set) var phase: Phase = .loading {
        didSet { if phase != oldValue { onChange?() } }
    }
    /// Why the last read failed (#794), set before `.failed`.
    private(set) var failure: NetworkFailure?
    var onChange: (() -> Void)?

    let manager: any SupervisionOverviewing
    /// The teen whose overview this is; nil: the viewer, a teen.
    let teenAccountID: String?
    /// Bumped by a write, so a read that started before it can't put back
    /// the limits it replaced.
    private var generation = 0

    init(manager: any SupervisionOverviewing, teenAccountID: String?) {
        self.manager = manager
        self.teenAccountID = teenAccountID
    }

    var overview: SupervisionOverview? {
        if case .loaded(let overview) = phase { overview } else { nil }
    }

    /// Only a supervisor sets limits; a teen reads them.
    var canEditLimits: Bool { teenAccountID != nil }

    /// Reads the overview. A failed reload keeps what is on screen.
    func load() async {
        if case .failed = phase { phase = .loading }
        let started = generation
        do {
            let overview = try await manager.supervisionOverview(teenAccountID: teenAccountID)
            guard started == generation else { return }
            phase = .loaded(overview)
        } catch {
            guard started == generation else { return }
            if case .loaded = phase { return }
            failure = NetworkFailure.of(error)
            phase = .failed
        }
    }

    /// Saves `limits` for the teen once the server agrees, and shows what it
    /// returned.
    func setLimits(_ limits: SupervisionLimits) async throws {
        guard let teenAccountID else { return }
        let saved = try await manager.setSupervisionLimits(limits, teenAccountID: teenAccountID)
        generation += 1
        let current = overview
        phase = .loaded(SupervisionOverview(
            limits: saved, screenTime: current?.screenTime ?? [], profiles: current?.profiles ?? []
        ))
    }
}
