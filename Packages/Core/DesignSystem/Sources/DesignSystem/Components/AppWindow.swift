import UIKit

/// Every window the app makes (#1145): the main one, App Lock's, Screen
/// Time's reminder, the toast overlay — and any window added later.
///
/// It carries the app's bar tap shield (`BarTapShield`, #562): a tap that
/// starts in a bar's area over the content reaches nothing behind it. And it
/// draws in the app's accent theme from its first frame (#1379). A window
/// made any other way would not, and nothing on screen would say so, so
/// `AppWindowGuardTests` fails on a `UIWindow` built or subclassed anywhere
/// but here.
open class AppWindow: UIWindow {
    override public init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        addGestureRecognizer(BarTapShield())
        // The app's accent theme (#1379), before the first frame.
        traitOverrides.accentTheme = AccentThemePreference.applied
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(BarTapShield())
        traitOverrides.accentTheme = AccentThemePreference.applied
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether this window carries the shield — what the tests read.
    public var carriesBarTapShield: Bool {
        gestureRecognizers?.contains { $0 is BarTapShield } ?? false
    }
}
