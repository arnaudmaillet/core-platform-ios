import CoreModels
import CoreNavigation
import DesignSystem
import Foundation

/// The notifications list: loads, splits into "New" and "Earlier", holds the
/// "Show more" state, marks the new rows seen, and routes a tap.
///
/// ## When a notification counts as read
///
/// When the viewer has LOOKED at the list — the drawer settled open with the
/// list loaded (`didReveal`) — the server is told at once, so the bell's badge
/// clears while the drawer is still open. The rows, though, stay where they
/// were for the rest of that visit: nothing moves out of "New" under the
/// viewer's eye. They move to "Earlier" when the drawer closes
/// (`didConceal`), which is also when "Show more" folds back. A peek that
/// never settles open marks nothing.
///
/// Everything behind "Show more" is marked too — the only write the contract
/// has is "mark ALL read" — and that is the right call anyway: the section
/// header said how many there were, which is what "seen" means for a badge.
@MainActor
public final class NotificationsViewModel {
    /// The shared four states (charter P11).
    public typealias Phase = Loadable<[NotificationSection]>

    public var onPhaseChange: ((Phase) -> Void)?

    private let repository: any NotificationsProviding
    private let router: (any Router)?
    private let pageSize: Int32
    private let now: @Sendable () -> Date

    private var items: [NotificationItem] = []
    private var phase: Phase = .loading { didSet { onPhaseChange?(phase) } }
    private var load: Task<Void, Never>?
    private var hasLoaded = false
    /// "Show more" was pressed this visit.
    private var isNewExpanded = false
    /// The drawer is open and settled.
    private var isRevealed = false
    /// The server has been told this visit's rows are read.
    private var hasMarkedThisVisit = false

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

    /// The list is about to show. Every visit after the first reloads, so a
    /// drawer opened an hour later is not an hour stale; the first visit's
    /// load is already running from `viewDidLoad`.
    public func willReveal() {
        guard hasLoaded, load == nil else { return }
        reload()
    }

    /// The list has settled on screen: the viewer is looking at it.
    public func didReveal() {
        isRevealed = true
        markSeenIfLooking()
    }

    /// The list has gone. What was new this visit is old from now on.
    public func didConceal() {
        isRevealed = false
        let wasExpanded = isNewExpanded
        isNewExpanded = false
        if hasMarkedThisVisit {
            hasMarkedThisVisit = false
            items = items.map { $0.markedRead() }
            emitContent()
        } else if wasExpanded {
            emitContent()
        }
    }

    public func refresh() {
        guard load == nil else { return }
        reload()
    }

    /// "Show more": the rest of the new rows, in place.
    public func showMore() {
        guard !isNewExpanded else { return }
        isNewExpanded = true
        emitContent()
    }

    /// Tap on a row: route to its subject — a post when the notification is
    /// about one, otherwise the sender's profile. Notifications never imports
    /// Feed or Profile; it only emits routes (and the shell, receiving one,
    /// closes the drawer to show where it went).
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

    // MARK: - Loading

    private func reload() {
        load?.cancel()
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.repository.loadNotifications(limit: self.pageSize)
                self.items = loaded
                self.hasLoaded = true
                if loaded.isEmpty {
                    self.phase = .empty
                } else {
                    self.emitContent()
                }
            } catch is CancellationError {
                // Superseded; leave the phase alone.
            } catch {
                if case .content = self.phase {} else {
                    self.phase = .failed(message: "Couldn't load your notifications.")
                }
            }
            self.load = nil
            self.markSeenIfLooking()
        }
    }

    /// Tells the server the new rows were seen — once per visit, only while
    /// the viewer is looking, and only once there is something loaded to have
    /// looked AT (a reveal over a skeleton waits for the load).
    private func markSeenIfLooking() {
        guard isRevealed, load == nil, !hasMarkedThisVisit,
              items.contains(where: { !$0.isRead }) else { return }
        hasMarkedThisVisit = true
        let repository = repository
        Task { try? await repository.markAllRead() }
    }

    private func emitContent() {
        guard !items.isEmpty else { return }
        phase = .content(NotificationSectionBuilder.sections(
            from: items, newExpanded: isNewExpanded, now: now()
        ))
    }
}
