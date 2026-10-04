import UIKit

/// Settings → App and Device → Display → Care Mode (#482): larger, bolder
/// text across the app, for viewers who find the default hard to read.
///
/// The larger text is `TextSizeCeiling`'s job (it raises the size to Extra
/// Large while this is on, under the app's XXXL ceiling); this adds bold text
/// with a `legibilityWeight` trait override. It never shrinks anything: when
/// the iPhone's own text size is already larger than Care Mode's floor, that
/// size wins. Stored on this iPhone.
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

    /// The text size the app uses for the iPhone's: raised to at least
    /// `minimumContentSize` while Care Mode is on, never above the ceiling.
    public static func contentSize(system: UIContentSizeCategory, isOn: Bool) -> UIContentSizeCategory {
        TextSizeCeiling.contentSize(system: system, careMode: isOn)
    }

    /// Stores the choice and applies it to every window of every connected
    /// scene, so the change shows at once.
    @MainActor
    public static func set(_ isOn: Bool) {
        self.isOn = isOn
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            apply(to: scene.windows)
        }
    }

    /// Applies the stored choice to `windows` (the scene calls this at
    /// launch; a window created later calls it for itself). Covers the text
    /// size too, through `TextSizeCeiling`.
    @MainActor
    public static func apply(to windows: [UIWindow]) {
        applyWeight(to: windows, isOn: isOn)
        TextSizeCeiling.apply(to: windows)
    }

    @MainActor
    static func applyWeight(to windows: [UIWindow], isOn: Bool) {
        for window in windows {
            if isOn {
                window.traitOverrides.legibilityWeight = .bold
            } else {
                window.traitOverrides.remove(UITraitLegibilityWeight.self)
            }
        }
    }
}
