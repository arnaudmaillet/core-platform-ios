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

    /// What every animation asks.
    public static var reducesMotion: Bool {
        UIAccessibility.isReduceMotionEnabled || appReducesMotion
    }
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
