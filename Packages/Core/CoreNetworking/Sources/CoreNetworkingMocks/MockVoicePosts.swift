import CoreModels
import CoreNetworking
import Foundation
import SwiftProtobuf

/// The seeded voice posts (#2206): about one TEXT post in five speaks —
/// half of them with their text kept under the voice, half voice alone —
/// spread over the timeline, For You, profiles and the map, as every one of
/// them reads posts from the dataset.
///
/// Picked by the post's rank among the dataset's text posts — every fifth,
/// the voices taken in turn, text kept on every other one — so exactly one
/// in five speaks, short and long alike, on every launch and in every
/// service. Media posts never speak: a voice is a text post's caption
/// (#2204).
extension MockSocialDataset {
    /// The voice post `postID` carries, and whether its text stays, or nil.
    public func seededVoice(forPostID postID: String) -> (voice: PostVoice, keepsText: Bool)? {
        guard let rank = posts.lazy.filter({ $0.media == nil }).map(\.postID).firstIndex(of: postID) else { return nil }
        return Self.seededVoice(rank: rank)
    }

    /// The pick itself, for the text post at `rank`.
    static func seededVoice(rank: Int) -> (voice: PostVoice, keepsText: Bool)? {
        guard rank % 5 == 2 else { return nil }
        let turn = rank / 5
        let ids = MockVoiceCatalog.postVoiceIDs
        guard let voice = MockVoiceCatalog.shared.postVoice(id: ids[turn % ids.count]) else { return nil }
        return (voice, turn % 2 == 0)
    }
}

extension MockVoiceCatalog {
    /// Voice `id` as a post carries it (#2206): its bundled file, its length,
    /// its waveform.
    public func postVoice(id: String) -> PostVoice? {
        guard let voice = voice(id: id) else { return nil }
        return PostVoice(
            assetID: voice.id,
            url: fileURL(voiceID: id),
            duration: voice.duration,
            waveform: PostVoiceWire.levels(voice.waveform)
        )
    }
}
