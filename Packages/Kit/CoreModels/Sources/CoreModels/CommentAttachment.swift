import Foundation

/// What a comment carries besides its words (#2309): ONE optional
/// attachment, told apart by its kind. A voice is the first kind; a photo
/// and a short video (#2310, on hold) will be more cases of this same value,
/// never a field beside it.
///
/// - **The body stays optional beside it:** a voice alone is a valid
///   comment, as a voice alone is a valid post (#2204).
/// - ⚠️ **An unknown kind is kept, never fatal:** a comment written by a
///   later client (or served by a later backend) whose attachment this build
///   can't read is `.unsupported`, and the comment still reads with its
///   text. Nothing plays or draws it; a surface may show a neutral line.
/// - **On the wire:** core-platform-backend#996's proposed
///   `CommentAttachment` (a `kind`, an `asset_id`, and per kind the voice's
///   `duration_ms` and `waveform`). Until the contracts carry it, the client
///   reads and writes it through `CommentAttachmentWire` (CoreNetworking).
public enum CommentAttachment: Sendable, Equatable, Hashable {
    /// A voice comment (#2309): the same value a voice post's caption
    /// carries (asset, url, length, waveform), drawn by the same shared
    /// voice view.
    case voice(PostVoice)
    /// A kind this build doesn't know, by its wire name: kept so a surface
    /// can say so neutrally, never drawn, never played.
    case unsupported(Kind)

    /// An attachment's kind, by its wire name — open, so a kind this build
    /// doesn't know still has a name.
    public struct Kind: RawRepresentable, Sendable, Equatable, Hashable, Codable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// backend#996's `COMMENT_ATTACHMENT_KIND_VOICE`.
        public static let voice = Kind(rawValue: "voice")
        // `image` and `video` are reserved for #2310: until a case reads
        // them, they arrive as `.unsupported`.
    }

    public var kind: Kind {
        switch self {
        case .voice: .voice
        case .unsupported(let kind): kind
        }
    }

    /// The voice, when it is one.
    public var voice: PostVoice? {
        if case .voice(let voice) = self { voice } else { nil }
    }

    /// Whether this build can draw it. False for `.unsupported` only.
    public var isSupported: Bool {
        if case .unsupported = self { false } else { true }
    }
}

// MARK: - Stored form

/// `{"kind": "voice", "voice": {…}}`. A kind this build doesn't know decodes
/// as `.unsupported`, so a record written by a later build still reads.
extension CommentAttachment: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case voice
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .voice: self = .voice(try container.decode(PostVoice.self, forKey: .voice))
        default: self = .unsupported(kind)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if case .voice(let voice) = self { try container.encode(voice, forKey: .voice) }
    }
}
