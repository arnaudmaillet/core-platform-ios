import MediaCore
import UIKit

/// The avatar loads of a list's rows, ONE PER CELL (#780).
///
/// ⚠️ KEYED BY CELL, NOT BY PERSON. A cell is recycled: scrolled from A to B,
/// it is configured for B while A's load is still on its way. Keyed by person,
/// A's load ran on and painted A's face on B's row — the cell was still alive
/// and the task was never cancelled, the only two things it checked. Keyed by
/// cell, configuring the cell again cancels whatever it was waiting for, so a
/// late picture only ever lands on the row that asked for it.
///
/// The same type lives in Profile, for its moderation lists.
@MainActor
final class RowAvatarLoads {
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Starts `row`'s avatar load, cancelling the one it had. A row with no
    /// URL (or no pipeline) only cancels, and keeps its initials.
    ///
    /// Cache-first and synchronous when it can be, so a warm avatar never
    /// flashes the monogram for a frame.
    ///
    /// - Parameter apply: draws the picture; capture the cell weakly.
    func load(
        _ url: URL?, using pipeline: ImagePipeline?, for row: AnyObject,
        apply: @escaping @MainActor (UIImage) -> Void
    ) {
        let key = ObjectIdentifier(row)
        tasks.removeValue(forKey: key)?.cancel()
        guard let url, let pipeline else { return }
        if let cached = pipeline.cachedImage(for: url) {
            apply(cached)
            return
        }
        tasks[key] = Task { [weak self] in
            let image = try? await pipeline.image(for: url)
            // Cancelled means the row moved on, and its slot already belongs
            // to the next load.
            guard !Task.isCancelled else { return }
            self?.tasks[key] = nil
            if let image { apply(image) }
        }
    }
}
