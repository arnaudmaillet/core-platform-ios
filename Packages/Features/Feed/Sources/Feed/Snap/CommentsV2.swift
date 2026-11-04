import Foundation

/// The comments space's flag (#2087): on, a media post's comments are the
/// redesign — a native sheet over the bottom of the screen, the post's media
/// shrunk whole into the room above it (`SnapCommentsSheetSession`); off,
/// the first space (`SnapCommentsPresentation`, in the page). A text post
/// keeps its own either way.
///
/// ON BY DEFAULT, Release included (the owner, 2026-11-04). DEBUG keeps the
/// first space a launch argument away, `-comments-v1`, until it is retired.
@MainActor
public enum CommentsV2 {
    #if DEBUG
    ///
    /// ⚠️ OFF UNDER A TEST HOST: the Feed suites cover the first space, which
    /// still ships in DEBUG; they retire with it (#2087's later step). The
    /// redesign's own tests do not read the flag.
    public static var isEnabled = !ProcessInfo.processInfo.arguments.contains("-comments-v1")
        && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    /// The sheet's bar in a navigation stack of its own — the first build,
    /// kept aside (the owner, 2026-11-03): `-comments-v2-navstack`. Off, the
    /// sheet carries a lone `UINavigationBar` (`SnapCommentsSheetViewController`).
    public static var sheetUsesNavigationStack = ProcessInfo.processInfo.arguments.contains("-comments-v2-navstack")
    /// The composer edits in a bar of its own over the keyboard, TikTok's
    /// way (the owner, 2026-11-04): the keyboard is not the sheet's, so UIKit
    /// leaves the sheet, its rows and the media where they are. Off
    /// (`-comments-v2-sheet-keyboard`), the sheet rises with the keys.
    public static var detachedComposer = !ProcessInfo.processInfo.arguments.contains("-comments-v2-sheet-keyboard")
    #else
    public static let isEnabled = true
    public static let sheetUsesNavigationStack = false
    public static let detachedComposer = true
    #endif
}
