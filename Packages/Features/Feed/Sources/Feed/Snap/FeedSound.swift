import Foundation

/// Whether the feed is heard: ONE answer for the session, every feed screen.
///
/// On by default, the way a short-video feed is: the post under the finger
/// plays with its sound, and the bubble beside the sound's attribution mutes
/// it. A choice made on one screen holds on the next one pushed, and resets
/// with the app — the viewer who muted in a meeting is not muted for good.
///
/// ⚠️ The ring switch still wins: the sound plays under the app's `.ambient`
/// session (`VideoPlaybackController.setAudibleSurface`), so a phone on
/// silent stays silent whatever this says.
@MainActor
enum FeedSound {
    private(set) static var isOn = true

    static func toggle() {
        isOn.toggle()
    }

    #if DEBUG
    /// Tests start from the shipped default.
    static func reset() { isOn = true }
    #endif
}
