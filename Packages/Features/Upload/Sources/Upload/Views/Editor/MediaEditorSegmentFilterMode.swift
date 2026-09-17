import UIKit

/// A look for ONE piece of a clip, chosen from a row under the collapsed
/// timeline — the way a cut's transition is.
///
/// Asked for in these words: *"dans la toolbar de gauche avoir une icône filtre
/// (à côté de l'icône des ciseaux et de la vitesse), qui sera active que
/// lorsqu'un segment sera sélectionné dans la timeline, et le clic sur ce bouton
/// activera le mode compact de la timeline et affichera en dessous une
/// scrollview horizontale avec les filtres disponibles"* — while the Filters
/// category keeps its look for the whole media.
///
/// ⚠️ **NOT A CATEGORY.** It opens from the track's action bar
/// (`TrackAction.filter`), inside the timeline's own tenant, so its `tenant` is
/// nil and the category bar never opens it.
///
/// ⚠️ **A STUB: THE ACTION STAYS DISABLED AND NOTHING OPENS.** The segment-filter
/// slice (S7) fills it: `actionEnabled` while a piece is held and the file's
/// real length is known, the focus recorded BEFORE the track collapses
/// (`setCompact(true)` deselects), the row, the loop over the piece, and every
/// way off the clip closing it.
@MainActor
final class MediaEditorSegmentFilterMode: MediaEditorMode {
    private weak var host: (any MediaEditorHosting)?

    init(host: any MediaEditorHosting) {
        self.host = host
    }

    /// Whether the row is open on a piece. While it is, the screen disables
    /// split, speed and the undo arrow — they would move the piece it is open
    /// on.
    var isOpen: Bool { false }

    /// Whether the track's filter action may be tapped.
    var actionEnabled: Bool { false }

    /// The track's filter action was tapped.
    func actionTapped() {}

    /// The stretch of `timeline`'s played seconds the preview loops while the
    /// row is open on this clip, or nil.
    func rehearsal(in timeline: MediaTimeline, fileSeconds: Double) -> ClosedRange<Double>? {
        nil
    }

    var tenant: UIView? { nil }

    func open(for id: String, item: MediaLibraryItem) {}

    func bandWillChange(to accessory: UIView?) {}

    func pageDidSettle(on id: String?) {}

    func screenWillDisappear() {}

    var canReset: Bool { false }

    func reset() {}
}
