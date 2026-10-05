import UIKit

/// Whether the app should keep motion to a minimum: the iOS Accessibility
/// setting, OR the app's own switch (Settings → App and Device → Display,
/// #468).
///
/// Every animation that honours Reduce Motion reads THIS, never
/// `UIAccessibility.isReduceMotionEnabled` directly — otherwise the app-level
/// switch would reach some animations and not others. Toggling the app
/// switch posts `UIAccessibility.reduceMotionStatusDidChangeNotification`, so
/// code already listening for the iOS change re-reads it with no extra wiring.
public enum MotionPreference {
    static let key = "display.reducesMotion"
    /// Swappable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// The app's own switch, independent of iOS.
    public static var appReducesMotion: Bool {
        get { defaults.bool(forKey: key) }
        set {
            guard newValue != appReducesMotion else { return }
            defaults.set(newValue, forKey: key)
            NotificationCenter.default.post(name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        }
    }

    /// What every animation asks: iOS, the app's switch, or Power Saving.
    public static var reducesMotion: Bool {
        UIAccessibility.isReduceMotionEnabled || appReducesMotion || PowerSavingPreference.isOn
    }
}

/// Settings → App and Device → Power Saving: one switch that stills animated
/// emojis, turns on Reduce Motion and stops videos from playing on their own.
///
/// It overrides rather than rewrites: the viewer's own Reduce Motion,
/// Autoplay and Animate Emojis choices are left as they were, and every
/// reader combines them with this (`MotionPreference.reducesMotion`,
/// `EmoteAnimationPreference.animatesEmotes`, the feed's autoplay policy).
/// Turning it off brings their choices back untouched.
public enum PowerSavingPreference {
    static let key = "device.powerSaving"
    /// Swappable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    public static var isOn: Bool {
        get { defaults.bool(forKey: key) }
        set {
            guard newValue != isOn else { return }
            defaults.set(newValue, forKey: key)
            let center = NotificationCenter.default
            // Everything that honours Reduce Motion already listens for this.
            center.post(name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
            center.post(name: .emoteAnimationPreferenceDidChange, object: nil)
            center.post(name: .powerSavingPreferenceDidChange, object: nil)
        }
    }
}

/// Settings → App and Device → Emojis: whether emojis and stickers in text
/// play their animation. Off, they stay on their still frame.
public enum EmoteAnimationPreference {
    static let key = "display.animatesEmotes"
    /// Swappable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// The viewer's own switch; on until they turn it off.
    public static var isOn: Bool {
        get { defaults.object(forKey: key) as? Bool ?? true }
        set {
            guard newValue != isOn else { return }
            defaults.set(newValue, forKey: key)
            NotificationCenter.default.post(name: .emoteAnimationPreferenceDidChange, object: nil)
        }
    }

    /// What an emote asks: the viewer's switch, unless Power Saving is on.
    public static var animatesEmotes: Bool {
        isOn && !PowerSavingPreference.isOn
    }
}

extension Notification.Name {
    /// Posted when `EmoteAnimationPreference.animatesEmotes` may have changed.
    public static let emoteAnimationPreferenceDidChange = Notification.Name("cn.wynn.core-platform-ios.emoteAnimationPreferenceDidChange")
    /// Posted when Power Saving is switched on or off.
    public static let powerSavingPreferenceDidChange = Notification.Name("cn.wynn.core-platform-ios.powerSavingPreferenceDidChange")
}

/// Light, dark, or following iOS — for the whole app (Settings → App and
/// Device → Display, #468). Applied as `overrideUserInterfaceStyle` on every
/// window: at launch by the scene, and live when the viewer changes it.
public enum AppearancePreference: String, CaseIterable, Sendable {
    case system, light, dark

    static let key = "display.appearance"
    /// Swappable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    public static var current: AppearancePreference {
        get { defaults.string(forKey: key).flatMap(AppearancePreference.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }

    public var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The SF Symbol drawn above the choice in Settings → Display.
    public var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    /// Stores the choice and applies it to every window of every connected
    /// scene, so the change shows at once.
    @MainActor
    public static func set(_ appearance: AppearancePreference) {
        current = appearance
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            apply(to: scene.windows)
        }
    }

    /// Applies the stored choice to `windows` (the scene calls this at launch).
    @MainActor
    public static func apply(to windows: [UIWindow]) {
        let style = current.interfaceStyle
        for window in windows {
            window.overrideUserInterfaceStyle = style
        }
    }
}
