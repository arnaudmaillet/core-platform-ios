import Foundation
import MediaPlayback

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

    /// ⚠️ A FILE, not just the console.
    ///
    /// `simctl launch --console-pty` stopped delivering output mid-session, and
    /// an empty log reads exactly like a passing one — two runs were reported as
    /// "0 failures" from a log with no lines in it before the line count was
    /// checked. A file the app writes itself cannot fail that way: it is either
    /// there with content or it is not.
    ///
    /// It also makes the auditor usable by someone who is not driving the
    /// simulator from a shell — reproduce the fault, then hand over the file.
    private static let sink: URL? = {
        guard isEnabled else { return nil }
        let url = URL.documentsDirectory.appendingPathComponent("carousel-audit.log")
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }()

    private static func emit(_ line: String) {
        print(line)
        guard let sink, let handle = try? FileHandle(forWritingTo: sink) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

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
        emit(String(
            format: "[audit] FAIL #%d %@ %@ page=%d hosted=%@ drawable=%@",
            failures, surface, subject, page,
            hosted ? "Y" : "N", drawable ? "Y" : "N"
        ))
    }

    /// The converse: a clip drawing on a page that carries none.
    ///
    /// ⚠️ The first invariant could not see this, and it is the shape the worst
    /// defect took — the card swapped to the video at the instant of the tap, on
    /// a photograph's page, and the flight carried what it found. "The clip's
    /// page shows its clip" and "a still page shows its still" are the same
    /// requirement from two sides, and only one of them was being asked.
    public static func checkStillPage(
        surface: String, subject: String, page: Int, drawsVideo: Bool
    ) {
        guard isEnabled else { return }
        checks += 1
        guard drawsVideo else { return }
        failures += 1
        emit(String(
            format: "[audit] FAIL #%d %@ %@ page=%d video-on-a-still-page",
            failures, surface, subject, page
        ))
    }

    /// A picture that is on screen and not moving.
    ///
    /// ⚠️ The third fault of this family, and the one no existing question
    /// could reach. The first asks whether the clip's page shows its clip; the
    /// second whether a still page is free of one. Both are satisfied by a
    /// surface that is exactly where it should be, showing the right frame, and
    /// paused — which is what a viewer reports as "the player freezes".
    ///
    /// Only asked when the viewer is ON the clip's page: paused is the correct
    /// state everywhere else, and a check that ignored that would report the
    /// feature working as a failure.
    /// How many consecutive observations a still picture must survive before it
    /// counts.
    ///
    /// ⚠️ ONE observation is not a freeze. Between the coordinator registering a
    /// start and the pool's async `play` binding a player there is a legitimate
    /// window with no player at all, and the audit runs inside it — the very
    /// first line of a run was a "no-player" report for a row that was starting
    /// normally. Counting that inflated a real fault with a transient and sent
    /// me looking for a bug in the handoff.
    ///
    /// Three, because reconciles come in bursts of two on a single scroll tick.
    private static let framesBeforeFrozen = 3
    private static var stillFrames: [String: Int] = [:]

    public static func checkAdvancing(
        surface: String, subject: String, page: Int,
        watching: Bool, advancing: Bool, hasPlayer: Bool
    ) {
        guard isEnabled else { return }
        checks += 1
        let slot = "\(surface)/\(subject)/\(page)"
        guard watching, !advancing else {
            stillFrames[slot] = 0
            return
        }
        let seen = (stillFrames[slot] ?? 0) + 1
        stillFrames[slot] = seen
        guard seen >= framesBeforeFrozen else { return }
        stillFrames[slot] = 0
        failures += 1
        // ⚠️ Two very different faults look identical on screen, so the line
        // names which one it is. A surface with NO player is one that lost its
        // loan while its owner still believed it had one; a surface with a
        // PAUSED player is one nobody resumed. Chasing them as a single symptom
        // is what made this take three rounds.
        emit(String(
            format: "[audit] FAIL #%d %@ %@ page=%d frozen (%@)",
            failures, surface, subject, page,
            hasPlayer ? "paused" : "no-player"
        ))
    }

    /// Two players on one asset — the state the pool's reuse rule exists to
    /// make impossible, reported rather than assumed absent.
    public static func reportDuplicate(url: String, players: Int) {
        guard isEnabled else { return }
        failures += 1
        emit("[audit] FAIL #\(failures) DUPLICATE players=\(players) url=\(url)")
    }

    /// A breadcrumb, for chasing a state whose CAUSE is elsewhere in time.
    ///
    /// The frozen page is the case: by the time it is detected, whoever paused
    /// it is long gone. Traces go to the same file so the sequence reads in
    /// order alongside the failures.
    public static func trace(_ line: String) {
        guard isEnabled else { return }
        emit("[audit] · \(line)")
    }

    /// Wires the pool's own boundary trace into this file, so the two sides of
    /// a handoff read as one sequence. Called once, by whoever builds the pool.
    public static func capturePoolTrace() {
        guard isEnabled else { return }
        VideoPlaybackTrace.sink = { trace($0) }
    }

    /// Prints a one-line verdict. Called from the harness between cycles so a
    /// long run reads as a sequence rather than as one number at the end.
    public static func report(_ label: String) {
        guard isEnabled else { return }
        _ = sink
        emit(String(format: "[audit] %@ checks=%d failures=%d", label, checks, failures))
    }
}
#endif
