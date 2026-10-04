import UIKit

/// The text size the app draws, decided in one place (#482, 2026-10-04):
/// the iPhone's own setting, raised to Extra Large while Care Mode is on,
/// and never larger than XXXL, the largest standard size (body 23 pt).
///
/// Why a ceiling: beyond XXXL, a screen this dense — full-bleed media, glass
/// pills, bars over the picture — breaks almost everywhere (measured at AX3,
/// body 40 pt: the profile's counters, the cards' author band, the feed's
/// pills, the appearance picker). The accessibility sizes (AX1…AX5) are
/// drawn as XXXL; AX1 was considered and set aside the same day.
///
/// How: a `preferredContentSizeCategory` trait override on each window.
/// ⚠️ `UIView.maximumContentSizeCategory` on the window was tried first and
/// changed nothing on screen (iOS 27 simulator, AX3): lists, titles and
/// labels all stayed at the system size. A trait override is what Care Mode
/// already proved to reach them. Elements in fixed chrome keep their own,
/// lower caps (`UIFont.scaledSystemFont(… maximumPointSize:)`).
public enum TextSizeCeiling {
    public static let maximum: UIContentSizeCategory = .extraExtraExtraLarge

    /// The size last applied to the windows, readable from anywhere a font is
    /// made (nil until the scene applies it, and in tests: the system size).
    nonisolated(unsafe) public private(set) static var current: UIContentSizeCategory?

    /// `current` as traits, for fonts made outside any view's traits.
    public static var currentTraits: UITraitCollection? {
        current.map { UITraitCollection(preferredContentSizeCategory: $0) }
    }

    /// The size the app draws for the iPhone's setting.
    public static func contentSize(system: UIContentSizeCategory, careMode: Bool) -> UIContentSizeCategory {
        var size = system
        if careMode, size < CareModePreference.minimumContentSize {
            size = CareModePreference.minimumContentSize
        }
        return size > maximum ? maximum : size
    }

    /// Call on every window the app creates (the scene's, App Lock's, the
    /// screen-time reminder's). Re-applied by itself when the iPhone's text
    /// size changes.
    @MainActor
    public static func apply(to windows: [UIWindow]) {
        observeSystemTextSize()
        apply(
            to: windows, system: UIApplication.shared.preferredContentSizeCategory,
            careMode: CareModePreference.isOn, recordsCurrent: !windows.isEmpty
        )
    }

    /// `recordsCurrent` false leaves `current` alone — a test overriding a
    /// throwaway window must not change the size every other suite's fonts
    /// are made at.
    @MainActor
    static func apply(to windows: [UIWindow], system: UIContentSizeCategory, careMode: Bool, recordsCurrent: Bool) {
        let target = contentSize(system: system, careMode: careMode)
        if recordsCurrent { current = target }
        for window in windows {
            if target == system {
                window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
            } else {
                window.traitOverrides.preferredContentSizeCategory = target
            }
        }
    }

    @MainActor
    static func applyToAllWindows() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            apply(to: scene.windows)
        }
    }

    /// The override is a fixed size, so a change to the iPhone's setting must
    /// recompute it.
    @MainActor private static var systemTextSizeObserver: NSObjectProtocol?

    @MainActor
    private static func observeSystemTextSize() {
        guard systemTextSizeObserver == nil else { return }
        systemTextSizeObserver = NotificationCenter.default.addObserver(
            forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { applyToAllWindows() }
        }
    }
}
