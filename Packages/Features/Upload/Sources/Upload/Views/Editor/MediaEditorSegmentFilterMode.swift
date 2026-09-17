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
/// ⚠️ **THE SCREEN KEEPS THE STATE; THIS FORWARDS.** The row shares the
/// transitions row's machinery — the loop, the saved pause, every way off the
/// clip — which lives in the screen; a second copy here would be two rules for
/// one surface.
@MainActor
final class MediaEditorSegmentFilterMode: MediaEditorMode {
    private weak var host: (any MediaEditorHosting)?

    init(host: any MediaEditorHosting) {
        self.host = host
    }

    /// Whether the row is open on a piece. While it is, the screen disables
    /// split, speed and the undo arrow — they would move the piece it is open
    /// on.
    var isOpen: Bool { host?.segmentFilterIsOpen ?? false }

    /// Whether the track's filter action may be tapped.
    var actionEnabled: Bool { host?.segmentFilterActionEnabled ?? false }

    /// The track's filter action was tapped.
    func actionTapped() { host?.toggleSegmentFilters() }

    /// The stretch of `timeline`'s played seconds the preview loops while the
    /// row is open on this clip, or nil.
    func rehearsal(in timeline: MediaTimeline, fileSeconds: Double) -> ClosedRange<Double>? {
        host?.segmentFilterRehearsal(in: timeline, fileSeconds: fileSeconds)
    }

    var tenant: UIView? { nil }

    func open(for id: String, item: MediaLibraryItem) {}

    func bandWillChange(to accessory: UIView?) {}

    func pageDidSettle(on id: String?) {}

    func screenWillDisappear() {}

    var canReset: Bool { false }

    func reset() {}
}
