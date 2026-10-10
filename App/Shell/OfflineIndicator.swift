import CoreNetworking
import DesignSystem
import UIKit

/// The app-wide answer to "is it me or the network?" (#793): a small glass
/// capsule under the navigation bar that reads **Offline** while the network is
/// gone, turns into **Back online** when it returns, and leaves.
///
/// One per window, above every screen and sheet, never taking a touch — it
/// states a condition; the screens beneath own what to do about it (their
/// failed states offer Try Again, and they reload on recovery).
///
/// It appears with a spring from above and leaves the same way, so the change
/// of state is felt rather than read; under Reduce Motion it cross-fades.
@MainActor
final class OfflineIndicator: UIView {
    private let backdrop = UIVisualEffectView(effect: nil)
    private let glyph = UIImageView()
    private let label = UILabel()
    nonisolated(unsafe) private var observation: NSObjectProtocol?
    private var hideWork: DispatchWorkItem?
    private var shown = false

    /// Installs the indicator above `window`, following `monitor`.
    ///
    /// ⚠️ IN ITS OWN WINDOW, a level above the app's. Added to the app window it
    /// sat under the root controller installed after it (launched offline, it
    /// never showed) and under every presented sheet. Its window takes no
    /// touch, so the app beneath stays fully usable.
    @discardableResult
    static func install(on window: UIWindow, monitor: ConnectivityMonitor = .shared) -> OfflineIndicator {
        let indicator = OfflineIndicator()
        let overlay: UIWindow = window.windowScene.map { PassthroughWindow(windowScene: $0) }
            ?? PassthroughWindow(frame: window.bounds)
        // ⚠️ A BAND, NOT THE SCREEN: a full-screen window above the app's
        // would take over the status bar's appearance (the feed's light
        // style). The band sits under the bar's row of bubbles.
        let statusBottom = window.windowScene?.statusBarManager?.statusBarFrame.maxY ?? 54
        overlay.frame = CGRect(x: 0, y: statusBottom + 50, width: window.bounds.width, height: 56)
        overlay.windowLevel = .normal + 1
        overlay.backgroundColor = .clear
        let host = UIViewController()
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        overlay.rootViewController = host
        overlay.isHidden = false
        indicator.overlay = overlay
        indicator.constrain(in: host.view) { parent in
            indicator.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            // The band is under the bar's row of bubbles; placed at the safe
            // area's top the capsule sat on the wallet badge and the search
            // button.
            indicator.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            indicator.leadingAnchor.constraint(greaterThanOrEqualTo: parent.layoutMarginsGuide.leadingAnchor)
        }
        indicator.observation = NotificationCenter.default.addObserver(
            forName: ConnectivityMonitor.didChangeNotification, object: monitor, queue: .main
        ) { [weak indicator] _ in
            MainActor.assumeIsolated { indicator?.follow(isOnline: monitor.isOnline) }
        }
        indicator.follow(isOnline: monitor.isOnline, animated: false)
        return indicator
    }

    /// The window the indicator lives in; kept alive with it.
    private var overlay: UIWindow?

    private init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        alpha = 0
        isHidden = true

        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = false
        backdrop.effect = glass
        backdrop.clipsToBounds = true
        backdrop.cornerConfiguration = .capsule()
        backdrop.isUserInteractionEnabled = false
        backdrop.pin(to: self)

        glyph.contentMode = .scaleAspectFit
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .appFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label

        let row = UIStackView(arrangedSubviews: [glyph, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.xs
        row.constrain(in: backdrop.contentView) { parent in
            row.topAnchor.constraint(equalTo: parent.topAnchor, constant: 7)
            row.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -7)
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 14)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -14)
        }
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let observation { NotificationCenter.default.removeObserver(observation) }
    }

    private func follow(isOnline: Bool, animated: Bool = true) {
        hideWork?.cancel()
        hideWork = nil
        if !isOnline {
            setContent(symbol: "wifi.slash", text: "Offline", tint: .secondaryLabel)
            UIAccessibility.post(notification: .announcement, argument: "You're offline")
            setShown(true, animated: animated)
        } else if shown {
            // The way back is part of the message: "Back online", then gone.
            setContent(symbol: "checkmark.circle.fill", text: "Back online", tint: .systemGreen)
            UIAccessibility.post(notification: .announcement, argument: "Back online")
            let work = DispatchWorkItem { [weak self] in self?.setShown(false, animated: true) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
        }
    }

    private func setContent(symbol: String, text: String, tint: UIColor) {
        let apply = {
            self.glyph.image = UIImage(systemName: symbol)
            self.glyph.tintColor = tint
            self.label.text = text
        }
        guard shown, window != nil else { return apply() }
        UIView.transition(with: self, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            apply()
        }
    }

    private func setShown(_ visible: Bool, animated: Bool) {
        guard visible != shown else { return }
        shown = visible
        let reducesMotion = UIAccessibility.isReduceMotionEnabled
        let offstage = CGAffineTransform(translationX: 0, y: -24).scaledBy(x: 0.9, y: 0.9)
        if visible {
            isHidden = false
            if !reducesMotion { transform = offstage }
        }
        let changes = {
            self.alpha = visible ? 1 : 0
            self.transform = visible || reducesMotion ? .identity : offstage
        }
        let done: (Bool) -> Void = { _ in
            guard !self.shown else { return }
            self.isHidden = true
            self.transform = .identity
        }
        guard animated else {
            changes()
            done(true)
            return
        }
        UIView.animate(
            withDuration: visible ? 0.5 : 0.35, delay: 0,
            usingSpringWithDamping: visible ? 0.8 : 1, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: changes, completion: done
        )
    }

    #if DEBUG
    var debugText: String? { isHidden ? nil : label.text }
    #endif
}

/// A window that never takes a touch: what lies beneath it gets them all.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
