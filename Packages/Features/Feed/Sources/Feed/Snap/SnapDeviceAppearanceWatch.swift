import CoreModels
import UIKit

/// What watching the device's appearance asks of the screen (#2514): its
/// view's window, the text pages built ahead, and the device's style.
@MainActor
protocol SnapDeviceAppearanceWatchHost: UIViewController {
    var restingWarm: SnapWarmSlots<PostID, UIViewController> { get }
    /// The theme the DEVICE is in, read off the window.
    var deviceInterfaceStyle: UIUserInterfaceStyle { get }
}

/// Hears the device's appearance on the screen's window (#2514), for the one
/// thing the screen styles with it explicitly: the text pages built ahead,
/// re-styled before they mount.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: `viewDidAppear` registers it in its turn,
/// where it did before.
@MainActor
final class SnapDeviceAppearanceWatch {
    private unowned let host: any SnapDeviceAppearanceWatchHost

    init(host: any SnapDeviceAppearanceWatchHost) {
        self.host = host
    }

    /// Where the device's appearance is heard, for the one thing this screen
    /// styles with it explicitly — the text page built ahead of time
    /// (`prewarmRestingComments`). The pages themselves listen on their own
    /// (`SnapFeedCell.observeDeviceAppearance`, whose note says why it has to
    /// be the WINDOW); the bars need nothing, since a text page leaves them
    /// `.unspecified` and a media page pins them dark whatever the device says.
    private weak var appearanceWindow: UIWindow?
    private var appearanceRegistration: (any UITraitChangeRegistration)?

    func observeDeviceAppearance() {
        guard appearanceWindow !== host.view.window else { return }
        if let registration = appearanceRegistration {
            appearanceWindow?.unregisterForTraitChanges(registration)
            appearanceRegistration = nil
        }
        appearanceWindow = host.view.window
        appearanceRegistration = host.view.window?.registerForTraitChanges(
            [UITraitUserInterfaceStyle.self]
        ) { [weak self] (_: UIWindow, _: UITraitCollection) in
            self?.deviceAppearanceDidChange()
        }
    }

    /// A panel built ahead in the device's old style would otherwise arrive
    /// in it and turn over at the mount, in front of the viewer — the one
    /// thing building ahead exists to prevent. A handed-over loading page
    /// already inherits (`.unspecified`) and is left alone.
    private func deviceAppearanceDidChange() {
        for warmed in host.restingWarm.values where warmed.overrideUserInterfaceStyle != .unspecified {
            warmed.overrideUserInterfaceStyle = host.deviceInterfaceStyle
        }
    }
}
