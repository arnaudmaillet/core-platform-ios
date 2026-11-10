import CoreModels
import CoreNetworking
import Foundation

/// The seeded channel showcases (#2216): TEXT posts carrying an embed that
/// references one of the mock's channels (`MockConversationBook`), one per
/// state the card draws — Join, Request to join, Requested, Open, a deleted
/// channel and a private one.
///
/// Picked by the post's rank among the dataset's text posts that are
/// neither reposts (a showcase is its author's own words) nor voice posts
/// (`MockVoicePosts`: a post never both speaks and shows a channel) — every
/// fourth from the second, the channels taken in turn — so about one in
/// six text posts is a showcase, on every launch and in every service.
/// Every service reads posts from the dataset, so the showcases reach the
/// timeline, For You, profiles, notifications and the map (every post has
/// a place there) alike.
///
/// Served only when channels are seeded (`-channels`, read by the app and
/// handed in): without them no post carries an embed.
extension MockSocialDataset {
    /// One showcase: the channel it points to, and the author's words above
    /// its card.
    public struct ChannelShowcase: Sendable, Equatable {
        public let conversationID: String
        public let text: String
    }

    /// The channels the showcases point to, in turn, with the author's
    /// words — one per state the card draws.
    static let showcasedChannels: [ChannelShowcase] = [
        // Public, the viewer not in: Join.
        ChannelShowcase(conversationID: "ch-harbour", text: "Started a channel for the harbour: boats in, boats out, every tide."),
        // On request, the viewer not in: Request to join.
        ChannelShowcase(conversationID: "ch-printroom", text: "The print room has a channel now. Ask to join and I'll let you in."),
        // On request, already asked: Requested.
        ChannelShowcase(conversationID: "ch-film", text: "Film stock club, the channel: what we shot, and what came back from the lab."),
        // On request, the viewer subscribed: Open.
        ChannelShowcase(conversationID: "ch-botanic", text: "New prints go to the channel first."),
        // The viewer's own: Open.
        ChannelShowcase(conversationID: "ch-daily", text: "Tonight's light is up on the channel 🌅"),
        // Gone: "This channel no longer exists".
        ChannelShowcase(conversationID: "ch-ferry-gone", text: "Ferry timetables, live, in my channel."),
        // Turned private: "This channel is private".
        ChannelShowcase(conversationID: "ch-backroom", text: "Backroom sessions — join the channel."),
    ]

    /// Every showcase, by post — computed once by whoever serves them
    /// (`MockBackend`): the pick reads the whole corpus.
    public func channelShowcases() -> [String: ChannelShowcase] {
        let voiceIDs = Set(posts.filter { $0.media == nil }.map(\.postID).filter { seededVoice(forPostID: $0) != nil })
        let candidates = posts.filter { $0.media == nil && $0.parentID.isEmpty && !voiceIDs.contains($0.postID) }
        var picked: [String: ChannelShowcase] = [:]
        for (rank, post) in candidates.enumerated() {
            if let showcase = Self.channelShowcase(rank: rank) { picked[post.postID] = showcase }
        }
        return picked
    }

    /// The showcase `postID` is, or nil (reads the whole corpus: tests).
    public func channelShowcase(forPostID postID: String) -> ChannelShowcase? {
        channelShowcases()[postID]
    }

    /// The pick itself, for the candidate at `rank`.
    static func channelShowcase(rank: Int) -> ChannelShowcase? {
        guard rank % 4 == 1 else { return nil }
        return showcasedChannels[(rank / 4) % showcasedChannels.count]
    }
}
