import UIKit

/// Text and Stickers: things laid over the picture, dragged, pinched and turned
/// on the canvas.
///
/// ⚠️ **ONE MODE FOR BOTH CATEGORIES.** Both edit the same overlay layer on the
/// same page; only the tools in the band differ. The screen sets `kind` before
/// it opens the mode.
///
/// ⚠️ **A STUB THAT SHOWS NOTHING AND DRESSES NOTHING, WHICH IS WHAT TEXT AND
/// STICKERS HAVE ALWAYS SHOWN.** The overlay slices (S9, then S10 for
/// stickers) fill it: `lockCanvas(by: .overlays)` while open, the tools as the
/// tenant, the page's `overlayHost` filled by `dress` and made interactive only
/// in this mode, the text composer and the sticker picker, and every lock given
/// back in `bandWillChange` and `screenWillDisappear`.
@MainActor
final class MediaEditorOverlayMode: MediaEditorMode {
    /// Which of the two categories the mode is open as.
    enum Kind {
        case text
        case stickers
    }

    var kind: Kind = .text

    private weak var host: (any MediaEditorHosting)?

    init(host: any MediaEditorHosting) {
        self.host = host
    }

    /// Lays the overlays stored for `id` into `cell`'s overlay host — called
    /// every time the canvas configures a page, because a recycled cell
    /// arrives carrying the previous picture's.
    func dress(_ cell: MediaEditorPageCell, for id: String) {}

    var tenant: UIView? { nil }

    func open(for id: String, item: MediaLibraryItem) {
        host?.showInBand(nil)
    }

    func bandWillChange(to accessory: UIView?) {}

    func pageDidSettle(on id: String?) {}

    func screenWillDisappear() {}

    /// Always false, on purpose, even once filled: each overlay has its own
    /// delete, and a one-tap "remove every overlay" is too destructive.
    var canReset: Bool { false }

    func reset() {}
}
