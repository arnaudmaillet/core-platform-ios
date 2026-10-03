import CoreStorage
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
///
/// Where the session STARTS is the viewer's "Start with sound" preference
/// (Settings → App Preferences, #409). Changing that preference mid-session
/// resets the session to it: the newest choice wins.
@MainActor
enum FeedSound {
    /// The session's own choice, once the mute button was used; nil follows
    /// the preference.
    private static var sessionChoice: Bool?

    static var isOn: Bool {
        _ = preferenceObservation
        return sessionChoice ?? MediaPlaybackPolicy.store.preferences.startsWithSound
    }

    static func toggle() {
        sessionChoice = !isOn
    }

    /// Created on first read: a new preference drops the session's choice.
    private static let preferenceObservation: NotificationObservation = {
        let observation = NotificationObservation()
        observation.token = NotificationCenter.default.addObserver(
            forName: .mediaPlaybackPreferencesDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { sessionChoice = nil }
        }
        return observation
    }()

    #if DEBUG
    /// Tests start from the shipped default.
    static func reset() { sessionChoice = nil }
    #endif
}
