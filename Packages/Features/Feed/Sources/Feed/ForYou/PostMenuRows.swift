import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import PostGrid
import UIKit

/// A post menu's own rows (#1498 §3), for every host that shows a post: Save,
/// Repost, Comment and Like in the palette — each in its state, each doing
/// what the card's control does — then Share, Copy Text and Copy Link.
///
/// One builder, so the grid's pages, the shelf and the sound sheet cannot
/// word or wire the same row two ways. Each seam is optional and gates its
/// row: a host with no staking offers no Like rather than a dead one. Repost
/// with no handler and Copy Link are shown disabled until they exist (#801;
/// no post URL yet), the owner's choice.
@MainActor
struct PostMenuRows {
    var bookmarks: PostBookmarkStore?
    var staking: PostCardStaking?
    /// Nil: Repost is shown disabled.
    var repost: (() -> Void)?
    /// Opens the post on its comments. Nil: no Comment row.
    var comment: (() -> Void)?
    /// After Save toggled: the host redraws its card's star.
    var savedDidChange: ((Bool) -> Void)?

    func rows(for post: GalleryPost, anchor: UIView) -> [PostCardMenuAction] {
        var rows: [PostCardMenuAction] = []
        let id = post.id
        if let bookmarks {
            let savedDidChange = savedDidChange
            rows.append(.save(isOn: bookmarks.isSaved(id.rawValue)) { [weak anchor] in
                guard let anchor else { return }
                MemberGates.perform(.save, from: anchor) {
                    _ = bookmarks.toggle(id.rawValue)
                    Feedback.toggled()
                    savedDidChange?(bookmarks.isSaved(id.rawValue))
                }
            })
        }
        rows.append(.repost(isOn: false, perform: repost))
        if let comment { rows.append(.comment(perform: comment)) }
        if let staking, let amounts = staking.stakeMenu(for: id, from: anchor) {
            rows.append(.like(isOn: staking.viewerStake(on: id) > 0, amounts: amounts))
        }
        rows.append(.share { [weak anchor] in
            guard let anchor else { return }
            Self.presentShareSheet(for: post, from: anchor)
        })
        let caption = post.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty {
            rows.append(.copyText { [weak anchor] in
                UIPasteboard.general.string = caption
                if let screen = anchor.flatMap(Self.screen(of:)) {
                    Feedback.success("Text copied", symbol: "doc.on.doc", from: screen)
                }
            })
        }
        rows.append(.copyLink(perform: nil))
        return rows
    }

    /// Who a post's author submenu is named after.
    static func author(of post: GalleryPost) -> PostCardMenuAuthor? {
        guard let handle = post.authorHandle, !handle.isEmpty else { return nil }
        return PostCardMenuAuthor(handle: handle)
    }

    /// The screen `view` is on, for what a row presents.
    static func screen(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    /// The system share sheet with the post's words and its picture's link —
    /// what the post screen shares (`SnapFeedViewController.presentShareSheet`).
    static func presentShareSheet(for post: GalleryPost, from anchor: UIView) {
        guard let screen = screen(of: anchor) else { return }
        var items: [Any] = []
        if !post.caption.isEmpty { items.append(post.caption) }
        if let url = post.videoURL ?? post.thumbnailURL { items.append(url) }
        guard !items.isEmpty else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = anchor
        screen.present(sheet, animated: true)
    }
}
