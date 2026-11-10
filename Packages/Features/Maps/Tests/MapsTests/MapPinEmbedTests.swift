import CoreContracts
import CoreModels
import CoreNetworking
import Foundation
import Testing
@testable import Maps

/// A channel's showcase on the map (#2216): a TEXT pin carrying its card.
struct MapPinEmbedTests {
    private let embed = PostEmbed.channel(ChannelEmbed(
        conversationID: ConversationID("ch-printroom"), name: "Print room", visibility: .onRequest
    ))

    @Test func aTextPinCarriesItsEmbedThroughEveryCopy() throws {
        var radar = GeoDiscovery_V1_RadarPin()
        radar.postID = "p-showcase"
        radar.lat = 48.85
        radar.lng = 2.35
        PostEmbedWire.write(embed, to: &radar)
        let pin = try #require(GeoDiscoveryRepository.makePin(from: radar))
        #expect(pin.embed == embed)
        #expect(pin.kind == .text && pin.isText, "a showcase's pin read as media")
        #expect(pin.tagged(with: []).embed == embed)
        #expect(pin.wearing(nil).embed == embed)
        #expect(pin.showing("icon").embed == embed)
        #expect(pin.previewing(nil).embed == embed)
        #expect(pin.liked(4).embed == embed)
    }

    @Test func aPinWithACoverCarriesNoCard() throws {
        var radar = GeoDiscovery_V1_RadarPin()
        radar.postID = "p-photo"
        radar.thumbnailURL = "https://cdn.example/t.jpg"
        PostEmbedWire.write(embed, to: &radar)
        let pin = try #require(GeoDiscoveryRepository.makePin(from: radar))
        #expect(pin.embed == nil)
    }

    @Test func thePinCacheKeepsTheEmbed() throws {
        let pin = MapPin(postID: PostID("p"), latitude: 1, longitude: 2, thumbnailURL: nil, kind: .text, embed: embed)
        let record = MapPinsLocalCache.Record(pin)
        let decoded = try JSONDecoder().decode(MapPinsLocalCache.Record.self, from: try JSONEncoder().encode(record))
        #expect(decoded.pin.embed == embed)
        #expect(decoded.pin.kind == .text)
    }
}
