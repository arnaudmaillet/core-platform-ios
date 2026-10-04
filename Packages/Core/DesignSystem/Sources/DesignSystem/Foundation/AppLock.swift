import LocalAuthentication
import UIKit

/// Require Face ID (or Touch ID, or the passcode) to open the app (Settings →
/// Security and Login → App Lock, #418). Stored on this iPhone.
public enum AppLockPreference {
    public enum Delay: Int, CaseIterable, Sendable {
        case immediately = 0
        case oneMinute = 60
        case fifteenMinutes = 900

        public var seconds: TimeInterval { TimeInterval(rawValue) }

        public var title: String {
            switch self {
            case .immediately: "Immediately"
            case .oneMinute: "After 1 Min"
            case .fifteenMinutes: "After 15 Min"
            }
        }
    }

    static let enabledKey = "appLock.enabled"
    static let delayKey = "appLock.delay"
    /// Swappable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    public static var isOn: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    public static var delay: Delay {
        get { Delay(rawValue: defaults.integer(forKey: delayKey)) ?? .immediately }
        set { defaults.set(newValue.rawValue, forKey: delayKey) }
    }

    /// Whether returning to the app must ask for the lock: on, and away for at
    /// least the delay. A cold launch (no background time) always locks.
    public static func shouldLock(isOn: Bool, backgroundedAt: Date?, now: Date, delay: Delay) -> Bool {
        guard isOn else { return false }
        guard let backgroundedAt else { return true }
        return now.timeIntervalSince(backgroundedAt) >= delay.seconds
    }
}

/// What the device can unlock with, and the act of unlocking. Behind a
/// protocol so the settings and the lock screen can be tested without a face.
@MainActor
public protocol DeviceAuthenticating: AnyObject {
    /// "Face ID", "Touch ID", "Optic ID", "Passcode", or nil when the device
    /// has neither biometrics nor a passcode set up.
    func availableMethod() -> String?
    func authenticate(reason: String) async -> Bool
}

/// `LAContext` with `.deviceOwnerAuthentication`: biometrics first, the
/// passcode as the fallback iOS offers.
@MainActor
public final class DeviceAuthenticator: DeviceAuthenticating {
    public init() {}

    public func availableMethod() -> String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// The screen over the app while it is locked: the app's name, a lock, and
/// one button that asks iOS for Face ID / the passcode. It asks once on its
/// own when it appears, the way banking apps do.
public final class AppLockViewController: UIViewController {
    private let authenticator: any DeviceAuthenticating
    private let onUnlock: () -> Void
    private let button = UIButton(configuration: .filled())
    private var isAuthenticating = false
    private var hasAutoPrompted = false

    public init(authenticator: any DeviceAuthenticating, onUnlock: @escaping () -> Void) {
        self.authenticator = authenticator
        self.onUnlock = onUnlock
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
        lock.tintColor = .label
        lock.preferredSymbolConfiguration = .init(pointSize: 44, weight: .semibold)

        let title = UILabel()
        title.text = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "App"
        title.font = .appFont(forTextStyle: .title2).withTraits(.traitBold)
        title.adjustsFontForContentSizeCategory = true

        let subtitle = UILabel()
        subtitle.text = "Locked"
        subtitle.font = .appFont(forTextStyle: .subheadline)
        subtitle.textColor = .secondaryLabel

        let method = authenticator.availableMethod() ?? "Passcode"
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Unlock with \(method)"
        configuration.cornerStyle = .capsule
        button.configuration = configuration
        button.addAction(UIAction { [weak self] _ in self?.unlock() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [lock, title, subtitle, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(32, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    /// Asks once on its own: called by the presenter once the app is active
    /// (a prompt raised while the app is still in the background is refused
    /// by iOS).
    public func promptIfNeeded() {
        guard !hasAutoPrompted else { return }
        hasAutoPrompted = true
        unlock()
    }

    private func unlock() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task { [weak self] in
            guard let self else { return }
            let unlocked = await authenticator.authenticate(reason: "Unlock the app")
            isAuthenticating = false
            if unlocked { onUnlock() }
        }
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
