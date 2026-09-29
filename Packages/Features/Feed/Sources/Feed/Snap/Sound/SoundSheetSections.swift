import CoreModels
import FeedInterface

/// One section of the sound sheet: a title, what the sheet shows of it, and
/// the whole ranking its "View all" opens.
struct SoundSheetSection: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, CaseIterable {
        /// A horizontal row — the one the collapsed detent shows — whose
        /// "View all" pushes its whole ranking.
        case popular
        /// The vertical grid under the row, newest first: the rest of the
        /// posts, all of them — it has no "View all".
        case new

        var title: String {
            switch self {
            case .popular: "Popular"
            case .new: "New"
            }
        }

        /// Whether the sheet lays it out as a horizontal row rather than a
        /// grid.
        var isRow: Bool { self == .popular }
    }

    let kind: Kind
    /// On the sheet, in order: the row's first posts, or the grid.
    let ids: [PostID]
    /// The section's whole ranking — what "View all" pushes. The grid's is
    /// what it shows.
    let all: [PostID]

    var title: String { kind.title }

    /// "View all" is offered when the ranking holds more than the sheet
    /// shows of it; a section that shows everything has nowhere to go.
    var hasMore: Bool { all.count > ids.count }
}

/// The sound sheet's sections, built from the provider's two rankings.
///
/// **EACH POST ONCE ON THE SHEET, EVERY POST SOMEWHERE.** The "Popular" row
/// shows the first posts of its ranking; the "New" grid is every other post,
/// newest first — so at large, scrolling the sheet never meets a tile twice,
/// and never misses one. "Popular"'s "View all" is its WHOLE ranking, though,
/// the posts in the grid included: "all the popular posts" means all of them.
///
/// **"POPULAR" LEADS WITH THE ORIGINAL, THEN THE POST WATCHED.** The row the
/// collapsed detent shows keeps the rule the grid had (`gridPostIDs`): the
/// post the sound was first published with — marked "Original" once it is
/// known to be a media post — then the post the sheet was opened from, then
/// the most engaged.
///
/// A section with nothing left to show is dropped; "Popular" never is: it
/// holds at least the post the sheet was opened from.
@MainActor
enum SoundSheetSections {
    /// How many posts the row shows before "View all": three and a peek on
    /// screen, a few more for the swipe.
    static let rowLimit = 8

    static func make(
        rankings: PostSoundRankings,
        current: PostID,
        original: PostID?,
        isMedia: (PostID) -> Bool?,
        excluding excluded: Set<PostID> = [],
        rowLimit: Int = rowLimit
    ) -> (sections: [SoundSheetSection], original: PostID?) {
        func kept(_ ids: [PostID]) -> [PostID] {
            var seen = Set<PostID>()
            return ids.filter { !excluded.contains($0) && seen.insert($0).inserted }
        }
        let head = SoundSheetViewController.gridPostIDs(
            current: current, original: original, using: kept(rankings.popular), isMedia: isMedia
        )
        let popularAll = kept(head.ids)
        let popularRow = Array(popularAll.prefix(rowLimit))
        let onPopular = Set(popularRow)

        // Every post somewhere: one the date order leaves out (the post the
        // sheet was opened from, a ranking that lags) joins the grid's end.
        let grid = kept(rankings.newest + popularAll).filter { !onPopular.contains($0) }

        let sections = [
            SoundSheetSection(kind: .popular, ids: popularRow, all: popularAll),
            SoundSheetSection(kind: .new, ids: grid, all: grid),
        ].filter { !$0.ids.isEmpty }
        return (sections, head.original)
    }
}
