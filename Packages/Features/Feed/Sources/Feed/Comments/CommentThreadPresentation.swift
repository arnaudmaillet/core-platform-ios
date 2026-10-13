import Foundation

/// One renderable unit of the threaded comments stream.
enum CommentStreamItem: Equatable {
    case comment(CommentDisplayModel)
    /// The rest of a thread: a tappable "View N more replies…" row at reply
    /// depth. Tapping expands the thread and asks for its next page of
    /// replies (#637); `hiddenCount` counts what is neither shown nor yet
    /// loaded, from the thread's server-side reply count.
    case viewMoreReplies(parentID: String, hiddenCount: Int)
    /// The fold's inverse face, closing an EXPANDED thread once all of it is
    /// loaded: a "Hide replies" row at the bottom of the reply block.
    case collapseReplies(parentID: String)
}

/// The stream's truncation authority — pure, so the pagination seam is
/// unit-tested without views. Input is the repository's thread order
/// (each parent immediately followed by its replies, most popular first);
/// output caps each thread's visible replies at `visibleRepliesThreshold`
/// until the parent is in `expanded`, standing a view-more row in for the
/// remainder.
///
/// **The remainder is the server's (#637).** A page carries each thread's two
/// most popular replies and the thread's `replyCount`; "View N more" is that
/// count minus what is shown, and an expanded thread keeps the row while the
/// server holds replies not loaded yet. Without a count (an older record),
/// what was loaded is the whole thread.
enum CommentThreadPresentation {
    /// How many replies a collapsed thread shows before the seam.
    static let visibleRepliesThreshold = 2

    static func items(
        from models: [CommentDisplayModel],
        expanded: Set<String>
    ) -> [CommentStreamItem] {
        var items: [CommentStreamItem] = []
        var index = 0
        while index < models.count {
            let model = models[index]
            items.append(.comment(model))
            index += 1
            guard !model.isReply else { continue } // orphan safety: never a thread head
            // Collect the parent's contiguous reply block.
            var replies: [CommentDisplayModel] = []
            while index < models.count, models[index].parentID == model.id {
                replies.append(models[index])
                index += 1
            }
            let total = max(model.replyCount ?? replies.count, replies.count)
            if expanded.contains(model.id) {
                items.append(contentsOf: replies.map(CommentStreamItem.comment))
                if total > replies.count {
                    items.append(.viewMoreReplies(parentID: model.id, hiddenCount: total - replies.count))
                } else if replies.count > visibleRepliesThreshold {
                    items.append(.collapseReplies(parentID: model.id))
                }
            } else {
                let shown = min(replies.count, visibleRepliesThreshold)
                items.append(contentsOf: replies.prefix(shown).map(CommentStreamItem.comment))
                if total > shown {
                    items.append(.viewMoreReplies(parentID: model.id, hiddenCount: total - shown))
                }
            }
        }
        return items
    }
}
