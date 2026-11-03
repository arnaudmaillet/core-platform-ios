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
    /// The media handed to its preview without travelling (a trial, the
    /// owner, 2026-11-03): it scales out above the sheet while the preview
    /// pops in at its corner — `-comments-v2-preview-pop`. Off, the preview
    /// carries the media from where it stood to its corner.
    public static var previewPops = ProcessInfo.processInfo.arguments.contains("-comments-v2-preview-pop")
    #else
    public static let isEnabled = false
    public static let sheetUsesNavigationStack = false
    public static let previewPops = false
    #endif
}
