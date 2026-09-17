import Foundation

/// A song laid under a video.
///
/// ⚠️ **THE FILE IS AN APP-OWNED COPY, AND IT MUST OUTLIVE THE EDITOR.** A
/// picker hands over a file that may be deleted as soon as its callback returns;
/// whoever makes one of these copies the song first and keeps the copy alive
/// until the post has published.
///
/// ⚠️ **CONSTANT VOLUMES, NO RAMPS, IN VERSION 1.** A volume ramp across a piece
/// played at 3x or 4x has frozen `AVAssetExportSession` for good (memory
/// `export-volume-ramp-hang`), so the song and the film's own sound each keep
/// one level for the whole film.
public struct VideoSoundtrack: Equatable, Sendable {
    public var fileURL: URL
    /// What the pill says once the song is chosen.
    public var title: String
    /// Where the excerpt starts, in seconds of the SONG.
    public var startSeconds: Double
    /// 0...1, the song's level.
    public var musicVolume: Double
    /// 0...1, the level of the film's own sound under it.
    public var originalVolume: Double

    public init(
        fileURL: URL, title: String, startSeconds: Double = 0,
        musicVolume: Double = 1, originalVolume: Double = 1
    ) {
        self.fileURL = fileURL
        self.title = title
        self.startSeconds = startSeconds
        self.musicVolume = musicVolume
        self.originalVolume = originalVolume
    }
}
