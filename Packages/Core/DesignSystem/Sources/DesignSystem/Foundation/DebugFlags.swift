import Foundation

/// The app's DEBUG feature switches (#2132): what used to be a launch
/// argument alone — `-viewport-share`, `-idle-calm-off`, … — read in one
/// place, so the debug dashboard can turn each on for good.
///
/// - **The launch argument wins** when it is passed: a QA run, a script and
///   a UI test behave exactly as before.
/// - **DEBUG:** without the argument, the dashboard's persisted switch.
/// - **Release:** the argument alone, as before — nothing persisted is read.
public enum DebugFlags {
    public struct Flag: Sendable, Identifiable, Equatable {
        /// The launch argument, `-viewport-share`.
        public let argument: String
        public let title: String
        /// What turning it on does, in a line.
        public let detail: String
        /// Read once at launch (a `static let`, the app's environment): the
        /// switch takes effect on the next launch.
        public let appliesAtLaunch: Bool
        public var id: String { argument }
    }

    /// Every switchable flag. A flag read anywhere else than through
    /// `isOn(_:)` cannot be switched, so a new one is added here and read
    /// through it.
    public static let all: [Flag] = [
        Flag(argument: "-group-chats", title: "Group chats",
             detail: "Groups in Messages: create, inbox rows, senders, the info screen (#2211)", appliesAtLaunch: true),
        Flag(argument: "-channels", title: "Channels",
             detail: "Channels: in Chats, made from the + menu and the inbox search, and their showcases on the feed and the map (#2211)",
             appliesAtLaunch: true),
        Flag(argument: "-voice-posts", title: "Voice posts",
             detail: "A text post's caption can be a voice: drawn on every surface, recorded in the composer (#2204)",
             appliesAtLaunch: true),
        Flag(argument: "-map-text-bubble", title: "Map text-post bubble",
             detail: "The text marker nearest the map's centre opens a glass bubble with its author and words", appliesAtLaunch: true),
        Flag(argument: "-profile-follow-prominent", title: "Prominent profile-bar Follow",
             detail: "Someone else's profile wears its bar's Follow in the brand's tint (.prominent) (#2248)",
             appliesAtLaunch: false),
        Flag(argument: "-row-action-style", title: "Row actions as words",
             detail: "Follow, Accept and Approve on rows drawn as bare words, not the tinted ground; at launch: -row-action-style text (#2231)",
             appliesAtLaunch: true),
        Flag(argument: "-viewport-share", title: "Viewport share trace",
             detail: "Logs the half-the-display playback measure (#1914)", appliesAtLaunch: false),
        Flag(argument: "-still-video-backdrop", title: "Still video backdrops",
             detail: "Video tiles' frosted backdrop stays a still", appliesAtLaunch: false),
        Flag(argument: "-text-reveal-plain", title: "Plain text-post push",
             detail: "Text posts open with the native push, no window", appliesAtLaunch: false),
        Flag(argument: "-top-fade-trace", title: "Titled top-edge trace",
             detail: "Logs each titled list's first content against the soft fade, and the fade's frames (#2240)",
             appliesAtLaunch: false),
        Flag(argument: "-top-fade-clearance-off", title: "Titled top-edge clearance off",
             detail: "Titled lists start at the bar again, inside the soft fade: the before of #2240",
             appliesAtLaunch: true),
        Flag(argument: "-idle-calm-off", title: "Idle calm off",
             detail: "Endless decoration never rests when untouched (#580)", appliesAtLaunch: true),
        Flag(argument: "-video-cache-remote", title: "Remote mock clips",
             detail: "The mock serves its clips from the network", appliesAtLaunch: true),
        Flag(argument: "-sound-cache-remote", title: "Remote mock sounds",
             detail: "The mock serves its songs from the network", appliesAtLaunch: true),
        Flag(argument: "-console-capture", title: "Console capture from launch",
             detail: "Logs keeps print, stdout and stderr from the first line", appliesAtLaunch: true),
        Flag(argument: "-use-local-fleet", title: "Local fleet",
             detail: "Talks to a local backend instead of the mock", appliesAtLaunch: true),
    ]

    /// Whether `argument` is on: passed at launch, or (DEBUG) switched on.
    public static func isOn(_ argument: String, arguments: [String] = ProcessInfo.processInfo.arguments,
                            defaults: UserDefaults = .standard) -> Bool {
        if arguments.contains(argument) { return true }
        #if DEBUG
        return defaults.bool(forKey: key(argument))
        #else
        return false
        #endif
    }

    #if DEBUG
    /// Whether the launch argument itself turns it on: the switch cannot
    /// turn it off.
    public static func isPassedAtLaunch(_ argument: String,
                                        arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(argument)
    }

    public static func set(_ argument: String, on: Bool, defaults: UserDefaults = .standard) {
        if on {
            defaults.set(true, forKey: key(argument))
        } else {
            defaults.removeObject(forKey: key(argument))
        }
    }

    /// Every switch back to off.
    public static func reset(defaults: UserDefaults = .standard) {
        all.forEach { defaults.removeObject(forKey: key($0.argument)) }
    }
    #endif

    static func key(_ argument: String) -> String { "debugFlag\(argument)" }
}
