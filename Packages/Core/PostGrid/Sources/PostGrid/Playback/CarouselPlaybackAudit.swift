import Foundation

#if DEBUG
/// Reports states in which the VIEWER would be looking at a still where a clip
/// is supposed to be playing.
///
/// ⚠️ It exists because every other signal lied. Across this feature the
/// coordinator logged clean starts, the pool decoded, the ranking was right and
/// the transition reported success — while the surface hung in the wrong page,
/// or in no page, or was hidden, or had no player behind it. Each of those is
/// invisible from the side that reports success, and each of them looks
/// identical to the viewer: the thumbnail.
///
/// So the invariant is stated from the VIEWER's side, once, and every surface
/// answers the same four questions:
///
///   playing? — someone believes this cell is playing
///   clip?    — the page being looked at carries a stream
///   hosted?  — the playback surface hangs in THAT page
///   drawable? — it is visible and has a player behind it
///
/// `playing && clip` with either of the last two false is the defect, whatever
/// produced it. Enabled by `-carousel-audit`, and silent unless something is
/// wrong — a passing run prints its cycle count and nothing else.
@MainActor
public enum CarouselPlaybackAudit {
    public static let isEnabled = ProcessInfo.processInfo.arguments.contains("-carousel-audit")

    private(set) static var failures = 0
    private(set) static var checks = 0

    /// - Parameters:
    ///   - surface: which screen is reporting, so a failure names its half.
    ///   - subject: the post, so a failure can be reproduced.
    public static func check(
        surface: String, subject: String, page: Int,
        playing: Bool, clip: Bool, hosted: Bool, drawable: Bool
    ) {
        guard isEnabled else { return }
        checks += 1
        guard playing, clip, !(hosted && drawable) else { return }
        failures += 1
        print(String(
            format: "[audit] FAIL #%d %@ %@ page=%d hosted=%@ drawable=%@",
            failures, surface, subject, page,
            hosted ? "Y" : "N", drawable ? "Y" : "N"
        ))
    }

    /// Prints a one-line verdict. Called from the harness between cycles so a
    /// long run reads as a sequence rather than as one number at the end.
    public static func report(_ label: String) {
        guard isEnabled else { return }
        print(String(format: "[audit] %@ checks=%d failures=%d", label, checks, failures))
    }
}
#endif
