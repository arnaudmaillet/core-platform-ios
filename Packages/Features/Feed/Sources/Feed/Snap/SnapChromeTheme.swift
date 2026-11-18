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
