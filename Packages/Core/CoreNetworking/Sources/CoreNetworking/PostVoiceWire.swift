import CoreModels
import Foundation
import SwiftProtobuf

/// A voice post's voice on the wire (#2206), until the backend's own field
/// lands (core-platform-backend#994: an optional `voice` on a text-only
/// post, and `has_voice` on the summaries).
///
/// The voice rides as ONE length-delimited field the contracts don't
/// declare (`fieldNumber`), on whatever message carries the post — the post
/// view, a map pin, a create request. It is a `cpvoice://` reference, the
/// shape `ChatMediaRef` gives a voice message:
/// `cpvoice://v1?a=<asset>&url=<url>&d=<seconds>&wf=<100 base-32 digits>`.
///
/// - **Proto-safe:** a client or server that doesn't know it keeps it as an
///   unknown field and reads a text post.
/// - **One place:** the mock writes it, the repositories read it. When #994
///   lands, `voice(in:)` reads the real field and this goes.
public enum PostVoiceWire {
    /// Far from every declared field.
    public static let fieldNumber = 9_204

    /// The voice `message` carries, if any.
    public static func voice(in message: some SwiftProtobuf.Message) -> PostVoice? {
        guard let reference = UnknownFieldWire.string(field: fieldNumber, in: message) else { return nil }
        return decode(reference)
    }

    /// Adds `voice` to `message`.
    public static func write<Message: SwiftProtobuf.Message>(_ voice: PostVoice, to message: inout Message) {
        UnknownFieldWire.write(encode(voice), field: fieldNumber, to: &message)
    }

    // MARK: - The reference

    static func encode(_ voice: PostVoice) -> String {
        var components = URLComponents()
        components.scheme = "cpvoice"
        components.host = "v1"
        components.queryItems = [
            URLQueryItem(name: "a", value: voice.assetID),
            URLQueryItem(name: "url", value: voice.url?.absoluteString ?? ""),
            URLQueryItem(name: "d", value: String(format: "%.1f", voice.duration)),
            URLQueryItem(name: "wf", value: waveformString(voice.waveform)),
        ]
        return components.string ?? ""
    }

    static func decode(_ reference: String) -> PostVoice? {
        guard let components = URLComponents(string: reference), components.scheme == "cpvoice" else { return nil }
        func value(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        guard let duration = value("d").flatMap(Double.init), duration > 0 else { return nil }
        return PostVoice(
            assetID: value("a") ?? "",
            url: value("url").flatMap { $0.isEmpty ? nil : URL(string: $0) },
            duration: duration,
            waveform: levels(value("wf") ?? "")
        )
    }

    private static let digits = Array("0123456789abcdefghijklmnopqrstuv")

    /// 100 levels, one base-32 digit each (`ChatMediaRef`'s `wf`).
    public static func waveformString(_ levels: [UInt8]) -> String {
        String(levels.map { digits[Int(min($0, 31))] })
    }

    public static func levels(_ string: String) -> [UInt8] {
        string.compactMap { character in digits.firstIndex(of: character).map(UInt8.init) }
    }
}
