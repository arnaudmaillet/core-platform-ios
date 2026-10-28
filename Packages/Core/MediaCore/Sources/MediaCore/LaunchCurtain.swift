import UIKit

/// The launch screen held over the shell until the first post's media is on
/// screen, then faded out (#1812, the owner 2026-10-28).
///
/// It was a hard cut from the launch screen to the shell at the first auth
/// state — a keychain read, long before the first post's picture — so a cold
/// start showed ~180 ms of black page under the whole chrome, and then the
/// picture in one frame. Now the shell is installed UNDER the launch view: it
/// lays out, the first page dequeues, the picture decodes and renders behind
/// it, and the launch view fades out over it.
///
/// ⚠️ THE SHELL IS NEVER HIDDEN WHILE IT WAITS. It must render, or the
/// picture is never committed and the signal never comes: the curtain is a
/// view over it, never an `isHidden` or `alpha = 0` on it.
///
/// What it waits for, `LaunchCurtain.decision`:
/// - the first page has what it shows (`shots.firstPageReady`: its picture, a
///   text page, a picture that failed for good, or the page's own empty or
///   failed state — offline with nothing on disk), plus one committed frame;
/// - or the cap, `cap` seconds after `app.didFinishLaunching` — a first
///   install whose first page is slow to come: the page then shows its own
///   centred loader;
/// - or nothing, when the launch opens somewhere else (a deep link, a
///   notification): it lifts as soon as the shell is in.
@MainActor
public final class LaunchCurtain {
    /// Why the curtain lifted.
    public enum Reveal: Equatable, Sendable {
        /// The first page had what it shows.
        case ready
        /// The cap ran out first.
        case capped
        /// The launch opened somewhere other than Shots.
        case route
    }

    /// The longest the launch screen is held, from `app.didFinishLaunching`.
    /// One constant, tuned on a device. DEBUG: `-launch-cap <seconds>`
    /// overrides it — a simulator's Debug launch under `-mock-auto-login`
    /// reaches the shell past 2 s, where the cap would fire at once.
    public static let cap: TimeInterval = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-launch-cap"), index + 1 < arguments.count,
           let seconds = TimeInterval(arguments[index + 1]) { return seconds }
        #endif
        return 2
    }()
    /// The fade: ease-out, no zoom.
    public static let fadeDuration: TimeInterval = 0.3

    /// Whether to lift now, and why — nil to keep waiting. Pure, for tests.
    public static func decision(pageReady: Bool, sinceLaunch: TimeInterval?, opensElsewhere: Bool) -> Reveal? {
        if opensElsewhere { return .route }
        if pageReady { return .ready }
        if let sinceLaunch, sinceLaunch >= cap { return .capped }
        return nil
    }

    /// The launch screen's view, kept over the shell.
    private let curtain: UIView
    /// Holds what drives the curtain's own loader (`LaunchViewController`'s
    /// gate) for as long as the curtain shows.
    private let owner: AnyObject
    public private(set) var isUp = false
    public private(set) var revealed: Reveal?
    private var frameLink: CADisplayLink?

    /// What the curtain waits for: the first Shots page having what it shows.
    /// Settable for tests, which use a milestone of their own.
    let readyMilestone: String

    public init(curtain: UIView, owner: AnyObject, readyMilestone: String = "shots.firstPageReady") {
        self.curtain = curtain
        self.owner = owner
        self.readyMilestone = readyMilestone
    }

    /// Puts the curtain over `window`'s new root and waits for the signal.
    public func hold(over window: UIWindow, opensElsewhere: Bool) {
        curtain.frame = window.bounds
        curtain.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(curtain)
        isUp = true
        LaunchTimeline.curtainIsUp = true
        if let reveal = Self.decision(pageReady: false, sinceLaunch: nil, opensElsewhere: opensElsewhere) {
            return lift(reveal)
        }
        LaunchTimeline.whenReached(readyMilestone) { [weak self] in self?.pageIsReady() }
        let since = LaunchTimeline.time(of: "app.didFinishLaunching")
            .flatMap { start in LaunchTimeline.sinceProcessStart().map { $0 - start } } ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, Self.cap - since)) { [weak self] in
            self?.lift(.capped)
        }
    }

    /// The picture is set: lifts on the next committed frame, so the fade
    /// never uncovers a picture that is set but not yet drawn.
    private func pageIsReady() {
        guard isUp, frameLink == nil else { return }
        let link = CADisplayLink(target: FrameProxy(self), selector: #selector(FrameProxy.tick))
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    fileprivate func frameCommitted() {
        frameLink?.invalidate()
        frameLink = nil
        lift(.ready)
    }

    /// Fades the curtain out and takes it away. Sound may start as the fade
    /// begins (`LaunchTimeline.curtainIsUp`).
    public func lift(_ reveal: Reveal) {
        guard isUp else { return }
        isUp = false
        revealed = reveal
        frameLink?.invalidate()
        frameLink = nil
        LaunchTimeline.mark("launch.revealed")
        if reveal == .capped { LaunchTimeline.mark("launch.revealCapped") }
        LaunchTimeline.curtainIsUp = false
        let curtain = curtain
        let owner = owner
        UIView.animate(withDuration: Self.fadeDuration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            curtain.alpha = 0
        } completion: { _ in
            curtain.removeFromSuperview()
            withExtendedLifetime(owner) {}
        }
    }

    /// Whether the curtain's view is still in the window.
    public var curtainIsShown: Bool { curtain.superview != nil }
}

/// Holds the curtain for its display link without keeping it alive.
@MainActor
private final class FrameProxy: NSObject {
    weak var curtain: LaunchCurtain?
    init(_ curtain: LaunchCurtain) { self.curtain = curtain }

    @objc func tick(_ link: CADisplayLink) {
        guard let curtain else { return link.invalidate() }
        curtain.frameCommitted()
    }
}
