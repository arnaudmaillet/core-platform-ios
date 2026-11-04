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
    /// The sheet's bar in a navigation stack of its own — the first build,
    /// kept aside (the owner, 2026-11-03): `-comments-v2-navstack`. Off, the
    /// sheet carries a lone `UINavigationBar` (`SnapCommentsSheetViewController`).
    public static var sheetUsesNavigationStack = ProcessInfo.processInfo.arguments.contains("-comments-v2-navstack")
    /// The composer edits in a bar of its own over the keyboard, TikTok's
    /// way (a trial, the owner, 2026-11-04): the keyboard is not the sheet's,
    /// so UIKit leaves the sheet, its rows and the media where they are —
    /// `-comments-v2-detached-composer`. Off, the sheet rises with the keys.
    public static var detachedComposer = ProcessInfo.processInfo.arguments.contains("-comments-v2-detached-composer")
    #else
    public static let isEnabled = false
    public static let sheetUsesNavigationStack = false
    public static let detachedComposer = false
    #endif
}
