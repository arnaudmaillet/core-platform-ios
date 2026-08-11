import CoreModels

/// WHICH PAGES A DIFFABLE SNAPSHOT WOULD SILENTLY LEAVE ALONE.
///
/// The snap feed's data source is keyed by `PostID`, so a snapshot describes
/// which posts are on screen and in what order — and nothing whatsoever about
/// what they contain. Apply a snapshot whose identifiers are unchanged and
/// UIKit correctly concludes there is no work to do: no move, no insert, no
/// reconfigure. Realized cells keep whatever they were last configured with.
///
/// That is the right default everywhere except one place, and this is that
/// place. A page opened from a grid is rendered TWICE from the same id: first
/// from the projection the grid handed over (`GalleryPostProjection`), then
/// from the entry the network returns. Identical id, different content, and
/// without this the second render changes a dictionary and not a pixel.
///
/// What it looked like: a post opened from a profile kept an unnamed author
/// capsule and a bare timestamp for the life of the screen, long after
/// `profile.v1` had answered. It reads as a data problem, and the data was
/// there — sitting in `modelsByID`, one lookup away from the cell that needed
/// it. Stated as a value because the failure is the ABSENCE of a call, which no
/// amount of reading `render` makes visible.
enum SeededPageReconciliation {
    /// The ids whose content changed under a stable identity.
    ///
    /// - `previous`/`current` are the models before and after this render.
    /// - An id absent from `previous` is NEW, and diffable inserts it already.
    /// - An id absent from `current` is GONE, and diffable removes it already.
    /// - `engaged` is the page whose comments the VIEWER opened, and it alone
    ///   is excluded — re-running its configuration underneath an open panel is
    ///   a rebuild nobody asked for, mid-interaction.
    ///
    /// ⚠️ **`engaged` must be nil for a text page**, and the distinction is the
    /// whole reason this takes an id rather than a flag. A text-only post has no
    /// media to dock, so its comments ARE its layout: it is engaged from the
    /// first frame and never disengages (`commentsEngagementIsResting`).
    /// Excluding "the engaged page" therefore excluded every text page
    /// permanently — which is to say, precisely the pages a seeded projection is
    /// most visible on, and the ones this was written for. It measured as
    /// `reconfigured=2` out of three items, with the third being the one on
    /// screen.
    static func idsNeedingReconfigure(
        ordered: [PostID],
        previous: [PostID: FeedItemDisplayModel],
        current: [PostID: FeedItemDisplayModel],
        engaged: PostID?
    ) -> [PostID] {
        ordered.filter { id in
            guard id != engaged,
                  let before = previous[id],
                  let after = current[id]
            else { return false }
            return before != after
        }
    }
}
