import CoreModels
import DesignSystem
import Foundation
import VoiceKitUI

/// Voice posts (#2204) on the text page and its previews: the one switch
/// and the playback id.
public enum VoicePosts {
    /// `-voice-posts` (DEBUG) until #2210: without it a voice post is drawn
    /// as the text post it is.
    public static var areDrawn: Bool { VoicePostDisplay.areDrawn }

    /// The id a post's voice plays under (`VoicePlaybackHub`): one for the
    /// post wherever it is drawn — a card, a pin, its page — so a voice
    /// started on one goes on, at the same place, on the next.
    public static func playbackID(_ postID: PostID) -> String { VoicePlaybackHub.postID(postID.rawValue) }

    /// The longest caption the share card's text carries (#2208).
    public static let shareCaptionLimit = 80

    /// What a voice post's share says where no player is drawn (#2208): "🎙
    /// Voice post · 32″", or its words marked and cut at
    /// `shareCaptionLimit`; nil for a post that does not speak, or with the
    /// switch off. Pure.
    public static func shareText(caption: String?, voice: PostVoice?, showsVoice: Bool = areDrawn) -> String? {
        guard showsVoice, let voice else { return nil }
        let words = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shown = words.count > shareCaptionLimit ? String(words.prefix(shareCaptionLimit)) + "…" : words
        return voice.previewText(caption: shown)
    }
}
