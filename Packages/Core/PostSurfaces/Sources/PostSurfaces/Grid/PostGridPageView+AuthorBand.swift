import CoreModels
import PostGrid
import UIKit

/// A flat row's author band, wired (#2145, #2300, #2419): its identity's tap
/// and hold, its Follow and Requested, its "...", and its binding to the
/// author's relation.
extension PostGridPageView {
    func wireAuthorBand(of cell: PostGridListRowCell, for post: GalleryPost) {
        // The band's identity and its "...", if the post carries an author.
        // Captured by AUTHOR and by POST for the same reason the caption's
        // handler is captured by post: the row that asked can have moved by
        // the time the answer is applied.
        if let authorID = post.authorID {
            // A person beside content (#2145, role 1; #2300): a tap the
            // card where the host has one, a hold the profile.
            cell.onAuthorTapped = { [weak self] in
                guard let self else { return }
                (onAuthorCardTapped ?? onAuthorTapped)?(post)
            }
            cell.onAuthorHeld = onAuthorTapped == nil ? nil : { [weak self] in self?.onAuthorTapped?(post) }
            // The band's Follow and Requested (#2419): the shared follow.
            cell.onAuthorFollowTapped = { [weak self] in
                guard let self else { return }
                authorMarks?.follow(authorID, handle: post.authorHandle, name: post.authorName, from: self)
            }
            cell.onAuthorCancelFollowRequest = { [weak self] in
                guard let self else { return }
                authorMarks?.cancelRequest(to: authorID, handle: post.authorHandle, from: self)
            }
            // ONE menu with the long press's (#1498): the palette, the
            // post's rows, then the author's.
            cell.authorMenuActions = { [weak self, weak cell] in
                guard let self, let cell else { return [] }
                return menuActions(
                    for: post, authorID: authorID, anchor: cell.authorMenuAnchor
                )
            }
        }
        // The band's face wears its author's relation mark (#2300), and the
        // band its Follow (#2419), bound like a feed page's author row:
        // redrawn on every answer, on screen or not. A bare band names
        // nobody, and is bound to no one.
        let bandAuthor = cell.authorBandModel?.showsIdentity == true ? post.authorID : nil
        authorMarks?.bind(cell, to: bandAuthor, offersFollow: offersAuthorFollow)
    }

    /// The Follow a stand-in of `post`'s row draws (the reveal's dismissal
    /// card): the row's own when it is realized, else what the row would
    /// draw — none on a host that offers no Follow (a profile's lists).
    func standInAuthorFollow(for post: GalleryPost) -> AuthorFollowOffer {
        if let row = cell(for: post.id) as? PostGridListRowCell { return row.authorFollowOffer }
        guard offersAuthorFollow else { return .none }
        return authorMarks?.followOffer(for: post.authorID) ?? .none
    }
}
