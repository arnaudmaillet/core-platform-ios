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
    /// A red frame around the post's media window, to follow it through the
    /// sheet's transitions (the owner, 2026-11-03): `-comments-v2-frames`,
    /// and on in the comments sandbox. DEBUG only.
    public static var showsDebugFrames = ProcessInfo.processInfo.arguments.contains("-comments-v2-frames")
    #else
    public static let isEnabled = false
    #endif
}
