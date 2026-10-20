import UIKit

/// The app's accent theme (#1379, the owner 2026-10-18): pink, the default
/// and free, or violet or red, bought with gems in the Shop.
///
/// A theme changes the ACCENT roles of `Palette` — the tint, the primary
/// fills and containers, the prominent glass, the brand's accent stop — and,
/// in violet, swaps the secondary to pink. It never changes the economy's
/// colours (the likes heart stays pink, gems violet, the saved star gold),
/// the system red of errors, `entityInk`, nor `brandGradient`.
///
/// It is a TRAIT (`AccentThemeTrait`), set on every window
/// (`AccentThemePreference.apply`): the palette's roles resolve it beside
/// light/dark and Increased Contrast, so a change re-tints every dynamic
/// colour in the same frame, with no per-screen code — as an appearance
/// change does. Colours held as `CGColor` re-resolve on the trait's change
/// where they are drawn (`registerForTraitChanges`).
public enum AccentTheme: String, CaseIterable, Sendable, Codable {
    case pink, violet, red

    /// Its name, in the Shop and on the Equip screen.
    public var title: String {
        switch self {
        case .pink: "Pink"
        case .violet: "Violet"
        case .red: "Red"
        }
    }

    /// The wallet catalogue's item id (backend #946: `theme.<name>`).
    public var itemID: String { "theme.\(rawValue)" }
}

/// The accent theme as a trait: pink unless a window says otherwise.
public struct AccentThemeTrait: UITraitDefinition {
    public static let defaultValue = AccentTheme.pink
    public static let name = "AccentTheme"
    public static let affectsColorAppearance = true
}

public extension UITraitCollection {
    /// The accent theme these traits draw in.
    var accentTheme: AccentTheme { self[AccentThemeTrait.self] }
}

public extension UIMutableTraits {
    var accentTheme: AccentTheme {
        get { self[AccentThemeTrait.self] }
        set { self[AccentThemeTrait.self] = newValue }
    }
}

/// The theme the app draws in, and where it is kept (#1379).
///
/// The applied theme is a DEVICE setting, per ACCOUNT, as an alternate icon
/// is (#937): a guest is pink. Which themes an account may apply is the
/// wallet's inventory (#938), checked by the caller; DEBUG `-theme
/// pink|violet|red` applies one without owning it, for QA and screenshots.
public enum AccentThemePreference {
    static let key = "display.accentTheme"
    /// The theme last applied on this device, whoever's it was.
    static let lastAppliedKey = "display.accentTheme.lastApplied"
    /// Swappable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// Posted when the applied theme changed.
    public static let didChangeNotification = Notification.Name("accentTheme.didChange")

    /// The theme every window draws in now; new windows take it too
    /// (`AppWindow`).
    ///
    /// ⚠️ At launch it is the theme LAST APPLIED on this device: the account
    /// is known only once the session is read, after the first frame, and a
    /// violet app must not open pink and turn violet (#1379). A different
    /// viewer then applies their own (`apply`).
    @MainActor public private(set) static var applied: AccentTheme = launchOverride ?? lastApplied

    /// The theme last applied on this device; pink before any.
    static var lastApplied: AccentTheme {
        defaults.string(forKey: lastAppliedKey).flatMap(AccentTheme.init(rawValue:)) ?? .pink
    }

    /// The theme `accountID` chose on this device; pink for a guest (nil) or
    /// an account that never chose.
    public static func theme(for accountID: String?) -> AccentTheme {
        guard let accountID,
              let stored = (defaults.dictionary(forKey: key) as? [String: String])?[accountID] else { return .pink }
        return AccentTheme(rawValue: stored) ?? .pink
    }

    /// Records `theme` as `accountID`'s choice on this device.
    public static func setTheme(_ theme: AccentTheme, for accountID: String) {
        var stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        stored[accountID] = theme == .pink ? nil : theme.rawValue
        defaults.set(stored, forKey: key)
    }

    /// DEBUG `-theme pink|violet|red`: the theme a launch asks for, owned or
    /// not.
    public static var launchOverride: AccentTheme? {
        #if DEBUG
        resolve(arguments: ProcessInfo.processInfo.arguments)
        #else
        nil
        #endif
    }

    /// What `-theme` names in `arguments`, if anything.
    static func resolve(arguments: [String]) -> AccentTheme? {
        guard let index = arguments.firstIndex(of: "-theme"), index + 1 < arguments.count else { return nil }
        return AccentTheme(rawValue: arguments[index + 1])
    }

    /// Draws every window of the app in `theme` at once, with no relaunch —
    /// a DEBUG `-theme` keeps its say.
    @MainActor
    public static func apply(_ theme: AccentTheme) {
        let theme = launchOverride ?? theme
        guard theme != applied else { return }
        applied = theme
        if launchOverride == nil { defaults.set(theme.rawValue, forKey: lastAppliedKey) }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.traitOverrides.accentTheme = theme }
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
