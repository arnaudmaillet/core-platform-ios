import CoreModels
import CoreNavigation
import Foundation

@MainActor
public final class NotificationsViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content([NotificationDisplayModel])
        case empty
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?
    /// Enables/disables the "Mark all read" affordance (true when any unread).
    public var onHasUnreadChange: ((Bool) -> Void)?

    private let repository: any NotificationsProviding
    private let router: (any Router)?
    private let pageSize: Int32
    private let now: @Sendable () -> Date

    private var items: [NotificationItem] = []
    private var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    private var load: Task<Void, Never>?

    public init(
        repository: any NotificationsProviding,
        router: (any Router)? = nil,
        pageSize: Int32 = 50,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.router = router
        self.pageSize = pageSize
        self.now = now
    }

    // MARK: - Inputs

    public func viewDidLoad() {
        reload()
    }

    public func refresh() {
        guard load == nil else { return }
        reload()
    }

    /// Tap on a row: route to its subject — a post when the notification is
    /// about one, otherwise the sender's profile. Notifications never imports
    /// Feed or Profile; it only emits routes.
    public func didSelect(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if let postID = item.postSubjectID {
            router?.route(to: .post(postID))
        } else {
            // Notification rows render an aggregated sentence, not the raw
            // handle, so there is no identity slice to attach.
            router?.route(to: .profile(item.senderID, stub: nil))
        }
    }

    /// Optimistically clears unread state, then tells the server. A failure
    /// simply resurfaces on the next load.
    public func markAllRead() {
        guard items.contains(where: { !$0.isRead }) else { return }
        items = items.map { $0.markedRead() }
        emitContent()
        Task { [weak self] in try? await self?.repository.markAllRead() }
    }

    // MARK: - Loading

    private func reload() {
        load?.cancel()
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.repository.loadNotifications(limit: self.pageSize)
                self.items = loaded
                if loaded.isEmpty {
                    self.phase = .empty
                    self.onHasUnreadChange?(false)
                } else {
                    self.emitContent()
                }
            } catch is CancellationError {
                // Superseded; leave the phase alone.
            } catch {
                if case .content = self.phase {} else {
                    self.phase = .failed(message: "Couldn't load your activity. Pull to retry.")
                }
            }
            self.load = nil
        }
    }

    private func emitContent() {
        let models = items.map { NotificationDisplayModel(item: $0, now: now()) }
        phase = .content(models)
        onHasUnreadChange?(items.contains { !$0.isRead })
    }
}

private extension NotificationItem {
    func markedRead() -> NotificationItem {
        NotificationItem(
            id: id,
            action: action,
            senderID: senderID,
            senderName: senderName,
            otherSenderCount: otherSenderCount,
            postSubjectID: postSubjectID,
            isRead: true,
            createdAt: createdAt
        )
    }
}
