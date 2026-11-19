import Foundation

// A plain value (#2380): the composer (ThreadKit) records it, Feed's text
// post page carries it, FeedInterface's `TextPostPublishing` hands it to
// Upload. Here rather than in ThreadKit so the interface needs no Core kit.

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
