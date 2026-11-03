import Foundation

/// The comments space's flag (#2087): off, a media post's comments are
/// today's (`SnapCommentsPresentation`, in the page); on, the redesign — a
/// native sheet over the bottom of the screen, the post's media shrunk whole
/// into the room above it (`SnapCommentsSheetSession`).
///
/// DEBUG only, and off by default: `-comments-v2` turns it on, and so does
/// the comments sandbox (`-comments-sandbox`). Release never reads it.
@MainActor
public enum CommentsV2 {
    #if DEBUG
    public static var isEnabled = ProcessInfo.processInfo.arguments.contains("-comments-v2")
    #else
    public static let isEnabled = false
    #endif
}
