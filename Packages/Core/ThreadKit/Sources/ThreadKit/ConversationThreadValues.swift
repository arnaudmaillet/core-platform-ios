import CoreModels
import MediaCore
import UIKit

// The conversation's row values (#2380): moved from FeedInterface's contract,
// which re-exports them.

/// A message's photo, video or voice message (#681, #2103), as the bubble
/// draws it.
public struct ConversationThreadMedia: Equatable, Sendable {
    public enum Kind: Sendable {
        case image
        case video
        case voice
    }

    public let kind: Kind
    /// The picture, or the clip. Nil while a sent message is still uploading.
    public let url: URL?
    /// A video's still.
    public let posterURL: URL?
    /// The picture the viewer picked, drawn while it uploads and after, so
    /// their own message never waits on the network.
    public let preview: UIImage?
    /// Width over height; nil when unknown.
    public let aspectRatio: CGFloat?
    /// A video's or a voice message's length in seconds.
    public let duration: TimeInterval?
    /// A voice message's 100 levels, 0–31 (#2103).
    public let waveform: [UInt8]?
    /// A voice message's asset: the key its audio is cached by.
    public let assetID: String?
    /// The viewer's own take while it is on its way: it plays from here.
    public let localFileURL: URL?

    public init(
        kind: Kind, url: URL?, posterURL: URL? = nil, preview: UIImage? = nil,
        aspectRatio: CGFloat? = nil, duration: TimeInterval? = nil,
        waveform: [UInt8]? = nil, assetID: String? = nil, localFileURL: URL? = nil
    ) {
        self.kind = kind
        self.url = url
        self.posterURL = posterURL
        self.preview = preview
        self.aspectRatio = aspectRatio
        self.duration = duration
        self.waveform = waveform
        self.assetID = assetID
        self.localFileURL = localFileURL
    }
}

extension ConversationThreadMedia {
    /// A voice message in one line: "🎤 Voice message (0:12)" — the inbox
    /// row's, a quote's, the thread's until the bubble draws it (#2103).
    public static func voiceSummary(duration: TimeInterval?) -> String {
        guard let duration else { return "🎤 Voice message" }
        let whole = max(0, Int(duration.rounded()))
        return "🎤 Voice message (\(String(format: "%d:%02d", whole / 60, whole % 60)))"
    }
}

/// Where the viewer's own message is: sent, on its way, or failed — a failed
/// one offers a retry (#681).
public enum ConversationThreadDelivery: Equatable, Sendable {
    case sent
    case sending
    case failed
}
