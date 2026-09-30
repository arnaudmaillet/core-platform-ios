import CoreModels
import FeedInterface

/// One section of the sound sheet: a title, what the sheet shows of it, and
/// the whole ranking its chevron opens.
struct SoundSheetSection: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, CaseIterable {
        /// A horizontal row — the one the collapsed detent shows whole — whose
        /// title and chevron push its whole ranking. Only when the backend
        /// gives the sound one.
        case popular
        /// The vertical grid: every post that used the sound, most recent
        /// first, but those the Popular row shows. It shows everything it
        /// holds, so it has nothing to push.
        case recent

        var title: String {
            switch self {
            case .popular: "Popular"
            case .recent: "Recent"
            }
        }

        /// Whether the sheet lays it out as a horizontal row rather than a
        /// grid.
        var isRow: Bool { self == .popular }
    }

    let kind: Kind
    /// On the sheet, in order: the row's first posts, or the grid.
    let ids: [PostID]
    /// The section's whole ranking — what the title's chevron pushes. The
    /// grid's is what it shows.
    let all: [PostID]

    var title: String { kind.title }

    /// The chevron is offered when the ranking holds more than the sheet
    /// shows of it; a section that shows everything has nowhere to go.
    var hasMore: Bool { all.count > ids.count }
}

/// The sound sheet's sections, built from the provider's two lists.
///
/// **"POPULAR" ONLY WHEN THE BACKEND SAYS SO** (asked for, 2026-09-30): an
/// empty `rankings.popular` is a sound with too few posts for one, and the
/// sheet goes from the sound straight to "Recent". The sheet never invents
/// the section; it only decides what each one shows.
///
/// **A POST SHOWS ONCE** (asked for, 2026-09-30, reversing #322's "in both"):
/// "Recent" is every post, most recent first, LESS the posts the Popular row
/// shows. The rest of the Popular ranking — behind its chevron, not on the
/// sheet — stays in "Recent".
///
/// **"RECENT" IS NEVER EMPTY, AND ALWAYS THERE.** The sheet opens from a post
/// set to the sound, and every post is in it: one the date order leaves out
/// (the post the sheet was opened from, a ranking that lags) joins its end.
/// Should the row show every post — a backend that ranks a sound of three —
/// the row goes, not "Recent": a Popular row holding everything says nothing
/// the grid would not, and the sheet keeps one of its two shapes (which the
/// collapsed detent counts, `SoundSheetViewController.foldBottom`).
///
/// **"POPULAR" LEADS WITH THE ORIGINAL, THEN THE POST WATCHED.** The row the
/// collapsed detent shows keeps the rule the grid had (`gridPostIDs`): the
/// post the sound was first published with — marked "Original" once it is
/// known to be a media post — then the post the sheet was opened from, then
/// the most engaged. Without a Popular section they stand in "Recent" at
/// their date, the original still marked.
@MainActor
enum SoundSheetSections {
    /// How many posts the row shows before its chevron: three and a peek on
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
        // Every post, by date; what the date order misses at the end — the
        // post watched and the original among them.
        let everyPost = kept(rankings.recent + head.ids)
        let recentAlone = [SoundSheetSection(kind: .recent, ids: everyPost, all: everyPost)]
        guard rankings.hasPopular else { return (recentAlone, head.original) }

        let popularAll = kept(head.ids)
        let popularRow = Array(popularAll.prefix(rowLimit))
        let shown = Set(popularRow)
        let recent = everyPost.filter { !shown.contains($0) }
        // The row would show every post: the grid alone says as much.
        guard !recent.isEmpty else { return (recentAlone, head.original) }
        return ([
            SoundSheetSection(kind: .popular, ids: popularRow, all: popularAll),
            SoundSheetSection(kind: .recent, ids: recent, all: recent),
        ], head.original)
    }
}
