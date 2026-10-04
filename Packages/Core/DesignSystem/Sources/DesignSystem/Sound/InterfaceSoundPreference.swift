import Foundation

/// Whether the app plays its own interface sounds — the pop of an element
/// arriving, the tap of a press, the click of an emote pick (Settings → App
/// and Device → Playback and Sound, #471). On by default.
///
/// Not the sound of videos and posts: that is the feed's own switch (Start
/// with Sound and the mute button, #409). And the silent switch still wins
/// underneath: `UISound` inherits the shared `.ambient` session, so a phone
/// on silent stays silent whatever this says.
public enum InterfaceSoundPreference {
    static let key = "sound.interfaceSounds"
    /// Swappable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    public static var isOn: Bool {
        get { defaults.object(forKey: key) as? Bool ?? true }
        set { defaults.set(newValue, forKey: key) }
    }
}
