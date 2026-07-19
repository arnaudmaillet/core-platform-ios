import Foundation

/// One renderable unit of the threaded comments stream.
enum CommentStreamItem: Equatable {
    case comment(CommentDisplayModel)
    /// The collapsed remainder of a popular thread: rendered as a tappable
    /// "View N more replies…" row at reply depth; tapping expands that
    /// parent's full reply pool.
    case viewMoreReplies(parentID: String, hiddenCount: Int)
}

/// The stream's truncation authority — pure, so the pagination seam is
/// unit-tested without views. Input is the repository's thread order
/// (each parent immediately followed by its replies); output caps each
/// thread's visible replies at `visibleRepliesThreshold` until the parent
/// is in `expanded`, standing a view-more row in for the remainder.
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
            if replies.count <= visibleRepliesThreshold || expanded.contains(model.id) {
                items.append(contentsOf: replies.map(CommentStreamItem.comment))
            } else {
                items.append(contentsOf: replies.prefix(visibleRepliesThreshold).map(CommentStreamItem.comment))
                items.append(.viewMoreReplies(
                    parentID: model.id,
                    hiddenCount: replies.count - visibleRepliesThreshold
                ))
            }
        }
        return items
    }
}
