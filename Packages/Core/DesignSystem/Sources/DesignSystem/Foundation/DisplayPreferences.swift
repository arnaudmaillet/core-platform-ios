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

    /// What every animation asks: iOS, the app's switch, or Low Power Mode
    /// followed (#1808).
    public static var reducesMotion: Bool {
        UIAccessibility.isReduceMotionEnabled || appReducesMotion || LowPowerMode.savesBattery
    }
}

/// Settings → App and Device → Follow Low Power Mode (#1808, the owner
/// 2026-10-28; replacing #527/#580's Power Saving): while the iPhone is in
/// Low Power Mode, emojis stay still, Reduce Motion is on, videos in grids and
/// previews don't play on their own, the feed's song is off and Don't Cover
/// People pauses. On by default; off, someone who keeps Low Power Mode on all
/// the time keeps the full app. There is no "always on": the app never turns
/// the effects on by itself.
///
/// It overrides rather than rewrites: the viewer's own Reduce Motion,
/// Autoplay and Animate Emojis choices are left as they were, and every
/// reader combines them with `savesBattery`. Low Power Mode ending, or the
/// switch going off, brings their choices back untouched.
///
/// ⚠️ ONE READ FOR EVERY VISIBLE EFFECT (`savesBattery`). The invisible
/// budgets (CacheKit's prefetch, the flight's pre-roll) follow iOS directly:
/// they change nothing the viewer sees, so the switch does not reach them.
public enum LowPowerMode {
    static let key = "device.followsLowPowerMode"
    /// Power Saving's old switch, forgotten once (`forgetPowerSaving`).
    static let powerSavingKey = "device.powerSaving"
    /// Swappable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    /// iOS's Low Power Mode. Swappable for tests.
    nonisolated(unsafe) static var system: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// The viewer's switch; on until they turn it off.
    public static var isFollowed: Bool {
        get { defaults.object(forKey: key) as? Bool ?? true }
        set {
            guard newValue != isFollowed else { return }
            defaults.set(newValue, forKey: key)
            reportIfChanged()
        }
    }

    /// What every visible effect asks: the switch on, and iOS in Low Power
    /// Mode.
    public static var savesBattery: Bool { isFollowed && system() }

    /// The effect last announced: a change is posted only when the effect
    /// itself changes — with the switch off, Low Power Mode posts nothing.
    nonisolated(unsafe) private static var announced: Bool?
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    /// Follows iOS's Low Power Mode live (the app calls it once, at start).
    ///
    /// ⚠️ iOS POSTS `NSProcessInfoPowerStateDidChange` ON AN ARBITRARY QUEUE:
    /// the change hops to the main actor before it is re-posted, because the
    /// observers are UIKit views.
    @MainActor
    public static func startFollowingSystem(center: NotificationCenter = .default) {
        guard observer == nil else { return }
        announced = savesBattery
        observer = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in
            Task { @MainActor in reportIfChanged() }
        }
    }

    /// Re-posts the three notifications every existing observer listens for
    /// when the effect changed, so each re-reads with no new wiring.
    static func reportIfChanged() {
        let now = savesBattery
        guard now != announced else { return }
        announced = now
        let center = NotificationCenter.default
        // Everything that honours Reduce Motion already listens for this.
        center.post(name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        center.post(name: .emoteAnimationPreferenceDidChange, object: nil)
        center.post(name: .lowPowerModeEffectDidChange, object: nil)
    }

    /// Forgets Power Saving's stored switch (#1808): a viewer who had it on
    /// now gets the effects only in Low Power Mode, the owner's intent.
    public static func forgetPowerSaving() {
        defaults.removeObject(forKey: powerSavingKey)
    }

    #if DEBUG
    /// Tests only: forgets what was announced, so the next change posts.
    static func resetAnnounced() { announced = nil }

    nonisolated(unsafe) private static var simulatedOn = false

    /// QA only (`-simulate-low-power-mode <seconds>`): the simulator has no
    /// Low Power Mode to turn on, so iOS's state is played instead. It flips
    /// every `period` seconds, starting off, and each flip is posted as iOS
    /// posts it — off main — so the live path is the real one. Call before
    /// `startFollowingSystem`.
    @MainActor
    public static func simulateSystem(flippingEvery period: TimeInterval, center: NotificationCenter = .default) {
        simulatedOn = false
        system = { simulatedOn }
        Timer.scheduledTimer(withTimeInterval: period, repeats: true) { _ in
            simulatedOn.toggle()
            DispatchQueue.global().async {
                center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            }
        }
    }
    #endif
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

    /// What an emote asks: the viewer's switch, unless Low Power Mode is
    /// followed (#1808).
    public static var animatesEmotes: Bool {
        isOn && !LowPowerMode.savesBattery
    }
}

extension Notification.Name {
    /// Posted when `EmoteAnimationPreference.animatesEmotes` may have changed.
    public static let emoteAnimationPreferenceDidChange = Notification.Name("cn.wynn.core-platform-ios.emoteAnimationPreferenceDidChange")
    /// Posted when `LowPowerMode.savesBattery` changed: Low Power Mode, or
    /// the switch that follows it (#1808).
    public static let lowPowerModeEffectDidChange = Notification.Name("cn.wynn.core-platform-ios.lowPowerModeEffectDidChange")
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
