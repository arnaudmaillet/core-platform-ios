import UIKit

/// Effects: the dials — brightness, contrast, saturation, warmth, highlights,
/// shadows, sharpness, vignette, grain — and one stylised effect, on photos and
/// videos alike.
///
/// ⚠️ **A STUB THAT SHOWS NOTHING, WHICH IS WHAT EFFECTS HAS ALWAYS SHOWN.** The
/// effects slice (S5) fills it: a row of dials and effect cards as the tenant,
/// a slider while one is being turned, changes written through `change` and
/// `editsDidChange(.look)` (a photo redraws, a video takes a live look), and an
/// undo arrow that resets the dials and the effect only.
@MainActor
final class MediaEditorEffectsMode: MediaEditorMode {
    private weak var host: (any MediaEditorHosting)?

    init(host: any MediaEditorHosting) {
        self.host = host
    }

    /// Nil: nothing to show yet, so a repeat tap on the category re-opens
    /// nothing.
    var tenant: UIView? { nil }

    func open(for id: String, item: MediaLibraryItem) {
        host?.showInBand(nil)
    }

    func bandWillChange(to accessory: UIView?) {}

    func pageDidSettle(on id: String?) {}

    func screenWillDisappear() {}

    var canReset: Bool { false }

    func reset() {}
}
