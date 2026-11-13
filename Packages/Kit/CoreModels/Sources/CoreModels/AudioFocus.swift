import Foundation

/// Who holds the sound (#2101, #2207): while a voice message records or plays,
/// everything else that makes sound pauses — the feed's audible video, the
/// sound sheet's track — and gets it back when the voice lets go.
///
/// The voice engine (VoiceKit) posts these and the players that yield
/// (MediaPlayback's `FeedSoundSession`) observe them. Neither imports the
/// other, so the names live here, once: they used to be spelled twice, and a
/// rename on one side would have silently broken the ducking (#2373).
public enum AudioFocus {
    /// A take started recording, or a voice message started playing.
    public static let voiceDidTake = Notification.Name("VoiceAudioFocus.didTake")
    /// It ended, paused or was cancelled: the others may play again.
    public static let voiceDidRelease = Notification.Name("VoiceAudioFocus.didRelease")
}
