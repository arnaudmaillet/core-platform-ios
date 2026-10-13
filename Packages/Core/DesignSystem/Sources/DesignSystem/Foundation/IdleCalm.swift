import UIKit

/// Whether the app is RESTING: nobody has touched it for `after` seconds, so
/// the endless motion that only decorates stops until the next touch (#580).
///
/// ⚠️ **ANY ENDLESS ANIMATION ON SCREEN COSTS A WHOLE FRAME, EVERY FRAME.** A
/// 20-point breathing badge makes the render server recomposite the screen —
/// glass and blurs included — as surely as a full-screen video: measured in
/// the #580 idle baseline. Power Saving stops it for those who turn it on;
/// this stops it for everyone once they stop touching (the viewer's decision,
/// 2026-10-07).
///
/// ⚠️ **DECORATION ONLY, NOT CONTENT.** What rests: the wallet badge's breath,
/// the skeletons' shimmer, the map's animated markers (far more numerous than
/// anywhere else), the record turning under a song. What does NOT: animated
/// emotes in text — a caption, a comment, the composer, the keyboard (#1072,
/// the owner's decision of 2026-10-13: they froze while the viewer read); the
/// feed's own clip, the backdrop that follows it, its song, its
/// comment band, the sound bubble's record, which says the post is playing
/// aloud (#683) — someone watching a post without touching it is the whole
/// point of a feed. Nor does ANY VIDEO PLAYER: the grids' tiles, the rails'
/// cards and the galleries rested here too until #882, and a video stopping
/// on its own read as a fault, not as calm. Read through
/// `MotionPreference.stillsDecoration`, never this alone.
///
/// Set by the app shell, which watches every touch (`IdleCalmMonitor`).
public enum IdleCalm {
    /// How long without a touch before decoration rests.
    public static let after: TimeInterval = 30

    /// Written on the main thread only, by `set(_:)`.
    nonisolated(unsafe) public private(set) static var isCalm = false

    /// Rests or wakes the app's decoration, and tells every reader.
    @MainActor
    public static func set(_ calm: Bool) {
        guard calm != isCalm else { return }
        isCalm = calm
        NotificationCenter.default.post(name: .decorativeMotionDidChange, object: nil)
    }
}

extension MotionPreference {
    /// What endless DECORATIVE motion asks: Reduce Motion (iOS or the app's
    /// switch), Power Saving, or an app at rest (`IdleCalm`). Readers also
    /// observe `.decorativeMotionDidChange`.
    public static var stillsDecoration: Bool {
        reducesMotion || IdleCalm.isCalm
    }
}

extension Notification.Name {
    /// Posted when `IdleCalm` rests or wakes: every endless decorative
    /// animation re-reads `MotionPreference.stillsDecoration`.
    public static let decorativeMotionDidChange = Notification.Name("DecorativeMotionDidChange")
}
