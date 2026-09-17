import UIKit

/// A song under a clip, opened from the sound pill.
///
/// ⚠️ **NOT A CATEGORY.** The pill opens and closes it (`toggle`) whatever the
/// category bar is resting on, so the category bar never opens it.
///
/// ⚠️ **A STUB: A TAP ON THE PILL STILL OPENS NOTHING, WHICH IS WHAT IT HAS
/// ALWAYS DONE.** The soundtrack slice (S11) fills it: the song tools as the
/// tenant on a video and a notice on a photo, the import seam, the excerpt and
/// the two levels, the preview un-muted while a song is attached, and the
/// pill's word naming the song.
@MainActor
final class MediaEditorSoundtrackMode: MediaEditorMode {
    /// What the pill says while the page has no song.
    static let addTitle = "Add a song"

    private weak var host: (any MediaEditorHosting)?

    init(host: any MediaEditorHosting) {
        self.host = host
    }

    /// What the pill says for the page in front of the author.
    var pillTitle: String { Self.addTitle }

    /// The pill was tapped: open the song tools, or put them away.
    func toggle() {}

    var tenant: UIView? { nil }

    func open(for id: String, item: MediaLibraryItem) {}

    func bandWillChange(to accessory: UIView?) {}

    func pageDidSettle(on id: String?) {}

    func screenWillDisappear() {}

    var canReset: Bool { false }

    func reset() {}
}
