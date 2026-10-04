import UIKit

/// Whether the app vibrates (Settings → App and Device → Playback and Sound
/// → Haptics, #470). On by default. iOS's own System Haptics setting still
/// applies underneath: off there, nothing vibrates whatever this says.
public enum HapticPreference {
    static let key = "sound.haptics"
    /// Swappable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    public static var isOn: Bool {
        get { defaults.object(forKey: key) as? Bool ?? true }
        set { defaults.set(newValue, forKey: key) }
    }
}

// The app's ONLY feedback generators. Each one wraps UIKit's and has exactly
// its API, so a call site keeps its style, its intensity and — for a stored
// generator — its `prepare()` warm-up (a generator built inside the handler
// arrives cold and fires late; see `StraightenDialView`). What they add is
// the one check: nothing fires, and nothing warms, while Haptics is off.
//
// ⚠️ NEVER USE A `UI…FeedbackGenerator` DIRECTLY. `HapticsCallSiteTests`
// fails the build of the suite if one appears outside this file, because a
// switch honoured by 40 call sites and ignored by the 41st is a broken switch.

/// `UIImpactFeedbackGenerator`, behind the Haptics switch.
@MainActor
public final class HapticImpact {
    private let generator: UIImpactFeedbackGenerator

    public init(style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        generator = UIImpactFeedbackGenerator(style: style)
    }

    public func prepare() {
        guard HapticPreference.isOn else { return }
        generator.prepare()
    }

    public func impactOccurred() {
        guard HapticPreference.isOn else { return }
        generator.impactOccurred()
    }

    public func impactOccurred(intensity: CGFloat) {
        guard HapticPreference.isOn else { return }
        generator.impactOccurred(intensity: intensity)
    }
}

/// `UISelectionFeedbackGenerator`, behind the Haptics switch.
@MainActor
public final class HapticSelection {
    private let generator = UISelectionFeedbackGenerator()

    public init() {}

    public func prepare() {
        guard HapticPreference.isOn else { return }
        generator.prepare()
    }

    public func selectionChanged() {
        guard HapticPreference.isOn else { return }
        generator.selectionChanged()
    }
}

/// `UINotificationFeedbackGenerator`, behind the Haptics switch.
@MainActor
public final class HapticNotification {
    private let generator = UINotificationFeedbackGenerator()

    public init() {}

    public func prepare() {
        guard HapticPreference.isOn else { return }
        generator.prepare()
    }

    public func notificationOccurred(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard HapticPreference.isOn else { return }
        generator.notificationOccurred(type)
    }
}
