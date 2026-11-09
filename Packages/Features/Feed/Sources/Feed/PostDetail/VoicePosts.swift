import CoreModels
import DesignSystem
import Foundation
import VoiceKitUI

/// Voice posts (#2204) on the text page and its previews: the one switch
/// and the playback id.
public enum VoicePosts {
    /// `-voice-posts` (DEBUG) until #2210: without it a voice post is drawn
    /// as the text post it is.
    public static var areDrawn: Bool { DebugFlags.isOn("-voice-posts") }

    /// The id a post's voice plays under (`VoicePlaybackHub`): one for the
    /// post wherever it is drawn — a card, a pin, its page — so a voice
    /// started on one goes on, at the same place, on the next.
    public static func playbackID(_ postID: PostID) -> String { "post-\(postID.rawValue)" }
}
