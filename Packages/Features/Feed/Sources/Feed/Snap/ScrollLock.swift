import UIKit

/// A temporary scroll freeze that remembers what it interrupted.
///
/// Exists because "unfreeze" and "enable" are not the same thing, and treating
/// them as one broke the comments screen in a way that survived the gesture
/// that caused it.
///
/// A dismissal swipe freezes the surfaces under it and thaws them on release.
/// Thawing by assignment — `isScrollEnabled = true` — is right only if the
/// surface was scrollable to begin with, and on this screen one of them is
/// not: an engaged comments panel disables the PAGER for the engagement's
/// whole lifetime, deliberately, as the structural answer to UIKit's
/// nested-scroll chaining (see the note at the engage site). Nested scroll
/// pans recognise simultaneously and boundary excess hands off to the outer
/// one; a disabled pan cannot receive that handoff, which is the only
/// reliable way to stop it.
///
/// So a cancelled swipe used to hand the pager back scrollable, the chaining
/// returned, and the comments dragged the feed with them — for the rest of
/// that engagement, because nothing else re-applies the lock. Closing and
/// reopening the post appeared to "fix" it, which is the tell: it rebuilt the
/// engagement, and the engagement is what owns the freeze.
///
/// This restores the value it found. A lock taken inside someone else's lock
/// is a no-op at both ends.
struct ScrollLock {
    /// Non-nil exactly while this lock is held; the value is what to put back.
    private var previous: Bool?

    /// Freezes `scrollView`, remembering whether it was scrollable. Re-entrant:
    /// a second freeze while one is held changes nothing, so a gesture that
    /// reports its start twice cannot record `false` as the value to restore
    /// and leave the surface dead for good.
    mutating func freeze(_ scrollView: UIScrollView?) {
        guard let scrollView, previous == nil else { return }
        previous = scrollView.isScrollEnabled
        scrollView.isScrollEnabled = false
    }

    /// Puts back what was there. A thaw with no freeze outstanding does
    /// nothing — it must never be a way to enable scrolling.
    mutating func thaw(_ scrollView: UIScrollView?) {
        guard let scrollView, let previous else { return }
        scrollView.isScrollEnabled = previous
        self.previous = nil
    }

    /// Whether a freeze is currently held.
    var isHeld: Bool { previous != nil }
}
