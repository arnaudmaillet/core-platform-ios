import Foundation

/// EXPERIMENTAL (#1681, the owner 2026-10-24): the For You tab lands on the
/// full-screen post feed instead of today's For You screen — the author pill
/// in the top bar, save and repost upright in the action column, no ⋯, and
/// the tab bar where the post's toolbar was.
///
/// Off by default. On through the launch argument `-foryou-fullscreen`, or
/// the switch a DEBUG build shows in Settings → App and Device → Display —
/// read at launch (the For You tab is built once per session, and again on
/// a change of viewer), so the switch applies from the next launch.
public enum ForYouFullScreenExperiment {
    static let argument = "-foryou-fullscreen"
    static let key = "experiments.forYouFullScreen"
    /// Swappable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    nonisolated(unsafe) static var arguments: [String] = ProcessInfo.processInfo.arguments

    /// Whether the experiment is on: the launch argument, or the stored switch.
    public static var isOn: Bool {
        arguments.contains(argument) || storedSwitch
    }

    /// The Settings switch — a DEBUG build's; a release build never writes it.
    public static var storedSwitch: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}
