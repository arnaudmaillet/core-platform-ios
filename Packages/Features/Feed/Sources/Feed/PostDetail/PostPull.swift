import CoreGraphics
import DesignSystem
import Foundation

/// Which way a text page's pull goes (#2298 § 2): the feed's directions, in
/// both tabs — the next post always below, the previous one always above.
/// Never inverted in Recent: everywhere else in the app, pulling down means
/// going back.
enum PostPullDirection: Equatable, Sendable {
    /// Pulled up past the stream's bottom end.
    case next
    /// Pulled down past its top.
    case previous
}

/// The post a pull would go to, as its pill shows it: the author's face.
struct PostPullTarget: Equatable {
    var authorName: String
    var monogram: String
    var avatarURL: URL?
}

/// The pull past a text page's stream ends (#2298 § 2, the owner 2026-11-11;
/// Telegram's "swipe up for the next channel" as the model):
///
/// - **Where the stream scrolls** (Recent, an overflowing Popular): pulled up
///   past its bottom end → the next post; pulled down past its top (Recent's
///   "Earlier comments" row, or the caption once all is in) → the previous.
/// - **The measure** is the content's overscroll past that end — UIKit's own
///   rubber band, so the list and the pill say the same number — and the
///   threshold is the app's one pull distance (`PullRefreshRule.threshold`):
///   every pull in the app costs the same effort.
/// - **Only a finger's pull counts:** a fling or a bounce that reaches the end
///   never shows the pill; a finger catching a bounce already past the
///   threshold did not pull it there, so it arms only once it has been short
///   of it under the finger — the pull to refresh's rule.
/// - **Release past the threshold goes; before it, nothing happens** — the
///   list springs back and the pill with it.
///
/// Where the stream does NOT scroll (a Popular its room holds whole), there
/// is no pull: the feed's own paging takes the swipe
/// (`fittingStreamSwipe`).
///
/// Pure, for tests (`PostPullTests`).
enum PostPullRule {
    /// The overscroll at which the pull arms.
    static var threshold: CGFloat { PullRefreshRule.threshold }
    /// The overscroll at which the pill comes out of the edge.
    static let appearLift: CGFloat = 8

    /// How far the content stands past its ends, in content points: `bottom`
    /// past its last row (an upward pull), `top` above its first (a downward
    /// one). Zero inside.
    static func overscroll(
        offsetY: CGFloat, topInset: CGFloat, bottomInset: CGFloat, contentHeight: CGFloat, viewport: CGFloat
    ) -> (top: CGFloat, bottom: CGFloat) {
        let top = -topInset
        let tail = max(top, contentHeight + bottomInset - viewport)
        return (max(0, top - offsetY), max(0, offsetY - tail))
    }

    /// The pill's fill for a pull: full exactly where it arms.
    static func progress(pulled: CGFloat) -> CGFloat {
        min(max(pulled / threshold, 0), 1)
    }

    // MARK: - The pill follows the pull (#2349)

    /// The pill's size where it comes out, a fraction of its own.
    static let smallestScale: CGFloat = 0.6
    /// Its size at the threshold's swell, with the tick, before it settles
    /// back to 1.
    static let swell: CGFloat = 1.06
    /// Between the pill's foot and the composer's top (the stream's bottom
    /// edge), and mirrored under the bar for the previous post: never stuck
    /// to the field (the owner, 2026-11-12).
    static let footGap: CGFloat = Spacing.lg
    /// The pull, past `appearLift`, over which the pill's avatar, ring and
    /// words come in.
    static let materialiseSpan: CGFloat = 24

    /// ⚠️ THE PILL'S SIZE FOLLOWS THE PULL, FRAME BY FRAME, BOTH WAYS (#2349):
    /// a pure function of the pulled distance — the same on the way out and
    /// on the way back, nothing timed. Gone short of `appearLift`; from there
    /// it grows from `smallestScale` to 1 at the threshold; and never taller
    /// than `room`, the height the gap the pull opens leaves it between its
    /// foot's place and the rows, so it is never over the last row's words —
    /// while the gap is smaller than the pill, the pill is smaller still.
    static func pillScale(pulled: CGFloat, room: CGFloat, height: CGFloat) -> CGFloat {
        guard pulled >= appearLift, height > 0 else { return 0 }
        let along = min(max((pulled - appearLift) / (threshold - appearLift), 0), 1)
        let grown = smallestScale + (1 - smallestScale) * along
        return max(0, min(grown, room / height))
    }

    /// The pill's content's opacity for a pull: in over `materialiseSpan`
    /// past `appearLift`, as its glass materialises.
    static func contentPresence(pulled: CGFloat) -> CGFloat {
        guard pulled >= appearLift else { return 0 }
        return min(1, (pulled - appearLift) / materialiseSpan)
    }

    /// Where a drag on a stream its room holds whole goes (#2298 § 1): it
    /// doesn't scroll, so the feed's own paging takes any vertical drag, as on
    /// a media post — up to the next post; down to the previous one when the
    /// feed has one to give (`pagesBack`, the feed's router, asked only then:
    /// the first post keeps its close). Nil for a sideways drag (the tabs').
    static func fittingStreamSwipe(
        velocity: CGPoint, translation: CGPoint, pagesBack: @autoclosure () -> Bool
    ) -> PostPullDirection? {
        let vertical = velocity.y != 0 ? velocity.y : translation.y
        guard vertical != 0, abs(velocity.y) >= abs(velocity.x) else { return nil }
        if vertical < 0 { return .next }
        return pagesBack() ? .previous : nil
    }
}

/// One pull, read frame by frame (`PostPullRule`).
struct PostPullTracker: Equatable {
    /// What the pill shows for a reading.
    struct Reading: Equatable {
        var direction: PostPullDirection
        /// The overscroll, in content points.
        var pulled: CGFloat
        /// 0…1 toward the threshold.
        var progress: CGFloat
        /// Past the threshold under the finger: a release goes.
        var isArmed: Bool
        /// Far enough out for the pill to show.
        var isShown: Bool
    }

    /// The pull under way, nil when there is none.
    private(set) var direction: PostPullDirection?
    /// Past the threshold, armed under the finger: a release goes.
    private(set) var isArmed = false
    /// This drag has read the pull short of the threshold under the finger.
    private var wasShortUnderFinger = false
    /// The way the host said had nowhere to go, until the pull comes home:
    /// asked once per pull, never on every frame.
    private var declined: PostPullDirection?

    /// Re-reads the stream. `offers` says whether a pull that way has
    /// somewhere to go (a post there, the keyboard down) — asked once, as a
    /// pull begins. Returns what the pill shows, nil for no pill.
    mutating func update(
        top: CGFloat, bottom: CGFloat, isTracking: Bool, offers: (PostPullDirection) -> Bool
    ) -> Reading? {
        let side: PostPullDirection? = bottom > 0 ? .next : top > 0 ? .previous : nil
        let pulled = side == .next ? bottom : side == .previous ? top : 0
        guard isTracking else {
            // The finger lifted (or was never down: a fling, its bounce):
            // nothing begins; a pull under way follows the spring back,
            // disarmed, until it is home. (The armed state waits for the
            // release, which reads it.)
            wasShortUnderFinger = false
            guard let current = direction, side == current, pulled > 0 else {
                direction = nil
                declined = side == nil ? nil : declined
                return nil
            }
            return reading(current, pulled: pulled, armed: false)
        }
        guard let side, pulled > 0 else {
            // Inside the list under the finger: any pull from here is the
            // finger's own.
            direction = nil
            declined = nil
            isArmed = false
            wasShortUnderFinger = true
            return nil
        }
        if direction != side {
            isArmed = false
            if declined == side {
                direction = nil
            } else if offers(side) {
                direction = side
                declined = nil
            } else {
                direction = nil
                declined = side
            }
        }
        guard let current = direction else { return nil }
        if pulled < PostPullRule.threshold { wasShortUnderFinger = true }
        isArmed = wasShortUnderFinger && pulled >= PostPullRule.threshold
        return reading(current, pulled: pulled, armed: isArmed)
    }

    /// The finger lets go: the direction to go to when the pull was armed,
    /// nil when it springs back.
    mutating func release() -> PostPullDirection? {
        defer { isArmed = false; wasShortUnderFinger = false }
        return isArmed ? direction : nil
    }

    /// Forgets the pull (a commit handed it over, the stream reset).
    mutating func reset() {
        direction = nil
        declined = nil
        isArmed = false
        wasShortUnderFinger = false
    }

    private func reading(_ going: PostPullDirection, pulled: CGFloat, armed: Bool) -> Reading {
        Reading(
            direction: going, pulled: pulled, progress: PostPullRule.progress(pulled: pulled),
            isArmed: armed, isShown: pulled >= PostPullRule.appearLift
        )
    }
}
