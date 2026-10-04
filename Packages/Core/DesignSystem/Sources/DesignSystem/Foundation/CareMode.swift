import UIKit

/// Settings → App and Device → Display → Care Mode (#482): larger, bolder
/// text across the app, for viewers who find the default hard to read.
///
/// Applied as window trait overrides, so every list, title and label that
/// follows Dynamic Type grows with it (a font set once without
/// `adjustsFontForContentSizeCategory` does not). It never shrinks anything:
/// when the iPhone's own text size is already larger than Care Mode's floor,
/// that size wins. Stored on this iPhone.
public enum CareModePreference {
    static let key = "display.careMode"
    /// Swappable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// The smallest text size Care Mode allows.
    public static let minimumContentSize: UIContentSizeCategory = .extraLarge

    public static var isOn: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }

    /// The text size the app uses: the iPhone's, raised to at least
    /// `minimumContentSize` while Care Mode is on.
    public static func contentSize(system: UIContentSizeCategory, isOn: Bool) -> UIContentSizeCategory {
        guard isOn else { return system }
        return system > minimumContentSize ? system : minimumContentSize
    }

    /// Stores the choice and applies it to every window of every connected
    /// scene, so the change shows at once.
    @MainActor
    public static func set(_ isOn: Bool) {
        self.isOn = isOn
        applyToAllWindows()
    }

    /// Applies the stored choice to `windows` (the scene calls this at
    /// launch; a window created later calls it for itself).
    @MainActor
    public static func apply(to windows: [UIWindow]) {
        observeSystemTextSize()
        let system = UIApplication.shared.preferredContentSizeCategory
        for window in windows {
            if isOn {
                window.traitOverrides.preferredContentSizeCategory = contentSize(system: system, isOn: true)
                window.traitOverrides.legibilityWeight = .bold
            } else {
                window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
                window.traitOverrides.remove(UITraitLegibilityWeight.self)
            }
        }
    }

    @MainActor
    private static func applyToAllWindows() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            apply(to: scene.windows)
        }
    }

    /// The override is a fixed size, so a change to the iPhone's text size
    /// must recompute it: a larger system size has to win again.
    @MainActor private static var systemTextSizeObserver: NSObjectProtocol?

    @MainActor
    private static func observeSystemTextSize() {
        guard systemTextSizeObserver == nil else { return }
        systemTextSizeObserver = NotificationCenter.default.addObserver(
            forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if isOn { applyToAllWindows() }
            }
        }
    }
}
