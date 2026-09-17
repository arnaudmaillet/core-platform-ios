import Synchronization

/// The look a PREVIEW is being drawn with, readable from the compositor's queue
/// while the main actor changes it.
///
/// ⚠️ **A BOARD, NOT A NEW PLAYER ITEM.** A slider dragged across a video would
/// otherwise rebuild the item — or the reader — sixty times a second. The
/// compositor reads the look from here on every frame, so a change reaches the
/// next composed frame; a paused frame is redrawn by asking the frame reader for
/// the same moment again, never by building a new item.
///
/// ⚠️ **A `Mutex`, BECAUSE THE READER IS ON ANOTHER THREAD.** The compositor
/// runs on AVFoundation's queue and the writer is the main actor; a lock held
/// for one copy of a value is the whole cost.
///
/// The preview only: an export draws the look its plan carries.
public final class VideoLiveLook: Sendable {
    private let current: Mutex<FrameLook>

    public init(_ look: FrameLook) {
        current = Mutex(look)
    }

    public func set(_ look: FrameLook) {
        current.withLock { $0 = look }
    }

    public var look: FrameLook {
        current.withLock { $0 }
    }
}
