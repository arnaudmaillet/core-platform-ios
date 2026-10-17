import CoreModels
import CoreStorage
import Foundation

/// When a post in the vertical feed counts as viewed (#1344): it has stayed
/// the settled, visible page for `delay` (`PostViewHistoryStore.dwell`, 2 s —
/// the owner, 2026-10-17). A page that resigns first — swiped past, covered,
/// the app left, the feed closed — is never recorded.
@MainActor
final class PostViewDwell {
    private let delay: TimeInterval
    private let record: (PostID) -> Void
    private var pending: DispatchWorkItem?
    private var current: PostID?

    init(delay: TimeInterval = PostViewHistoryStore.dwell, record: @escaping (PostID) -> Void) {
        self.delay = delay
        self.record = record
    }

    /// `id` became the active page.
    func begin(_ id: PostID) {
        pending?.cancel()
        current = id
        let item = DispatchWorkItem { [weak self] in
            guard let self, current == id else { return }
            pending = nil
            record(id)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// The active page resigned.
    func end() {
        pending?.cancel()
        pending = nil
        current = nil
    }
}
