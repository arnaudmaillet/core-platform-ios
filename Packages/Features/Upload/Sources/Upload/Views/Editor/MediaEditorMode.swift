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

    /// Whether the undo arrow has anything to undo in this mode, on the current
    /// page.
    var canReset: Bool { get }

    /// The undo arrow was tapped while this mode's tools were up.
    func reset()
}
