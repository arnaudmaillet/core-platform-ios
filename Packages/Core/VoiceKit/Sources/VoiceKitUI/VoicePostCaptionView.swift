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
    /// becomes the voice, sized to the room. Both players are the same
    /// neutral panel (#2241): at full size its width says its length
    /// (#2329); compact, it fills the width its host gives.
    public enum Size: Sendable, Equatable {
        /// Play / pause, the waveform (tap and drag to seek), the timer: a
        /// post's page, For You's card preview, list cards — its width
        /// says its length (#2329).
        case full
        /// The same panel, as tall since #2329, its width the host's: cards
        /// in horizontal shelves, history rows, the map's text bubble
        /// (#2241's table). Its drags
        /// are its own, as at `.full`, unless the host says otherwise
        /// (`VoicePostCaptionView.show(…dragsAreOwn:)`, #2275): only a
        /// shelf's card gives them to its scroll.
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
///   action (a host's tap recognizer asks `keepsTouch(_:)`). A host sizes
///   the view, not the voice: at `.full` the panel's width says the
///   voice's length within it, leading-aligned (#2329); at `.compact` it
///   takes the view's whole width (#2241) — the shelf's card, the history
///   row and the map's bubble fix it.
/// - **Its drags are its own** (`dragsAreOwn`, #2275), at both sizes: the
///   screen's pans — a list's, a pager's, a map's — wait for the panel's
///   sideways drag. Off only in a horizontal shelf's card: a tap seeks, a
///   drag scrolls the shelf.
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
    /// Whether the player's drags are its own (#2275), as last shown.
    public private(set) var dragsAreOwn = true
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
    ///
    /// - Parameter dragsAreOwn: whether the panel's drags are its own
    ///   (`VoiceView.dragsAreOwn`, #2275): yes at both sizes, but in a
    ///   horizontal shelf's card. Every show says it again, so a reused
    ///   cell never keeps the last host's rule.
    public func show(
        postID: String, url: URL?, duration: TimeInterval, levels: [UInt8], author: String?,
        size: VoicePostDisplay.Size, dragsAreOwn: Bool = true
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
            player.dragsAreOwn = dragsAreOwn
            player.role = .post(author: author)
            hub.bind(player, id: id, url: url, duration: duration, levels: waveform)
            playbackID = id
        }
        self.size = size
        self.dragsAreOwn = dragsAreOwn
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
