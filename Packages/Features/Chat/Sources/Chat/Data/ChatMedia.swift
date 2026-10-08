import CryptoKit
import Foundation
import UIKit

/// A photo or a video carried by a chat message (#681).
public struct ChatMedia: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case image
        case video
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
    /// A video's length in seconds.
    public let duration: TimeInterval?

    public init(
        kind: Kind, url: URL, posterURL: URL? = nil,
        pixelWidth: Int = 0, pixelHeight: Int = 0, duration: TimeInterval? = nil
    ) {
        self.kind = kind
        self.url = url
        self.posterURL = posterURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
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
        }
    }
}

extension ChatMessage {
    /// The message in one line: its text, or — a caption-less photo or
    /// video — what it carries (#681).
    public var summary: String {
        guard body.isEmpty, let media else { return body }
        return media.kind.label
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
/// ```
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
            duration: values["d"].flatMap(TimeInterval.init)
        )
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

    /// The picture to show while the message is on its way.
    public var preview: UIImage? {
        switch self {
        case .image(let image): image
        case .video(let video): video.poster
        }
    }

    public var kind: ChatMedia.Kind {
        switch self {
        case .image: .image
        case .video: .video
        }
    }
}

public struct ChatVideoUpload: Sendable {
    public let fileURL: URL
    public let mimeType: String
    public let poster: UIImage?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: TimeInterval

    public init(
        fileURL: URL, mimeType: String = "video/mp4", poster: UIImage?,
        pixelWidth: Int, pixelHeight: Int, duration: TimeInterval
    ) {
        self.fileURL = fileURL
        self.mimeType = mimeType
        self.poster = poster
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
    }

    /// The file's size and SHA-256, read in chunks.
    func fingerprint() throws -> (size: UInt64, sha256: String) {
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
