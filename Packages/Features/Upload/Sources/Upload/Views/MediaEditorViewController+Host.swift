import DesignSystem
import MediaPlayback
import UIKit

/// What an edit changed, so the screen knows what to bring up to date.
enum MediaEditKind {
    /// The whole look — preset, dials, effect. A photograph is redrawn; a
    /// playing clip takes it live, with no new item.
    case look
    /// What a clip's item is built from — its pieces and their filters, its
    /// crop, its song. A clip gets a new item when the film would differ; a
    /// photograph is redrawn.
    case film
    /// The overlays. They are views over the page, so nothing is re-rendered:
    /// the overlay mode redraws its own layer.
    case overlays
}

/// Who is holding the canvas still. See `MediaEditorViewController.lockCanvas(by:)`.
enum CanvasLockOwner: Hashable {
    /// The crop surface, while it is up.
    case crop
    /// Text or Stickers, while overlays can be dragged.
    case overlays
}

/// What the editor offers the mode objects in `Views/Editor/`.
///
/// ⚠️ **A PROTOCOL, NOT THE SCREEN ITSELF.** A mode reaches only what is
/// listed here, which is what lets five of them be written in parallel against
/// one screen without each learning the rest of its 3,000 lines — and what
/// keeps a mode from quietly depending on a member nobody meant to share.
///
/// ⚠️ **EVERY EDIT GOES THROUGH `change(_:_:)`, THEN `editsDidChange`.** The
/// first keeps "absent means untouched" true; the second is the one place that
/// knows whether a change is a redraw, a live look or a new item.
@MainActor
protocol MediaEditorHosting: AnyObject {
    // MARK: The page in front of the author

    var currentItemID: String? { get }
    func item(_ id: String) -> MediaLibraryItem?
    /// The page carrying `id`, if it is laid out.
    func pageCell(for id: String) -> MediaEditorPageCell?
    /// The size a full-page picture is asked for, in points.
    var canvasSize: CGSize { get }
    /// The canvas-sized picture the library last answered with, undressed and
    /// uncut — for a video, its poster.
    var heldPicture: (id: String, image: UIImage)? { get }
    var library: any MediaLibraryReading { get }

    // MARK: Edits

    /// What is decided about `id`; `.untouched` when nothing is.
    func edits(for id: String) -> MediaEdits
    func change(_ id: String, _ mutate: (inout MediaEdits) -> Void)
    /// Brings the canvas and the preview up to date after `change`.
    func editsDidChange(_ id: String, _ kind: MediaEditKind)

    // MARK: The band and the chrome

    /// Puts a view in the editing band, or empties it with nil. Every mode
    /// hears it through `bandWillChange(to:)` first.
    func showInBand(_ accessory: UIView?)
    var bandContent: UIView? { get }
    /// Re-decides the undo arrow — a mode's `canReset` changed.
    func refreshResetItem()
    /// Re-decides the sound pill's word — `MediaEditorSoundtrackMode.pillTitle`.
    func refreshSoundPill()
    func presentSheet(_ controller: UIViewController)

    /// Says the sheet this mode put up has gone, so the clip it covered may run
    /// again. ⚠️ **UIKit DOES NOT SAY THIS** — see the implementation.
    func sheetDidClose()

    // MARK: The canvas

    func lockCanvas(by owner: CanvasLockOwner)
    func unlockCanvas(by owner: CanvasLockOwner)

    // MARK: Video

    var preview: any MediaVideoPreviewing { get }
    /// The surface the settled page's clip plays in, if one is playing.
    var playingSurface: VideoRenderView? { get }
    /// The FILE's real length for `id`, once it has been read — nil before.
    func fileSeconds(for id: String) -> Double?

    // MARK: The timeline

    var timelineTools: MediaTimelineToolsView { get }
    var actionBar: IconActionBar { get }
    /// The length of the clip the track is showing, in seconds of the file.
    var trackSeconds: Double { get }
    /// Re-decides which of the track's actions may be tapped.
    func refreshTrackActions()

    // MARK: A piece's filter

    var segmentFilterIsOpen: Bool { get }
    var segmentFilterActionEnabled: Bool { get }
    func toggleSegmentFilters()
    func segmentFilterRehearsal(in timeline: MediaTimeline, fileSeconds: Double) -> ClosedRange<Double>?
}

extension MediaEditorViewController: MediaEditorHosting {
    func item(_ id: String) -> MediaLibraryItem? { itemsByID[id] }

    func pageCell(for id: String) -> MediaEditorPageCell? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return canvas.cellForItem(at: IndexPath(item: index, section: 0)) as? MediaEditorPageCell
    }

    var heldPicture: (id: String, image: UIImage)? { lastSource }

    /// ⚠️ **THE PAGE IS REDRAWN FOR A CLIP TOO.** A playing clip covers its
    /// poster, but the poster is what the page shows the next time it starts —
    /// and it is the picture a look or a crop has to be seen on while the clip
    /// is not playing.
    func editsDidChange(_ id: String, _ kind: MediaEditKind) {
        switch kind {
        case .look:
            redraw(id)
            if id == playingID, let surface = playingSurface,
               !preview.setLiveLook(edits(for: id).look, in: surface) {
                // ⚠️ **A BACKING THAT CANNOT TAKE A LOOK LIVE GETS A NEW ITEM.**
                // The legacy layer path is the one that refuses; leaving it at
                // that would draw the author's filter on the poster and not on
                // the clip.
                refreshPreview(force: true)
            }
        case .film:
            redraw(id)
            refreshPreview()
        case .overlays:
            break
        }
        refreshResetItem()
    }

    func showInBand(_ accessory: UIView?) { setEditingAccessory(accessory) }

    var bandContent: UIView? { band.content }

    /// ⚠️ **A SHEET OVER THE EDITOR STOPS THE CLIP, AND THE EDITOR IS NEVER
    /// TOLD IT WENT UP.** A page sheet does not remove the presenting view from
    /// the hierarchy, so none of `viewWillDisappear`, `viewDidDisappear`,
    /// `viewWillAppear` or `viewDidAppear` fires for a cover — measured with a
    /// thread sample while the song picker was up: the editor's frame clock was
    /// still ticking and the composed reader still decoding, for a picture
    /// nobody could see. This seam is the one funnel every sheet goes through,
    /// so it is where the cover is raised.
    func presentSheet(_ controller: UIViewController) {
        present(controller, animated: true)
        pauseUnderACover()
    }

    /// The sheet a mode put up has gone — see `presentSheet`. Whoever presented
    /// it says so, because UIKit will not.
    func sheetDidClose() {
        resumeAfterACover(retries: 2)
    }

    func fileSeconds(for id: String) -> Double? { fileLengths[id] }
}
