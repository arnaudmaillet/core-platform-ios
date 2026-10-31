import QuartzCore
import UIKit

/// THE SHARE OF A SCREEN STILL ON SCREEN, 0…1 (#1914, the owner 2026-10-30):
/// what a clip's gate reads, under one rule — **a clip plays while its
/// surface holds most of the viewport**: it plays at 0.5 and above, pauses
/// below, and its sound follows the share down from full to silent at half.
///
/// Not the post's, not the player's: whether a clip should play is a fact
/// about the SCREEN. The player cannot see what slides over it; the host
/// knows what plays and feeds the share into its own gate.
///
/// Sources, as hosts adopt them:
/// - **a screen pushed over the host, or popped off it**, animated or
///   interactive: read frame by frame from the covering screen's
///   presentation layer while the transition runs (a display link only
///   then), so a cancelled drag reports the way back (`track`);
/// - **the host's own arrival and departure**, a push bringing it in, a pop
///   or a grab carrying the live screen off: read from the host's own
///   presentation layer, as the part of it inside the window
///   (`trackArrival`, `trackDeparture`);
/// - the host's own pager or drawer, reported as a fraction (`report`).
///
/// ⚠️ THE SCREEN UNDER A DEPARTING HOST IS NEVER ITS COVER: a host leaving
/// is measured by where it is, not by what it uncovers. And a flight
/// carrying the host's player to a tile is not handed over at all: the
/// flight keeps that player playing. The host decides which transitions to
/// hand over.
@MainActor
public final class ViewportShare {
    /// The share now: 1 with nothing over the host.
    public private(set) var share: CGFloat = 1

    /// Told on every change of `share`.
    public var onChange: ((CGFloat) -> Void)?

    /// Whether a clip plays at the share now (`plays(at:)`).
    public private(set) var plays = true

    /// Told when `plays` flips: the gate a host with no sound to fade needs.
    public var onPlaysChange: ((Bool) -> Void)?

    /// The threshold of the rule: plays at or above it.
    public static let playThreshold: CGFloat = 0.5

    /// Whether a clip plays at `share`.
    public static func plays(at share: CGFloat) -> Bool { share >= playThreshold }

    /// The sound's level at `share`: full on the whole screen, silent at the
    /// threshold, where the clip pauses.
    public static func volume(at share: CGFloat) -> Float {
        Float(min(1, max(0, (share - playThreshold) / (1 - playThreshold))))
    }

    private weak var host: UIView?
    private var link: CADisplayLink?
    private weak var cover: UIView?
    /// Whether the tracked transition is the host's own departure, sampled
    /// from the host rather than from a cover.
    private var isDeparting = false
    /// Whether the running link has seen the host in a window.
    private var hasSampled = false
    /// Bumped by every `track`: only the latest transition's end settles the
    /// share. A push begun before the previous one's completion ran would
    /// otherwise have its link stopped and its share overwritten by the old end.
    private var generation = 0

    /// Every live share by its host's view, so that a covered host reads the
    /// share of the screen covering it rather than measuring it a second time.
    private static let byHost = NSMapTable<UIView, ViewportShare>.weakToWeakObjects()

    /// The covered hosts taking this host's complement while it arrives or
    /// leaves.
    private let followers = NSHashTable<ViewportShare>.weakObjects()

    public init(host: UIView) {
        self.host = host
        Self.byHost.setObject(self, forKey: host)
    }

    /// A fraction from a source of the host's own (a pager, a drawer).
    public func report(_ value: CGFloat) {
        let clamped = min(1, max(0, value))
        guard abs(clamped - share) > 0.001 else { return }
        share = clamped
        #if DEBUG
        trace(String(format: "%.3f", clamped))
        #endif
        onChange?(clamped)
        let nowPlays = Self.plays(at: clamped)
        if nowPlays != plays {
            plays = nowPlays
            onPlaysChange?(nowPlays)
        }
        // The screens under this one, told in the same breath.
        guard isDeparting, let host else { return }
        for follower in followers.allObjects where follower.cover === host {
            follower.report(1 - clamped - Self.coveredYield)
        }
    }

    /// Follows `coordinator`'s transition, in which `cover` is the screen
    /// sliding over the host (a push) or off it (a pop back to it). At its
    /// end the share settles on what the transition decided.
    ///
    /// - Parameter coversAtEnd: whether `cover` covers the host once the
    ///   transition completes (a push: true; a pop back: false). A cancel
    ///   reverses it.
    public func track(
        _ coordinator: UIViewControllerTransitionCoordinator, cover: UIView, coversAtEnd: Bool
    ) {
        guard isCover(cover) else { return }
        let tracked = beginTracking(cover)
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            self?.transitionEnded(tracked, cancelled: context.isCancelled, coversAtEnd: coversAtEnd)
        }
    }

    /// Follows `coordinator`'s transition bringing the host itself onto the
    /// screen (#1914, the owner 2026-10-31: a pushed profile's clips waited
    /// for the push's end): the share is the part of the screen the host
    /// already takes, so its clips start once it takes half. At its end the
    /// share settles on whole, or on gone for a cancel.
    public func trackArrival(_ coordinator: UIViewControllerTransitionCoordinator) {
        report(0)
        let tracked = beginDeparture()
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            self?.transitionEnded(tracked, cancelled: context.isCancelled, coversAtEnd: false)
        }
    }

    /// Follows `coordinator`'s transition carrying the host itself off the
    /// screen (#1914, the owner 2026-10-31: a page's clips stopped at the
    /// first frame of the grab taking it back): the share is the part of the
    /// screen the host still takes, so its clips pause once it takes less
    /// than half — slid half off, or held smaller than half the screen. At its end the share settles
    /// on gone, or on whole again for a cancel.
    public func trackDeparture(_ coordinator: UIViewControllerTransitionCoordinator) {
        let tracked = beginDeparture()
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            self?.transitionEnded(tracked, cancelled: context.isCancelled, coversAtEnd: true)
        }
    }

    /// What a screen's appearance or disappearance asks of its host.
    public enum Change: Equatable {
        /// The share follows a transition; the host hears it through
        /// `onChange`.
        case followed
        /// Nothing to follow: the host acts now, as it always did (an
        /// appearance starts its clips where it always started them; a
        /// disappearance has already reported 0).
        case now
        /// A post opened from the screen, flying into a zoom destination: the
        /// flight owns the player it carries, and the host keeps its own rule
        /// for the rest.
        case flight
    }

    /// The screen hosting this share is about to appear: a push bringing it
    /// in is followed by its own place (`trackArrival`), a plain screen
    /// popping off it by that screen (`track`). A flight's return, a tab
    /// switch or a first appearance with no transition answer `.now`.
    public func screenWillAppear(_ screen: UIViewController) -> Change {
        trace("will appear moving=\(screen.isMovingToParent) transition=\(screen.transitionCoordinator != nil)"
              + " cancelled=\(screen.transitionCoordinator?.isCancelled == true)")
        guard let coordinator = screen.transitionCoordinator else { return .now }
        // ⚠️ A DEPARTURE ABANDONED (the owner's device, 2026-10-31: a grab
        // released short left the screen's clips stopped). UIKit calls the
        // screen's appearance once the cancel has run — with
        // `isMovingToParent` TRUE (traced) — on a coordinator that is over.
        // Taken for a push, it started an "arrival" whose cancel settled the
        // share on gone. The departure, tracked from its start, settles it.
        if coordinator.isCancelled { return .followed }
        if screen.isMovingToParent {
            guard !(screen is any ZoomTransitionDestination) else { return .now }
            trackArrival(coordinator)
            return .followed
        }
        guard !(coordinator.viewController(forKey: .from) is any ZoomTransitionDestination),
              let cover = Self.cover(of: coordinator, .from)
        else { return .now }
        track(coordinator, cover: cover, coversAtEnd: false)
        return .followed
    }

    /// The screen hosting this share is about to disappear: its own pop is
    /// followed by its own place (`trackDeparture`), a plain screen pushed
    /// over it by that screen (`track`). A post opened from it answers
    /// `.flight`; with no transition to follow the share reports 0 now.
    public func screenWillDisappear(_ screen: UIViewController) -> Change {
        let coordinator = screen.transitionCoordinator
        trace("will disappear moving=\(screen.isMovingFromParent) transition=\(coordinator != nil)"
              + " cancelled=\(coordinator?.isCancelled == true)")
        // ⚠️ A PUSH ABANDONED: UIKit calls the screen's disappearance once
        // the cancel has run, on a coordinator that is over. Its arrival,
        // tracked from the start, has already settled the share.
        if let coordinator, coordinator.isCancelled {
            report(0)
            return .now
        }
        if screen.isMovingFromParent, let coordinator {
            trackDeparture(coordinator)
            return .followed
        }
        if screen.navigationController?.topViewController is any ZoomTransitionDestination {
            return .flight
        }
        if let coordinator, let cover = Self.cover(of: coordinator, .to) {
            track(coordinator, cover: cover, coversAtEnd: true)
            return .followed
        }
        report(0)
        return .now
    }

    /// The screen covering a host in `coordinator`'s transition: the view of
    /// the controller at `key` — the very view that screen measures itself
    /// by when it arrives or leaves.
    ///
    /// ⚠️ NOT `view(forKey:)` (the owner's device, 2026-10-31): the view the
    /// transition hands over can be another than the controller's — the
    /// screen under a popped profile and the profile itself then measured
    /// two different rects, their shares added up to 1.09 (traced), and both
    /// played. Read from one view, the two shares are each other's
    /// complement.
    public static func cover(
        of coordinator: UIViewControllerTransitionCoordinator, _ key: UITransitionContextViewControllerKey
    ) -> UIView? {
        if let view = coordinator.viewController(forKey: key)?.viewIfLoaded { return view }
        return coordinator.view(forKey: key == .from ? .from : .to)
    }

    /// Whether `cover` can cover the host: never the host, nor a screen
    /// holding it.
    ///
    /// ⚠️ A CANCELLED TRANSITION HANDS THE HOST ITS OWN VIEW (the owner's
    /// device, 2026-10-30). A push over the host abandoned half way calls
    /// its `viewWillAppear` again, with the host's own screen as the
    /// transition's `from`; a pop back to it abandoned calls its
    /// `viewWillDisappear`, with the host as the `to`. Measured as a cover,
    /// the host hid all of itself: the share read 0, the cancel settled it
    /// on "covered", and the clip stayed paused, at volume 0, on a screen
    /// the viewer was looking at. Those transitions are already tracked
    /// from their start, by their real cover, which settles the share.
    func isCover(_ cover: UIView) -> Bool {
        guard let host else { return false }
        return !host.isDescendant(of: cover)
    }

    /// Takes `follower`, a host this one covers, as a screen following its
    /// share: told its complement now and on every change.
    func adopt(_ follower: ViewportShare) {
        guard !followers.contains(follower) else { return }
        followers.add(follower)
        follower.report(1 - share - Self.coveredYield)
    }

    /// `-viewport-share`: the host's screen and what happened to its share.
    func trace(_ event: @autoclosure () -> String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-viewport-share") else { return }
        let owner = host.map { String(describing: type(of: $0.next ?? $0)) } ?? "gone"
        print("[viewport-share] \(owner) \(event())")
        #endif
    }

    /// Starts sampling `cover`; returns the transition's generation.
    func beginTracking(_ cover: UIView) -> Int {
        self.cover = cover
        isDeparting = false
        generation += 1
        trace("track cover #\(generation)")
        startLink()
        return generation
    }

    /// Starts sampling the host's own place (an arrival or a departure);
    /// returns the transition's generation.
    func beginDeparture() -> Int {
        cover = nil
        isDeparting = true
        generation += 1
        trace("track own place #\(generation)")
        startLink()
        return generation
    }

    /// A tracked transition's end: settles the share on what it decided —
    /// unless a newer transition began meanwhile, which owns the share now.
    func transitionEnded(_ tracked: Int, cancelled: Bool, coversAtEnd: Bool) {
        trace("end #\(tracked) of #\(generation) cancelled=\(cancelled)")
        guard generation == tracked else { return }
        stopLink()
        cover = nil
        isDeparting = false
        let covered = cancelled ? !coversAtEnd : coversAtEnd
        report(covered ? 0 : 1)
    }

    // ⚠️ ONE MEASURE FOR BOTH SCREENS: THE SCREEN'S (the owner's device,
    // 2026-10-31). A departing screen used to be measured against its own
    // area and the screen under it against the window — and iOS shrinks a
    // page it pops, so the two added up to as much as 1.09 (traced): Shots
    // started at 0.50 under a profile still reading 0.59, and both played.
    // Measured against the same window, the two always add up to 1, and only
    // one of them can hold half.

    /// The share of the screen left to a host under `cover`: what `cover`
    /// does not take of the window's `bounds`, in window coordinates. Pure,
    /// for tests.
    public static func share(coveredBy cover: CGRect, in bounds: CGRect) -> CGFloat {
        1 - ownShare(of: cover, in: bounds)
    }

    /// The share of the screen a host arriving or leaving takes: its part of
    /// the window's `bounds`, against the window. Pure, for tests.
    public static func ownShare(of host: CGRect, in bounds: CGRect) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 0 }
        let visible = host.intersection(bounds)
        guard !visible.isNull else { return 0 }
        return visible.width * visible.height / (bounds.width * bounds.height)
    }

    /// What a covered host gives up at the exact half: the screen over it
    /// plays there, so the two never play together.
    static let coveredYield: CGFloat = 0.0005

    private func startLink() {
        stopLink()
        hasSampled = false
        let link = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // ⚠️ NOT SAMPLED NOW: before the transition's first frame the cover
        // still stands at its final frame — a push read 0, then 1, and paused
        // the clip for a frame (measured). The link's first tick reads it.
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func sample() {
        // A host that LEFT the window has nothing left to measure: the link
        // stops rather than tick for a transition whose end it may never
        // hear. One not in it yet (an arrival's first tick) waits.
        guard let host else { return stopLink() }
        guard let window = host.window else {
            if hasSampled { trace("left the window"); stopLink() }
            return
        }
        hasSampled = true
        let windowLayer = window.layer.presentation() ?? window.layer
        if isDeparting {
            let hostLayer = host.layer.presentation() ?? host.layer
            let hostRect = hostLayer.convert(hostLayer.bounds, to: windowLayer)
            report(Self.ownShare(of: hostRect, in: window.bounds))
            return
        }
        guard let cover else { return }
        // ⚠️ ONE MEASURE, NOT TWO (the owner's device, 2026-10-31): measured
        // on its own display link, the screen under a moving one read a frame
        // apart from it, and both still played for a frame or two at half
        // (traced). A cover that measures its own place is followed instead:
        // this share is its complement, told whenever it changes.
        if let source = Self.byHost.object(forKey: cover), source.isDeparting, source.link != nil {
            source.adopt(self)
            return
        }
        let coverLayer = cover.layer.presentation() ?? cover.layer
        let coverRect = coverLayer.convert(coverLayer.bounds, to: windowLayer)
        report(Self.share(coveredBy: coverRect, in: window.bounds) - Self.coveredYield)
    }

    /// The display link's target, weakly holding the share so the link never
    /// keeps it alive — and ending the link once the share is gone.
    @MainActor
    private final class LinkTarget: NSObject {
        weak var owner: ViewportShare?
        init(_ owner: ViewportShare) { self.owner = owner }
        /// The link runs on the main run loop.
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { return link.invalidate() }
            owner.sample()
        }
    }
}
