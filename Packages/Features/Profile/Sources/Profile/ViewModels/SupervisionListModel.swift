import CoreNetworking
import Foundation

/// The viewer's supervisions, both roles (#417): what Family and Teens lists
/// under Parental Supervision, and what the detail screen ends.
///
/// Writes are never optimistic: the server may refuse an end (ACC-3005, the
/// link already gone), and the list shown is always one the server returned.
@MainActor
final class SupervisionListModel {
    enum Phase: Equatable {
        case loading
        case loaded([Supervision])
        case failed
    }

    /// A teen has at most two supervisors (ACC-3003 past that).
    static let maxSupervisors = 2

    private(set) var phase: Phase = .loading {
        didSet { if phase != oldValue { onChange?() } }
    }
    /// Why the last load failed (#794), set before `.failed`.
    private(set) var failure: NetworkFailure?
    var onChange: (() -> Void)?

    let manager: any SupervisionManaging
    /// Bumped by every change of list, so a read that started before an end
    /// or an accept can't put back what the write replaced.
    private var generation = 0

    init(manager: any SupervisionManaging) {
        self.manager = manager
    }

    var supervisions: [Supervision] {
        if case .loaded(let list) = phase { list } else { [] }
    }

    /// The people supervising the viewer (the viewer is the teen).
    var supervisors: [Supervision] { supervisions.filter { $0.otherRole == .supervisor } }
    /// The teens the viewer supervises.
    var teens: [Supervision] { supervisions.filter { $0.otherRole == .teen } }

    /// A teen with two supervisors has no room for a third: the invite is not
    /// offered (the server would refuse its acceptance).
    var canInviteSupervisor: Bool { supervisors.count < Self.maxSupervisors }

    /// Reads the list. A reload keeps the rows on screen while it runs; only
    /// a failed list goes back to loading.
    func load() async {
        if case .failed = phase { phase = .loading }
        let started = generation
        do {
            let list = try await manager.supervisions()
            guard started == generation else { return }
            phase = .loaded(list)
        } catch {
            guard started == generation else { return }
            // A failed REload keeps the list it had: the rows are still true
            // as far as anyone knows, and the next visit reads again.
            if case .loaded = phase { return }
            failure = NetworkFailure.of(error)
            phase = .failed
        }
    }

    /// A code the viewer accepted: the new link joins the list at the top.
    func accepted(_ supervision: Supervision) {
        generation += 1
        let others = supervisions.filter { $0.otherAccountID != supervision.otherAccountID }
        phase = .loaded([supervision] + others)
    }

    /// Ends `supervision` once the server agrees, and shows what it says is
    /// left. A link that was already gone (ACC-3005) leaves the list too:
    /// the server has just said it doesn't exist.
    func end(_ supervision: Supervision) async throws {
        do {
            let left = try await manager.endSupervision(with: supervision.otherAccountID)
            generation += 1
            phase = .loaded(left)
        } catch SupervisionError.notFound {
            generation += 1
            phase = .loaded(supervisions.filter { $0.otherAccountID != supervision.otherAccountID })
            throw SupervisionError.notFound
        }
    }
}
