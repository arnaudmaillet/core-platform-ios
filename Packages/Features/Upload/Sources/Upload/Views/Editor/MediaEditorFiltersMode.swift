import MediaPlayback
import UIKit

/// Filters: one look over the whole picture, chosen from a row of thumbnails —
/// on a photograph and on a video alike.
///
/// ⚠️ **A VIDEO GETS THE ROW NOW, AND THIS WAS A NOTICE UNTIL THE LOOK
/// REACHED ITS PIXELS.** For as long as `post()`'s video branch never read
/// `edits`, offering the row on a clip let an author choose a look, watch it on
/// the canvas, and publish the untouched film — so a video was told it could
/// not be filtered. The look now travels in the clip's plan
/// (`MediaEdits.exportPlan`) and plays live in the preview
/// (`editsDidChange(.look)` → `setLiveLook`), so the refusal would be the lie.
///
/// ⚠️ **THE UNDO ARROW GOES BACK TO ORIGINAL** — the preset only; the dials and
/// the effect are Effects'.
@MainActor
final class MediaEditorFiltersMode: MediaEditorMode {
    private weak var host: (any MediaEditorHosting)?

    init(host: any MediaEditorHosting) {
        self.host = host
    }

    /// The row of looks the band holds while "Filters" is the chosen category.
    /// Built once, because rebuilding it per selection would re-render nine
    /// thumbnails for a band that is merely being reopened.
    private lazy var row: MediaFilterRowView = {
        let row = MediaFilterRowView()
        row.onPick = { [weak self] filter in
            guard let self, let id = host?.currentItemID else { return }
            apply(filter, to: id)
        }
        return row
    }()

    var tenant: UIView? { row }

    func open(for id: String, item: MediaLibraryItem) {
        host?.showInBand(row)
        refresh()
    }

    func bandWillChange(to accessory: UIView?) {}

    /// ⚠️ **SILENT WHEN THE BAND IS SHUT, AND THAT IS THE POINT.** Every settle
    /// calls this; without the guard each one would run a full
    /// `PHImageManager` request — iCloud access allowed — to dress a row nobody
    /// is looking at.
    func pageDidSettle(on id: String?) {
        guard let host, host.bandContent === row else { return }
        refresh()
    }

    func screenWillDisappear() {}

    var canReset: Bool {
        guard let host, let id = host.currentItemID else { return false }
        return host.edits(for: id).filter != .original
    }

    func reset() {
        guard let id = host?.currentItemID, canReset else { return }
        row.setSelected(.original)
        apply(.original, to: id)
    }

    /// Feeds the row the picture it is choosing a look for, and restores the
    /// look this item already carries.
    ///
    /// ⚠️ **ONE PICTURE, NOT NINE — AND THE PAGE'S OWN WHEN IT IS IN HAND.** The
    /// row filters locally from a single source. The canvas-sized picture the
    /// screen holds (a video's poster, on a clip) is shrunk and used at once;
    /// only a page the screen holds nothing for goes to the library, whose seam
    /// caches nothing.
    private func refresh() {
        guard let current = host, let id = current.currentItemID else { return }
        row.setSelected(current.edits(for: id).filter)
        if let held = current.heldPicture, held.id == id {
            dress(from: held.image, for: id)
            return
        }
        // ⚠️ THE THUMBNAIL'S SIDE, NOT THE ROW'S HEIGHT. The row is taller than
        // its pictures by a caption, and asking for that size would fetch a
        // picture bigger than anything shown.
        let side = MediaFilterRowView.thumbnailSide
        Task { [weak self] in
            guard let self, let host else { return }
            let source = await host.library.thumbnail(for: id, size: CGSize(width: side, height: side))
            guard host.currentItemID == id, let source else { return }
            dress(from: source, for: id)
        }
    }

    /// ⚠️ **CUT HERE, AND NEVER INSIDE THE ROW.** The row is handed ONE picture
    /// and renders nine looks from it locally; teaching it about crops would
    /// make it learn a second concept it exists not to know. Handing it the
    /// uncut picture instead is the invisible version of this bug: nine chips
    /// previewing looks on a photograph that no longer matches the canvas above
    /// them.
    private func dress(from source: UIImage, for id: String) {
        guard let host else { return }
        let edits = host.edits(for: id)
        let pixels = MediaFilterRowView.thumbnailSide * max(1, row.traitCollection.displayScale)
        let base = MediaLookThumbnails.base(source, crop: edits.crop, pixels: pixels)
        row.show(base, wearing: edits.look)
    }

    private func apply(_ filter: MediaFilter, to id: String) {
        host?.change(id) { $0.filter = filter }
        host?.editsDidChange(id, .look)
    }

    /// Internal for tests: the row, whether or not the band holds it.
    var debugRow: MediaFilterRowView { row }
}
