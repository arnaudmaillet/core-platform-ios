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
    public static let isEnabled = !ProcessInfo.processInfo.arguments.contains("-comments-v1")
        && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    #else
    public static let isEnabled = true
    #endif
}
