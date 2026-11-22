import UIKit

/// Hears the DEVICE's appearance on a window (#2521): the one place it arrives
/// unpinned while a screen or a page pins a style of its own. Re-registers
/// when the window changes, and only then. The screen's
/// `SnapDeviceAppearanceWatch` and each `SnapFeedCell` listen through one.
@MainActor
final class SnapWindowAppearanceWatch {
    private let onChange: () -> Void
    private weak var appearanceWindow: UIWindow?
    private var appearanceRegistration: (any UITraitChangeRegistration)?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Listens on `window` from now on.
    func observe(_ window: UIWindow?) {
        guard appearanceWindow !== window else { return }
        if let registration = appearanceRegistration {
            appearanceWindow?.unregisterForTraitChanges(registration)
            appearanceRegistration = nil
        }
        appearanceWindow = window
        appearanceRegistration = window?.registerForTraitChanges(
            [UITraitUserInterfaceStyle.self]
        ) { [weak self] (_: UIWindow, _: UITraitCollection) in
            self?.onChange()
        }
    }
}
