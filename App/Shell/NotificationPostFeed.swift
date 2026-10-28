import CoreModels
import FeedInterface
import NotificationsInterface
import PostGrid
import UIKit

/// How a post notification opens its post (#1577, the owner 2026-10-22): the
/// ONE post screen, the vertical full-screen feed, ABOVE the drawer.
///
/// ⚠️ **OVER THE DRAWER, NOT IN IT, NOT BEHIND IT.** The drawer's stack is
/// drawer-wide (`SideDrawerContainerViewController`), and the router closes
/// the drawer before it pushes onto a tab — two screens moving at once, and a
/// close that lands on the tab instead of the list. So a clear, full-screen
/// stack is presented over the whole container without animation
/// (`OverSheetFeedHost`, the wallet's stakes' way), the feed is pushed onto
/// IT, and every dismissal — the chevron, the grab, the edge swipe — pops
/// back to the clear host, which takes itself away: the open list is what is
/// left.
///
/// The feed grows out of the row's still when it shows one (the app's zoom
/// flight, measured through the clear host), and slides in otherwise (a text
/// post, or a post the cache cannot describe).
@MainActor
enum NotificationPostFeed {
    /// One opening at a time: a second tap while the first looks its post up.
    private static var isOpening = false

    static func open(_ opening: NotificationPostOpening, feed: any FeedFeatureBuilding) {
        // ⚠️ NEVER A DEAD TAP (#1862). The flight used to await the post's
        // model over the network before anything moved; on a slow network the
        // row did nothing for as long as that read took. Now the post is read
        // from what the app holds, synchronously: held, it flies from the
        // row's still; not held, the feed slides in at once onto its own
        // loading page for that post, which loads inside it.
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        let id = PostID(opening.postID)
        let presenter = opening.presenter
        guard presenter.view.window != nil, presenter.presentedViewController == nil else { return }
        let post = opening.thumbnail == nil ? nil : feed.heldGalleryPost(id)
        switch decision(held: post, thumbnail: opening.thumbnail != nil) {
        case .fly:
            guard let post, let thumbnail = opening.thumbnail else { return }
            let origin = heroOrigin(for: post, thumbnail: thumbnail, list: presenter)
            OverSheetFeedHost.present(over: presenter) { host in
                feed.presentSnapFeedHero(postIDs: [id], from: host, origin: origin)
            }
        case .slide:
            OverSheetFeedHost.present(over: presenter) { host in
                feed.pushSnapFeed(postIDs: [id], from: host)
            }
        }
    }

    enum Opening: Equatable {
        /// The zoom flight from the row's still: the post is held.
        case fly
        /// The slide, at once: a text post, a still-less row, or a post not
        /// held — the feed's loading page loads it.
        case slide
    }

    /// How a post notification opens, decided with no await. Pure.
    static func decision(held post: GalleryPost?, thumbnail: Bool) -> Opening {
        guard thumbnail, let post, post.kind != .text else { return .slide }
        return .fly
    }

    private static func heroOrigin(
        for post: GalleryPost, thumbnail: NotificationPostOpening.Thumbnail, list: UIViewController
    ) -> SnapFeedHeroOrigin {
        SnapFeedHeroOrigin(
            post: post,
            stream: [post],
            hasHero: true,
            cover: thumbnail.cover,
            // A list's still: no tile furniture riding the card.
            style: .listMedia,
            frame: thumbnail.frame,
            isOnScreen: { [weak list] in
                guard let list else { return false }
                return thumbnail.frame(list.view) != nil
            },
            setConcealed: thumbnail.setConcealed,
            cornerRadius: thumbnail.cornerRadius,
            // A squircle, as the still's: a radius alone flies a circle's curve.
            cornerCurve: .continuous
        )
    }
}
