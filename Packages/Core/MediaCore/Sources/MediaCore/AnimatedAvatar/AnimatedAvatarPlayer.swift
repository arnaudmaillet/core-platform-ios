import DesignSystem
import UIKit

/// The screens where an avatar plays on its first display rather than in the
/// rounds (`AnimatedAvatarPlayer.Trigger.firstAppearance`): one per screen, so
/// an avatar plays once there however often its cell is reused.
@MainActor
public final class AnimatedAvatarScope {
    fileprivate var played: Set<URL> = []
    public init() {}
}

/// An animated avatar over its picture (#1358, #1424): the sheet's LAST frame
/// at rest, and the sheet played ONCE, from frame 0 back to that last frame
/// (a seamless loop, so neither end is a cut). When it plays (the owner,
/// 2026-10-19):
/// - most avatars (lists, cards, rows) are picked at random, a few at a
///   time, staggered, while their screen rests (`AnimatedAvatarRounds`).
///   Nothing plays because it appeared or scrolled;
/// - on the two screens where an avatar is large and alone (the profile page,
///   For You's Friends faces), on its FIRST DISPLAY there, after a short
///   beat (`.firstAppearance`);
/// - the post screen's author pill, when its person CHANGES (`.change`);
/// - on the viewer's tap (`replay()`, the profile page's avatar).
///
/// Never under `minimumDiameter` (tile thumbnails, danmaku bubbles), never
/// under Reduce Motion, Low Power Mode or idle calm (a tap ignores the last two),
/// and never more than `maxConcurrent` at once.
///
/// ⚠️ ONE LAYER, AT REST AND PLAYING. The sheet's layer always shows a frame
/// of the sheet: its model value is the last frame, and a play is a single,
/// non-repeating keyframe animation from frame 0 to the last. However late
/// the bookkeeping runs, Core Animation ends the play ON the last frame, on
/// the sheet's own clock — frame 0 is never shown after it (#1424: a timer
/// hid the sheet late, after the shared clock had wrapped).
///
/// Laid inside the avatar's picture view, which clips it to the avatar's
/// outline; a still avatar shows nothing of it. `attach(to:)` finds or adds
/// it; `setAvatar(_:)` names the avatar on every configure.
@MainActor
public final class AnimatedAvatarPlayer: UIView {
    public enum Trigger {
        /// Picked at random by the rounds while its screen rests.
        case rounds
        /// Plays on its first display within the scope's screen, then, like
        /// `.rounds`, whenever the rounds pick it (the owner, 2026-10-20: a
        /// face that played once and never again read as broken).
        case firstAppearance(AnimatedAvatarScope)
        /// Plays when the avatar it shows CHANGES while on screen — a fixed
        /// piece of chrome whose person moves with a scroll: the post
        /// screen's author pill, on paging to the next post. Its first
        /// avatar rests.
        case change
        /// Plays once when it first shows on screen, its sheet landed — a
        /// FRESH view standing for a change: the post screen's author pill,
        /// a new pill per author (#1791), whose host keeps `.change` on the
        /// first one so that one rests. Never in the rounds.
        case arrival
    }

    /// The smallest avatar that plays: a post card's author (40 pt), a
    /// Messages row (52 pt), the post screen's author pill (36 pt) do; a
    /// tile's author (16 pt) and a danmaku bubble (20 pt) do not.
    public static let minimumDiameter: CGFloat = 32
    /// Playing at once, app-wide — measured headroom (#1358's bench).
    public static let maxConcurrent = 4

    /// How many play at once: the app's one, or a test's own — shared, it
    /// let a parallel test's players hold every slot, and a play refused
    /// for room is not asked again.
    @MainActor
    final class Concurrency {
        fileprivate(set) var playing = 0
        static let app = Concurrency()
    }

    public var trigger: Trigger = .rounds {
        didSet { updateMembership() }
    }
    /// Where sheets come from — the app's, or a test's own.
    var registry = AnimatedAvatars.shared
    /// The sheet's rung (#1444): set by a view that knows the size it draws
    /// at (`AvatarView`: its picture's bucket); nil, from this player's own
    /// drawn size when the avatar is set.
    public var rung: AnimatedAvatars.Rung?

    private var resolvedRung: AnimatedAvatars.Rung {
        if let rung { return rung }
        let side = max(bounds.width, bounds.height)
        guard side > 0 else { return .px128 }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        return AnimatedAvatars.Rung(pixels: side * scale)
    }
    /// Who counts the plays — the app's, or a test's own.
    var concurrency = Concurrency.app
    /// Who picks the plays — the app's, or a test's own.
    var rounds = AnimatedAvatarRounds.app {
        willSet { rounds.leave(self) }
        didSet { updateMembership() }
    }

    /// Told when an animated avatar's still is known — its sheet's last
    /// frame, which the avatar draws as ITS picture (#1424): one image, at
    /// rest, playing or not.
    public var onStill: ((UIImage) -> Void)?

    /// The player over `host` (an avatar's picture view), added the first
    /// time.
    public static func attach(to host: UIView) -> AnimatedAvatarPlayer {
        if let existing = host.subviews.lazy.compactMap({ $0 as? AnimatedAvatarPlayer }).first { return existing }
        let player = AnimatedAvatarPlayer(frame: host.bounds)
        player.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(player)
        return player
    }

    private let sheetView = UIView()
    private(set) var url: URL?
    private var sheet: AnimatedIconSheet?
    private var stillImage: UIImage?
    /// A play asked for before the sheet came.
    private var owesPlay = false
    private var wasVisible = false
    private var observations: [NSKeyValueObservation] = []
    private var playToken = 0
    private var firstDisplayWork: DispatchWorkItem?
    private(set) var isPlaying = false

    private static let playKey = "avatar.play"

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        sheetView.frame = bounds
        sheetView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sheetView.layer.contentsGravity = .resizeAspectFill
        sheetView.isUserInteractionEnabled = false
        addSubview(sheetView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The avatar shown — nil for none. A still avatar hides the player; an
    /// animated one rests on its sheet's last frame.
    public func setAvatar(_ url: URL?) {
        guard url != self.url else { return }
        let replacesOne = self.url != nil
        self.url = url
        stop()
        cancelFirstDisplay()
        sheet = nil
        stillImage = nil
        sheetView.layer.contents = nil
        owesPlay = false
        isHidden = true
        updateMembership()
        guard let url else { return }
        if case .change = trigger, replacesOne, window != nil { owesPlay = true }
        if case .arrival = trigger { owesPlay = true }
        let rung = resolvedRung
        registry.sheet(for: url, rung: rung) { [weak self] sheet in
            guard let self, self.url == url else { return }
            adopt(sheet)
        }
    }

    private func adopt(_ sheet: AnimatedIconSheet?) {
        self.sheet = sheet
        guard let sheet, let last = sheet.frameRects.last else {
            isHidden = true
            updateMembership()
            return
        }
        stillImage = url.flatMap { registry.cachedStill(for: $0, rung: resolvedRung) } ?? AnimatedAvatars.lastFrame(of: sheet)
        sheetView.layer.contents = sheet.sheet.cgImage
        sheetView.layer.contentsRect = last
        isHidden = false
        updateMembership()
        if let stillImage { onStill?(stillImage) }
        if owesPlay {
            if isVisible {
                owesPlay = false
                requestPlay()
            } else if case .change = trigger {
                owesPlay = false
            }
            // `.arrival` keeps owing: its display is still to come.
        } else if case .firstAppearance = trigger, isVisible {
            // ⚠️ The avatar often arrives AFTER its screen is up — a profile
            // loads after its header is on show — so the first display was
            // seen with nothing to play. It is the first display that counts.
            firstAppearance()
        }
    }

    // MARK: When it plays

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        observations = []
        updateMembership()
        guard window != nil else {
            stop()
            cancelFirstDisplay()
            wasVisible = false
            return
        }
        let visible = isVisible
        wasVisible = visible
        // An arrival whose sheet landed before it joined the window.
        if owesPlay, visible, sheet != nil {
            owesPlay = false
            requestPlay()
        }
        guard case .firstAppearance = trigger else { return }
        // Every scroll view it rides in — a face in a row that scrolls
        // sideways: its first display can come with a scroll.
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                observations.append(scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.scrolled() }
                })
            }
            ancestor = view.superview
        }
        if visible { firstAppearance() }
    }

    private func scrolled() {
        let visible = isVisible
        defer { wasVisible = visible }
        guard visible, !wasVisible else { return }
        firstAppearance()
    }

    /// A member of the rounds while it can be picked at all: animated, in a
    /// window, and theirs to play — `.rounds` and `.firstAppearance` alike;
    /// `.change` plays only on a change. Off screen, no timer runs for it.
    private func updateMembership() {
        if joinsRounds, window != nil, sheet != nil {
            rounds.join(self)
        } else {
            rounds.leave(self)
        }
    }

    /// A beat after it is shown, not the instant it lands (the owner,
    /// 2026-10-19). It counts as played once it PLAYS: shown for less than
    /// the beat, it plays on its next display. Its sheet not here yet,
    /// `adopt` asks again when it lands.
    private func firstAppearance() {
        guard case .firstAppearance(let scope) = trigger, let url, !scope.played.contains(url),
              sheet != nil, firstDisplayWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.firstDisplayWork = nil
                guard self.url == url, self.isVisible, !scope.played.contains(url) else { return }
                scope.played.insert(url)
                self.requestPlay()
            }
        }
        firstDisplayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + rounds.tuning.draw(rounds.tuning.firstDisplayDelay), execute: work)
    }

    /// Whether the rounds may pick it: everything but `.change` and
    /// `.arrival`.
    private var joinsRounds: Bool {
        switch trigger {
        case .change, .arrival: false
        case .rounds, .firstAppearance: true
        }
    }

    private func cancelFirstDisplay() {
        firstDisplayWork?.cancel()
        firstDisplayWork = nil
    }

    /// Whether the rounds may pick it now: animated, idle, big enough, on
    /// screen, its screen resting (no scroll under it, nothing presented over
    /// it, the scene in front).
    var isRoundCandidate: Bool {
        guard sheet != nil, !isPlaying, min(bounds.width, bounds.height) >= Self.minimumDiameter else { return false }
        return isVisible && !isScrolling && !isCovered && isSceneActive
    }

    /// On screen: inside its window and inside every scroll view it rides in.
    private var isVisible: Bool {
        // Its own `isHidden` is not asked: a still avatar's player is
        // hidden and still has a place on screen.
        // Not laid out yet is not on screen: a zero-sized avatar counted as
        // seen would never play when it gets its size.
        guard let window, bounds.width > 0, bounds.height > 0 else { return false }
        var rect = convert(bounds, to: window)
        var ancestor = superview
        while let view = ancestor {
            if view.isHidden || view.alpha < 0.01 { return false }
            if view.clipsToBounds { rect = rect.intersection(view.convert(view.bounds, to: window)) }
            ancestor = view.superview
        }
        rect = rect.intersection(window.bounds)
        return !rect.isNull && rect.width * rect.height >= bounds.width * bounds.height * 0.5
    }

    private var isScrolling: Bool {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView, scroll.isDragging || scroll.isDecelerating { return true }
            ancestor = view.superview
        }
        return false
    }

    /// Under a presentation that is not its own: a sheet, a full-screen modal.
    private var isCovered: Bool {
        guard var top = window?.rootViewController else { return false }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        guard top !== window?.rootViewController else { return false }
        return !isDescendant(of: top.view)
    }

    /// The app in front: a backgrounded or inactive scene plays nothing. A
    /// window with no scene (a test's) counts as in front.
    private var isSceneActive: Bool {
        guard let scene = window?.windowScene else { return true }
        return scene.activationState == .foregroundActive
    }

    // MARK: Playing

    /// Plays it again, now — the viewer's own request (a tap on the profile
    /// page's avatar). Low Power Mode and idle calm do not block it; Reduce
    /// Motion does, and an avatar with no sheet does nothing.
    public func replay() {
        requestPlay(viewerAsked: true)
    }

    /// Picked by the rounds.
    func playFromRound() {
        requestPlay()
    }

    /// How many times one play runs the sheet's loop, back to back (the owner,
    /// 2026-10-25): the sheet is baked as a seamless loop, so two passes read
    /// as one longer clip, and the second still ends on the last frame — the
    /// rest.
    static let loopsPerPlay = 2

    /// How long one play lasts on the sheet's clock.
    static func playDuration(of sheet: AnimatedIconSheet) -> CFTimeInterval {
        sheet.loopDuration * CFTimeInterval(loopsPerPlay)
    }

    private func requestPlay(viewerAsked: Bool = false) {
        guard let sheet, let last = sheet.frameRects.last else { return refuse("no sheet") }
        guard !isPlaying else { return refuse("already playing") }
        guard min(bounds.width, bounds.height) >= Self.minimumDiameter else {
            return refuse("under \(Self.minimumDiameter) pt: \(bounds.size)")
        }
        if viewerAsked {
            guard !MotionPreference.reducesMotion else { return refuse("reduce motion") }
        } else {
            guard !MotionPreference.stillsDecoration else {
                return refuse("decoration stilled (reduce motion \(MotionPreference.reducesMotion), idle calm \(IdleCalm.isCalm))")
            }
            guard concurrency.playing < Self.maxConcurrent else { return refuse("\(concurrency.playing) already playing") }
        }
        concurrency.playing += 1
        isPlaying = true
        playCount += 1
        playToken += 1
        let token = playToken
        // Frame 0 now, each frame its own duration, the last one held: the
        // model value IS the last frame, so the end of the animation is the
        // rest, on the sheet's own clock.
        let count = sheet.frameRects.count
        let animation = CAKeyframeAnimation(keyPath: "contentsRect")
        animation.calculationMode = .discrete
        animation.values = sheet.frameRects.map { NSValue(cgRect: $0) }
        animation.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
        animation.duration = sheet.loopDuration
        animation.repeatCount = Float(Self.loopsPerPlay)
        let fps = Float(min(60, max(1, (1 / sheet.frameDuration).rounded())))
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        animation.delegate = PlayEnd(player: self, token: token)
        sheetView.layer.contentsRect = last
        sheetView.layer.add(animation, forKey: Self.playKey)
        lastPlayAnimation = animation
        #if DEBUG
        playStartedAt = CACurrentMediaTime()
        if Self.logsPlays {
            print(String(format: "[avatar] play frames=%d loop=%.2fs loops=%d", count, sheet.loopDuration, Self.loopsPerPlay))
        }
        #endif
        // The slot comes back with the animation's end — and, should its
        // delegate never be told (a test host, a stripped layer), a beat after.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.playDuration(of: sheet) + 0.25) { [weak self] in
            self?.playEnded(token)
        }
    }

    fileprivate func playEnded(_ token: Int) {
        guard token == playToken, isPlaying else { return }
        release()
    }

    /// How many times it has started playing — what a test reads: a play
    /// lasts one loop (a test sheet's is 0.2 s), so `isPlaying` can have
    /// come and gone before a starved test looks again.
    private(set) var playCount = 0

    /// Why the last asked-for play was refused, nil when none was — what a
    /// failing test prints.
    private(set) var lastRefusal: String?

    /// The last play's animation, for a test to read its shape.
    private(set) var lastPlayAnimation: CAKeyframeAnimation?

    private func refuse(_ reason: String) {
        lastRefusal = reason
    }

    /// Back to the still — the last frame, the layer's model value.
    private func stop() {
        playToken += 1
        sheetView.layer.removeAnimation(forKey: Self.playKey)
        guard isPlaying else { return }
        release()
    }

    private func release() {
        #if DEBUG
        if Self.logsPlays, let started = playStartedAt {
            print(String(format: "[avatar] play ended after %.2fs", CACurrentMediaTime() - started))
        }
        playStartedAt = nil
        #endif
        isPlaying = false
        concurrency.playing = max(0, concurrency.playing - 1)
    }

    /// The still on show — the sheet's last frame — or nil for a still avatar.
    public var still: UIImage? { sheet == nil ? nil : stillImage }

    #if DEBUG
    /// `-avatar-play-log`: each play's frames and loops, and when it ended.
    private static let logsPlays = ProcessInfo.processInfo.arguments.contains("-avatar-play-log")
    private var playStartedAt: CFTimeInterval?

    /// What a test reads.
    var debugSheet: AnimatedIconSheet? { sheet }
    var debugStill: UIImage? { stillImage }
    /// The frame the layer rests on (its model value).
    var debugRestingRect: CGRect { sheetView.layer.contentsRect }
    static var debugPlayingCount: Int { Concurrency.app.playing }
    #endif
}

/// A play's end, told by Core Animation. Holds the player weakly: an
/// animation keeps its delegate. Told on the main thread, and read only
/// there.
private final class PlayEnd: NSObject, CAAnimationDelegate, @unchecked Sendable {
    weak var player: AnimatedAvatarPlayer?
    let token: Int

    init(player: AnimatedAvatarPlayer, token: Int) {
        self.player = player
        self.token = token
    }

    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        MainActor.assumeIsolated { player?.playEnded(token) }
    }
}
