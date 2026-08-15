import UIKit

/// A pill's menu, split by WHEN each part can be known.
///
/// UIKit resolves a `UIDeferredMenuElement` after it has begun presenting the
/// menu, so anything inside one is absent from the first frame and arrives in
/// a swap. That is the right trade for state that can go stale between the
/// cell being configured and the thumb landing — and the wrong one for the
/// person's own name, which cannot.
///
/// So the header is EAGER (identity: name, handle, face — all hydrated in one
/// pass and sitting in memory) and the verbs are LIVE (the mute entry reads a
/// flag anything else in the app may have flipped).
struct MapPillMenu {
    /// The plain caption, for menus with no header — a place category. Empty
    /// when `header` carries the name.
    let title: String
    /// Drawn in the menu's first frame.
    let header: UIMenuElement?
    /// Resolved when the menu opens.
    let liveSection: () -> [UIMenuElement]
}
