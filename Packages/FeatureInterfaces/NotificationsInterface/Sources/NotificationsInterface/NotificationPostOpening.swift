import UIKit

/// A post notification asking the shell to open its post (#1577, the owner
/// 2026-10-22): the vertical full-screen feed ABOVE the drawer — the drawer
/// stays open beneath it, and every dismissal lands back on the list.
///
/// Notifications knows neither Feed nor its models, so it hands over what it
/// has: the post's id, the screen to present from, and the row's thumbnail as
/// a flight origin when the row shows one.
@MainActor
public struct NotificationPostOpening {
    /// The post, by its raw id.
    public let postID: String
    /// The list: what the feed is presented over.
    public let presenter: UIViewController
    /// The row's still, for the feed to grow out of; nil when the row shows
    /// none (a text post), and the feed slides in instead.
    public let thumbnail: Thumbnail?

    public init(postID: String, presenter: UIViewController, thumbnail: Thumbnail?) {
        self.postID = postID
        self.presenter = presenter
        self.thumbnail = thumbnail
    }

    /// The row's thumbnail, read live: the row can scroll or be recycled
    /// while the feed is up.
    @MainActor
    public struct Thumbnail {
        /// What it draws now.
        public let cover: UIImage?
        /// Its corner, for the flight's ends.
        public let cornerRadius: CGFloat
        /// Its frame in `space`; nil once it is off the list.
        public let frame: (UICoordinateSpace) -> CGRect?
        /// Hides it while the flight carries its picture.
        public let setConcealed: (Bool) -> Void

        public init(
            cover: UIImage?, cornerRadius: CGFloat,
            frame: @escaping (UICoordinateSpace) -> CGRect?, setConcealed: @escaping (Bool) -> Void
        ) {
            self.cover = cover
            self.cornerRadius = cornerRadius
            self.frame = frame
            self.setConcealed = setConcealed
        }
    }
}
