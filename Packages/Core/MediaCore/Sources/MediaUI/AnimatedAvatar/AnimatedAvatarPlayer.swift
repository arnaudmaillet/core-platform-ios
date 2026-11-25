import DesignSystem
import LaunchArguments
import MediaCore
import UIKit

/// An animated avatar over its picture (#1358, #1424): the sheet's LAST frame
/// at rest, and the sheet played ONCE, from frame 0 back to that last frame
/// (a seamless loop, so neither end is a cut). When it plays is its SCREEN'S
/// RULE (#2454): the screen it is drawn in declares itself once
/// (`traitOverrides.avatarMotionScreen`), and the table
/// (`AvatarMotionPolicy`) says what that screen's avatars do — nothing, the
/// random rounds, a sequence one at a time, a first display, a change, an
/// arrival. A screen that declares nothing gets the rounds. The viewer's tap
/// replays it (`replay()`, the profile page's avatar).
///
/// Never under `minimumDiameter` (tile thumbnails, danmaku bubbles; a
/// group's first face: `groupFaceMinimumDiameter`), never
/// under Reduce Motion, Low Power Mode or idle calm (a tap ignores the last two),
/// and never more than `maxConcurrent` at once: these limits stay above every
/// rule.
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
    /// The smallest avatar that plays: a post card's author (40 pt), a
    /// Messages row (52 pt), the post screen's author pill (36 pt) do; a
    /// tile's author (16 pt) and a danmaku bubble (20 pt) do not.
    public static let minimumDiameter: CGFloat = 32
    /// The smallest GROUP'S FIRST FACE that plays (#2454, the coordinator on
    /// the owner's 2026-11-23 instruction): the table says a group plays its
    /// first face, and in a 56 pt row that face is 34 pt with two faces, 31
    /// with three, 27 with four — under `minimumDiameter`, most groups would
    /// never play. Every other limit still wins over it: Reduce Motion, Low
    /// Power Mode, idle calm, `maxConcurrent`.
    public static let groupFaceMinimumDiameter: CGFloat = 24
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

    /// Where it ranks in a sequence ordered by it (`.unreadFirst`): its host
    /// raises an unread row.
    public var motionPriority: AvatarMotionPriority = .normal

    /// A FRESH view standing for a change of person — the post screen's
    /// author pill, a new pill per author (#1791): under `.change`, it plays
    /// once on screen like the change it stands for, where a pill's first
    /// avatar rests.
    public var standsForChange = false

    /// Never plays, whatever its screen's rule: a group's faces past its
    /// first, a group's photo (#2454). Its still shows.
    var holdsStill = false {
        didSet { updateMembership() }
    }

    /// A group's first face, the one that plays (`GroupAvatarView`): its
    /// floor is `groupFaceMinimumDiameter`.
    var isGroupFirstFace = false

    /// The smallest it plays at.
    var playableDiameter: CGFloat { isGroupFirstFace ? Self.groupFaceMinimumDiameter : Self.minimumDiameter }

    /// Where sheets come from: the pipeline's the avatar is drawn through
    /// (`AvatarView.setPicture`), or a test's own. Nil: nothing animates.
    var registry: AnimatedAvatars?
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
    /// Who conducts the plays, and holds the table — the app's, or a test's
    /// own.
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
    /// A play owed since the avatar was set, until its display: an arrival's,
    /// or a change's when `owesChange`. Whether it is due is read from the
    /// rule at the display, not when the avatar is set.
    private var owesPlay = false
    private var owesChange = false
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
        // A screen declared above it after it was laid in: its rule now.
        registerForTraitChanges([AvatarMotionTrait.self]) { (player: AnimatedAvatarPlayer, _: UITraitCollection) in
            player.updateMembership(duringTraitChange: true)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Its screen

    /// The screen it is drawn in, with that screen's memory of first
    /// displays; nil when no screen above it declared one.
    var place: AvatarMotionPlace? {
        // ⚠️ A DECLARATION ABOVE IT REACHES ITS TRAITS ON THE NEXT LAYOUT:
        // read now, a header configured before it is laid out would still
        // have no screen.
        updateTraitsIfNeeded()
        return traitCollection.avatarMotionPlace
    }

    /// `place`, as told by a trait change: its traits are current there.
    private func motionPlace(duringTraitChange: Bool) -> AvatarMotionPlace? {
        duringTraitChange ? traitCollection.avatarMotionPlace : place
    }

    /// Its screen's name, nil for none.
    var screen: AvatarMotionScreen? { place?.screen }

    /// The rule it follows now: its screen's, from the table.
    var rule: AvatarMotionRule { holdsStill ? .off : rounds.rule(for: screen) }

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
        // ⚠️ THE RULE IS READ WHEN THE PLAY IS DUE, NOT HERE: off a window, a
        // screen declared above it may not have reached its traits yet (a
        // pill set before it joins the bar read no screen on iOS 26, #2454).
        owesPlay = true
        owesChange = standsForChange || (replacesOne && window != nil)
        guard let registry else { return }
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
        stillImage = url.flatMap { registry?.cachedStill(for: $0, rung: resolvedRung) } ?? AnimatedAvatars.lastFrame(of: sheet)
        sheetView.layer.contents = sheet.sheet.cgImage
        sheetView.layer.contentsRect = last
        isHidden = false
        updateMembership()
        if let stillImage { onStill?(stillImage) }
        let current = rule
        if owesPlay, isVisible {
            // Its display: the owed play plays now, or not at all.
            owesPlay = false
            if owedPlayIsDue(under: current) {
                requestPlay()
                return
            }
        } else if owesPlay, case .change = current, !standsForChange {
            owesPlay = false
        }
        // An arrival keeps owing: its display is still to come.
        if case .firstAppearance = current, isVisible {
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
            if owedPlayIsDue(under: rule) { requestPlay() }
        }
        guard case .firstAppearance = rule else { return }
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

    /// Whether the play owed since the avatar was set is one `rule` plays.
    private func owedPlayIsDue(under rule: AvatarMotionRule) -> Bool {
        switch rule {
        case .arrival: true
        case .change: owesChange
        default: false
        }
    }

    private func scrolled() {
        let visible = isVisible
        defer { wasVisible = visible }
        guard visible, !wasVisible else { return }
        firstAppearance()
    }

    /// A member of its screen's conductor while it can be picked at all:
    /// animated, in a window, and its rule a conducted one (the rounds, a
    /// sequence, after a first display). Off screen, no timer runs for it.
    private func updateMembership(duringTraitChange: Bool = false) {
        guard window != nil, sheet != nil, !holdsStill else { return rounds.leave(self) }
        let screen = motionPlace(duringTraitChange: duringTraitChange)?.screen
        if rounds.rule(for: screen).conducted != nil {
            rounds.join(self, on: screen)
        } else {
            rounds.leave(self)
        }
    }

    /// A beat after it is shown, not the instant it lands (the owner,
    /// 2026-10-19). It counts as played once it PLAYS: shown for less than
    /// the beat, it plays on its next display. Its sheet not here yet,
    /// `adopt` asks again when it lands. Once per screen: a screen pushed
    /// again is a new one (`AvatarMotionPlace`).
    private func firstAppearance() {
        guard case .firstAppearance = rule, let place, let url, !place.firstShown.contains(url),
              sheet != nil, firstDisplayWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.firstDisplayWork = nil
                guard self.url == url, self.isVisible, !place.firstShown.contains(url) else { return }
                place.firstShown.insert(url)
                self.requestPlay()
            }
        }
        firstDisplayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + rounds.tuning.draw(rounds.tuning.firstDisplayDelay), execute: work)
    }

    private func cancelFirstDisplay() {
        firstDisplayWork?.cancel()
        firstDisplayWork = nil
    }

    /// Whether its conductor may play it now: animated, idle, big enough, on
    /// screen, its screen resting (no scroll under it, nothing presented over
    /// it, the scene in front).
    var isRoundCandidate: Bool {
        guard sheet != nil, !isPlaying, min(bounds.width, bounds.height) >= playableDiameter else { return false }
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

    /// Played by its conductor (a round, a sequence): how long the play
    /// lasts, nil when a limit refused it.
    @discardableResult
    func playFromConductor() -> TimeInterval? {
        guard requestPlay(), let sheet else { return nil }
        return Self.playDuration(of: sheet)
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

    @discardableResult
    private func requestPlay(viewerAsked: Bool = false) -> Bool {
        guard let sheet, let last = sheet.frameRects.last else { return refuse("no sheet") }
        guard !isPlaying else { return refuse("already playing") }
        guard min(bounds.width, bounds.height) >= playableDiameter else {
            return refuse("under \(playableDiameter) pt: \(bounds.size)")
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
            let why = "screen=\(screen?.rawValue ?? "unlisted") rule=\(viewerAsked ? "tap" : rule.description)"
            print("[avatar] play \(why) " + String(
                format: "frames=%d loop=%.2fs loops=%d", count, sheet.loopDuration, Self.loopsPerPlay
            ))
        }
        #endif
        // The slot comes back with the animation's end — and, should its
        // delegate never be told (a test host, a stripped layer), a beat after.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.playDuration(of: sheet) + 0.25) { [weak self] in
            self?.playEnded(token)
        }
        return true
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

    private func refuse(_ reason: String) -> Bool {
        lastRefusal = reason
        #if DEBUG
        if Self.logsPlays { print("[avatar] refused screen=\(screen?.rawValue ?? "unlisted") rule=\(rule): \(reason)") }
        #endif
        return false
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
    /// `-avatar-play-log`: each play's screen, rule, frames and loops, when
    /// it ended, and each refusal's reason.
    private static let logsPlays = LaunchArgument.avatarPlayLog.isPassed()
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
