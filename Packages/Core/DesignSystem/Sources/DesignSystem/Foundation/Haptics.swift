import UIKit

/// Whether the app vibrates (Settings → App and Device → Playback and Sound
/// → Haptics, #470). On by default. iOS's own System Haptics setting still
/// applies underneath: off there, nothing vibrates whatever this says.
public enum HapticPreference {
    static let key = "sound.haptics"
    /// Swappable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    public static var isOn: Bool {
        get { defaults.object(forKey: key) as? Bool ?? true }
        set { defaults.set(newValue, forKey: key) }
    }
}

// The app's ONLY feedback generators. Each one wraps UIKit's and has exactly
// its API, so a call site keeps its style, its intensity and — for a stored
// generator — its `prepare()` warm-up (a generator built inside the handler
// arrives cold and fires late; see `StraightenDialView`). What they add is
// the one check: nothing fires, and nothing warms, while Haptics is off.
//
// ⚠️ NEVER USE A `UI…FeedbackGenerator` DIRECTLY. `HapticsCallSiteTests`
// fails the build of the suite if one appears outside this file, because a
// switch honoured by 40 call sites and ignored by the 41st is a broken switch.

/// `UIImpactFeedbackGenerator`, behind the Haptics switch.
@MainActor
public final class HapticImpact {
    private let generator: UIImpactFeedbackGenerator

    public init(style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        generator = UIImpactFeedbackGenerator(style: style)
    }

    public func prepare() {
        guard HapticPreference.isOn else { return }
        generator.prepare()
    }

    public func impactOccurred() {
        guard HapticPreference.isOn else { return }
        generator.impactOccurred()
    }

    public func impactOccurred(intensity: CGFloat) {
        guard HapticPreference.isOn else { return }
        generator.impactOccurred(intensity: intensity)
    }
}

/// `UISelectionFeedbackGenerator`, behind the Haptics switch.
@MainActor
public final class HapticSelection {
    private let generator = UISelectionFeedbackGenerator()

    public init() {}

    public func prepare() {
        guard HapticPreference.isOn else { return }
        generator.prepare()
    }

    public func selectionChanged() {
        guard HapticPreference.isOn else { return }
        generator.selectionChanged()
    }
}

/// `UINotificationFeedbackGenerator`, behind the Haptics switch.
@MainActor
public final class HapticNotification {
    private let generator = UINotificationFeedbackGenerator()

    public init() {}

    public func prepare() {
        guard HapticPreference.isOn else { return }
        generator.prepare()
    }

    public func notificationOccurred(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard HapticPreference.isOn else { return }
        generator.notificationOccurred(type)
    }
}

// MARK: - The haptic map (#1881)

/// THE APP'S HAPTIC VOCABULARY (#1881): a call site names the ROLE a moment
/// plays — `Haptics.play(.held)` — never a generator or a style. One table
/// (`recipe`) gives each role its generator, style and intensity, and it is
/// the only place the feel is tuned: the same moment feels the same on
/// every screen.
///
/// The rules every role keeps (Apple HIG "Playing haptics", WWDC19/21):
/// - **causality** — it answers what the viewer's finger did, at that
///   moment; never a background event, a sync, an error they did not cause;
/// - **rarely, lightly** — never on every tap, a navigation push or pop, a
///   list's scroll or its rubber band, a plain button;
/// - **never doubling the system** — context menus, `UISwitch`,
///   `UIDatePicker`, `UIPickerView` and the system slider play their own;
/// - **never the only channel** — the app reads whole with haptics off.
///
/// Silent on purpose (the owner's decisions, 2026-10-29): turning a state
/// OFF (unfollow, unlike, unbookmark, a boost's undo), tab taps and pager
/// settles, sending a message or a comment, transport controls, map taps.
public enum Haptic: Sendable, CaseIterable {
    /// A fine step under the finger: a ruler notch, the dial, the timeline,
    /// a choice in a list or a picker row.
    case tick
    /// A coarse step under the finger: a page crossed on a scrub, an emote
    /// crossing the wheel's detent, a shelf settling on a new item.
    case step
    /// A custom long press is recognised (never a context menu: it plays the
    /// system's own).
    case held
    /// A drag crosses its commit point with the finger still down — a pull,
    /// the trash, the capture lock. Once per crossing, silent on disarm.
    case armed
    /// A custom drag lifts an item: the tray, the timeline.
    case grab
    /// That item lands in a new place.
    case drop
    /// A scrub, a ruler or a dial reaches its end or its centre.
    case boundary
    /// A state the viewer adds turns on, on the control itself: follow,
    /// repost, bookmark, a comment's like. Turning it off is silent.
    case toggleOn
    /// A weighty action fires: a stake or a boost, the shutter, recording
    /// starting or stopping.
    case commit
    /// The outcome of the viewer's own action — through `Feedback`'s toasts
    /// or beside a visible message, never twice.
    case success
    case warning
    case error

    /// THE ONE TABLE: what each role plays. Each starts at today's dominant
    /// choice for its moment (#1882), so moving a call site onto a role
    /// changes the feel only where the app was inconsistent.
    public var recipe: HapticRecipe {
        switch self {
        case .tick: .selection
        // The page bar's (the owner, on a device, 2026-10-25: selection too
        // faint, medium too strong).
        case .step: .impact(.light, intensity: 1)
        case .held: .impact(.medium, intensity: 1)
        // `PullThresholdFeedback`'s.
        case .armed: .selection
        case .grab: .impact(.light, intensity: 1)
        case .drop: .impact(.soft, intensity: 1)
        case .boundary: .impact(.rigid, intensity: 0.5)
        // `Feedback.toggled`'s.
        case .toggleOn: .impact(.light, intensity: 1)
        case .commit: .impact(.medium, intensity: 1)
        case .success: .notification(.success)
        case .warning: .notification(.warning)
        case .error: .notification(.error)
        }
    }

    /// A step under the finger: paced (`Haptics.stepSpacing`).
    var isStep: Bool { self == .tick || self == .step }
}

/// What a role plays: one of UIKit's three feedback generators, and its
/// style or type.
public enum HapticRecipe: Hashable, Sendable {
    case selection
    case impact(UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat)
    case notification(UINotificationFeedbackGenerator.FeedbackType)
}

/// THE PLAYER (#1882): `play` a role, `prepare` it ahead of the moment.
///
/// - **Warm generators.** One long-lived generator per recipe, built on
///   first use and kept, and prepared again right after each play so a
///   burst stays warm — `prepare()` only helps AHEAD of the moment, which is
///   why a host calls `prepare(_:)` when its gesture starts (touch-down,
///   `.began`, a pull's first point). A generator built in the handler is
///   cold and lands late.
/// - **The switch.** Nothing plays and nothing warms while Haptics is off
///   (`HapticPreference`); the system switch sits underneath, with no
///   public API to read it.
/// - **Paced.** `tick` and `step` never play twice within `stepSpacing`
///   (leading edge, the extra dropped, never queued: iOS rate-limits fast
///   feedback at 32 Hz and the actuator rings 20–50 ms after a pulse); any
///   other role played twice within `repeatSpacing` plays once.
@MainActor
public enum Haptics {
    /// Between two `tick`s or two `step`s, at least.
    public static let stepSpacing: TimeInterval = 0.060
    /// Between two plays of the same role, at least.
    public static let repeatSpacing: TimeInterval = 0.100

    /// Plays `role`, unless the switch is off or it is too soon.
    public static func play(_ role: Haptic) {
        guard HapticPreference.isOn else { return }
        #if DEBUG
        let now = recorder?.clock?() ?? clock()
        #else
        let now = clock()
        #endif
        #if DEBUG
        // Recorded instead of played, with its own pacing: a test asserts on
        // it with no device, and no other test's haptics.
        if let recorder {
            if let last = recorder.lastPlayed[role], now - last < spacing(of: role) { return }
            recorder.lastPlayed[role] = now
            recorder.record(role)
            return
        }
        #endif
        if let last = lastPlayed[role], now - last < spacing(of: role) { return }
        lastPlayed[role] = now
        #if DEBUG
        if logs { print("haptic \(role)") }
        #endif
        let recipe = role.recipe
        switch recipe {
        case .selection:
            let generator = selection
            generator.selectionChanged()
            generator.prepare()
        case .impact(let style, let intensity):
            let generator = impact(style)
            generator.impactOccurred(intensity: intensity)
            generator.prepare()
        case .notification(let type):
            notification.notificationOccurred(type)
            notification.prepare()
        }
    }

    /// Warms `role`'s generator for a moment about to come. Nothing while the
    /// switch is off.
    public static func prepare(_ role: Haptic) {
        guard HapticPreference.isOn else { return }
        #if DEBUG
        if let recorder {
            recorder.recordPrepare(role)
            return
        }
        #endif
        switch role.recipe {
        case .selection: selection.prepare()
        case .impact(let style, _): impact(style).prepare()
        case .notification: notification.prepare()
        }
    }

    private static var lastPlayed: [Haptic: TimeInterval] = [:]

    private static func spacing(of role: Haptic) -> TimeInterval {
        role.isStep ? stepSpacing : repeatSpacing
    }
    private static let selection = HapticSelection()
    private static let notification = HapticNotification()
    private static var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: HapticImpact] = [:]

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) -> HapticImpact {
        if let generator = impacts[style] { return generator }
        let generator = HapticImpact(style: style)
        impacts[style] = generator
        return generator
    }

    /// The clock the pacing reads. Swappable for tests.
    static var clock: () -> TimeInterval = { CACurrentMediaTime() }

    #if DEBUG
    /// Records each role played, in order, after the switch and the pacing,
    /// while set — INSTEAD of playing it: what a test asserts on, with no
    /// device and no generator. ⚠️ TASK-LOCAL: suites run side by side, and a
    /// global recorder would hear another test's haptics.
    @TaskLocal public static var recorder: HapticRecorder?

    /// `-haptics-log`: a `haptic <role>` line per play — the simulator's QA
    /// hook (it has no Taptic Engine: a sim run can only check that the right
    /// role fired).
    static let logs = ProcessInfo.processInfo.arguments.contains("-haptics-log")

    #endif
}

#if DEBUG
/// What `Haptics` played (and warmed), in order. Tests set one as
/// `Haptics.recorder`, act, and read `played`.
@MainActor
public final class HapticRecorder {
    public private(set) var played: [Haptic] = []
    public private(set) var prepared: [Haptic] = []
    /// The pacing, this recorder's own.
    var lastPlayed: [Haptic: TimeInterval] = [:]
    /// The clock its pacing reads, when a test drives time.
    public var clock: (() -> TimeInterval)?

    public init() {}

    func record(_ role: Haptic) { played.append(role) }
    func recordPrepare(_ role: Haptic) { prepared.append(role) }

    /// Runs `body` with a fresh recorder (and its own pacing) for this
    /// task; returns what played.
    public static func recording(_ body: () throws -> Void) rethrows -> [Haptic] {
        let recorder = HapticRecorder()
        try Haptics.$recorder.withValue(recorder) { try body() }
        return recorder.played
    }
}
#endif
