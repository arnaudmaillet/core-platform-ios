import UIKit

/// The page under the comments sheet, as one value (#2287 § 4): what
/// `SnapFeedCell.setCommentsSheetLayout` draws — how far the media has gone
/// towards the sheet, the room it shrinks into, its scale-out, its corners'
/// way to the preview's — and how far the page's interface has gone.
struct CommentsSheetPose: Equatable {
    /// 0 the page at rest, 1 the media in `region`.
    var progress: CGFloat
    /// The room the media shrinks into, in the window's coordinates.
    var region: CGRect
    /// The media's scale-out where it stands, 0 in, 1 out.
    var out: CGFloat
    /// How far its corners have gone to the preview's.
    var towardsPreview: CGFloat
    /// The page's interface hidden by this share, 0 shown, 1 hidden: the
    /// progress while the sheet drives the page; on the way back it waits
    /// for the media (`CommentsSheetLanding`).
    var interface: CGFloat

    /// The page at rest, the room left to whoever draws it.
    static let restingPose = CommentsSheetPose(progress: 0, region: .zero, out: 0, towardsPreview: 0, interface: 0)

    /// The page at rest: what `SnapFeedCell.clearCommentsSheetLayout` leaves.
    var isAtRest: Bool { progress <= 0.0005 && out <= 0.0005 && interface <= 0.0005 }

    /// A new opening TURNING AROUND from this pose (#2287 § 4): a sheet
    /// reopened while the media was still on its way back. The rising
    /// sheet's own pose (`sheet`) takes over as it reaches the media — until
    /// then the media holds where it stood, the room it shrinks into going
    /// over to the new sheet's — so nothing jumps. `w` 1, the sheet's pose.
    func turningAround(towards sheet: CommentsSheetPose) -> (pose: CommentsSheetPose, caughtUp: Bool) {
        guard progress > 0.001 else { return (sheet, true) }
        let w = min(1, max(0, sheet.progress / progress))
        guard w < 1 else { return (sheet, true) }
        let blend = { (from: CGFloat, to: CGFloat) in from + (to - from) * w }
        let room = CGRect(
            x: blend(region.minX, sheet.region.minX), y: blend(region.minY, sheet.region.minY),
            width: blend(region.width, sheet.region.width), height: blend(region.height, sheet.region.height)
        )
        let pose = CommentsSheetPose(
            progress: max(progress, sheet.progress), region: room, out: blend(out, sheet.out),
            towardsPreview: blend(towardsPreview, sheet.towardsPreview), interface: blend(interface, sheet.interface)
        )
        return (pose, false)
    }
}

/// THE MEDIA'S WAY BACK TO FULL SCREEN (#2287 § 4, the owner 2026-11-11):
/// once the comments sheet leaves with no finger on it (its ✕, a tap above
/// it, a swipe let go), the media lands in ONE movement of its own — from
/// the pose it stood in to the page at rest, on the display link's clock —
/// and the session ends only once it has landed.
///
/// ⚠️ NEVER SNAPPED IN FLIGHT. Until #2287 the media followed the leaving
/// sheet alone, and the session's end (`clearCommentsSheetLayout`, run as
/// UIKit's dismissal completed) put the page back at once over whatever the
/// motion had left: the 0.2 s scale-in from the preview (#2087) and the
/// growth from expanded were cut short — the owner's film: a card at ~60 %
/// of the screen, full screen the next frame. Which of the two ended first
/// varied: hence "sometimes". Now the dismissal and the media end on their
/// own, and the page is cleared only from rest — where clearing it changes
/// nothing on the screen.
///
/// ⚠️ THE SHEET STILL LEADS, FROM ITS FIRST FRAME (the coordinator's film,
/// 2026-11-11). A first version ran the media on an ease-out of its own,
/// only never behind the sheet: its steep start — and a display link idling
/// at 30 Hz, whose first tick came late — threw the media from the
/// collapsed card to nearly full screen in the frame after the tap, the
/// sheet a few points down. While the sheet can be read, the media is
/// where the sheet's share of its way down says
/// (`advance(to:sheetRemaining:)`), the one measure the page always
/// followed — a backstop flat at the start only takes over if the sheet
/// lags, and lands it by the deadline. Once the sheet can no longer be
/// read (gone, or never read), the media carries on from where it stands,
/// easing in and out (`tail`): continuous whichever ends first.
///
/// ⚠️ NO DIMMING ON THE WAY BACK (the owner): a media still scaled out — its
/// preview had it — comes back in at its brightness within the first part
/// of the movement; the page's interface waits for it, coming back over the
/// last part.
struct CommentsSheetLanding {
    let from: CommentsSheetPose
    let start: CFTimeInterval
    /// When the media has landed, whatever the sheet does.
    let deadline: CFTimeInterval
    /// The media on its own, the sheet no longer read: the share still to go
    /// as it began, when, and when it lands.
    private var tail: (share: CGFloat, at: CFTimeInterval, end: CFTimeInterval)?
    /// The share of the way still to go, 1 at the start, 0 landed.
    private(set) var remaining: CGFloat = 1

    /// The movement's length when nothing says otherwise.
    static let standardDuration: CFTimeInterval = 0.35
    /// The share still to go under which the media's scale-out has gone.
    static let outGoneBy: CGFloat = 0.6
    /// The share still to go from which the page's interface comes back.
    static let interfaceFrom: CGFloat = 0.35
    /// The media on its own: this long for the whole way, never shorter
    /// than `shortestTail` for what is left of it.
    static let tailDuration: CFTimeInterval = 0.35
    static let shortestTail: CFTimeInterval = 0.1

    init(from: CommentsSheetPose, start: CFTimeInterval, duration: CFTimeInterval = Self.standardDuration) {
        self.from = from
        self.start = start
        deadline = start + max(0, duration)
        if from.isAtRest { remaining = 0 }
    }

    var hasLanded: Bool { remaining <= 0 }

    /// The movement at `now`. `sheetRemaining`: the share of its way down
    /// the sheet still has to go (1 where the movement began, 0 off the
    /// screen), nil once it has gone or cannot be read.
    mutating func advance(to now: CFTimeInterval, sheetRemaining: CGFloat?) -> CommentsSheetPose {
        guard !hasLanded else { return pose(remaining: 0) }
        var share: CGFloat
        if tail == nil, let sheet = sheetRemaining.map({ min(1, max(0, $0)) }) {
            share = min(sheet, backstop(at: now))
        } else {
            if tail == nil {
                let left = Double(remaining)
                tail = (remaining, now, now + max(Self.shortestTail, Self.tailDuration * left))
            }
            share = tailed(at: now)
        }
        // Only ever on towards rest.
        share = min(share, remaining)
        if share < 0.0005 { share = 0 }
        remaining = share
        return pose(remaining: share)
    }

    /// The most still to go at `now` while the sheet leads: flat at first —
    /// the sheet's — down to nothing at the deadline.
    private func backstop(at now: CFTimeInterval) -> CGFloat {
        let span = deadline - start
        guard span > 0, now < deadline else { return 0 }
        let u = CGFloat(min(1, max(0, (now - start) / span)))
        return 1 - u * u * u
    }

    /// The media on its own, from where it stood, easing in and out.
    private func tailed(at now: CFTimeInterval) -> CGFloat {
        guard let tail, tail.end > tail.at else { return 0 }
        let u = CGFloat((now - tail.at) / (tail.end - tail.at))
        return tail.share * (1 - Self.smoothstep(u))
    }

    /// The pose with `remaining` of the way still to go.
    func pose(remaining share: CGFloat) -> CommentsSheetPose {
        let r = min(1, max(0, share))
        let outShare = Self.smoothstep((r - Self.outGoneBy) / (1 - Self.outGoneBy))
        let interfaceShare = Self.smoothstep(r / Self.interfaceFrom)
        return CommentsSheetPose(
            progress: from.progress * r,
            region: from.region,
            out: from.out * outShare,
            towardsPreview: from.towardsPreview,
            interface: min(from.interface, max(from.progress * r, interfaceShare * from.interface))
        )
    }

    static func smoothstep(_ t: CGFloat) -> CGFloat {
        let t = min(max(0, t), 1)
        return t * t * (3 - 2 * t)
    }
}
