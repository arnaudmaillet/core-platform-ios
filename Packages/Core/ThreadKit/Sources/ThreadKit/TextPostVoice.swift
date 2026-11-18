import Foundation

// Moved from FeedInterface's text post contract (#2380), which re-exports it:
// the composer records it.

/// A take the text composer records as a post's caption (#2209).
public struct TextPostVoice: Sendable, Equatable {
    public let fileURL: URL
    public let duration: TimeInterval
    /// 100 levels, 0–31.
    public let waveform: [UInt8]

    public init(fileURL: URL, duration: TimeInterval, waveform: [UInt8]) {
        self.fileURL = fileURL
        self.duration = duration
        self.waveform = waveform
    }

    /// The longest a voice post is (#2204): a minute, the last ten seconds
    /// counted down.
    public static let maximumDuration: TimeInterval = 60
}
