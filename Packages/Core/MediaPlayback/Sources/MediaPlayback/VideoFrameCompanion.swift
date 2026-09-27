import CoreMedia
import CoreVideo
import QuartzCore

/// One decoded frame, as the renderer names it between the moment it is pulled
/// and the moment it is put on screen. Increasing, never reused by a renderer.
public struct VideoFrameID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let serial: Int
    public init(_ serial: Int) { self.serial = serial }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.serial < rhs.serial }
    public var description: String { "#\(serial)" }
}

/// Something drawn FROM a surface's frames that has to change on the same
/// refresh as the picture — the blurred band of a fitted clip.
///
/// ## Why the renderer has to help
///
/// Pictures are pulled just in time: on each refresh the renderer asks the
/// player's output for the frame due at that refresh's `targetTimestamp` and
/// enqueues it `DisplayImmediately` (see `VideoFrameRenderer`). A frame is
/// therefore on screen at the very refresh anything outside the renderer could
/// first read it, and whatever is derived from it off the main thread lands a
/// refresh or more after the picture — the lag a viewer reads as "the band
/// is late".
///
/// So while a surface has a companion that asks (`wantsFramesAhead`), its
/// renderer pulls AHEAD: it takes the frame a refresh or two before it is due,
/// hands it to the companion (`prepare`), holds it, and enqueues it at the
/// refresh it would have been enqueued at anyway — telling the companion in
/// the same main-thread turn (`present`). The picture's timing against the
/// player's clock does not change; only the pull moves earlier. What the
/// companion shows at `present` is committed in the same transaction the
/// enqueue rides with, so the two change on the same refresh.
///
/// With no companion asking, nothing changes: the renderer pulls just in time
/// and holds nothing, as it always has.
@MainActor
public protocol VideoFrameCompanion: AnyObject {
    /// Whether this companion wants frames ahead of their display right now.
    /// Asked on every refresh; false costs the renderer nothing.
    var wantsFramesAhead: Bool { get }
    /// `buffer` will be put on screen, as `frame`, at a later refresh — one or
    /// two from now. Start whatever takes time.
    ///
    /// ⚠️ BORROWED FROM THE PLAYER'S POOL: hold it for as long as one
    /// conversion takes and no longer.
    func prepare(_ buffer: CVPixelBuffer, as frame: VideoFrameID)
    /// `frame` is being enqueued on the surface IN THIS TURN. Whatever is set
    /// now is committed with it. A frame that was never prepared (the refresh
    /// the companion first asked on) is never presented either.
    func present(_ frame: VideoFrameID)
}

/// The frames a leading renderer holds between pull and display, and the
/// arithmetic of when each is due. A value type with no clock of its own, so
/// the schedule is pinned by specs without a decoder.
struct LeadingFrameQueue {
    struct Entry {
        let buffer: CVPixelBuffer
        let itemTime: CMTime
        let id: VideoFrameID
        /// The host time of the refresh the frame belongs to — the one a
        /// just-in-time pull would have enqueued it at.
        let due: CFTimeInterval
    }

    /// At most this many frames are ever held. A frame held is a frame the
    /// decoder has to allocate around, so this is a small number on purpose:
    /// two refreshes of lead at 30 fps is one frame, at 60 fps two.
    static let capacity = 3

    private(set) var entries: [Entry] = []
    private var nextSerial = 1

    var isEmpty: Bool { entries.isEmpty }
    var isFull: Bool { entries.count >= Self.capacity }

    /// How far ahead of a refresh to pull: one refresh, two when refreshes are
    /// short (ProMotion) — so the companion has at least ~16 ms to get ready
    /// whatever the display does.
    static func lead(refreshInterval: CFTimeInterval) -> CFTimeInterval {
        refreshInterval < 0.012 ? refreshInterval * 2 : refreshInterval
    }

    /// When a frame pulled at `hostTime` for `requestedHostTime` is due.
    ///
    /// The output hands back the latest frame at or before the requested item
    /// time, `behind` seconds of film earlier; at `rate`, the clock reaches it
    /// that much sooner. Never before the next refresh — a frame pulled now
    /// cannot go on screen at the refresh already being drawn — and at the next
    /// refresh for a clock that is not moving (paused, scrubbing).
    static func due(
        hostTime: CFTimeInterval, refreshInterval: CFTimeInterval,
        requestedHostTime: CFTimeInterval, behind: Double, rate: Double
    ) -> CFTimeInterval {
        let next = hostTime + refreshInterval
        guard rate > 0, behind.isFinite else { return next }
        return max(next, requestedHostTime - max(behind, 0) / rate)
    }

    /// Holds a frame and names it.
    mutating func hold(_ buffer: CVPixelBuffer, itemTime: CMTime, due: CFTimeInterval) -> VideoFrameID {
        let id = VideoFrameID(nextSerial)
        nextSerial += 1
        entries.append(Entry(buffer: buffer, itemTime: itemTime, id: id, due: due))
        return id
    }

    /// The frame to put on screen at the refresh displayed at `refresh`: the
    /// LATEST one due by then. Earlier ones are dropped with it — a refresh
    /// shows one picture, and a just-in-time pull would have shown the latest.
    mutating func takeDue(at refresh: CFTimeInterval) -> Entry? {
        // A millisecond of slack: `due` and `refresh` are sums of the same
        // host times taken different ways, and must not miss by a rounding.
        guard let index = entries.lastIndex(where: { $0.due <= refresh + 0.001 }) else { return nil }
        let entry = entries[index]
        entries.removeFirst(index + 1)
        return entry
    }

    /// The latest frame held, dropping the rest — for the refresh leading
    /// stops on, which must not keep a frame it will never show.
    mutating func takeAll() -> Entry? {
        defer { entries.removeAll() }
        return entries.last
    }

    mutating func removeAll() { entries.removeAll() }
}
