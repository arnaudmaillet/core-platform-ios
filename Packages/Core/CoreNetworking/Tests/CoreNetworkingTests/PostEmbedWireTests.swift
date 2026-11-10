import CoreContracts
import CoreModels
import Foundation
import SwiftProtobuf
import Testing
@testable import CoreNetworking

/// A showcase's embed on the wire (#2216): one undeclared field on the post
/// view and the map's pin — never an attachment, never a sound.
struct PostEmbedWireTests {
    private let channel = ChannelEmbed(
        conversationID: ConversationID("ch-harbour"), name: "Harbour notes & co + friends",
        photoURL: URL(string: "https://picsum.photos/seed/harbour/400/400"),
        description: "Boats in, boats out. 50% tides?", subscriberCount: 12_400, visibility: .onRequest,
        viewerState: .requested, availability: .available, lastMessagePreview: "The ferry's late again"
    )

    @Test func anEmbedRidesThePostViewAndSurvivesTheWire() throws {
        var view = Post_V1_PostView()
        view.postID = "p1"
        view.kind = .textOnly
        view.caption = "Come aboard"
        PostEmbedWire.write(.channel(channel), to: &view)
        let decoded = try Post_V1_PostView(serializedBytes: try view.serializedData())
        #expect(PostEmbedWire.embed(in: decoded) == .channel(channel))
        #expect(decoded.caption == "Come aboard")
        #expect(decoded.kind == .textOnly)
        #expect(decoded.attachments.isEmpty, "an embed is never an attachment")
        #expect(!decoded.hasAudioRef, "an embed is never the post's sound")
    }

    @Test func everyStateRoundTrips() {
        for availability in ChannelEmbed.Availability.allCases {
            for state in ChannelEmbed.ViewerState.allCases {
                for visibility in ChannelEmbed.Visibility.allCases {
                    let embed = PostEmbed.channel(ChannelEmbed(
                        conversationID: ConversationID("ch"), visibility: visibility, viewerState: state,
                        availability: availability
                    ))
                    #expect(PostEmbedWire.decode(PostEmbedWire.encode(embed)) == embed)
                }
            }
        }
    }

    @Test func aMapPinCarriesItToo() throws {
        var pin = GeoDiscovery_V1_RadarPin()
        pin.postID = "p-showcase"
        PostEmbedWire.write(.channel(channel), to: &pin)
        let decoded = try GeoDiscovery_V1_RadarPin(serializedBytes: try pin.serializedData())
        #expect(PostEmbedWire.embed(in: decoded) == .channel(channel))
    }

    @Test func aVoiceAndAnEmbedLiveSideBySide() {
        let voice = PostVoice(assetID: "v", url: nil, duration: 3, waveform: [1, 2, 3])
        var view = Post_V1_PostView()
        PostVoiceWire.write(voice, to: &view)
        PostEmbedWire.write(.channel(channel), to: &view)
        #expect(PostVoiceWire.voice(in: view) == voice)
        #expect(PostEmbedWire.embed(in: view) == .channel(channel))
    }

    @Test func theLastEmbedWrittenWins() {
        var view = Post_V1_PostView()
        PostEmbedWire.write(.channel(channel), to: &view)
        let joined = channel.with(viewerState: .subscriber)
        PostEmbedWire.write(.channel(joined), to: &view)
        #expect(PostEmbedWire.embed(in: view) == .channel(joined))
    }

    @Test func aPostWithoutAnEmbedOrWithAnUnknownOneHasNone() {
        var view = Post_V1_PostView()
        view.caption = "Just words"
        #expect(PostEmbedWire.embed(in: view) == nil)
        #expect(PostEmbedWire.decode("cpembed://v1/quote?p=post-1") == nil, "a later case read as something")
        #expect(PostEmbedWire.decode("cpembed://v1/channel?n=No+id") == nil, "a channel with no id")
        #expect(PostEmbedWire.decode("cpvoice://v1?d=3") == nil)
    }

    @Test func anUnknownStateReadsAsAStrangersCard() throws {
        let embed = try #require(PostEmbedWire.decode("cpembed://v1/channel?c=ch-x&vs=moderator&a=archived&v=secret"))
        #expect(embed.channel?.viewerState == ChannelEmbed.ViewerState.none)
        #expect(embed.channel?.availability == .available)
        #expect(embed.channel?.visibility == .onRequest)
    }
}
