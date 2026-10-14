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
/// **THE POST WATCHED IS NOWHERE** (asked for, 2026-10-14, #1147, reversing
/// #326): the sheet opens over it, so it is in no section and in no pushed
/// ranking — the original included, when the sheet opens from it.
///
/// **A SECTION WITH NOTHING TO SHOW IS NOT THERE** (#1147): "Recent" goes
/// when every other post fits the Popular row, or when there is no other
/// post; with neither section the sheet is the sound alone. The collapsed
/// detent knows those shapes (`SoundSheetViewController.foldBottom`).
///
/// **"POPULAR" LEADS WITH THE ORIGINAL** (`gridPostIDs`): the post the sound
/// was first published with — marked "Original" once it is known to be a
/// media post — then the most engaged. Without a Popular section it stands
/// in "Recent" at its date, still marked.
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
        let hidden = excluded.union([current])
        func kept(_ ids: [PostID]) -> [PostID] {
            var seen = Set<PostID>()
            return ids.filter { !hidden.contains($0) && seen.insert($0).inserted }
        }
        let head = SoundSheetViewController.gridPostIDs(
            original: original == current ? nil : original, using: kept(rankings.popular), isMedia: isMedia
        )
        // Every other post, by date; what the date order misses — the
        // original among them — at the end.
        let everyPost = kept(rankings.recent + head.ids)
        func recentAlone() -> [SoundSheetSection] {
            everyPost.isEmpty ? [] : [SoundSheetSection(kind: .recent, ids: everyPost, all: everyPost)]
        }
        let popularAll = kept(head.ids)
        guard rankings.hasPopular, !popularAll.isEmpty else { return (recentAlone(), head.original) }

        let popularRow = Array(popularAll.prefix(rowLimit))
        let shown = Set(popularRow)
        let recent = everyPost.filter { !shown.contains($0) }
        let popular = SoundSheetSection(kind: .popular, ids: popularRow, all: popularAll)
        // Every other post fits the row: "Recent" would be empty.
        guard !recent.isEmpty else { return ([popular], head.original) }
        return ([popular, SoundSheetSection(kind: .recent, ids: recent, all: recent)], head.original)
    }
}
