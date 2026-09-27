import MediaCore
import UIKit

/// A `UILabel` whose emotes animate — the one building block a text surface
/// adopts.
///
/// ## Adopting it
///
/// Swap the class. Plain `text` is marked on the way in (in the label's font,
/// colour and alignment); an `attributedText` should be built with
/// `EmoteText.attributedString` / `EmoteText.marked`. Everything else — font,
/// colour, lines, truncation, alignment, Dynamic Type — is the label's own.
///
/// ## What it does
///
/// Text with no emotes takes `UILabel`'s own path, untouched. Text with emotes
/// is drawn through `EmoteTextLayout`, which also says where each emote's glyph
/// landed. Over each visible glyph the label places an `AnimatedIconView` —
/// the map's sprite-sheet player — and only once that view holds art does the
/// label stop drawing the glyph underneath. Until then, and whenever an emote
/// cannot animate, the glyph is simply the system emoji. Never blank.
///
/// ## What it costs
///
/// - **Nothing off screen.** Not in a window, or hidden: no layout work, no
///   bakes, no views — and a request still baking is cancelled.
/// - **Nothing per frame.** Playback is a `CAKeyframeAnimation` on the render
///   server; scrolling moves the label, which re-lays nothing out.
/// - **Bounded.** At most `EmoteEngine.maxAnimatedEmotes` animate at once,
///   app-wide; the rest keep their static glyph until a slot frees.
/// - **Reduce Motion** (and serious thermal pressure): no animation at all.
///   Emoji stay the system's own still glyph and nothing is baked; a house
///   emote shows its first frame.
@MainActor
open class EmoteLabel: UILabel {
    /// The engine art comes from. The app's shared one unless a test says
    /// otherwise.
    public var engine: EmoteEngine = .shared {
        didSet { resetPlayers() }
    }

    /// Off switch for a surface that wants the static glyphs only.
    public var animatesEmotes = true {
        didSet {
            guard animatesEmotes != oldValue else { return }
            resetPlayers()
        }
    }

    /// The marked emotes of the current text, in string order.
    private var marks: [(range: NSRange, id: String)] = []
    private let textLayout = EmoteTextLayout()
    /// Per mark index.
    private var players: [Int: EmotePlayer] = [:]
    /// Mark indices whose glyph is currently NOT drawn, because an animation
    /// covers it.
    private var coveredMarks: Set<Int> = []

    override public init(frame: CGRect) {
        super.init(frame: frame)
        observeEnvironment()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeEnvironment()
    }

    // MARK: - Text

    /// Sets plain `text`, drawn in the label's current font, colour and
    /// alignment, with its emotes marked (`:code:`s replaced).
    public func setEmoteText(_ text: String?) {
        guard let text else {
            attributedText = nil
            return
        }
        // Alignment only. A TRUNCATING paragraph mode would make every
        // paragraph a single line — the well-known attributed-`UILabel` trap;
        // the label's own `lineBreakMode` already governs its last line.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment
        attributedText = EmoteText.attributedString(text, attributes: [
            .font: font ?? UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: textColor ?? UIColor.label,
            .paragraphStyle: paragraph
        ], catalog: engine.catalog)
    }

    override open var attributedText: NSAttributedString? {
        get { super.attributedText }
        set {
            super.attributedText = newValue
            textDidChange()
        }
    }

    /// Plain text with emotes is marked on the way in, so swapping the class
    /// is the whole adoption for a label fed through `text`. Text without
    /// emotes stays on `UILabel`'s own path.
    override open var text: String? {
        get { super.text }
        set {
            if let newValue, EmoteParser.mayContainEmotes(newValue),
               !EmoteParser.matches(in: newValue, catalog: engine.catalog).isEmpty {
                setEmoteText(newValue)
                return
            }
            super.text = newValue
            textDidChange()
        }
    }

    /// `UILabel` re-applies a new font (Dynamic Type included) across its
    /// attributed text; the marks survive, the layout does not.
    override open var font: UIFont! {
        didSet { layoutDidChange() }
    }

    override open var numberOfLines: Int {
        didSet { layoutDidChange() }
    }

    override open var lineBreakMode: NSLineBreakMode {
        didSet { layoutDidChange() }
    }

    override open var isHidden: Bool {
        didSet { if isHidden != oldValue { layoutDidChange() } }
    }

    /// Whether the current text holds emotes the label draws itself.
    public var hasEmotes: Bool { !marks.isEmpty && !adjustsFontSizeToFitWidth }

    private func textDidChange() {
        resetPlayers()
        marks = EmoteText.marks(in: super.attributedText)
        if !marks.isEmpty { setNeedsLayout() }
    }

    private func layoutDidChange() {
        guard !marks.isEmpty else { return }
        setNeedsLayout()
        setNeedsDisplay()
    }

    // MARK: - Layout and drawing

    /// The box the text is laid out in for `rect`: the label's own width and
    /// height, a hair taller so a rounding never drops the last line.
    private func configureLayout(for rect: CGRect, lines: Int) -> Bool {
        guard let text = super.attributedText, text.length > 0, rect.width > 0 else { return false }
        textLayout.configure(
            text: text,
            size: CGSize(width: rect.width, height: rect.height + 1),
            numberOfLines: lines,
            lineBreakMode: lineBreakMode
        )
        return true
    }

    /// Where the text container's origin sits in `rect`: vertically centred,
    /// like `UILabel`, on a device pixel.
    private func textOrigin(in rect: CGRect) -> CGPoint {
        let used = textLayout.usedSize
        let scale = max(traitCollection.displayScale, 1)
        let y = rect.minY + max(0, (rect.height - used.height) / 2)
        return CGPoint(x: rect.minX, y: (y * scale).rounded() / scale)
    }

    override open func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        guard hasEmotes else { return super.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines) }
        guard let text = super.attributedText, text.length > 0, bounds.width > 0 else {
            return super.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines)
        }
        textLayout.configure(text: text, size: bounds.size, numberOfLines: numberOfLines, lineBreakMode: lineBreakMode)
        let used = textLayout.usedSize
        let scale = max(traitCollection.displayScale, 1)
        return CGRect(
            x: bounds.minX, y: bounds.minY,
            width: (used.width * scale).rounded(.up) / scale,
            height: (used.height * scale).rounded(.up) / scale
        )
    }

    override open func drawText(in rect: CGRect) {
        guard hasEmotes, configureLayout(for: rect, lines: numberOfLines) else {
            super.drawText(in: rect)
            return
        }
        let origin = textOrigin(in: rect)
        var cleared: [CGRect] = []
        if !coveredMarks.isEmpty {
            let placements = textLayout.placements(for: marks)
            for index in coveredMarks where index < placements.count {
                if let placement = placements[index] { cleared.append(placement.glyphBox) }
            }
        }
        textLayout.draw(at: origin, clearing: cleared, scale: traitCollection.displayScale)
    }

    /// The rect this label's `drawText(in:)` ends up drawing into, for a
    /// given bounds — `bounds` itself unless a subclass insets or moves its
    /// text (a padded pill). Emotes are placed in it, so a subclass that
    /// changes where it draws must say so here, or its emotes land beside
    /// their glyphs.
    open func emoteTextRect(forBounds bounds: CGRect) -> CGRect {
        bounds
    }

    override open func layoutSubviews() {
        super.layoutSubviews()
        placeEmotes()
    }

    override open func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            resetPlayers()
        } else if !marks.isEmpty {
            setNeedsLayout()
        }
    }

    /// Places, starts, moves and removes the players for the current layout.
    private func placeEmotes() {
        let textBox = emoteTextRect(forBounds: bounds)
        guard hasEmotes, animatesEmotes, window != nil, !isHidden,
              configureLayout(for: textBox, lines: numberOfLines)
        else {
            resetPlayers()
            return
        }
        let origin = textOrigin(in: textBox)
        let placements = textLayout.placements(for: marks)
        let policy = AnimatedIconView.policy
        let motion: EmoteEngine.Motion = policy == .still ? .still : .loop
        let scale = traitCollection.displayScale
        var live = Set<Int>()

        for (index, mark) in marks.enumerated() {
            guard let placement = placements[index], let emote = engine.catalog.emote(id: mark.id) else { continue }
            // An emoji's still IS the system glyph: nothing to bake or place.
            if motion == .still && emote.isUnicodeEmoji { continue }
            let square = placement.square.offsetBy(dx: origin.x, dy: origin.y)
            let side = EmoteEngine.pixelSide(forPoints: square.width, scale: scale)
            live.insert(index)
            let player: EmotePlayer
            if let existing = players[index], existing.matches(emote: emote, side: side, motion: motion) {
                player = existing
            } else {
                if let replaced = players[index] { release(replaced) }
                player = EmotePlayer(emote: emote, side: side, motion: motion)
                players[index] = player
                addSubview(player.view)
                start(player, index: index)
            }
            player.view.frame = square
            if !player.isShowing, let art = player.art {
                // Art that arrived while every playback slot was taken.
                present(art, in: player, index: index)
            }
        }
        for index in Array(players.keys) where !live.contains(index) {
            if let player = players.removeValue(forKey: index) { release(player) }
        }
        updateCoveredMarks()
    }

    private func start(_ player: EmotePlayer, index: Int) {
        if let art = engine.cachedArt(for: player.emote, pixelSide: player.side, motion: player.motion) {
            present(art, in: player, index: index)
            return
        }
        player.request = engine.requestArt(
            for: player.emote, pixelSide: player.side, motion: player.motion
        ) { [weak self, weak player] art in
            guard let self, let player, self.players[index] === player else { return }
            player.request = nil
            guard let art else { return }
            self.present(art, in: player, index: index)
            self.updateCoveredMarks()
        }
    }

    private func present(_ art: AnimatedIconArt, in player: EmotePlayer, index: Int) {
        player.art = art
        let animates = player.motion == .loop && art.frameCount > 1
        if animates, !player.holdsSlot {
            guard engine.acquirePlaybackSlot(waiter: self) else { return }
            player.holdsSlot = true
        }
        player.view.setArt(art)
        player.view.isHidden = false
        player.isShowing = true
    }

    private func release(_ player: EmotePlayer) {
        player.request?.cancel()
        player.request = nil
        player.view.setArt(nil)
        player.view.removeFromSuperview()
        player.isShowing = false
        if player.holdsSlot {
            player.holdsSlot = false
            engine.releasePlaybackSlot()
        }
    }

    private func resetPlayers() {
        guard !players.isEmpty || !coveredMarks.isEmpty else { return }
        let dropped = players.values
        players.removeAll()
        dropped.forEach(release)
        updateCoveredMarks()
        setNeedsLayout()
    }

    /// Redraws the text only when the set of covered glyphs changed — a label
    /// whose emotes are all already playing is not redrawn by a layout pass.
    private func updateCoveredMarks() {
        let covered = Set(players.compactMap { $0.value.isShowing ? $0.key : nil })
        guard covered != coveredMarks else { return }
        coveredMarks = covered
        setNeedsDisplay()
    }

    // MARK: - Environment

    private func observeEnvironment() {
        // A sheet's bucket is a function of the screen's scale.
        registerForTraitChanges([UITraitDisplayScale.self]) { (self: EmoteLabel, _) in
            self.layoutDidChange()
        }
        let center = NotificationCenter.default
        // Selector observers are dropped with the label: nothing to remove.
        for name in [
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification
        ] {
            center.addObserver(self, selector: #selector(motionPolicyChanged), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(willEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    /// The policy is read when a player starts, so a change restarts them all
    /// — a demotion to still as much as a promotion back.
    ///
    /// ⚠️ NONISOLATED: the power-state notification is posted off the main
    /// thread, and a main-actor selector would trap on the isolation check.
    @objc nonisolated private func motionPolicyChanged() {
        Task { @MainActor [weak self] in self?.resetPlayers() }
    }

    /// A trip to the background can strip layer animations.
    @objc nonisolated private func willEnterForeground() {
        Task { @MainActor [weak self] in
            self?.players.values.forEach { $0.view.reinstall() }
        }
    }

    // MARK: - Test seams

    /// How many emotes are placed (animating or waiting on art).
    var placedEmoteCount: Int { players.count }
    /// How many are showing art over their glyph.
    var showingEmoteCount: Int { players.values.filter(\.isShowing).count }
    /// The squares the players occupy, in the label's coordinates.
    var emoteFrames: [CGRect] { players.keys.sorted().compactMap { players[$0]?.view.frame } }
    var coveredMarkIndices: Set<Int> { coveredMarks }
}

extension EmoteLabel: EmotePlaybackWaiting {
    func emotePlaybackSlotFreed() {
        setNeedsLayout()
    }
}

/// One emote on one label: its player view, and the request feeding it.
@MainActor
final class EmotePlayer {
    let emote: Emote
    let side: Int
    let motion: EmoteEngine.Motion
    let view: AnimatedIconView
    var request: EmoteRequest?
    var art: AnimatedIconArt?
    var isShowing = false
    var holdsSlot = false

    init(emote: Emote, side: Int, motion: EmoteEngine.Motion) {
        self.emote = emote
        self.side = side
        self.motion = motion
        view = AnimatedIconView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isHidden = true
        view.accessibilityElementsHidden = true
    }

    func matches(emote: Emote, side: Int, motion: EmoteEngine.Motion) -> Bool {
        self.emote.id == emote.id && self.side == side && self.motion == motion
    }
}
