import CoreStorage
import DesignSystem
import UIKit

/// Counts time in the app and raises the daily-limit and break reminders
/// (Settings → Your Activity → Time Management, #489), on the scene's
/// lifecycle:
///
/// - **active**: a stretch of use starts; the next reminder is scheduled;
/// - **resign active**: the stretch is written to the ledger and every timer
///   stops — nothing runs while the app isn't in front of the viewer.
///
/// Time is flushed to the ledger every half minute while active, so Settings
/// reads a current total. Reminders show in their own window, above the app
/// and below App Lock's.
@MainActor
final class ScreenTimeCoordinator {
    private let scene: UIWindowScene
    private let mainWindow: UIWindow
    private let store: ScreenTimeStore
    private let calendar: Calendar
    private let now: () -> Date

    /// When the current stretch of use began, nil while inactive.
    private var activeSince: Date?
    /// The last time written to the ledger.
    private var lastFlush: Date?
    /// The last break reminder, which restarts the continuous-use clock.
    private var lastBreakAt: Date?
    private var reminderTimer: Timer?
    private var flushTimer: Timer?
    private var reminderWindow: UIWindow?
    private var settingsObserver: NSObjectProtocol?

    static let flushInterval: TimeInterval = 30

    init(
        scene: UIWindowScene,
        mainWindow: UIWindow,
        store: ScreenTimeStore = .standard,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.scene = scene
        self.mainWindow = mainWindow
        self.store = store
        self.calendar = calendar
        self.now = now
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .screenTimeSettingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule() }
        }
    }

    func sceneDidBecomeActive() {
        guard activeSince == nil else { return }
        let start = now()
        activeSince = start
        lastFlush = start
        lastBreakAt = nil
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        reschedule()
    }

    func sceneWillResignActive() {
        flush()
        activeSince = nil
        lastFlush = nil
        flushTimer?.invalidate()
        flushTimer = nil
        reminderTimer?.invalidate()
        reminderTimer = nil
    }

    private func flush() {
        guard let from = lastFlush else { return }
        let to = now()
        store.record(from: from, to: to, calendar: calendar)
        lastFlush = to
    }

    /// Schedules one timer for the next reminder due, if any.
    private func reschedule() {
        reminderTimer?.invalidate()
        reminderTimer = nil
        guard let activeSince, reminderWindow == nil else { return }
        flush()
        let current = now()
        guard let next = ScreenTimeSchedule.next(
            settings: store.settings,
            usedToday: store.ledger.seconds(on: current, calendar: calendar),
            continuousSince: max(activeSince, lastBreakAt ?? activeSince),
            now: current,
            state: store.reminderState,
            todayKey: ScreenTimeLedger.key(for: current, calendar: calendar)
        ) else { return }
        let delay = next.at.timeIntervalSince(current)
        if delay <= 0.5 {
            present(next.reminder)
            return
        }
        // A timer fires late rather than early, and re-checks on fire: a day
        // that rolled over or a setting changed meanwhile is caught there.
        reminderTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule() }
        }
    }

    private func present(_ reminder: ScreenTimeReminder) {
        let current = now()
        let usedToday = store.ledger.seconds(on: current, calendar: calendar)
        let controller: ScreenTimeReminderViewController
        switch reminder {
        case .dailyLimit:
            let limit = TimeInterval((store.settings.dailyLimitMinutes ?? 0) * 60)
            controller = .dailyLimit(used: usedToday, limit: limit) { [weak self] choice in
                self?.resolveDailyLimit(choice)
            }
        case .takeABreak:
            let since = max(activeSince ?? current, lastBreakAt ?? .distantPast)
            controller = .takeABreak(continuous: current.timeIntervalSince(since)) { [weak self] in
                self?.lastBreakAt = self?.now()
                self?.dismissReminder()
            }
        }
        let window = UIWindow(windowScene: scene)
        // Above the app's sheets and alerts, below App Lock's `.alert + 1`.
        window.windowLevel = .alert
        window.overrideUserInterfaceStyle = mainWindow.overrideUserInterfaceStyle
        // The app's text size and Care Mode's bold text, like every window.
        CareModePreference.apply(to: [window])
        window.rootViewController = controller
        window.makeKeyAndVisible()
        reminderWindow = window
        HapticNotification().notificationOccurred(.warning)
    }

    private func resolveDailyLimit(_ choice: ScreenTimeReminderViewController.LimitChoice) {
        let current = now()
        store.updateReminderState { state in
            switch choice {
            case .remindLater:
                state.limitSnoozedUntil = current.addingTimeInterval(TimeInterval(ScreenTimeSettings.snoozeMinutes * 60))
            case .ignoreToday:
                state.limitIgnoredDay = ScreenTimeLedger.key(for: current, calendar: calendar)
            }
        }
        dismissReminder()
    }

    private func dismissReminder() {
        reminderWindow?.isHidden = true
        reminderWindow = nil
        mainWindow.makeKey()
        reschedule()
    }

    #if DEBUG
    /// `-screen-time-seed <minutes>`: today's ledger starts with this much
    /// time, so the limit can be reached in a QA run.
    static func applyDebugSeed(store: ScreenTimeStore = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let index = arguments.firstIndex(of: "-screen-time-seed"), index + 1 < arguments.count,
              let minutes = Double(arguments[index + 1])
        else { return }
        let end = Date()
        store.record(from: end.addingTimeInterval(-minutes * 60), to: end)
        store.updateReminderState { $0 = ScreenTimeReminderState() }
    }
    #endif
}

/// The reminder itself: an hourglass, what happened, and what the viewer can
/// do about it. iOS gives an app no way to close itself, so the choices are
/// about when to be reminded again.
final class ScreenTimeReminderViewController: UIViewController {
    enum LimitChoice { case remindLater, ignoreToday }

    private let titleText: String
    private let bodyText: String
    private let actions: [(title: String, prominent: Bool, handler: () -> Void)]

    private init(title: String, body: String, actions: [(title: String, prominent: Bool, handler: () -> Void)]) {
        titleText = title
        bodyText = body
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func dailyLimit(used: TimeInterval, limit: TimeInterval, onChoice: @escaping (LimitChoice) -> Void) -> ScreenTimeReminderViewController {
        ScreenTimeReminderViewController(
            title: "You've reached today's limit",
            body: "You've spent \(ScreenTimeLedger.durationText(used)) in the app today. "
                + "Your daily limit is \(ScreenTimeLedger.durationText(limit)). "
                + "You can change it in Settings → Your Activity.",
            actions: [
                ("Remind Me in \(ScreenTimeSettings.snoozeMinutes) Minutes", true, { onChoice(.remindLater) }),
                ("Ignore Limit for Today", false, { onChoice(.ignoreToday) })
            ]
        )
    }

    static func takeABreak(continuous: TimeInterval, onDismiss: @escaping () -> Void) -> ScreenTimeReminderViewController {
        ScreenTimeReminderViewController(
            title: "Time for a break?",
            body: "You've been scrolling for \(ScreenTimeLedger.durationText(continuous)). "
                + "Look away from the screen for a moment, stretch, have some water.",
            actions: [("OK", true, onDismiss)]
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityViewIsModal = true

        let icon = UIImageView(image: UIImage(systemName: "hourglass"))
        icon.tintColor = .label
        icon.preferredSymbolConfiguration = .init(textStyle: .largeTitle, scale: .large)

        let title = UILabel()
        title.text = titleText
        title.font = .scaledFont(forTextStyle: .title1, weight: .bold)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        title.numberOfLines = 0

        let body = UILabel()
        body.text = bodyText
        body.font = .appFont(forTextStyle: .body)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = .secondaryLabel
        body.textAlignment = .center
        body.numberOfLines = 0

        let buttons = actions.map { action in
            var configuration: UIButton.Configuration = action.prominent ? .filled() : .plain()
            configuration.title = action.title
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .large
            let button = UIButton(configuration: configuration)
            button.addAction(UIAction { _ in action.handler() }, for: .primaryActionTriggered)
            return button
        }

        let text = UIStackView(arrangedSubviews: [icon, title, body])
        text.axis = .vertical
        text.alignment = .center
        text.spacing = 16
        let buttonStack = UIStackView(arrangedSubviews: buttons)
        buttonStack.axis = .vertical
        buttonStack.spacing = 8
        let stack = UIStackView(arrangedSubviews: [text, buttonStack])
        stack.axis = .vertical
        stack.spacing = 40
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -32),
            // Centred on screen; at large text sizes the content outgrows the
            // screen and scrolls instead of clipping the buttons.
            stack.centerYAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            scroll.contentLayoutGuide.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
                .withPriority(.defaultLow)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: titleText)
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
