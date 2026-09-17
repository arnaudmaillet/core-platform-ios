import UIKit

/// Filters: one look over the whole picture, chosen from a row of thumbnails.
///
/// ⚠️ **MOVED HERE FROM THE EDITOR'S FILE, UNCHANGED.** The row, the notice a
/// video gets and the settle refresh are what `MediaEditorViewController` did
/// itself; the only difference is that they reach the screen through
/// `MediaEditorHosting`.
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

    /// What the band says instead, on a video. See the note in `open`.
    private lazy var unavailable = BandNoticeView(
        "A video can't be filtered yet — it'll be posted as it is."
    )

    var tenant: UIView? {
        guard let host, let id = host.currentItemID else { return nil }
        return host.item(id)?.isVideo == true ? unavailable : row
    }

    func open(for id: String, item: MediaLibraryItem) {
        // ⚠️ **A VIDEO GETS THE NOTICE, NOT THE ROW — AND THIS BECAME TRUE THE
        // DAY VIDEOS STARTED PUBLISHING.** The row was offered on every page for
        // as long as a clip was dropped at publish: the look went nowhere, but so
        // did the video, and the finalisation screen said so. Now the clip goes
        // and `post()`'s video branch never reads `edits` — `MediaFilter` is
        // `UIImage`-to-`UIImage` — so leaving the row here would let an author
        // choose a look, watch it applied on the canvas, and publish the
        // untouched clip. That is the exact defect `where !item.isVideo` was
        // removed to end, wearing a different sleeve.
        if item.isVideo {
            host?.showInBand(unavailable)
        } else {
            host?.showInBand(row)
            refresh()
        }
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

    /// Nothing to undo from here yet: the undo arrow has only ever reset the
    /// crop and the timeline.
    var canReset: Bool { false }

    func reset() {}

    /// Feeds the row the picture it is choosing a look for, and restores the
    /// look this item already carries.
    ///
    /// ⚠️ **ONE FETCH, NOT NINE.** The row filters locally from a single source;
    /// the library seam caches nothing, so nine thumbnail requests would be nine
    /// `PHImageManager` round trips for one photograph.
    private func refresh() {
        guard let current = host, let id = current.currentItemID else { return }
        row.setSelected(current.edits(for: id).filter)
        // ⚠️ THE THUMBNAIL'S SIDE, NOT THE ROW'S HEIGHT. The row is taller than
        // its pictures by a caption, and asking for that size would fetch a
        // picture bigger than anything shown.
        let side = MediaFilterRowView.thumbnailSide
        Task { [weak self] in
            guard let self, let host else { return }
            let source = await host.library.thumbnail(for: id, size: CGSize(width: side, height: side))
            guard host.currentItemID == id else { return }
            // ⚠️ **CUT HERE, AND NEVER INSIDE THE ROW.** The row is handed ONE
            // picture and renders nine looks from it locally; teaching it about
            // crops would make it learn a second concept it exists not to know.
            // Handing it the uncut picture instead is the invisible version of
            // this bug: nine chips previewing looks on a photograph that no
            // longer matches the canvas above them.
            let crop = host.edits(for: id).crop
            row.show(source.flatMap { MediaCropRenderer.apply(crop, to: $0) } ?? source)
        }
    }

    private func apply(_ filter: MediaFilter, to id: String) {
        host?.change(id) { $0.filter = filter }
        host?.editsDidChange(id, .look)
    }
}
