import CoreModels
import Foundation
import Testing

/// A channel's showcase (#2216): the embed on a text post — its action per
/// viewer state, its text where no card is drawn, and a stored post that
/// predates it.
struct PostEmbedTests {
    private func channel(
        _ state: ChannelEmbed.ViewerState, visibility: ChannelEmbed.Visibility = .public,
        availability: ChannelEmbed.Availability = .available
    ) -> ChannelEmbed {
        ChannelEmbed(conversationID: ConversationID("ch-harbour"), name: "Harbour notes", subscriberCount: 10,
                     visibility: visibility, viewerState: state, availability: availability)
    }

    // MARK: - The action table

    @Test func theActionFollowsTheViewersState() {
        #expect(channel(.none, visibility: .public).action == .join)
        #expect(channel(.none, visibility: .onRequest).action == .requestToJoin)
        #expect(channel(.requested, visibility: .onRequest).action == .requested)
        #expect(channel(.member).action == .open)
        #expect(channel(.subscriber, visibility: .onRequest).action == .open)
        #expect(channel(.banned).action == nil, "a banned viewer got a button")
    }

    @Test func anUnavailableChannelHasNoAction() {
        for availability in [ChannelEmbed.Availability.deleted, .private, .blocked] {
            for state in ChannelEmbed.ViewerState.allCases {
                #expect(channel(state, availability: availability).action == nil, "\(availability) \(state)")
            }
        }
    }

    @Test func joiningCountsTheViewerInAndLeavingOut() {
        let joined = channel(.none).with(viewerState: .subscriber)
        #expect(joined.viewerState == .subscriber && joined.subscriberCount == 11)
        #expect(joined.action == .open)
        let requested = channel(.none, visibility: .onRequest).with(viewerState: .requested)
        #expect(requested.subscriberCount == 10, "a request counted the viewer in")
        #expect(requested.with(viewerState: .none).action == .requestToJoin)
        #expect(joined.with(viewerState: .none).subscriberCount == 10)
    }

    @Test func aNamelessChannelIsCalledChannel() {
        #expect(ChannelEmbed(conversationID: ConversationID("x"), name: "  ").displayName == "Channel")
        #expect(channel(.none).displayName == "Harbour notes")
    }

    // MARK: - The text where no card is drawn

    @Test func thePreviewTextIsTheChannelThenTheWords() {
        let embed = PostEmbed.channel(channel(.none))
        #expect(embed.previewText(caption: nil) == "📣 Harbour notes")
        #expect(embed.previewText(caption: " \n ") == "📣 Harbour notes", "blank words are no words")
        #expect(embed.previewText(caption: " Boats in at six ") == "📣 Harbour notes · Boats in at six")
        #expect(embed.channel?.conversationID == ConversationID("ch-harbour"))
    }

    // MARK: - On the post

    @Test func aShowcaseIsATextPostAndItsEmbedRoundTrips() throws {
        let embed = PostEmbed.channel(channel(.requested, visibility: .onRequest))
        let post = Post(id: PostID("p"), authorID: ProfileID("a"), caption: "Come aboard", attachments: [],
                        publishedAt: Date(timeIntervalSince1970: 1_800_000_000), embed: embed)
        #expect(post.attachments.isEmpty, "a showcase read as media")
        let data = try JSONEncoder().encode(post)
        #expect(try JSONDecoder().decode(Post.self, from: data).embed == embed)
    }

    @Test func aStoredPostWithoutTheFieldOrWithAnUnknownOneDecodesWithNone() throws {
        let post = Post(id: PostID("p"), authorID: ProfileID("a"), caption: "", attachments: [],
                        publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        embed: .channel(channel(.none)))
        var object = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(post)) as? [String: Any])
        object["embed"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Post.self, from: old).embed == nil)
        // A later build's case: the post still reads, with no embed.
        object["embed"] = ["group": ["_0": ["conversationID": "grp-1"]]]
        let later = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Post.self, from: later).embed == nil)
    }
}
