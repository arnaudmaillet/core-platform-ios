import UIKit

/// ⚠️ EXPERIMENTAL (#560): the media page's comment surfaces — the reaction
/// band's kinetic backdrop and the subtitle pills — on a blur material
/// instead of a black wash, behind a launch argument. Off — the default, and
/// always in Release — everything is today's wash, unchanged. Behaviour,
/// timing and curves are the same either way; only the material changes.
enum CommentBlur {
    static let launchArgument = "-comment-blur"

    /// Whether `arguments` ask for the blur. Release builds never do.
    static func isEnabled(arguments: [String]) -> Bool {
        #if DEBUG
        arguments.contains(launchArgument)
        #else
        false
        #endif
    }

    /// Whether this process asked for it — the default the surfaces take;
    /// tests set theirs per view instead (a process-wide switch would leak
    /// across parallel suites).
    static let isEnabled = isEnabled(arguments: ProcessInfo.processInfo.arguments)

    /// The fill setting's top (Settings: 0…0.9).
    static let pillFillCeiling: CGFloat = 0.9

    /// A pill's blur strength (0…1) for the viewer's fill setting.
    static func pillStrength(fill: CGFloat) -> CGFloat {
        min(1, max(0, fill) / pillFillCeiling)
    }
}
