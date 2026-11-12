import CoreModels
import Foundation
import SwiftProtobuf

/// A comment's attachment on the wire (#2309), until the backend's own field
/// lands (core-platform-backend#996: an optional `CommentAttachment
/// attachment` on `CommentView` and `CreateCommentRequest` — a `kind`, an
/// `asset_id`, and for a voice its `duration_ms` and `waveform`).
///
/// The attachment rides as ONE length-delimited field the contracts don't
/// declare (`fieldNumber`), on whatever message carries the comment — the
/// comment view (pages, replies, previews) or the create request — as
/// `PostVoiceWire` carries a post's voice. It is a `cpattach://` reference
/// mirroring #996's proposed message, field for field:
/// `cpattach://v1?kind=voice&a=<asset_id>&url=<url>&ms=<duration_ms>&wf=<100 base-32 digits>`.
/// Any other `kind` reads as `.unsupported(kind)`: the comment keeps its
/// text.
///
/// - **Proto-safe:** a client or server that doesn't know it keeps it as an
///   unknown field and reads a text comment.
/// - **One place:** the mock writes it, the repository reads it. When #996
///   lands, these two functions read and write the generated
///   `attachment` instead (`kind` → the case, `UNRECOGNIZED` →
///   `.unsupported`), the call sites stay as they are, and this reference
///   goes.
public enum CommentAttachmentWire {
    /// Far from every declared field, and from the post's voice (9 204) and
    /// embed (9 216).
    public static let fieldNumber = 9_309

    /// The attachment `message` carries, if any. A malformed voice (no
    /// length) is none: the comment reads with its text.
    public static func attachment(in message: some SwiftProtobuf.Message) -> CommentAttachment? {
        guard let reference = UnknownFieldWire.string(field: fieldNumber, in: message) else { return nil }
        return decode(reference)
    }

    /// Adds `attachment` to `message`.
    public static func write<Message: SwiftProtobuf.Message>(_ attachment: CommentAttachment, to message: inout Message) {
        UnknownFieldWire.write(encode(attachment), field: fieldNumber, to: &message)
    }

    // MARK: - The reference

    static let scheme = "cpattach"

    static func encode(_ attachment: CommentAttachment) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "v1"
        var items = [URLQueryItem(name: "kind", value: attachment.kind.rawValue)]
        if case .voice(let voice) = attachment {
            items += [
                URLQueryItem(name: "a", value: voice.assetID),
                URLQueryItem(name: "url", value: voice.url?.absoluteString ?? ""),
                URLQueryItem(name: "ms", value: String(Int64((voice.duration * 1000).rounded()))),
                URLQueryItem(name: "wf", value: PostVoiceWire.waveformString(voice.waveform)),
            ]
        }
        components.queryItems = items
        // `+` is a space to some readers: spelled out, so a URL keeps it.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.string ?? ""
    }

    static func decode(_ reference: String) -> CommentAttachment? {
        guard let components = URLComponents(string: reference), components.scheme == scheme,
              components.host == "v1" else { return nil }
        func value(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        guard let name = value("kind"), !name.isEmpty else { return nil }
        let kind = CommentAttachment.Kind(rawValue: name)
        switch kind {
        case .voice:
            guard let milliseconds = value("ms").flatMap(Int64.init), milliseconds > 0 else { return nil }
            return .voice(PostVoice(
                assetID: value("a") ?? "",
                url: value("url").flatMap { $0.isEmpty ? nil : URL(string: $0) },
                duration: TimeInterval(milliseconds) / 1000,
                waveform: PostVoiceWire.levels(value("wf") ?? "")
            ))
        default:
            return .unsupported(kind)
        }
    }
}
