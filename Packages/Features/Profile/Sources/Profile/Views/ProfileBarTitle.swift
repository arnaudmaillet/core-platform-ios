import DesignSystem
import HeroPage
import UIKit

/// What the bar's @handle title asks of its screen (#2522): the handle,
/// whether the screen leads with its day (the tab root, untitled) or is a
/// page for no one, whether the header's tray has gone under the bar, the
/// bar's ink, the header line's passage, and the bar's soft top edge.
///
/// Nothing here is the profile's: any hero page that titles its bar with a
/// handle could be its host, so the title can move down to HeroPage the day
/// a second screen wears one (#2522).
@MainActor
protocol ProfileBarTitleHost: UIViewController {
    var currentHandle: String? { get }
    var dayLeads: Bool { get }
    var namesNoOne: Bool { get }
    var isTrayScrolledAway: Bool { get }
    var barTitleInk: UIColor { get }
    func subtitlePassage(travelled: CGFloat) -> CGFloat
    func setSoftTopEdge(_ soft: Bool)
}

/// The bar's @handle, scrubbed on the scroll, out of `ProfileViewController`
/// (#2522): how far the header's @handle line has gone under the bar, the
/// native title it draws from that (plain, or attributed while scrubbed),
/// its style, and the soft top edge of a titled bar.
///
/// ⚠️ WHAT WAS DRAWN IS ITS OWN RECORD (`drawnBarTitleOpacity`), never read
/// back from `attributedTitle`'s getter (#2334). It writes the navigation
/// item's title, attributed title and style, and no item.
@MainActor
final class ProfileBarTitle {
    private unowned let host: any ProfileBarTitleHost

    init(host: any ProfileBarTitleHost) {
        self.host = host
    }

    /// How much of the header's @handle line has gone under the bar, on
    /// `HeroBarTitle`'s steps (0…1): the bar's @handle follows it (#2334).
    private var handlePassage: CGFloat = 0
    /// The bar title's opacity last drawn, so a title is written only when
    /// its step changes.
    private var drawnBarTitleOpacity: CGFloat = 0

    /// The bar's title: the profile's @handle on a pushed profile, nil on the
    /// tab root (its leading group is the bell and the day, #1642) and over a
    /// page for no one (#800, #1406). A stub that knew only the name (#1858)
    /// waits for the handle rather than titling the bar with a name that
    /// would then be replaced: a native title changes without a fade.
    ///
    /// ⚠️ **IT FOLLOWS THE SCROLL (#2334), as a large title does.** At rest
    /// the header shows the name and the handle itself; the bar's handle
    /// comes in WHILE THE HEADER'S @HANDLE LINE PASSES UNDER THE BAR
    /// (`barTitleOpacity`), and goes the same way down. Follow (or the bell)
    /// and the soft blur keep their own trigger, the tray going under the
    /// bar (#2268, `isTrayScrolledAway`) — a little later: the tray stands
    /// under the bio, so the handle is whole by the time they switch.
    private var barTitle: String? {
        guard barTitleOpacity > 0, let handle = titleHandle else { return nil }
        return handle
    }

    /// The handle the bar may wear: a pushed profile's, known — nil on the
    /// tab root (its leading group is the bell and the day, #1642) and over
    /// a page for no one (#800, #1406).
    private var titleHandle: String? {
        guard !host.dayLeads, !host.namesNoOne, let handle = host.currentHandle, handle.hasPrefix("@") else { return nil }
        return handle
    }

    /// How visible the bar's handle is, 0…1: how far the header's @handle
    /// line has gone under the bar — and whole once the tray has, whatever
    /// the line's frame said (a faded identity, a test standing in for the
    /// scroll).
    private var barTitleOpacity: CGFloat { host.isTrayScrolledAway ? 1 : handlePassage }

    /// The @handle, NATIVE, beside the chevron (#2248, the owner 2026-11-10 —
    /// Instagram's arrangement): `navigationItem.title` with the `.browser`
    /// style, which draws the title LEADING, next to the back button, with
    /// no custom view — the wallet's History and Stakes screens wear it.
    /// Shown once the header's tray has gone under the bar (`barTitle`,
    /// #2268); UIKit truncates it at the tail when room runs out.
    ///
    /// ⚠️ **NO LEADING ITEM BESIDE IT.** Until #2248 this bar drew no title,
    /// and crowding was why: with an item in the leading group the title was
    /// not truncated but ABSENT (`-header-bar-tree` showed the platters and
    /// an empty `HostedViewContainer`), and dropping the leading item made the
    /// same label draw at once, left-aligned, at its full width. Three other
    /// explanations were tried first and were wrong: `largeTitleDisplayMode`,
    /// the compression priority, `sizeToFit`. The identity pill — the last
    /// leading item on a pushed profile — went with #2248, so the leading
    /// group of a pushed profile is the chevron alone.
    ///
    /// Its ink over the banner is the hero page's (`HeroPageViewController`):
    /// white over a picture at rest, the page's own ink with no picture
    /// behind the bar, the system's once the header has gone under it.
    ///
    /// ⚠️ **SCRUBBED, NATIVE (#2334).** On its way in or out the same native
    /// title is drawn through `navigationItem.attributedTitle` (iOS 26):
    /// its ink at the passage's opacity, a few points low and climbing
    /// (`HeroBarTitle`; a plain fade under Reduce Motion). Whole, the
    /// attributed title is cleared and the plain one wears the bar's own
    /// dress, as before. Nothing else in the bar is written.
    func applyBarTitle() {
        let title = barTitle
        let opacity = title == nil ? 0 : barTitleOpacity
        let attributed = title.flatMap {
            HeroBarTitle.attributed(
                $0, opacity: opacity, ink: host.barTitleInk, reduceMotion: MotionPreference.reducesMotion
            )
        }
        // ⚠️ WHAT WAS DRAWN IS OUR OWN RECORD, NOT `attributedTitle`'S
        // GETTER: set to nil with `title` still set, it answered "@lena"
        // as an attributed string (iOS 26, the Profile lane, #2334) — UIKit
        // derives it from the title — so it cannot tell a scrubbed title
        // from a plain one.
        let wasScrubbed = drawnBarTitleOpacity > 0 && drawnBarTitleOpacity < 1
        let titleChanged = host.navigationItem.title != title
        if let attributed {
            // The plain title first: the attributed one drawn over it.
            if titleChanged { host.navigationItem.title = title }
            if titleChanged || !wasScrubbed || opacity != drawnBarTitleOpacity {
                host.navigationItem.attributedTitle = attributed
            }
        } else {
            // Leaving the scrub: the attributed title cleared, then the plain
            // title written again, so the bar draws it in its own dress
            // whatever the attributed one left behind.
            if wasScrubbed { host.navigationItem.attributedTitle = nil }
            if wasScrubbed || titleChanged { host.navigationItem.title = title }
        }
        drawnBarTitleOpacity = opacity
        // The tab root keeps the stock style: it has no title to lead with.
        let style: UINavigationItem.ItemStyle = host.dayLeads ? .navigator : .browser
        if host.navigationItem.style != style { host.navigationItem.style = style }
        // ⚠️ THE BLUR KEEPS THE TRAY'S TRIGGER (#2268, #2334): a titled bar
        // wears UIKit's soft top edge down to its foot (`applyTopEdge(for:
        // .titled)`, the app's rule since #1591) — switched as the tray goes
        // under the bar, with Follow, by which point the scrubbed handle is
        // whole. An untitled bar stays clear.
        host.setSoftTopEdge(host.isTrayScrolledAway && titleHandle != nil)
    }

    /// The handle's passage for `travelled`, on the steps.
    private func steppedHandlePassage(travelled: CGFloat) -> CGFloat {
        HeroBarTitle.step(host.subtitlePassage(travelled: travelled))
    }

    /// The passage half of the screen's `heroPageHeaderDidMove`: the
    /// header's @handle line for `travelled`, on the steps. Whether it moved.
    func headerDidMove(travelled: CGFloat) -> Bool {
        let passage = steppedHandlePassage(travelled: travelled)
        let passageChanged = passage != handlePassage
        handlePassage = passage
        return passageChanged
    }

    #if DEBUG
    /// Stands in for the scroll: the header's @handle line `passage` (0…1)
    /// of the way under the bar, the tray still on screen (#2334) — the
    /// title's path a scroll takes, on the same steps.
    func debugSetHandlePassage(_ passage: CGFloat) {
        let stepped = HeroBarTitle.step(passage)
        guard stepped != handlePassage else { return }
        handlePassage = stepped
        applyBarTitle()
    }
    /// The bar title's opacity as drawn: 0 untitled, 1 whole (#2334).
    var debugBarTitleOpacity: CGFloat { drawnBarTitleOpacity }
    #endif
}
