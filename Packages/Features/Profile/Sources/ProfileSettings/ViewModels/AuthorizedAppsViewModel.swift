import CoreNetworking
import Foundation

/// Settings → Security and Login → Apps and Websites (#485): the apps the
/// holder let use their account, and Remove Access.
@MainActor
package final class AuthorizedAppsViewModel {
    package enum Phase: Equatable {
        case loading
        case loaded([AuthorizedApp])
        case failed
    }

    package private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    /// Why the last load failed (#794), set before the phase.
    package private(set) var failure: NetworkFailure?
    /// Apps whose removal is on its way — their rows wait.
    package private(set) var removing: Set<String> = [] {
        didSet { onChange?() }
    }
    package var onChange: (() -> Void)?

    private let manager: any AuthorizedAppsManaging

    package init(manager: any AuthorizedAppsManaging) {
        self.manager = manager
    }

    package func load() async {
        if case .failed = phase { phase = .loading }
        do {
            let apps = try await manager.authorizedApps()
            failure = nil
            phase = .loaded(apps)
        } catch {
            failure = NetworkFailure.of(error)
            phase = .failed
        }
    }

    /// Not optimistic: the row goes once the server has removed the access,
    /// and the list shown is the one it answers with.
    package func remove(_ app: AuthorizedApp) async throws {
        guard !removing.contains(app.id) else { return }
        removing.insert(app.id)
        defer { removing.remove(app.id) }
        let remaining = try await manager.revokeAuthorizedApp(app.id)
        phase = .loaded(remaining)
    }
}
