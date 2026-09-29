import CoreModels
import FeedInterface

/// One section of the sound sheet: a title, what the sheet shows of it, and
/// the whole ranking its "View all" opens.
struct SoundSheetSection: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, CaseIterable {
        /// A horizontal row — the one the collapsed detent shows.
        case popular
        /// A horizontal row, newest first.
        case new
        /// The vertical grid under the rows, in the recommendation's order.
        case forYou

        var title: String {
            switch self {
            case .popular: "Popular"
            case .new: "New"
            case .forYou: "For you"
            }
        }

        /// Whether the sheet lays it out as a horizontal row rather than a
        /// grid.
        var isRow: Bool { self != .forYou }
    }

    let kind: Kind
    /// On the sheet, in order: a row's first posts, or the grid.
    let ids: [PostID]
    /// The section's whole ranking — what "View all" pushes.
    let all: [PostID]

    var title: String { kind.title }

    /// "View all" is offered when the ranking holds more than the sheet
    /// shows of it; a section that shows everything has nowhere to go.
    var hasMore: Bool { all.count > ids.count }
}

/// The sound sheet's sections, built from the provider's three rankings.
///
/// **EACH POST ONCE ON THE SHEET.** The two rows and the grid share no post:
/// "New" skips what "Popular" shows, and "For you" whatever either row shows
/// — so at large, scrolling the sheet never meets a tile twice. A section's
/// "View all" is its WHOLE ranking, though, the posts shown elsewhere on the
/// sheet included: "all the popular posts" means all of them.
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
    /// How many posts a row shows before "View all": three and a peek on
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

        let newAll = kept(rankings.newest)
        let newRow = Array(newAll.filter { !onPopular.contains($0) }.prefix(rowLimit))
        let onRows = onPopular.union(newRow)

        // Every post somewhere: one the recommendation leaves out (the post
        // the sheet was opened from, a ranking that lags) joins its end.
        let recommendedAll = kept(rankings.recommended + popularAll + newAll)
        let grid = recommendedAll.filter { !onRows.contains($0) }

        let sections = [
            SoundSheetSection(kind: .popular, ids: popularRow, all: popularAll),
            SoundSheetSection(kind: .new, ids: newRow, all: newAll),
            SoundSheetSection(kind: .forYou, ids: grid, all: recommendedAll),
        ].filter { !$0.ids.isEmpty }
        return (sections, head.original)
    }
}
