import CoreModels
import Foundation
import SwiftProtobuf

/// A showcase's embed on the wire (#2216), until the backend's own field
/// lands (core-platform-backend#995: a text post may carry an embed
/// referencing a conversation, and the feed, map and search responses carry
/// it hydrated for the viewer).
///
/// The embed rides as ONE length-delimited field the contracts don't declare
/// (`fieldNumber`), on whatever message carries the post — the post view, a
/// map pin — as `PostVoiceWire` carries a voice. It is a `cpembed://`
/// reference holding the hydrated card:
/// `cpembed://v1/channel?c=<conversation>&n=<name>&p=<photo>&d=<description>`
/// `&s=<subscribers>&v=<public|onRequest>&vs=<viewer state>&a=<availability>&m=<last message>`.
///
/// - **Proto-safe:** a client or server that doesn't know it keeps it as an
///   unknown field and reads a text post.
/// - **One place:** the mock writes it, the repositories read it. When #995
///   lands, `embed(in:)` reads the real field and this goes.
public enum PostEmbedWire {
    /// Far from every declared field, and from the voice's (9 204).
    public static let fieldNumber = 9_216

    /// The embed `message` carries, if any.
    public static func embed(in message: some SwiftProtobuf.Message) -> PostEmbed? {
        guard let reference = UnknownFieldWire.string(field: fieldNumber, in: message) else { return nil }
        return decode(reference)
    }

    /// Adds `embed` to `message`.
    public static func write<Message: SwiftProtobuf.Message>(_ embed: PostEmbed, to message: inout Message) {
        UnknownFieldWire.write(encode(embed), field: fieldNumber, to: &message)
    }

    // MARK: - The reference

    static let scheme = "cpembed"

    static func encode(_ embed: PostEmbed) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "v1"
        switch embed {
        case .channel(let channel):
            components.path = "/channel"
            var items = [
                URLQueryItem(name: "c", value: channel.conversationID.rawValue),
                URLQueryItem(name: "n", value: channel.name),
                URLQueryItem(name: "p", value: channel.photoURL?.absoluteString ?? ""),
                URLQueryItem(name: "d", value: channel.description),
                URLQueryItem(name: "s", value: String(channel.subscriberCount)),
                URLQueryItem(name: "v", value: channel.visibility.rawValue),
                URLQueryItem(name: "vs", value: channel.viewerState.rawValue),
                URLQueryItem(name: "a", value: channel.availability.rawValue),
            ]
            if let preview = channel.lastMessagePreview { items.append(URLQueryItem(name: "m", value: preview)) }
            components.queryItems = items
        }
        // `+` is a space to some readers: spelled out, so a name keeps it.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.string ?? ""
    }

    static func decode(_ reference: String) -> PostEmbed? {
        guard let components = URLComponents(string: reference), components.scheme == scheme,
              components.host == "v1" else { return nil }
        func value(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        switch components.path {
        case "/channel":
            guard let id = value("c"), !id.isEmpty else { return nil }
            // A state this build doesn't know reads as the safest one: no
            // standing, available — the card then offers what a stranger
            // gets, and the server refuses what it must.
            let channel = ChannelEmbed(
                conversationID: ConversationID(id),
                name: value("n") ?? "",
                photoURL: value("p").flatMap { $0.isEmpty ? nil : URL(string: $0) },
                description: value("d") ?? "",
                subscriberCount: value("s").flatMap { Int($0) } ?? 0,
                visibility: value("v").flatMap { ChannelEmbed.Visibility(rawValue: $0) } ?? .onRequest,
                viewerState: value("vs").flatMap { ChannelEmbed.ViewerState(rawValue: $0) } ?? .none,
                availability: value("a").flatMap { ChannelEmbed.Availability(rawValue: $0) } ?? .available,
                lastMessagePreview: value("m")
            )
            return .channel(channel)
        default:
            // A later embed's case: the post reads as the text post it is.
            return nil
        }
    }
}
