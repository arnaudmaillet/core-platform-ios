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
        guard let reference = string(field: fieldNumber, in: message.unknownFields.data) else { return nil }
        return decode(reference)
    }

    /// Adds `voice` to `message`.
    public static func write<Message: SwiftProtobuf.Message>(_ voice: PostVoice, to message: inout Message) {
        let payload = Data(encode(voice).utf8)
        var bytes = Data()
        appendVarint(UInt64(fieldNumber << 3 | 2), to: &bytes)
        appendVarint(UInt64(payload.count), to: &bytes)
        bytes.append(payload)
        // Appended on the wire and read back: a decoder keeps a field it
        // doesn't know as an unknown field (`UnknownStorage.append` is not
        // public).
        guard let serialized = try? message.serializedData(),
              let decoded = try? Message(serializedBytes: serialized + bytes) else { return }
        message = decoded
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

    // MARK: - Unknown fields

    /// The first length-delimited `field` in `data`, as UTF-8.
    private static func string(field: Int, in data: Data) -> String? {
        var index = data.startIndex
        while index < data.endIndex {
            guard let key = readVarint(data, &index) else { return nil }
            let number = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0: guard readVarint(data, &index) != nil else { return nil }
            case 1: index = data.index(index, offsetBy: 8, limitedBy: data.endIndex) ?? data.endIndex
            case 5: index = data.index(index, offsetBy: 4, limitedBy: data.endIndex) ?? data.endIndex
            case 2:
                guard let length = readVarint(data, &index),
                      let end = data.index(index, offsetBy: Int(length), limitedBy: data.endIndex) else { return nil }
                if number == field { return String(data: data[index..<end], encoding: .utf8) }
                index = end
            default: return nil
            }
        }
        return nil
    }

    private static func readVarint(_ data: Data, _ index: inout Data.Index) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index = data.index(after: index)
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
    }
}
