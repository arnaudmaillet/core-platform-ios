import CoreModels
import DesignSystem
import ObjectiveC
import UIKit

/// THE AUTHOR'S PROFILE OPENED AS A WINDOW (#1874) — an experiment behind
/// `-profile-window`, kept or dropped once the owner has seen it on a device.
///
/// On a full-screen post (every one but the Shots root), the profile opens
/// out of the container the viewer started from — the author pill on a long
/// press, the profile card on a tap on its header — and closes back onto the
/// author pill, whichever way it was opened.
///
/// No new animation: the profile is pushed through the reveal window
/// (`RevealTransition`) by an `InteractiveSlideDismissal` attached to it, as
/// the place page closes onto the map's marker (#1651). The pill is the
/// SOURCE (the close lands on it); the card is the opening's LAUNCH only.
@MainActor
public enum ProfileWindow {
    /// Whether a profile opens as a window from a screen: the flag on, motion
    /// allowed (Reduce Motion keeps the native push and pop), and not the
    /// Shots root, whose author row is in the page rather than a toolbar.
    /// Pure, for tests.
    public static func opens(flag: Bool, reducesMotion: Bool, isShotsRoot: Bool) -> Bool {
        flag && !reducesMotion && !isShotsRoot
    }

    /// The same decision with the launch flag and the motion setting read now.
    public static func opens(isShotsRoot: Bool) -> Bool {
        opens(flag: isFlagOn, reducesMotion: HeroMotionPolicy.prefersNativePush, isShotsRoot: isShotsRoot)
    }

    /// DEBUG `-profile-window`, off by default. Never in Release.
    public static let isFlagOn: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-profile-window")
        #else
        false
        #endif
    }()

    /// Arms `profile`'s push and close as the window: a slide driver that
    /// opens on `opening` and closes on what `closing` measures when the close
    /// stages — the plain slide when it answers nil, never a window onto
    /// nothing. The driver lives as long as the profile (`driver(of:)`);
    /// `install(on:)` it on the stack, then push.
    ///
    /// `releaseSource` gives the source back (the pill the opening concealed)
    /// whenever no window will: a close that falls back to the slide, and
    /// every completed pop as a backstop.
    @discardableResult
    public static func attach(
        to profile: UIViewController,
        opening: RevealGeometry,
        closing: @escaping () -> RevealGeometry?,
        releaseSource: @escaping () -> Void = {}
    ) -> InteractiveSlideDismissal {
        let slide = InteractiveSlideDismissal()
        slide.resetForNewPresentation()
        slide.attach(to: profile, axes: [.horizontal])
        slide.revealPresents = true
        // No flight ever takes this screen's close: the pager under it is a
        // feed's, and a hero answering about its post would take the chevron.
        slide.heroLandingAcceptsHero = { false }
        slide.fallbackSlideAxis = .horizontal
        slide.revealGeometry = opening
        // ⚠️ WEAK, as every caller of this hook must (`prepareForDismissal`).
        slide.prepareForDismissal = { [weak slide] _ in
            let geometry = closing()
            slide?.revealGeometry = geometry
            if geometry == nil { releaseSource() }
        }
        slide.onFeedPopped = { _ in releaseSource() }
        // The profile's own limits on where a back drag may begin — the edge
        // always, the whole surface on its first tab, never a carousel's drag
        // (`ContentPopGating`, the native swipe's gate).
        slide.permitsDrag = { [weak profile] origin, _, view in
            origin.x <= PagedScreenDismissalPolicy.edgeZone
                || (profile as? ContentPopGating)?.allowsContentPop(beginningAt: origin, in: view) ?? true
        }
        objc_setAssociatedObject(profile, &driverKey, slide, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return slide
    }

    /// The window driver `attach` gave `profile`, if any.
    public static func driver(of profile: UIViewController) -> InteractiveSlideDismissal? {
        objc_getAssociatedObject(profile, &driverKey) as? InteractiveSlideDismissal
    }

    /// Puts `profile`'s window driver back on top of its stack — called on
    /// every appearance, as the place page does: a screen pushed above the
    /// profile takes the stack's delegate, and the back button would then
    /// pop natively instead of closing the window.
    public static func reassert(on profile: UIViewController) {
        guard let slide = driver(of: profile), let nav = profile.navigationController else { return }
        slide.install(on: nav)
    }

    /// A picture of what the screen composites in `rect` (window space) now —
    /// the glass platter under a bar item included, which a snapshot of the
    /// item's own view would leave out. A picture rather than a snapshot
    /// view, so the opening and the close can each wear a fresh view of it.
    public static func picture(of rect: CGRect, in window: UIWindow) -> UIImage? {
        guard rect.width > 0, rect.height > 0, window.bounds.contains(rect) else { return nil }
        return UIGraphicsImageRenderer(bounds: rect).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    /// A stand-in wearing `picture`, filling the window it rides.
    public static func standIn(wearing picture: UIImage) -> UIView {
        let view = UIImageView(image: picture)
        view.contentMode = .scaleToFill
        view.clipsToBounds = true
        return view
    }

    private static var driverKey: UInt8 = 0
}

/// A screen a profile opens out of as a window and closes back onto (#1874):
/// a full-screen post, by its author pill.
@MainActor
public protocol ProfileWindowSource: AnyObject {
    /// Whether this screen opens profiles as windows at all
    /// (`ProfileWindow.opens`). False: every path is exactly as without the
    /// experiment — the card closes animated, the hold pushes natively.
    var opensProfileWindows: Bool { get }
    /// The window for `profileID`'s profile, measured now on the screen's
    /// author pill — `launch` is where the opening leaves from instead (the
    /// profile card), nil for the pill itself and for every close. Nil when
    /// the pill is not on screen or shows someone else: the plain push or
    /// slide.
    func profileWindowGeometry(for profileID: ProfileID, launch: RevealLaunch?) -> RevealGeometry?
    /// The profile is gone, or leaving without a window: whatever the opening
    /// concealed comes back.
    func releaseProfileWindowSource()
}

/// A sheet a profile can open out of as a window (#1874): the profile card.
/// The router hands it `opensProfileThroughWindow`; with it set, the sheet
/// leaves without animation and hands over its rect and still, in one turn.
@MainActor
public protocol ProfileWindowLaunching: AnyObject {
    var opensProfileThroughWindow: ((RevealLaunch) -> Void)? { get set }
}
