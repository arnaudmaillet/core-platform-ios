import CryptoKit
import Foundation
import FeedInterface
import UIKit

/// A photo, a video or a voice message carried by a chat message (#681,
/// #2103).
public struct ChatMedia: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case image
        case video
        /// A voice message (#2103): an `.m4a`, its length and its waveform.
        case voice
    }

    public let kind: Kind
    /// The delivery URL: the picture, or the clip.
    public let url: URL
    /// A video's still, when one was uploaded.
    public let posterURL: URL?
    /// The media's pixel size, for laying the bubble out before it loads.
    /// Zero when unknown (a reference from another client).
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// A video's or a voice message's length in seconds.
    public let duration: TimeInterval?
    /// A voice message's waveform: 100 levels, 0–31 (#2101). Nil when the
    /// sender's client gave none — drawn from the file once it is here.
    public let waveform: [UInt8]?
    /// The media asset, when the reference names it: the key a voice
    /// message's audio is cached by (#2101's `VoiceFileCache`).
    public let assetID: String?

    public init(
        kind: Kind, url: URL, posterURL: URL? = nil,
        pixelWidth: Int = 0, pixelHeight: Int = 0, duration: TimeInterval? = nil,
        waveform: [UInt8]? = nil, assetID: String? = nil
    ) {
        self.kind = kind
        self.url = url
        self.posterURL = posterURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.waveform = waveform
        self.assetID = assetID
    }

    /// Width over height, or nil when the size is unknown.
    public var aspectRatio: CGFloat? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }
}

extension ChatMedia.Kind {
    /// What a caption-less media message reads as in a preview or a quote.
    public var label: String {
        switch self {
        case .image: "Photo"
        case .video: "Video"
        case .voice: "Voice message"
        }
    }
}

extension ChatMedia {
    /// What a caption-less message carrying this reads as in a preview or a
    /// quote: "Photo", "Video", "🎤 Voice message (0:12)" (#2103).
    public var summary: String { Self.summary(kind: kind, duration: duration) }

    /// `summary` for a kind and a length — a bubble that has no `ChatMedia`.
    public static func summary(kind: Kind, duration: TimeInterval?) -> String {
        guard kind == .voice else { return kind.label }
        return ConversationThreadMedia.voiceSummary(duration: duration)
    }
}

extension ChatMessage {
    /// The message in one line: its text, or — a caption-less photo, video
    /// or voice message — what it carries (#681, #2103).
    public var summary: String {
        guard body.isEmpty, let media else { return body }
        return media.summary
    }
}

/// chat.v1's `media_ref` as this client writes it.
///
/// The service treats the reference as OPAQUE: it requires one on a MEDIA
/// message and stores it, nothing more (`Message::create`, backend
/// `crates/services/chat`). media.v1 has no read the recipient could resolve
/// an asset id with, and the bubble needs the kind and the size before
/// anything loads, so the reference carries them itself:
///
/// ```
/// cpmedia://v1?kind=image&url=<delivery>&w=1080&h=1350
/// cpmedia://v1?kind=video&url=<clip>&poster=<still>&w=…&h=…&d=12.4
/// cpmedia://v1?kind=voice&url=<audio>&d=12.4&wf=<100 levels>&a=<asset id>
/// ```
///
/// ⚠️ THE VOICE MESSAGE'S SHAPE IS THE CLIENT'S UNTIL THE CONTRACT HAS ONE
/// (#2103, the owner 2026-11-04: client first). chat.v1 and media.v1 carry no
/// audio yet (backend#993); the length, the waveform and the asset travel in
/// this reference, and THIS is the one place to switch to the contract's
/// fields once they land. The waveform is one character per level, 0–31 as
/// `0`–`9` then `a`–`v`: 100 characters.
///
/// A bare URL — a client that wrote the delivery URL alone — reads as a photo
/// of unknown size.
public enum ChatMediaRef {
    static let scheme = "cpmedia"

    public static func encode(_ media: ChatMedia) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "v1"
        var items = [
            URLQueryItem(name: "kind", value: media.kind.rawValue),
            URLQueryItem(name: "url", value: media.url.absoluteString),
        ]
        if let poster = media.posterURL { items.append(URLQueryItem(name: "poster", value: poster.absoluteString)) }
        if media.pixelWidth > 0, media.pixelHeight > 0 {
            items.append(URLQueryItem(name: "w", value: String(media.pixelWidth)))
            items.append(URLQueryItem(name: "h", value: String(media.pixelHeight)))
        }
        if let duration = media.duration { items.append(URLQueryItem(name: "d", value: String(format: "%.1f", duration))) }
        if let waveform = media.waveform { items.append(URLQueryItem(name: "wf", value: Waveform.encode(waveform))) }
        if let assetID = media.assetID { items.append(URLQueryItem(name: "a", value: assetID)) }
        // Encoded by hand: `queryItems` leaves `&` and `=` inside a value
        // alone, and a delivery URL with its own query must not split this one.
        components.percentEncodedQuery = items.map { item in
            "\(item.name)=\(item.value?.addingPercentEncoding(withAllowedCharacters: .refValue) ?? "")"
        }.joined(separator: "&")
        return components.string ?? media.url.absoluteString
    }

    public static func decode(_ reference: String) -> ChatMedia? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let components = URLComponents(string: trimmed), components.scheme == scheme else {
            return URL(string: trimmed).map { ChatMedia(kind: .image, url: $0) }
        }
        let values = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        guard let url = values["url"].flatMap(URL.init(string:)) else { return nil }
        return ChatMedia(
            kind: values["kind"].flatMap(ChatMedia.Kind.init(rawValue:)) ?? .image,
            url: url,
            posterURL: values["poster"].flatMap(URL.init(string:)),
            pixelWidth: values["w"].flatMap(Int.init) ?? 0,
            pixelHeight: values["h"].flatMap(Int.init) ?? 0,
            duration: values["d"].flatMap(TimeInterval.init),
            waveform: values["wf"].flatMap(Waveform.decode),
            assetID: values["a"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// A waveform as text: one base-32 digit per level.
    enum Waveform {
        static let digits = Array("0123456789abcdefghijklmnopqrstuv")

        static func encode(_ levels: [UInt8]) -> String {
            String(levels.map { digits[Int(min($0, 31))] })
        }

        static func decode(_ text: String) -> [UInt8]? {
            let levels = text.compactMap { character in digits.firstIndex(of: character).map(UInt8.init) }
            return levels.count == text.count && !levels.isEmpty ? levels : nil
        }
    }
}

private extension CharacterSet {
    /// What a query VALUE may hold unescaped: no `&`, `=`, `+`, `?` or `#`.
    static let refValue: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()
}

/// What the viewer picked to send, before it is uploaded.
public enum ChatMediaUpload: Sendable {
    /// A photo, encoded and hashed at send time (`MediaEncoder`).
    case image(UIImage)
    /// A clip already exported for upload (H.264 in an MP4), with its
    /// still, its pixel size and its length.
    case video(ChatVideoUpload)
    /// A finished take (#2101's draft): its file, length and waveform.
    case voice(ChatVoiceUpload)

    /// The picture to show while the message is on its way.
    public var preview: UIImage? {
        switch self {
        case .image(let image): image
        case .video(let video): video.poster
        case .voice: nil
        }
    }

    public var kind: ChatMedia.Kind {
        switch self {
        case .image: .image
        case .video: .video
        case .voice: .voice
        }
    }
}

/// A take to send as a voice message (#2103): AAC in an `.m4a` (#2101).
public struct ChatVoiceUpload: Sendable {
    public let fileURL: URL
    public let mimeType: String
    public let duration: TimeInterval
    /// 100 levels, 0–31.
    public let waveform: [UInt8]

    public init(fileURL: URL, mimeType: String = "audio/mp4", duration: TimeInterval, waveform: [UInt8]) {
        self.fileURL = fileURL
        self.mimeType = mimeType
        self.duration = duration
        self.waveform = waveform
    }

    /// The file's size and SHA-256, read in chunks.
    func fingerprint() throws -> (size: UInt64, sha256: String) {
        try FileFingerprint.of(fileURL)
    }
}

public struct ChatVideoUpload: Sendable {
    public let fileURL: URL
    public let mimeType: String
    public let poster: UIImage?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: TimeInterval
    /// What keeps `fileURL` on disk (#898): the upload flow's exported clip
    /// is deleted with its owner. Held as long as this value is — by the
    /// pending bubble, through its retries — and let go with it once the
    /// message is sent or discarded.
    let fileOwner: (any AnyObject & Sendable)?

    public init(
        fileURL: URL, mimeType: String = "video/mp4", poster: UIImage?,
        pixelWidth: Int, pixelHeight: Int, duration: TimeInterval,
        fileOwner: (any AnyObject & Sendable)? = nil
    ) {
        self.fileURL = fileURL
        self.mimeType = mimeType
        self.poster = poster
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.fileOwner = fileOwner
    }

    /// The file's size and SHA-256, read in chunks.
    func fingerprint() throws -> (size: UInt64, sha256: String) {
        try FileFingerprint.of(fileURL)
    }
}

/// A file's size and SHA-256, read a megabyte at a time.
enum FileFingerprint {
    static func of(_ fileURL: URL) throws -> (size: UInt64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += UInt64(chunk.count)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (size, hex)
    }
}
