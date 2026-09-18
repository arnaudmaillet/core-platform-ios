import UIKit

/// One editing mode of `MediaEditorViewController`, as an object of its own.
///
/// ⚠️ **THE SCREEN DECIDES WHEN, THE MODE DECIDES WHAT.** The editor calls these
/// at fixed moments — a category chosen, the band changing hands, a page coming
/// to rest, the screen going, the undo arrow — and never looks inside a mode.
/// A mode reaches back only through `MediaEditorHosting`.
///
/// ⚠️ **NO DEFAULT IMPLEMENTATIONS, ON PURPOSE.** A mode that inherited a
/// silent `screenWillDisappear` would leave its lock or its sheet behind with
/// nothing to say it had been asked; every mode states each answer, even when
/// it is "nothing".
@MainActor
protocol MediaEditorMode: AnyObject {
    /// What this mode shows in the band when it is open on the current page —
    /// its tools or a notice — or nil when it has nothing to show. The screen
    /// compares it with the band's content to tell whether the mode is up.
    var tenant: UIView? { get }

    /// The mode's category was chosen, or chosen again while its tools were
    /// away: show them for `item`.
    func open(for id: String, item: MediaLibraryItem)

    /// The band is about to hold `accessory` — this mode's tenant, another's,
    /// or nothing. Close whatever this mode opened that belongs to the band.
    ///
    /// ⚠️ **NEVER CHANGE THE BAND FROM HERE.** This is called from inside the
    /// one funnel every band change goes through.
    func bandWillChange(to accessory: UIView?)

    /// A page came to rest; `id` is the item now in front, nil only when the
    /// editor has none.
    func pageDidSettle(on id: String?)

    /// The screen is going — "Next", or back. Give back every lock and put
    /// away every sheet.
    func screenWillDisappear()

    /// A step back or forward put a whole edit back on `id`: whatever this mode
    /// is showing about that page is now out of date.
    ///
    /// ⚠️ **ANY FIELD MAY HAVE MOVED.** A restored state is not "this mode's
    /// part changed" — it is the page as it was, so a mode states everything it
    /// draws again rather than diffing.
    func editsWereRestored(for id: String)

    // ⚠️ **NO `canReset`, AND NO `reset()`.** Every mode used to answer "what
    // would the header's arrow take off you?", because one arrow acted on
    // whichever mode was open. The arrows walk the author's own history now and
    // ask no mode anything — what is left of "reset" is a control a mode owns
    // outright (the ⊘ icon in the Effects row, the crop's own reset), so it is
    // that mode's own business and not a seam.
}

extension MediaEditorMode {
    /// Most modes draw nothing of their own about a page, so a restored state
    /// changes nothing they show.
    func editsWereRestored(for id: String) {}
}
