import CoreModels
import FeedInterface

/// One section of the sound sheet: a title, what the sheet shows of it, and
/// the whole ranking its chevron opens.
struct SoundSheetSection: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, CaseIterable {
        /// A horizontal row — the one the collapsed detent shows whole — whose
        /// title and chevron push its whole ranking.
        case popular
        /// The vertical grid under the row: EVERY post that used the sound,
        /// most recent first — the popular ones too. It shows everything it
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

/// The sound sheet's sections, built from the provider's two rankings.
///
/// **TWO VIEWS OF THE SAME POSTS, NOT A PARTITION.** The "Popular" row shows
/// the first posts of its ranking; the "Recent" grid is EVERY post that used
/// the sound, most recent first — a popular post is in both (asked for,
/// 2026-09-30: "Recent" says who used the sound lately, whoever they are).
/// So a post can show twice on the sheet, once per section — the sheet's
/// items are a post IN a section (`SoundSheetViewController.Item`).
///
/// **NEITHER IS EVER EMPTY.** The sheet opens from a post set to the sound,
/// and that post is in both: "Popular" leads with it (after the original),
/// and "Recent" holds every post — one the date order leaves out (the post
/// the sheet was opened from, a ranking that lags) joins its end.
///
/// **"POPULAR" LEADS WITH THE ORIGINAL, THEN THE POST WATCHED.** The row the
/// collapsed detent shows keeps the rule the grid had (`gridPostIDs`): the
/// post the sound was first published with — marked "Original" once it is
/// known to be a media post — then the post the sheet was opened from, then
/// the most engaged.
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
        let popularAll = kept(head.ids)
        let popularRow = Array(popularAll.prefix(rowLimit))
        // Every post, by date; what the date order misses at the end.
        let recent = kept(rankings.recent + popularAll)

        let sections = [
            SoundSheetSection(kind: .popular, ids: popularRow, all: popularAll),
            SoundSheetSection(kind: .recent, ids: recent, all: recent),
        ].filter { !$0.ids.isEmpty }
        return (sections, head.original)
    }
}
