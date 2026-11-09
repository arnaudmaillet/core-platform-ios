import DesignSystem
import UIKit

/// Voice posts (#2204) on every surface that draws one (#2208): the switch
/// and the sizes, in one module every surface reaches — PostGrid, Maps and
/// Feed alike (no feature imports another).
public enum VoicePostDisplay {
    /// `-voice-posts` (DEBUG) until #2210: without it a voice post is drawn
    /// as the text post it is, on every surface.
    public static var areDrawn: Bool { DebugFlags.isOn("-voice-posts") }

    /// How much room a surface gives the caption's voice (#2208) — the
    /// owner's rule: the TEXT post's design everywhere, only the caption
    /// becomes the voice, sized to the room.
    public enum Size: Sendable, Equatable {
        /// Play / pause, the waveform (tap and drag to seek), the timer: the
        /// map's text bubble, For You's card preview, list cards, history rows.
        case full
        /// The same, but no drag on the waveform — it would fight the
        /// shelf's scroll: cards in horizontal shelves.
        case compact
        /// A mic, a still waveform, the length; not interactive — a tap is
        /// the tile's: grid tiles, map pins.
        case mark
    }
}

/// A voice post's caption on a card, a tile or a bubble (#2208): the shared
/// voice component at the size the host's room allows, bound to the post's
/// one playback id (`VoicePlaybackHub.postID`), and let go when it leaves
/// the screen.
///
/// - **`.full` / `.compact`:** a `VoiceView`, bound to the hub — its play
///   button and waveform take their own taps; the rest of the card keeps its
///   action (a host's tap recognizer asks `keepsTouch(_:)`).
/// - **`.mark`:** a `VoiceMarkView`; no binding, no taps.
/// - **It stops when its card leaves the screen** — out of the window,
///   reused (`clear()`), or a list's `didEndDisplaying` (`leftScreen()`) —
///   unless another view on screen shows the same voice: the page a tap on
///   the card opened goes on, at the same place (`VoicePlaybackHub
///   .viewLeftScreen`).
/// - **Its ink is its ground's** (`inks`), set by the host.
public final class VoicePostCaptionView: UIView {
    /// The size shown; nil while nothing is.
    public private(set) var size: VoicePostDisplay.Size?
    /// The id the voice plays under, while a player shows.
    public private(set) var playbackID: String?
    /// The player (`.full`, `.compact`) or the mark (`.mark`) shown.
    public private(set) var voiceView: VoiceView?
    public private(set) var markView: VoiceMarkView?
    /// The app's one hub; a test puts its own in before `show`.
    public lazy var hub: VoicePlaybackHub = .shared
    /// The ground's colours: the played bars and the glyph, the unplayed
    /// bars, the timer. The mark wears `played`.
    public var inks: VoiceView.Inks = .standard {
        didSet { applyInks() }
    }
    private var duration: TimeInterval = 0
    private var author: String?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows post `postID`'s voice at `size`. A view shown again (a reused
    /// cell) lets its last voice go first.
    public func show(
        postID: String, url: URL?, duration: TimeInterval, levels: [UInt8], author: String?,
        size: VoicePostDisplay.Size
    ) {
        let id = VoicePlaybackHub.postID(postID)
        if let shownID = playbackID, shownID != id || size != self.size { release() }
        self.duration = duration
        self.author = author
        isHidden = false
        let waveform = levels.isEmpty ? nil : levels
        switch size {
        case .mark:
            removePlayer()
            let mark = markView ?? install(VoiceMarkView())
            markView = mark
            mark.configure(duration: duration, levels: waveform)
            playbackID = nil
        case .full, .compact:
            markView?.removeFromSuperview()
            markView = nil
            let playerSize: VoiceView.Size = size == .full ? .full : .compact
            if let shown = voiceView, shown.size != playerSize { removePlayer() }
            let player = voiceView ?? install(VoiceView(size: playerSize))
            voiceView = player
            player.role = .post(author: author)
            hub.bind(player, id: id, url: url, duration: duration, levels: waveform)
            playbackID = id
        }
        self.size = size
        applyInks()
    }

    /// Shows nothing — a cell reused for a post that does not speak; a voice
    /// it played stops (unless shown elsewhere on screen).
    public func clear() {
        release()
        removePlayer()
        markView?.removeFromSuperview()
        markView = nil
        size = nil
        isHidden = true
    }

    /// The card left the screen (a list's `didEndDisplaying`): its voice
    /// stops where it is, unless another view on screen shows it.
    public func leftScreen() {
        guard let player = voiceView else { return }
        hub.viewLeftScreen(player)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { leftScreen() }
    }

    /// What its card reads aloud: "Voice post, 32 seconds".
    public var accessibilityDescription: String {
        VoiceView.accessibilityLabel(role: .post(author: author), senderName: nil, duration: duration, unplayed: false)
    }

    /// Whether `touch` is the voice's own — on its play button, its waveform
    /// or its speed chip — so a card's tap recognizer leaves it alone and the
    /// rest of the card keeps its action (#2208).
    public static func keepsTouch(_ touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if let voice = current as? VoiceView { return voice.keepsPress(at: touch.location(in: voice)) }
            view = current.superview
        }
        return false
    }

    // MARK: - Parts

    private func install<View: UIView>(_ part: View) -> View {
        part.translatesAutoresizingMaskIntoConstraints = false
        addSubview(part)
        let trailing = part is VoiceMarkView
            ? part.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
            : part.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            part.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailing,
            part.topAnchor.constraint(equalTo: topAnchor),
            part.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        return part
    }

    /// Lets the bound voice go: it stops unless shown elsewhere.
    private func release() {
        guard let player = voiceView, playbackID != nil else { return }
        hub.viewLeftScreen(player)
        hub.unbind(player)
        playbackID = nil
    }

    private func removePlayer() {
        release()
        voiceView?.removeFromSuperview()
        voiceView = nil
    }

    private func applyInks() {
        voiceView?.inks = inks
        markView?.ink = inks.played
    }
}
