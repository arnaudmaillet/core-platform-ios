import DesignSystem
import UIKit

/// The engaged screen's READABILITY LAYER: the one surface between the
/// post's full-bleed media and the comment stream reading over it.
///
/// It is a black view whose alpha animates, and deliberately nothing more.
/// No blur, no material, no gradient — two rounds of dark material were
/// tried and both cost the photo (the archaeology is on
/// `SnapCommentsLayout.backdropDimOpacity`). A wash scales luminance and
/// leaves hue, detail, and motion untouched, so the post stays legible AS
/// the post; a dark material desaturates and tints toward its own grey,
/// which over a full-screen image reads as fog.
///
/// Being plain also makes it the cheapest possible answer. It covers the
/// whole cell over a surface that may be a playing `AVPlayerLayer`, where a
/// full-screen blur is a per-frame render-server cost; an opaque-blend pass
/// is nearly free. It needs no window guard for the same reason — there is
/// no `UIBlurEffect` here to contact the render server, so unlike every
/// other effect surface in this feature it behaves identically on a
/// headless CI host and on a device.
///
/// Alpha is the animatable channel (and the only one it has), so the whole
/// treatment rides the engagement's single spring block for free.
///
/// HIT-INERT: the media behind it keeps whatever hit-testing it had, and
/// the stream in front keeps every touch. This layer owns none.
/// THE PAGE'S THEME, and the only place it is decided.
///
/// A snap page is one visual object made of surfaces that live in three
/// different view trees — the cell (its frost band and the hosted comment
/// panel), the navigation bar, and the toolbar. Nothing inherits across
/// those boundaries, so before this existed each tree answered "am I light
/// or dark?" on its own and they disagreed: in light mode a media page drew
/// white-on-light nav platters above a dark caption bubble and a dark
/// composer.
///
/// Two rules, and they follow from what is BEHIND the chrome:
///
///   • MEDIA — pinned dark. The chrome floats over an arbitrary photo or
///     video, so its contrast can only come from the material it is made
///     of; the device's appearance has no opinion worth taking here.
///   • TEXT — inherited. The page's own ground follows the system (see
///     `SnapFeedCell.configure`), so the chrome over it must too, or light
///     mode puts white glass and white text on a white page.
enum SnapChromeTheme {
    static func style(hasMedia: Bool) -> UIUserInterfaceStyle {
        hasMedia ? .dark : .unspecified
    }

    /// The same rule for something INSIDE a screen that may itself be pinned.
    ///
    /// ⚠️ `.unspecified` MEANS "ASK MY PARENT", and a page's parent is a screen
    /// that pins itself dark while a photograph is settled. So a text page
    /// scrolling in under a media page inherited DARK, then turned light at the
    /// settle when the screen's own pin was released — a whole page changing
    /// theme under the viewer, visible on any recording of the scroll.
    ///
    /// A text page follows the DEVICE, which is what it looks like it should
    /// do, and saying so explicitly is the only way to mean it from inside a
    /// subtree someone else has pinned.
    static func style(hasMedia: Bool, device: UIUserInterfaceStyle) -> UIUserInterfaceStyle {
        hasMedia ? .dark : device
    }
}

/// What lending the page's theme to the shared bars asks of the screen
/// (#2514): whether a bar change may animate now. The bars, the toolbar's
/// items, the window and the screen's own style are the view controller's.
@MainActor
protocol SnapChromeThemeLenderHost: UIViewController {
    /// On screen, and no transition or flight owns the bar's items.
    var canAnimateBarItems: Bool { get }
}

/// Lends `SnapChromeTheme`'s style to the chrome the screen borrows (#2514):
/// the navigation bar, the toolbar and its glass container, the window's
/// status-band blur and the stack's bottom blur — and hands every piece back
/// on the way out, at once or once a grab is decided.
///
/// ⚠️ THE SCREEN IS THE LENDER. The blurs record who lent them a style
/// (`lendStyle(_:from:)`), and the release returns exactly that loan: both
/// pass the screen, never this object.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: every entry point runs in the caller's
/// turn, where the screen called it before — the settle (`updateBarChrome`),
/// the appearance callbacks, the author pill joining its window, the hero's
/// departure.
@MainActor
final class SnapChromeThemeLender {
    private unowned let host: any SnapChromeThemeLenderHost

    init(host: any SnapChromeThemeLenderHost) {
        self.host = host
    }

    /// On screen again (a return, a cancelled grab): the bars may be lent.
    func resumeLending() {
        hasHandedChromeBack = false
    }

    /// Puts the SCREEN's bars on the page's theme.
    ///
    /// The bars are the half of the page that the cell cannot reach: they
    /// belong to the navigation controller, not to the cell's view tree, so
    /// nothing propagates into them. Overriding the bars themselves — rather
    /// than each item's custom view — is what matters, because the Liquid
    /// Glass PLATTER behind an item is drawn by UIKit from the bar's own
    /// traits. Styling only the contents produced the exact bug this fixes:
    /// white text sitting on a light platter, over a dark page.
    ///
    /// Applied per settled page (`updateBarChrome`) and re-applied on
    /// appearance, since the bars are shared with whatever the feed pushes.
    ///
    /// ⚠️ THE TOOLBAR'S GLASS IS NOT IN THE TOOLBAR. On iOS 26/27 the bottom
    /// toolbar's item platters are hosted in a floating-bar container that is
    /// a SIBLING of `UIToolbar`, directly under the navigation controller's
    /// view (`-dump-bars` prints the chain). So the override on `toolbar`
    /// never reached them: on a light device a photograph wore a dark
    /// navigation bar over a LIGHT toolbar — grey glass, black glyphs — the
    /// "not always dark on media" that was reported. The nav bar's platters
    /// do live under `UINavigationBar`, which is why only the bottom half was
    /// wrong. See `toolbarGlassHost` for where the style goes instead.
    func applyChromeTheme(hasMedia: Bool) {
        // ⚠️ NOTHING IS LENT ONCE THE SCREEN IS LEAVING OR GONE (#1500): a
        // page settling, the author pill re-hosted or an appearance callback
        // landing after the hand-back re-styled the presenter's bars, and
        // nothing handed them back again. Undecided grab: wait (#1325).
        guard !isHandingChromeBack, !hasHandedChromeBack else { return }
        let style = SnapChromeTheme.style(hasMedia: hasMedia)
        // In one frame, not dissolved like the bars: the variants differ by
        // one half-opacity layer over 62pt.
        statusBarBlur?.lendStyle(style, from: self.host)
        if let band = BottomEdgeBlurView.installed(in: self.host.navigationController) {
            band.lendStyle(style, from: self.host)
            styledBottomEdgeBlur = band
        }
        guard let nav = self.host.navigationController else {
            self.host.overrideUserInterfaceStyle = style
            return
        }
        lentChromeNavigation = nav
        let host = toolbarGlassHost()
        if let previous = themedToolbarGlassHost, previous !== host {
            previous.overrideUserInterfaceStyle = .unspecified
        }
        themedToolbarGlassHost = host
        // A CHANGE between two settled pages dissolves instead of snapping.
        // Filmed: paging from a text page to a photograph kept the light bars
        // over the incoming dark page for the whole scroll (right — they
        // follow the SETTLED page) and then turned them dark in one frame at
        // the settle. A cross-dissolve on the two bar views is UIKit's own
        // transition over their rendered content — no alpha is written on
        // either bar — and it is skipped whenever nothing is changing, or
        // while a presentation's own bar animation owns them.
        let changes = nav.navigationBar.overrideUserInterfaceStyle != style
            || nav.toolbar.overrideUserInterfaceStyle != style
            || (host.map { $0.overrideUserInterfaceStyle != style } ?? false)
        let apply = {
            nav.navigationBar.overrideUserInterfaceStyle = style
            nav.toolbar.overrideUserInterfaceStyle = style
            host?.overrideUserInterfaceStyle = style
        }
        if changes, self.host.canAnimateBarItems {
            // Both transitions ride the one change: they are added in this
            // turn, and the new style is what both layers commit with.
            if let host {
                UIView.transition(
                    with: host, duration: 0.25,
                    options: [.transitionCrossDissolve, .allowUserInteraction], animations: nil
                )
            }
            UIView.transition(
                with: nav.navigationBar, duration: 0.25,
                options: [.transitionCrossDissolve, .allowUserInteraction], animations: apply
            )
        } else {
            apply()
        }
        self.host.overrideUserInterfaceStyle = style
    }

    /// The view that hosts the toolbar items' glass: the ancestor of one of
    /// this screen's own toolbar views that sits directly under the navigation
    /// controller's view.
    ///
    /// Found by walking up from a view this screen owns, through public API
    /// only, rather than by naming UIKit's private container. And NOT the
    /// navigation controller itself, which was the first fix and is filmed
    /// wrong: its override cascades into every controller in the stack, and
    /// the For You list under an opening flight is ON SCREEN — the whole list
    /// turned dark in the flight's first frames. The container holds the
    /// toolbar and nothing else.
    ///
    /// Nil while no item has been hosted yet (early in a presentation); the
    /// theme is re-applied once the screen has appeared. If UIKit ever hosts
    /// the items inside `UIToolbar` again, the walk lands on the toolbar,
    /// which is overridden anyway.
    ///
    /// ⚠️ ANY hosted item, not the first: an item handed over in the same turn
    /// as this runs is not in any window yet — when the attribution was a fresh
    /// view per page, walking up from it found nothing, and the toolbar stayed
    /// light after paging onto a photograph (filmed).
    private func toolbarGlassHost() -> UIView? {
        guard let root = host.navigationController?.view else { return themedToolbarGlassHost }
        for item in host.toolbarItems ?? [] {
            guard var view = item.customView else { continue }
            while let parent = view.superview, parent !== root { view = parent }
            if view.superview === root { return view }
        }
        // None hosted right now (a hand-over in flight): keep the one already
        // found rather than dropping the style it carries.
        return themedToolbarGlassHost
    }

    /// What `applyChromeTheme` styled, so the release hands back exactly that.
    private weak var themedToolbarGlassHost: UIView?

    /// Hands the shared bars back before anything else uses them.
    ///
    /// The feed does not own the navigation bar or the toolbar — it borrows
    /// them under the keep-and-stack contract. A pushed profile inheriting
    /// a dark-pinned bar because the feed happened to be showing a photo is
    /// exactly the kind of leak that shared chrome invites.
    ///
    /// The disappearance's hand-back: at once, or — an interactive one —
    /// once `whenDecided` reports a committed close (a cancel keeps it).
    /// Internal so a test can decide.
    func handBackChromeTheme(interactive: Bool, whenDecided: (@escaping (Bool) -> Void) -> Void) {
        guard interactive else { return releaseChromeTheme() }
        // ⚠️ THE STACK NOW, NOT AT THE DECISION (#1500). A committed grab
        // reports from the transition's completion, after the pop: the feed
        // has no `navigationController` any more, and the release found no
        // bars to hand back — the presenter's header stayed dark after a
        // rightward grab (filmed by the owner, 2026-10-21).
        let nav = host.navigationController ?? lentChromeNavigation
        // ⚠️ BOTH BARS, NOT ONLY THE BOTTOM ONE (#1325). The header was handed
        // back at the grab's first frame, on the reading that it is the
        // destination's — and it turned light over the media page for the
        // whole grab (filmed by the owner). It stays on screen too until the
        // close is decided: a media post's bars are dark for as long as it is.
        isHandingChromeBack = true
        whenDecided { [weak self] committed in
            guard let self else { return }
            self.isHandingChromeBack = false
            if committed { self.releaseChromeTheme(from: nav) }
        }
    }

    /// A grab is undecided: nothing re-themes or hands back meanwhile.
    private(set) var isHandingChromeBack = false
    /// The bars are handed back and the screen is leaving or gone: nothing
    /// lends them again until it appears (#1500).
    private var hasHandedChromeBack = false
    /// The stack whose bars `applyChromeTheme` styled, so the hand-back
    /// reaches them once the feed is off it.
    private weak var lentChromeNavigation: UINavigationController?

    /// Hands every lent style back — to `nav`'s bars, or the stack's.
    func releaseChromeTheme(from nav: UINavigationController? = nil) {
        let nav = nav ?? host.navigationController ?? lentChromeNavigation
        hasHandedChromeBack = true
        lentChromeNavigation = nil
        themedToolbarGlassHost?.overrideUserInterfaceStyle = .unspecified
        themedToolbarGlassHost = nil
        nav?.toolbar.overrideUserInterfaceStyle = .unspecified
        nav?.navigationBar.overrideUserInterfaceStyle = .unspecified
        host.overrideUserInterfaceStyle = .unspecified
        statusBarBlur?.returnStyle(from: host)
        styledBottomEdgeBlur?.returnStyle(from: host)
        styledBottomEdgeBlur = nil
    }

    /// The window's status-band blur, which wears the settled page's style
    /// while the feed covers it — the dark variant over a photograph, as when
    /// the band lived in this screen's view. See `StatusBarBlurView`.
    private var statusBarBlur: StatusBarBlurView? {
        StatusBarBlurView.installed(in: host.viewIfLoaded?.window ?? host.navigationController?.viewIfLoaded?.window)
    }

    /// The stack's bottom blur (#1002) this feed lent its style to, so the
    /// release hands it back even once the feed is off the stack (the
    /// departing-flight release runs with `navigationController` nil). See
    /// `BottomEdgeBlurView`.
    private weak var styledBottomEdgeBlur: BottomEdgeBlurView?
}
