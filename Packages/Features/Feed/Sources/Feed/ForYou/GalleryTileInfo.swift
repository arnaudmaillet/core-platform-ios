import Foundation

/// EXPERIMENT (2026-10-03): the mosaic's LARGE tiles — For You's chunks and
/// the pushed Discover gallery — wear their post's author and the start of
/// its caption over the picture, the Following card's foot
/// (`PostCardCaptionOverlay`): a face and a name, one or two lines, a scrim
/// under them, the likes closing the author line instead of sitting in the
/// tile's corner. Which tiles, and how many lines, is `PostTileInfo`'s rule;
/// the small ones stay pictures.
///
/// The words fly with the tile: the flight's card carries a copy as its
/// resting furniture and fades it as it grows into the page (#319's
/// arrangement), and a close's stand-in lands wearing them.
///
/// Off by default: without the launch argument every tile is exactly what it
/// was.
enum GalleryTileInfo {
    /// The launch argument that turns the experiment on.
    static let launchArgument = "-gallery-tile-info"

    /// Whether `arguments` ask for the experiment. Release builds never do.
    static func isEnabled(arguments: [String]) -> Bool {
        #if DEBUG
        arguments.contains(launchArgument)
        #else
        false
        #endif
    }

    /// Whether this process asked for it — what For You builds its surfaces
    /// with.
    static var isEnabled: Bool {
        isEnabled(arguments: ProcessInfo.processInfo.arguments)
    }
}
