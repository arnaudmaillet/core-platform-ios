import Foundation
import PostGrid

/// The instant the Following tab counts from, frozen for the length of a
/// session.
///
/// **Why a second watermark, when `ForYouUnreadStore` already has one.** That
/// one is a PERSISTED cursor and it moves as soon as the viewer looks at the
/// tab — which is correct for "what will be new next time I open the app", and
/// useless for anything on screen right now. A badge derived from it reads zero
/// the moment you arrive, so a "New" section derived from it would be empty
/// exactly when someone is looking at it, and the section and the badge could
/// never be the same number.
///
/// So the session freezes a copy: the persisted watermark's value as it stood
/// when the corpus first landed, before the visit advanced it. That value does
/// not move again until the app is relaunched. Everything the viewer can see —
/// the tab badge, the counts in the mode menu, the split between New and Recent
/// — is derived from this one instant, so those numbers agree by construction
/// rather than by being kept in step.
///
/// The same shape, and the same reasoning, as `InboxTabWatermark` in Chat: a
/// count that is DERIVED from one stored instant cannot drift out of step with
/// the rows it counts. The persisted cursor still advances underneath, so the
/// NEXT launch starts counting from where this one finished.
struct ForYouSessionWatermark: Equatable {
    /// Publication time, in milliseconds. Anything published strictly after
    /// this is new; strictly, so a corpus that has not changed lands on zero
    /// rather than one.
    let baselineMS: Int64

    func isNew(_ post: GalleryPost) -> Bool {
        post.publishedAtMS > baselineMS
    }

    /// How many of these arrived since the session opened.
    func count(in posts: [GalleryPost]) -> Int {
        posts.count { isNew($0) }
    }

    /// The corpus split in two, preserving the order it arrives in.
    ///
    /// ⚠️ The caller's order is kept exactly: this partitions, it does not
    /// sort. The Following page is a timeline where order carries meaning, and
    /// re-sorting inside a section to "tidy" it would reorder posts behind the
    /// viewer. In practice the feed is newest-first, so `new` is its leading
    /// run — but a corpus that interleaves still splits correctly, and no
    /// caller has to promise it does not.
    func partition(_ posts: [GalleryPost]) -> (new: [GalleryPost], earlier: [GalleryPost]) {
        var new: [GalleryPost] = []
        var earlier: [GalleryPost] = []
        for post in posts {
            if isNew(post) { new.append(post) } else { earlier.append(post) }
        }
        return (new, earlier)
    }
}
