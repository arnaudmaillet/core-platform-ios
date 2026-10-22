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
        guard !isOpening else { return }
        isOpening = true
        let id = PostID(opening.postID)
        let presenter = opening.presenter
        Task { @MainActor in
            // The flight needs the post's model; a still-less row slides in
            // and needs nothing.
            let post = opening.thumbnail == nil ? nil : await feed.galleryPosts([id])[id]
            isOpening = false
            guard presenter.view.window != nil, presenter.presentedViewController == nil else { return }
            if let post, post.kind != .text, let thumbnail = opening.thumbnail {
                let origin = heroOrigin(for: post, thumbnail: thumbnail, list: presenter)
                OverSheetFeedHost.present(over: presenter) { host in
                    feed.presentSnapFeedHero(postIDs: [id], from: host, origin: origin)
                }
            } else {
                OverSheetFeedHost.present(over: presenter) { host in
                    feed.pushSnapFeed(postIDs: [id], from: host)
                }
            }
        }
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
