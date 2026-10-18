import DesignSystem
import UIKit

/// The screens where an avatar plays on its first display rather than on
/// scrolling into view (`AnimatedAvatarPlayer.Trigger.firstAppearance`): one
/// per screen, so an avatar plays once there however often its cell is
/// reused.
@MainActor
public final class AnimatedAvatarScope {
    fileprivate var played: Set<URL> = []
    public init() {}
}

/// An animated avatar over its picture (#1358): the sheet's last frame at
/// rest, the sheet played ONCE when the rule says so (the owner,
/// 2026-10-18):
/// - only an avatar that COMES ON SCREEN DURING A SCROLL plays — a screen's
///   avatars already visible when it appears stay still (paging the
///   vertical feed is a scroll);
/// - or, on the two screens where an avatar is large and alone (the profile
///   page, For You's Friends faces), on its FIRST DISPLAY there
///   (`.firstAppearance`);
/// - never under `minimumDiameter` (tile thumbnails, danmaku bubbles), never
///   under Reduce Motion, Power Saving or idle calm, and never more than
///   `maxConcurrent` at once.
///
/// Laid inside the avatar's picture view, which clips it to the avatar's
/// outline; a still avatar shows nothing of it. `attach(to:)` finds or adds
/// it; `setAvatar(_:)` names the avatar on every configure.
@MainActor
public final class AnimatedAvatarPlayer: UIView {
    public enum Trigger {
        /// Plays when it scrolls into view.
        case scrollAppearance
        /// Plays on its first display within the scope's screen.
        case firstAppearance(AnimatedAvatarScope)
        /// Plays when the avatar it shows CHANGES while on screen — a fixed
        /// piece of chrome whose person moves with a scroll: the post
        /// screen's author pill, on paging to the next post. Its first
        /// avatar rests.
        case change
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
        fileprivate var playing = 0
        static let app = Concurrency()
    }

    public var trigger: Trigger = .scrollAppearance
    /// Where sheets come from — the app's, or a test's own.
    var registry = AnimatedAvatars.shared
    /// Who counts the plays — the app's, or a test's own.
    var concurrency = Concurrency.app

    /// The player over `host` (an avatar's picture view), added the first
    /// time.
    public static func attach(to host: UIView) -> AnimatedAvatarPlayer {
        if let existing = host.subviews.lazy.compactMap({ $0 as? AnimatedAvatarPlayer }).first { return existing }
        let player = AnimatedAvatarPlayer(frame: host.bounds)
        player.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(player)
        return player
    }

    private let stillView = UIImageView()
    private let sheetView = AnimatedIconView()
    private var url: URL?
    private var sheet: AnimatedIconSheet?
    /// An appearance that should have played came before the sheet did.
    private var owesPlay = false
    private var wasVisible = false
    private var observations: [NSKeyValueObservation] = []
    private var playToken = 0
    private(set) var isPlaying = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        for view in [stillView, sheetView] as [UIView] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        stillView.contentMode = .scaleAspectFill
        sheetView.contentGravity = .resizeAspectFill
        sheetView.isHidden = true
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
        sheet = nil
        owesPlay = false
        isHidden = true
        guard let url else { return }
        if case .change = trigger, replacesOne, window != nil { owesPlay = true }
        registry.sheet(for: url) { [weak self] sheet in
            guard let self, self.url == url else { return }
            adopt(sheet)
        }
    }

    private func adopt(_ sheet: AnimatedIconSheet?) {
        self.sheet = sheet
        guard let sheet else {
            isHidden = true
            return
        }
        stillView.image = url.flatMap(registry.still(for:)) ?? AnimatedAvatars.lastFrame(of: sheet)
        isHidden = false
        if owesPlay {
            owesPlay = false
            if isVisible { requestPlay() }
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
        guard window != nil else {
            stop()
            wasVisible = false
            return
        }
        // Every scroll view it rides in: a row in a list in a pager.
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                observations.append(scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.scrolled() }
                })
            }
            ancestor = view.superview
        }
        let visible = isVisible
        switch trigger {
        case .change:
            wasVisible = visible
        case .firstAppearance:
            wasVisible = visible
            if visible { firstAppearance() }
        case .scrollAppearance:
            // Dequeued mid-scroll and already in view: it came on screen
            // with the scroll. Present when the screen appeared: still.
            wasVisible = visible
            if visible, isScrolling { appeared() }
        }
    }

    private func scrolled() {
        let visible = isVisible
        defer { wasVisible = visible }
        guard visible, !wasVisible else { return }
        switch trigger {
        case .change: break
        case .firstAppearance: firstAppearance()
        case .scrollAppearance: if isScrolling { appeared() }
        }
    }

    private func firstAppearance() {
        guard case .firstAppearance(let scope) = trigger, let url, !scope.played.contains(url) else { return }
        scope.played.insert(url)
        appeared()
    }

    private func appeared() {
        guard sheet != nil else {
            owesPlay = true
            return
        }
        requestPlay()
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

    // MARK: Playing

    private func requestPlay() {
        guard let sheet, !isPlaying,
              min(bounds.width, bounds.height) >= Self.minimumDiameter,
              !MotionPreference.stillsDecoration,
              concurrency.playing < Self.maxConcurrent
        else { return }
        concurrency.playing += 1
        isPlaying = true
        // The sheets play on a shared clock: shift so frame 0 is the one now.
        sheetView.setArt(.sheet(sheet), phase: 0)
        let now = sheetView.displayedFrame ?? 0
        sheetView.setArt(.sheet(sheet), phase: (sheet.frameCount - now) % sheet.frameCount)
        sheetView.isHidden = false
        playToken += 1
        let token = playToken
        DispatchQueue.main.asyncAfter(deadline: .now() + sheet.loopDuration) { [weak self] in
            guard let self, self.playToken == token else { return }
            self.stop()
        }
    }

    /// Back to the still — the last frame, which is where the loop ended.
    private func stop() {
        playToken += 1
        guard isPlaying else { return }
        isPlaying = false
        concurrency.playing = max(0, concurrency.playing - 1)
        sheetView.isHidden = true
        sheetView.setArt(nil)
    }

    /// The still on show — the sheet's last frame — or nil for a still avatar.
    public var still: UIImage? { sheet == nil ? nil : stillView.image }

    #if DEBUG
    /// What a test reads.
    var debugSheet: AnimatedIconSheet? { sheet }
    var debugStill: UIImage? { stillView.image }
    static var debugPlayingCount: Int { Concurrency.app.playing }
    #endif
}
