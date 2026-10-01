import QuartzCore
import UIKit

/// A destination that can say when its first frame would already be its
/// settled self — charter P12a.
///
/// The pusher asks once, through `PresentationHold`, and pushes on the answer
/// or at the hold's ceiling, whichever comes first. What "settled" means is
/// the screen's own business: for a profile it is the header's data, the
/// relationship, both pictures and the first gallery page.
@MainActor
public protocol PresentationReadying: UIViewController {
    /// Starts whatever the settled first frame needs and calls `ready` once it
    /// has it — synchronously when it already does (a warm cache).
    ///
    /// Called at most once, before the screen is pushed. Calling `ready` more
    /// than once is harmless; never calling it is allowed, and the hold's
    /// ceiling then pushes the screen as it is, which must still be a
    /// presentable screen (its skeleton): this is a wait for a better first
    /// frame, never a precondition for one.
    func prepareForPresentation(ready: @escaping @MainActor () -> Void)
}

/// Holds a push for a short, bounded time while the destination finishes the
/// data its first frame shows, so the screen slides in as itself rather than
/// as a skeleton that turns into itself mid-slide.
///
/// # Why a hold, against P12's "nothing awaits before push"
///
/// Because the screen it was written for cannot be seeded. A profile reached
/// from a chat or a feed row is known to its origin by a name and a picture;
/// its counters, bio, follow state and posts are one round trip away, and on
/// the mock that round trip is a few milliseconds that land just AFTER the
/// push has started. Filmed on device (1 October 2026): the profile slid in
/// as bones and a blue "Follow", then became the real page — "Following",
/// the face, the cards — as the slide ended. Two interfaces for one screen.
///
/// Waiting a few milliseconds before the slide removes the second one. The
/// ceiling is what keeps it a P12 citizen: past it, the push goes ahead on the
/// skeleton exactly as before, so a slow network costs at most `ceiling` of
/// latency and never a stuck tap.
@MainActor
public final class PresentationHold {
    /// Why the presentation went ahead.
    public enum Release: Equatable, Sendable {
        /// The destination said it was ready (or was never asked: not a
        /// `PresentationReadying` screen).
        case ready
        /// The ceiling passed first; the destination is pushed as it is.
        case ceiling
    }

    /// Long enough for a warm fleet's round trip and every mock answer;
    /// short enough that a tap still reads as instant when it runs out —
    /// about the length of the system's own tap-to-push feedback.
    public static let defaultCeiling: TimeInterval = 0.25

    private var present: ((Release, TimeInterval) -> Void)?
    private let startedAt = CACurrentMediaTime()

    private init(present: @escaping @MainActor (Release, TimeInterval) -> Void) {
        self.present = present
    }

    /// Whether the hold has neither presented nor been cancelled.
    public var isPending: Bool { present != nil }

    /// Starts preparing `destination` and calls `present` exactly once: when
    /// it is ready, or at `ceiling`. Synchronously, before returning, when the
    /// destination is ready at once or is not a `PresentationReadying` screen.
    ///
    /// `present` receives why it fired and how long the hold waited.
    @discardableResult
    public static func begin(
        _ destination: UIViewController,
        ceiling: TimeInterval = defaultCeiling,
        present: @escaping @MainActor (Release, _ waited: TimeInterval) -> Void
    ) -> PresentationHold {
        let hold = PresentationHold(present: present)
        guard let readying = destination as? PresentationReadying else {
            hold.release(.ready)
            return hold
        }
        readying.prepareForPresentation { [weak hold] in hold?.release(.ready) }
        if hold.isPending {
            // Strong on purpose: the ceiling must fire even if the caller
            // dropped its handle — a dropped hold is not a cancelled one.
            DispatchQueue.main.asyncAfter(deadline: .now() + ceiling) {
                hold.release(.ceiling)
            }
        }
        return hold
    }

    /// Drops the presentation: a newer route superseded it.
    public func cancel() {
        present = nil
    }

    private func release(_ reason: Release) {
        guard let present else { return }
        self.present = nil
        present(reason, CACurrentMediaTime() - startedAt)
    }
}
