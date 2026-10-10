import UIKit

/// The app's ONE way to answer an action with a toast (#804): what happened,
/// in the right place, with the right feel.
///
/// Before this, `ToastView.present` had twenty callers and each one guessed
/// its host. The guesses went wrong in the same three ways:
/// - **Under a sheet.** A toast posted onto the screen a sheet covers is drawn
///   behind the sheet: the user is told nothing. `Feedback` resolves the host
///   as the TOPMOST PRESENTED screen in the source's window, so a toast fired
///   from under a sheet shows above it.
/// - **No failure style.** A failure looked exactly like a success, with a
///   different glyph the eye does not read. `failure` tints its glyph red.
/// - **No haptic.** A toast is for results that are off-screen or easy to
///   miss, which is exactly when the hand should feel the answer too. Each
///   kind pairs its notification haptic, through `HapticNotification`, so the
///   Haptics switch (#470) is honoured.
///
/// Wording (the toast's own rule): short, past tense for a result, no
/// trailing period — "Copied", "Report sent", "Couldn't follow @ava".
///
/// ⚠️ NEVER CALL `ToastView.present` DIRECTLY. `FeedbackTests` scans the
/// sources and fails if anything but this file does: a presenter honoured by
/// nineteen call sites and bypassed by the twentieth is back to guessing.
@MainActor
public enum Feedback {
    /// What a toast reports. Each kind owns its toast style and its haptic.
    public enum Kind: Sendable {
        /// The action happened.
        case success
        /// The action did not happen — rolled back, refused, or failed.
        case failure
        /// Neither: a neutral notice ("Hidden from this feed"). No haptic —
        /// nothing succeeded or failed, so the hand has nothing to learn.
        case info

        var style: ToastView.Style { self == .failure ? .failure : .confirmation }

        /// The notification haptic the toast arrives with, if any.
        public var haptic: UINotificationFeedbackGenerator.FeedbackType? {
            switch self {
            case .success: .success
            case .failure: .error
            case .info: nil
            }
        }

        /// The glyph a toast of this kind leads with unless told otherwise.
        public var defaultSymbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .failure: "exclamationmark.triangle.fill"
            case .info: "info.circle.fill"
            }
        }
    }

    /// The action happened: a confirmation toast and a success haptic.
    ///
    /// - Parameters:
    ///   - source: the screen the action was taken on. The toast goes to the
    ///     topmost presented screen over it, or to `source` itself when
    ///     nothing covers it (see `host(for:)`).
    ///   - floor: what the capsule stands on instead of the safe area — the
    ///     top of a composer resting there (#729). Only used when the toast
    ///     lands on `source` itself: on a sheet above it, the floor belongs to
    ///     a screen that is no longer in view.
    @discardableResult
    public static func success(
        _ message: String,
        symbol: String? = Kind.success.defaultSymbol,
        from source: UIViewController,
        above floor: NSLayoutYAxisAnchor? = nil
    ) -> ToastView {
        show(.success, message, symbol: symbol, from: source, above: floor)
    }

    /// The action did not happen: a failure-style toast and an error haptic.
    @discardableResult
    public static func failure(
        _ message: String,
        symbol: String? = Kind.failure.defaultSymbol,
        from source: UIViewController,
        above floor: NSLayoutYAxisAnchor? = nil
    ) -> ToastView {
        show(.failure, message, symbol: symbol, from: source, above: floor)
    }

    /// A neutral notice: a confirmation-style toast, no haptic.
    @discardableResult
    public static func info(
        _ message: String,
        symbol: String? = Kind.info.defaultSymbol,
        from source: UIViewController,
        above floor: NSLayoutYAxisAnchor? = nil
    ) -> ToastView {
        show(.info, message, symbol: symbol, from: source, above: floor)
    }

    /// Plays a kind's haptic. Swappable so a test can see which one played
    /// without a device; always restored by the test that swaps it.
    static var playHaptic: (UINotificationFeedbackGenerator.FeedbackType) -> Void = { type in
        notifier.notificationOccurred(type)
    }

    /// One generator for the app's lifetime: built once, so it is not cold
    /// every time (see `HapticNotification`).
    private static let notifier = HapticNotification()

    private static func show(
        _ kind: Kind,
        _ message: String,
        symbol: String?,
        from source: UIViewController,
        above floor: NSLayoutYAxisAnchor?
    ) -> ToastView {
        let host = host(for: source)
        let toast = ToastView.present(
            message,
            symbol: symbol,
            in: host.view,
            above: host === source ? floor : nil,
            style: kind.style
        )
        if let haptic = kind.haptic { playHaptic(haptic) }
        return toast
    }

    /// Where a toast from `source` is drawn.
    ///
    /// The topmost presented screen in `source`'s window — so a toast fired
    /// from a screen a sheet now covers shows on the sheet — unless `source`
    /// IS that screen or sits inside it, in which case `source` itself. That
    /// second rule matters: the window's root is the tab shell, whose view's
    /// safe area does not clear the tab bar, while the screen on top of a tab
    /// does. A screen not in a window (dismissed, popped) keeps its own view:
    /// there is nothing better to guess.
    ///
    /// The walk stops under an alert (an alert's view is not somewhere to
    /// draw) and under a screen already on its way out.
    public static func host(for source: UIViewController) -> UIViewController {
        guard let root = source.viewIfLoaded?.window?.rootViewController else { return source }
        var top = root
        while let presented = top.presentedViewController,
              !presented.isBeingDismissed,
              !(presented is UIAlertController) {
            top = presented
        }
        var ancestor: UIViewController? = source
        while let current = ancestor {
            if current === top { return source }
            ancestor = current.parent
        }
        return top
    }
}
