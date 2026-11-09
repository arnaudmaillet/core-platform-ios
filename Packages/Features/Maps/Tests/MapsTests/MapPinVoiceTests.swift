import CoreContracts
import CoreModels
import CoreNetworking
import Foundation
import Testing
@testable import Maps

/// A voice post's pin (#2206) is a TEXT pin whose caption speaks.
struct MapPinVoiceTests {
    private let voice = PostVoice(assetID: "voice-short", url: nil, duration: 2.9, waveform: [])

    @Test func aTextPinCarriesItsVoice() throws {
        var radar = GeoDiscovery_V1_RadarPin()
        radar.postID = "p-voice"
        radar.lat = 48.85
        radar.lng = 2.35
        PostVoiceWire.write(voice, to: &radar)
        let pin = try #require(GeoDiscoveryRepository.makePin(from: radar))
        #expect(pin.voice == voice && pin.hasVoice)
        #expect(pin.kind == .text && pin.isText)
        // Every copy keeps it.
        #expect(pin.tagged(with: []).voice == voice)
        #expect(pin.wearing(nil).voice == voice)
        #expect(pin.showing("icon").voice == voice)
        #expect(pin.liked(4).voice == voice)
    }

    @Test func aPinWithoutAVoiceHasNone() throws {
        var radar = GeoDiscovery_V1_RadarPin()
        radar.postID = "p-text"
        let pin = try #require(GeoDiscoveryRepository.makePin(from: radar))
        #expect(pin.voice == nil && !pin.hasVoice)
    }

    @Test func thePinCacheKeepsTheVoice() throws {
        let pin = MapPin(postID: PostID("p"), latitude: 1, longitude: 2, thumbnailURL: nil, kind: .text, voice: voice)
        let record = MapPinsLocalCache.Record(pin)
        let decoded = try JSONDecoder().decode(MapPinsLocalCache.Record.self, from: try JSONEncoder().encode(record))
        #expect(decoded.pin.voice == voice)
    }
}
