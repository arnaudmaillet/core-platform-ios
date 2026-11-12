import DesignSystem
import UIKit

/// The app's voice component (#2205): a voice message in the conversation
/// (#2104) and a voice post's caption (#2204), one view in three sizes —
/// `.full` and `.compact` here, `.mark` as `VoiceMarkView`. Moved out of
/// Feed so every surface that draws a voice post reaches it.
///
/// - **`.full`:** play / pause, the waveform (tap and drag to seek), the
///   slot at the trailing end — the timer, or the speed's words while it
///   plays; its width says its length (#2329).
/// - **`.compact`:** the same panel, 44 pt tall as well (#2329), with a
///   smaller glyph — and the width of its host whatever the length: a
///   shelf's card, a history row, the map's bubble fix it.
/// - **Its drags are its own at both sizes** (`dragsAreOwn`, #2275): a drag
///   that starts on the play button is the button's, a sideways drag on the
///   panel is the panel's (on the waveform it scrubs), and the screen's pans
///   wait for them. Off only where something scrolls sideways under it — a
///   horizontal shelf's card: a tap seeks, a drag is the shelf's.
/// - **The ink follows its ground** (`inks`), set by the host.
///
/// **A neutral panel (#2241, the owner 2026-11-10),** the same on every
/// surface — a conversation, a post's page, a card, a history row, the map's
/// glass bubble, For You's lift:
///
/// ```
///  ╭──────────────────────────────────────╮
///  │ ▶  ▂▅▇▅▃▂▅▇▆▃▂▁▃▅▇▅▃▂▁▂▃▅▇  [0:12] • │   44 pt, the media tiles' corner
///  ╰──────────────────────────────────────╯
///  bare  waveform: as many bars   slot   unplayed dot
///  glyph as the width holds       (timer or speed)
/// ```
///
/// - **Its width says its length (#2329, Telegram's rule)** where
///   `widthFollowsLength` (a voice post at full size, a voice message):
///   `minimumPanelWidth` up to 2 s, then straight to the full available
///   width at 30 s and beyond (`panelWidth(forLength:available:)`) —
///   leading-aligned, the bars' count following the width. A host that
///   fixes the voice's width (a shelf's card, a history row, the map's
///   bubble: `.compact`) keeps it whatever the length. `maxPanelWidth` caps
///   the available width in a conversation's text column.
/// - **A rounded rectangle (#2329):** the media tiles' corner
///   (`Surface.mediaCornerRadius`) — a voice in a post is content, like a
///   photo, not a control's capsule; in a conversation the panel is the
///   message's bubble and wears the media message's corner, the same token.
/// - **Its ground is the host's ink at a low opacity** (`Inks.panel`), never
///   the brand's colour: it reads on a plain row, a card, a dark page and
///   glass alike.
/// - **Its line is centred in the panel (#2274):** a host that ever gives it
///   less than its height shrinks the air above and below evenly, never on
///   one side.
/// - **The play button is a bare glyph (#2274, the owner 2026-11-10: no
///   disc),** in the played bars' ink, in a 32 pt frame — the same
///   `AppIconButton`, so the same 44 pt target, press swell and loader. Its
///   play ⇄ pause is the scale and fade (#2329): a glyph on every frame.
/// - **The waveform is the message's face:** 2 pt bars 2 pt apart across
///   the panel between the glyph and the slot, re-binned from the voice's
///   100 levels to however many fit, and drawn with the voice's own
///   contrast (`drawnShares`) so a flat-sounding take still has a shape.
/// - **One slot at the trailing end (#2274):** the total length at rest, the
///   speed while it plays, the time reached when paused mid-way, the total
///   again at the end. One size for all of them (`slotSize`), so the
///   waveform is binned once and never moves.
/// - **The slot hugs its words (#2364):** as wide as the widest of them —
///   the voice's timer at its longest and the bare "1.5×" — and what it
///   shows stands against its trailing edge, so no empty ground sits round
///   the timer; the spare, when one is shorter, goes toward the waveform.
/// - **The speed is a bare text button (#2364):** "1×", "1.5×", "2×" in the
///   timer's font and ink, no capsule, no ground — dimmed under the finger,
///   with an invisible 44 pt target round the words (`VoiceSpeedButton`).
///   Between the timer and the speed the words cross-fade in place as the
///   digits turn (`showSlot`).
/// - **The timer's format is the voice's (#2294, `timerStyle`):** a post's
///   seconds, "30″"; a message's clock, "0:30".
/// - **Under a finger on the waveform the whole panel swells (#2274),** as
///   the app's buttons do: its ground grows (`PressFeedback.swelledScale`),
///   its corner kept, and what it holds scales by one factor on both
///   axes (#2284) — never a layout, and the seek is read on the panel at
///   rest.
/// - **Its drags are its own:** one that starts on the play button or the
///   waveform goes before the list's scroll and the screen's swipes.
/// - **It draws; the screen plays** (`VoicePlayer`, one for the app): every
///   tap is told through the callbacks.
public final class VoiceView: UIView, UIGestureRecognizerDelegate {
    /// What the bubble shows, all of it — so a reused cell never keeps
    /// another message's progress.
    public struct State: Equatable {
        public var delivery: Delivery = .sent
        public var levels: [UInt8]? = nil
        public var duration: TimeInterval = 0
        /// A received message the viewer hasn't played.
        public var unplayed = false
        public var playback: Playback = .rest
        public var speedLabel = "1×"

        public init(
            delivery: Delivery = .sent, levels: [UInt8]? = nil, duration: TimeInterval = 0,
            unplayed: Bool = false, playback: Playback = .rest, speedLabel: String = "1×"
        ) {
            self.delivery = delivery
            self.levels = levels
            self.duration = duration
            self.unplayed = unplayed
            self.playback = playback
            self.speedLabel = speedLabel
        }

        /// A message's delivery — a voice post is always `.sent`.
        public enum Delivery: Equatable, Sendable {
            case sent
            case sending
            case failed
        }

        public enum Playback: Equatable {
            /// Not started, or played to its end: the duration shows.
            case rest
            case loading
            case playing(progress: Double)
            /// Paused mid-way.
            case paused(progress: Double)
            /// The audio could not be read: ↻.
            case failed
        }

        public var progress: Double {
            switch playback {
            case .playing(let progress), .paused(let progress): progress
            default: 0
            }
        }

        public var isUnderway: Bool {
            switch playback {
            case .playing, .paused: true
            default: false
            }
        }
    }

    /// How much room the host gives it (#2205).
    public enum Size: Sendable, Equatable {
        /// The thread's bubble, a post's page, a list's card: its width says
        /// its length (#2329).
        case full
        /// A shelf's card, a history row, the map's bubble: as tall as full
        /// since #2329, a smaller glyph, the host's width whatever the
        /// length. Whether its drags are its own is the host's
        /// (`dragsAreOwn`), not the size's (#2275).
        case compact
    }

    /// Whose voice it is, for VoiceOver: a message (its sender), a post or
    /// a post's comment (#2309).
    public enum Role: Equatable, Sendable {
        case message
        case post(author: String?)
        /// A voice comment (#2309): public and up to a minute, as a post —
        /// the seconds timer, no unplayed dot — read as a comment.
        case comment(author: String?)
    }

    /// What the trailing slot shows (#2274).
    public enum SlotContent: Equatable, Sendable {
        /// The total length at rest and at the end, the time reached when
        /// paused mid-way.
        case timer
        /// The speed's words (#2364), while it plays — and from the tap,
        /// while its audio loads: the glyph and the slot change together.
        case speed
    }

    /// How the slot changed (#2329).
    public enum SlotMotion: Equatable, Sendable {
        /// Off screen, a row filled afresh.
        case cut
        /// The words cross-fade in place against the slot's trailing edge
        /// while they turn like a counter's digit (#2329, #2364: no ground
        /// grows any more).
        case morph
        /// Reduce Motion: one dissolves into the other in place.
        case crossFade
    }

    /// Its colours, from its ground (#2205): a text face's ink, a glass
    /// bubble's vibrancy. `.standard` is the conversation's.
    ///
    /// Neutral by rule (#2241): every colour here is the host's ink or one
    /// derived from it — the panel's ground included — never the brand's.
    public struct Inks: Equatable, Sendable {
        /// The played bars and the play glyph (#2274).
        public var played: UIColor
        public var unplayed: UIColor
        /// The timer's words and the speed's (#2329, #2364): one ink, so the
        /// two read as one thing — the label's, by default.
        public var timer: UIColor

        public init(played: UIColor, unplayed: UIColor, timer: UIColor) {
            self.played = played
            self.unplayed = unplayed
            self.timer = timer
        }

        /// `VoiceView.ink`, spelled out: a static here is not the view's actor's.
        /// The timer and the speed in the label's ink (#2329), not a grey.
        public static var standard: Inks {
            Inks(played: UIColor.label.withAlphaComponent(0.7), unplayed: .tertiaryLabel, timer: .label)
        }

        /// The panel's ground (#2241): the played ink, opaque, at a low
        /// opacity — a light grey on a light ground, a dark grey on a dark
        /// one, glass showing through on the map. Derived rather than picked,
        /// so a host that sets its ink gets a matching ground for free.
        public var panel: UIColor { Self.panel(from: played) }

        /// The panel's opacity over its ground, by appearance: a dark ground
        /// needs a little more for the same step.
        public static let panelOpacityLight: CGFloat = 0.06
        public static let panelOpacityDark: CGFloat = 0.12

        /// `ink` as a panel's ground (#2241).
        public static func panel(from ink: UIColor) -> UIColor {
            UIColor { traits in
                let opacity: CGFloat = traits.userInterfaceStyle == .dark
                    ? Inks.panelOpacityDark : Inks.panelOpacityLight
                return ink.resolvedColor(with: traits).withAlphaComponent(opacity)
            }
        }
    }

    public let size: Size
    /// Its start from its leading edge: the thread's text column.
    public let leadingInset: CGFloat
    /// The panel's widest (#2241): a conversation's text column caps it, so
    /// it doesn't stretch across an iPad-wide or landscape column — the
    /// "full width" a 30 s message reaches (#2329). Nil: the host's width.
    public let maxPanelWidth: CGFloat?
    /// Whether the panel's width says the voice's length (#2329,
    /// `panelWidth(forLength:available:)`): a voice post at full size — the
    /// feed's card, the text page, For You's lift — and a voice message.
    /// Off where the host fixes the voice's width (`.compact`: a shelf's
    /// card, a history row, the map's bubble): the panel fills it.
    public var widthFollowsLength: Bool {
        didSet {
            guard widthFollowsLength != oldValue else { return }
            applyWidthRule()
        }
    }
    /// Whether the panel's drags are its own (#2275) — the host's call, not
    /// the size's: the play button's hold (any direction), the panel's
    /// sideways hold and the waveform's scrub, every other pan waiting for
    /// them (`WaveformBars.yields`): a list's, a pager's, a map's, the
    /// screen's swipes. A vertical drag still goes to the list or the pager.
    /// Off only inside a horizontal shelf's card, whose scroll takes the
    /// drag: a tap still seeks.
    public var dragsAreOwn: Bool {
        didSet {
            guard dragsAreOwn != oldValue else { return }
            applyDragRule()
        }
    }
    public var role: Role = .message {
        didSet {
            guard role != oldValue else { return }
            updateTrailingEnd()
            // A post's seconds or a message's clock (#2294): the slot is
            // measured again for the other format.
            refreshSlotSize()
            if shownSlot != .speed { showTimerText() }
            updateAccessibility()
        }
    }
    /// How the timer writes the length (#2294): the role's — a voice
    /// post's seconds ("30″"), a voice message's clock ("0:30").
    public var timerStyle: TimerStyle { TimerStyle(role: role) }
    public var inks: Inks = .standard {
        didSet { applyInks() }
    }
    /// Whether motion is kept to a minimum — the app's Reduce Motion
    /// (`MotionPreference`); a test sets its own. Under it the panel never
    /// swells (#2274) and the slot cross-fades (#2329).
    public var reducesMotion: @MainActor () -> Bool = { MotionPreference.reducesMotion }

    // MARK: - Geometry

    /// The play glyph's frame: 32 pt at both sizes since #2329 (40 in full
    /// before), with the HIG's 44 pt hit region round it
    /// (`AppControl.hitRegion`).
    public static func buttonSide(for size: Size) -> CGFloat {
        32
    }

    /// The bare play glyph (#2274): 20 pt in full, 16 pt compact — what
    /// still tells the two sizes apart, with the width rule (#2329).
    public static func glyphPointSize(for size: Size) -> CGFloat {
        size == .full ? 20 : 16
    }

    /// The bars' full height: 24 pt at both sizes (#2329). #2241's 32 pt
    /// held a short voice up on a full-width panel; a short voice is a short
    /// panel now.
    public static func waveformHeight(for size: Size) -> CGFloat {
        24
    }

    /// The panel's air round the glyph's frame — above, below and before it:
    /// 6 pt at both sizes (#2329).
    public static func panelPadding(for size: Size) -> CGFloat {
        6
    }

    /// The panel's air after the slot (or the dot), its trailing end: 12 pt,
    /// read against the play glyph's air on the leading side (#2364) — the
    /// 6 pt padding and the glyph's inset in its 32 pt frame, about 13 pt —
    /// now that the words stand against the slot's trailing edge.
    public static let panelTrailingPadding: CGFloat = Spacing.md

    /// The panel's height at the default text size: the glyph's frame and
    /// its air — 44 pt at both sizes (#2329, 56 in full before). A larger
    /// timer makes it taller; playing never does.
    public static func panelHeight(for size: Size) -> CGFloat {
        buttonSide(for: size) + 2 * panelPadding(for: size)
    }

    /// The panel's corner (#2329): the media tiles' (`Surface
    /// .mediaCornerRadius`), a rounded rectangle at every size and text
    /// size — no longer concentric with a glyph that has had no disc since
    /// #2274. A conversation's media message wears the same corner, so a
    /// voice message — whose panel is its bubble — follows it.
    public static func panelCornerRadius(for size: Size) -> CGFloat {
        Surface.mediaCornerRadius
    }

    /// A conversation's panel at its widest (#2241): the text column, held
    /// to this so a landscape or iPad column never stretches it — the full
    /// width a 30 s message reaches (#2329).
    public static let conversationMaxWidth: CGFloat = 280

    // MARK: - The width says the length (#2329)

    /// The panel's narrowest, a voice of `minimumWidthLength` or less: the
    /// glyph, the bars and the slot at the default text size — about 18 bars
    /// on a post, 16 on a message, whose unplayed dot's place comes out of
    /// them, since the slot hugs its words (#2364; a dozen before).
    /// Telegram's is 120 pt, round a smaller timer.
    public static let minimumPanelWidth: CGFloat = 168
    /// Up to this length the panel stands at its narrowest.
    public static let minimumWidthLength: TimeInterval = 2
    /// From this length on the panel takes the full available width.
    public static let fullWidthLength: TimeInterval = 30

    /// How far `length` takes the panel from its narrowest to the full
    /// width, 0…1: straight from `minimumWidthLength` to `fullWidthLength`,
    /// on whole seconds — the timer's — so a take whose length comes back a
    /// tenth different once sent (4.37 s → 4.4 s) keeps its width.
    public static func lengthShare(_ length: TimeInterval) -> CGFloat {
        let whole = max(0, length.rounded(.down))
        let share = (whole - minimumWidthLength) / (fullWidthLength - minimumWidthLength)
        return CGFloat(min(1, max(0, share)))
    }

    /// The panel's width for a voice `length` long given `available` points
    /// (#2329, Telegram's rule): `minimumPanelWidth` up to 2 s, the full
    /// `available` width from 30 s, straight between; never wider than
    /// `available`, and `available` itself when that is under the minimum.
    public static func panelWidth(forLength length: TimeInterval, available: CGFloat) -> CGFloat {
        guard available > 0 else { return 0 }
        let narrowest = min(minimumPanelWidth, available)
        return narrowest + (available - narrowest) * lengthShare(length)
    }

    /// The unplayed dot's side.
    public static let dotSide: CGFloat = 6

    /// The widest speed the slot says (#2274), as bare words (#2364): the
    /// slot holds it.
    public static let widestSpeedLabel = "1.5×"

    /// The speed's target round its words, at least, on both axes (#2364):
    /// the HIG's 44 pt, invisible — it may reach over the waveform's end and
    /// the panel's trailing air.
    public static let speedTargetSide: CGFloat = 44
    /// The speed's words under the finger (#2364): dimmed, as a text
    /// button's are — no ground appears.
    public static let speedPressedAlpha: CGFloat = 0.35
    /// The speed's words changing (1× → 1.5× → 2×): a short cross-fade in
    /// place.
    public static let speedChangeDuration: TimeInterval = 0.15

    /// The speed's target round words standing at `words` (#2364): grown
    /// evenly to at least `speedTargetSide` on each axis, centred on them.
    public static func speedTarget(around words: CGRect) -> CGRect {
        let dx = max(0, (speedTargetSide - words.width) / 2)
        let dy = max(0, (speedTargetSide - words.height) / 2)
        return words.insetBy(dx: -dx, dy: -dy)
    }

    // MARK: - The slot's morph (#2329)

    /// The timer ⇄ speed change: one motion, eased in and out, no overshoot.
    public static let slotMorphDuration: TimeInterval = 0.25
    /// How far the words travel as they turn — up and out, up and in.
    public static let slotTurnDistance: CGFloat = 6
    /// Reduce Motion's cross-fade between the timer and the speed.
    public static let slotCrossFadeDuration: TimeInterval = 0.2

    /// The slot's change: cut off screen or for a row filled afresh, the
    /// morph on screen, a cross-fade under Reduce Motion.
    public static func slotMotion(animated: Bool, reducesMotion: Bool) -> SlotMotion {
        guard animated else { return .cut }
        return reducesMotion ? .crossFade : .morph
    }

    /// The timer's font (#2329), and the speed's (#2364): a row button's
    /// title font (`AppButton.titleFont(for: .row)`, the subheadline on the
    /// app's scale, scaled with the text size) with monospaced digits, so
    /// the count never jiggles and the two read at one size.
    public static var timerFont: UIFont {
        timerFont(compatibleWith: nil)
    }

    /// `timerFont` at `traits`' text size — nil: the app's.
    public static func timerFont(compatibleWith traits: UITraitCollection?) -> UIFont {
        UIFont.appMonospacedDigitFont(forTextStyle: .subheadline, compatibleWith: traits)
    }

    /// The slot's one size (#2364): as wide as the widest of its states as
    /// words in `font` — the timer at its longest, the voice's total `length`
    /// in its own `style` (a post's "30″", a message's "0:30"), and the bare
    /// `widestSpeedLabel` — and as tall as a line of them. Nothing round
    /// the words: no capsule, no inset.
    public static func slotSize(forLength length: TimeInterval, style: TimerStyle, font: UIFont) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let longest = (timerText(length, style: style) as NSString).size(withAttributes: attributes)
        let speed = (widestSpeedLabel as NSString).size(withAttributes: attributes)
        let width = max(longest.width, speed.width)
        let height = max(longest.height, speed.height, font.lineHeight)
        return CGSize(width: ceil(width), height: ceil(height))
    }

    /// `slotSize(forLength:style:font:)` in the timer's font at `traits`'
    /// text size — nil: the app's.
    public static func slotSize(forLength length: TimeInterval, style: TimerStyle, traits: UITraitCollection?) -> CGSize {
        slotSize(forLength: length, style: style, font: timerFont(compatibleWith: traits))
    }

    /// What the slot shows for `playback` (#2274): the speed while it plays
    /// (and loads, from the tap), the timer otherwise.
    public static func slotContent(for playback: State.Playback) -> SlotContent {
        switch playback {
        case .playing, .loading: .speed
        case .rest, .paused, .failed: .timer
        }
    }

    /// The scale the panel's content swells to under a finger on its
    /// waveform (#2274): the app's press swell on the panel's size, ONE
    /// factor on both axes (`PressFeedback.swell(for:)`, #2284) — the glyph,
    /// the bars, the slot grow without stretching. The ground grows the rest
    /// (`swelledGroundSize(for:)`).
    public static func swelledScale(for panelSize: CGSize) -> CGAffineTransform {
        let even = PressFeedback.swell(for: panelSize).content
        return CGAffineTransform(scaleX: even, y: even)
    }

    /// The panel's ground swollen (#2284), in the panel's own points — under
    /// the content's scale: drawn, it reaches the app's swell, about 9 pt
    /// across and 5 pt up and down on a full panel.
    public static func swelledGroundSize(for panelSize: CGSize) -> CGSize {
        let growth = PressFeedback.swell(for: panelSize).groundGrowth
        return CGSize(width: panelSize.width + growth.width, height: panelSize.height + growth.height)
    }

    /// The bars' ink and the mark's — the played bars: a dark grey, not the
    /// brand's colour nor black (the owner, 2026-11-07).
    public static let ink = UIColor.label.withAlphaComponent(0.7)
    public static let barWidth: CGFloat = 2
    public static let barGap: CGFloat = 2
    public static let minBarHeight: CGFloat = 2
    /// How long a play waits on its audio before the loader replaces the
    /// pause glyph: the glyph turns on the tap, the loader only when it lasts.
    public static let loaderDelay: TimeInterval = 0.4

    /// How many bars a waveform `width` wide holds: 2 pt bars, 2 pt apart
    /// (about 45 at 180 pt).
    public static func barCount(forWidth width: CGFloat) -> Int {
        max(1, Int((width + barGap) / (barWidth + barGap)))
    }

    /// The message's levels as `count` bars.
    ///
    /// - **Fewer bars than levels:** the loudest level of each bin — a peak
    ///   shows where the voice is.
    /// - **More bars than levels (#2241):** read between the levels, straight
    ///   from one to the next. A full-width panel can hold more bars than a
    ///   voice's 100 levels; repeating each level drew flat blocks.
    public static func rebin(_ levels: [UInt8], to count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        guard !levels.isEmpty else { return Array(repeating: 0, count: count) }
        let n = levels.count
        guard count > n else {
            return (0..<count).map { bar in
                let start = bar * n / count
                let end = max(start + 1, (bar + 1) * n / count)
                return levels[start..<min(end, n)].max() ?? 0
            }
        }
        let last = Double(n - 1)
        let span = Double(count - 1)
        return (0..<count).map { bar in
            let position: Double = Double(bar) * last / span
            let low = Int(position.rounded(.down))
            let high = min(low + 1, n - 1)
            let share: Double = position - Double(low)
            let value: Double = Double(levels[low]) * (1 - share) + Double(levels[high]) * share
            return UInt8(value.rounded())
        }
    }

    /// The share of the waveform's height each bar stands at, 0…1 — 0 for a
    /// pause, which draws the minimum bar.
    ///
    /// ⚠️ THE VOICE'S OWN CONTRAST (#2241). Levels arrive already in decibels
    /// against the take's loud parts (`VoiceWaveform`), and a take whose
    /// loudness barely moves — the mock's synthesised voices, a steady
    /// speaker — sits at the top all through: re-binned to a full width it
    /// drew an almost even row (the owner's screenshot, a 2 s voice). Each
    /// bar is read against the voice's own range instead: from a little
    /// under its quiet tenth (`contrastFloorPercentile`, less
    /// `contrastFloorMargin`) to its peak, over at least `contrastMinimumSpan`
    /// levels (a voice of one level stays full), then squared, so the loud
    /// words stand out. A voiced bar never falls under `quietShare`: it stays
    /// taller than a pause.
    public static func drawnShares(of bars: [UInt8]) -> [CGFloat] {
        let voiced = bars.filter { $0 > 0 }.sorted()
        guard let peak = voiced.last else { return bars.map { _ in 0 } }
        let tenthIndex = Int(Double(voiced.count - 1) * contrastFloorPercentile)
        let floor: Int = max(0, Int(voiced[tenthIndex]) - contrastFloorMargin)
        let span: Double = max(Double(Int(peak) - floor), contrastMinimumSpan)
        return bars.map { level in
            guard level > 0 else { return 0 }
            let below: Double = Double(Int(peak) - Int(level))
            let share: Double = min(1, max(0, 1 - below / span))
            return max(quietShare, CGFloat(share * share))
        }
    }

    /// Where a voice's quiet floor is read, among its voiced bars.
    public static let contrastFloorPercentile: Double = 0.1
    /// How far under that floor the range starts, in levels — the quietest
    /// tenth still stands a little above `quietShare`.
    public static let contrastFloorMargin = 4
    /// The narrowest range a voice is read over, in levels.
    public static let contrastMinimumSpan: Double = 8
    /// The shortest a voiced bar is drawn, as a share of the height.
    public static let quietShare: CGFloat = 0.12

    /// The waveform drawn when a voice comes with no levels (a summary that
    /// carries none, #2205): a fixed, speech-like rise and fall, 100 levels.
    public static let genericLevels: [UInt8] = (0..<100).map { index in
        let t = Double(index) / 99
        let envelope = sin(t * .pi) * 0.7 + 0.3
        let ripple = (sin(t * 37) + sin(t * 61 + 1.3)) / 4 + 0.5
        return UInt8(max(3, min(31, (envelope * ripple * 31).rounded())))
    }

    /// How a voice's length is written (#2294, the owner 2026-11-11): what
    /// the voice is decides it, and nothing writes a voice's length by hand —
    /// `timerText(_:style:)` for the eyes, `spokenTime(_:style:)` for
    /// VoiceOver.
    public enum TimerStyle: Equatable, Sendable {
        /// A voice message, up to five minutes: the clock, "0:30", "4:59".
        case clock
        /// A voice post, up to a minute: whole seconds and the seconds sign,
        /// "30″" — never "0:30", and "60″" at the limit, never a minute. A
        /// longer one (from before the limit) still says "75″": one format
        /// per kind of voice.
        case seconds

        /// The style of the voice `role` says: a message's clock, a post's
        /// or a comment's seconds.
        public init(role: Role) {
            switch role {
            case .message: self = .clock
            case .post, .comment: self = .seconds
            }
        }
    }

    /// The seconds sign (#2294): the double prime, U+2033 — not a straight
    /// quote nor a curly one — right after the digits.
    public static let secondsSign = "\u{2033}"

    /// A length as the timer shows it: "0:12", "12:04", "1:02:03".
    public static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        let hours = whole / 3_600, minutes = whole % 3_600 / 60, rest = whole % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// A voice post's length as its timer shows it (#2294): whole seconds,
    /// rounded down as `clock` rounds them, and the seconds sign — "0″",
    /// "7″", "60″", "75″".
    public static func seconds(_ length: TimeInterval) -> String {
        "\(max(0, Int(length.rounded(.down))))\(secondsSign)"
    }

    /// A length as a timer in `style` shows it: `clock` or `seconds`.
    public static func timerText(_ length: TimeInterval, style: TimerStyle) -> String {
        switch style {
        case .clock: clock(length)
        case .seconds: seconds(length)
        }
    }

    /// A timer's length as VoiceOver reads it (#2294): a post's "30 seconds"
    /// (never "30 double prime"); a message's clock, as it always read.
    public static func spokenTime(_ length: TimeInterval, style: TimerStyle) -> String {
        switch style {
        case .clock: return clock(length)
        case .seconds:
            let whole = max(0, Int(length.rounded(.down)))
            return whole == 1 ? "1 second" : "\(whole) seconds"
        }
    }

    // MARK: - Callbacks

    /// Play or pause (or try again after a failure).
    public var onPlayTap: (() -> Void)?
    /// A tap or a drag on the waveform, 0…1; `scrubbing` while the finger is down.
    public var onSeek: ((_ fraction: Double, _ scrubbing: Bool) -> Void)?
    public var onSpeedTap: (() -> Void)?
    /// "Not sent. Tap to retry".
    public var onRetry: (() -> Void)?

    // MARK: - Parts

    /// The panel (#2241): its ground and everything the voice draws inside
    /// it. Under a finger on the waveform (#2274) it scales by the content's
    /// one factor (#2284) — its transform, never its frame.
    private let frameView = UIView()
    /// The panel's neutral ground and its corner (#2329), filling the
    /// panel: what GROWS under the finger (#2284) — its size, round at every
    /// frame — while the panel's transform scales the rest evenly. Laid by
    /// hand (`layoutGround`), never by a constraint.
    private let panelGround = UIView()
    /// The panel's line: the glyph's frame's height, or the slot's words'
    /// when larger text makes it taller — centred in the panel.
    private let line = UILayoutGuide()
    /// The app's icon button as a bare glyph (#2274: the disc is gone), in
    /// the played bars' ink, with the app's swell under the finger and a
    /// 44 pt target. The same button as before, so the same Replace morph.
    /// The owner's play and pause (#2276), swapped as `PlayPauseGlyph`
    /// says for this site.
    private let playButton = VoicePlayGlyphButton(style: .glyph, content: .symbol(AppSymbol.play.rawValue), dims: false)
    private let loader = AppLoaderView(size: .medium)
    /// The waveform's box: the line's whole height, between the glyph and
    /// the slot; the bars fill it.
    private let scrubber = UIView()
    /// The trailing slot (#2274): one size for the timer and the speed,
    /// whatever the state — the waveform ends at its leading edge. It hugs
    /// its words (#2364).
    private let slot = UILayoutGuide()
    private var slotWidth: NSLayoutConstraint?
    private var slotHeight: NSLayoutConstraint?
    /// What the slot was last sized for: the voice's length, its timer's
    /// format (#2294), the text size.
    private var slotSizedFor: (duration: TimeInterval, style: TimerStyle, category: UIContentSizeCategory)?
    /// The panel's content ends at the slot (a post) or at the unplayed
    /// dot's place after it (a message), whatever the state.
    private var endsAtSlot: NSLayoutConstraint?
    private var endsAtDot: NSLayoutConstraint?
    /// The panel closes the view, or the "Not sent" line under it does.
    private var panelEndsView: NSLayoutConstraint?
    public let waveform = WaveformBars()
    private let timerLabel = UILabel()
    /// The speed as a bare text button (#2364, the owner 2026-11-12): its
    /// words in the timer's font and ink, no capsule, no ground, dimmed
    /// under the finger, a 44 pt target round them. It fills the slot, its
    /// words against the slot's trailing edge, as the timer's are.
    private let speedButton = VoiceSpeedButton()
    /// The width rule's constraints (#2329), rebuilt for a new length.
    private var lengthRule: [NSLayoutConstraint] = []
    /// The slot's last change (#2329).
    private var lastSlotMotion: SlotMotion = .cut
    private let dot = UIView()
    private let failedLabel = UILabel()
    /// VoiceOver's voice while the speed shows (#2274): the panel then reads
    /// as this element, and the speed as its own beside it.
    private lazy var playElement = VoicePlayElement(owner: self)
    public private(set) var state = State()
    private var shownGlyph = ""
    private var scrubSteps = -1
    private var pendingLoader: DispatchWorkItem?
    private let sideHold = UIPanGestureRecognizer()
    /// The play button's hold: a drag that starts on the button is its own.
    private let playHold = UIPanGestureRecognizer()
    /// What the slot shows; nil until first shown.
    private var shownSlot: SlotContent?
    /// A finger is down on the waveform — a tap or a drag, until it lifts
    /// or is cancelled.
    private var fingerOnWaveform = false
    /// A finger is scrubbing the bars (the waveform's drag).
    private var isScrubbing = false
    /// The panel stands swollen.
    private var isSwollen = false
    /// A glyph set without its transition.
    private var glyphStill = false

    /// - Parameters:
    ///   - leadingInset: where the panel starts — a conversation's text column.
    ///   - maxPanelWidth: the panel's widest (#2241); nil fills the host.
    ///   - dragsAreOwn: whether its drags are its own (#2275) — at both
    ///     sizes, but in a horizontal shelf's card.
    ///   - widthFollowsLength: whether the width says the length (#2329);
    ///     nil: yes at full size, no compact.
    public init(
        size: Size = .full, leadingInset: CGFloat = 0, maxPanelWidth: CGFloat? = nil, dragsAreOwn: Bool = true,
        widthFollowsLength: Bool? = nil
    ) {
        self.size = size
        self.leadingInset = leadingInset
        self.maxPanelWidth = maxPanelWidth
        self.dragsAreOwn = dragsAreOwn
        self.widthFollowsLength = widthFollowsLength ?? (size == .full)
        super.init(frame: .zero)
        frameView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(frameView)
        panelGround.isUserInteractionEnabled = false
        panelGround.layer.cornerRadius = Self.panelCornerRadius(for: size)
        panelGround.layer.cornerCurve = .continuous
        frameView.addSubview(panelGround)

        // ⚠️ NO PRESSED DIMMING (`dims: false`; the owner's device check,
        // 2026-11-06, filmed): the glyph greyed under the finger kept that
        // grey through the Replace, half a second after the tap.
        playButton.symbolPointSize = Self.glyphPointSize(for: size)
        // The app's one play ⇄ pause swap decides Replace or the scale and
        // fade (#2276). ⚠️ THE SCALE AND FADE HERE (#2329, the owner's
        // recording): Replace sent the old glyph off before the new one
        // came, and some frames had no glyph at all; the scale and fade
        // overlaps them. The transition stays set for a site switched back.
        playButton.symbolTransition = PlayPauseGlyph.replaceTransition
        playButton.symbolSwap = PlayPauseGlyph.swap(for: .voicePanel)
        // Sized here (`buttonSide`): no spring after a swap holding the new
        // glyph back.
        playButton.followsContentSize = false
        playButton.reducesMotion = { [weak self] in
            guard let self else { return MotionPreference.reducesMotion }
            return reducesMotion() || glyphStill
        }
        playButton.isAccessibilityElement = false
        playButton.addAction(UIAction { [weak self] _ in self?.onPlayTap?() }, for: .primaryActionTriggered)
        // A drag that starts on the button is the button's: neither the
        // list's scroll nor the screen's swipes take it (the owner's device
        // check, 2026-11-06). It leaves the button its touches, so a press
        // that drifts is still a press.
        playHold.cancelsTouchesInView = false
        playHold.delegate = self
        playButton.addGestureRecognizer(playHold)
        // ⚠️ AND A SIDEWAYS DRAG ANYWHERE ON THE PANEL IS THE PANEL'S (the
        // owner's device check, 2026-11-06, filmed): one from the speed chip
        // went to the screen's back swipe. The screen's pans wait for this
        // one; the panel's own run alongside it; a vertical drag scrolls.
        sideHold.cancelsTouchesInView = false
        sideHold.delegate = self
        frameView.addGestureRecognizer(sideHold)
        // ⚠️ AT BOTH SIZES (#2275, the owner's recording): a compact panel
        // in a history row gave its sideways drag to the profile's pager.
        // Off only in a shelf's card, where a drag is the shelf's (#2205).
        applyDragRule()
        // Across the panel's width — itself the length's (#2329) — the bars
        // re-binned to it, drawn with the voice's own contrast (#2241).
        waveform.fillsWidth = true
        waveform.spreadsLevels = true
        loader.isHidden = true

        // The timer's words (#2329): a row button's title font, monospaced
        // digits, scaled with the text size; its ink (`applyInks`). Against
        // the slot's trailing edge (#2364).
        timerLabel.font = Self.timerFont
        timerLabel.adjustsFontForContentSizeCategory = true
        timerLabel.textAlignment = .natural

        // The speed's words, the same font and ink (#2364).
        speedButton.font = Self.timerFont
        speedButton.isHidden = true
        speedButton.alpha = 0
        speedButton.onTap = { [weak self] in self?.onSpeedTap?() }

        dot.layer.cornerRadius = Self.dotSide / 2
        dot.isHidden = true

        failedLabel.text = "Not sent. Tap to retry"
        failedLabel.font = .appFont(forTextStyle: .caption1)
        failedLabel.adjustsFontForContentSizeCategory = true
        failedLabel.textColor = .systemRed
        failedLabel.isHidden = true
        failedLabel.isUserInteractionEnabled = true
        failedLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retryTapped)))

        waveform.onSeek = { [weak self] fraction, scrubbing in self?.seek(fraction, scrubbing: scrubbing) }
        waveform.onFinger = { [weak self] down in self?.fingerChanged(down) }
        // ⚠️ THE FINGER IS READ ON THE PANEL AT REST (#2274): swollen, the
        // bar under a still finger would be another, and the playhead would
        // jump with the swell.
        waveform.fractionReader = { [weak self] gesture in
            guard let self else { return nil }
            return restingFraction(at: gesture.location(in: self))
        }

        for part in [playButton, loader, scrubber, waveform, timerLabel, speedButton, dot, failedLabel] as [UIView] {
            part.translatesAutoresizingMaskIntoConstraints = false
        }
        frameView.addSubview(playButton)
        playButton.addSubview(loader)
        frameView.addSubview(scrubber)
        scrubber.addSubview(waveform)
        frameView.addSubview(timerLabel)
        frameView.addSubview(dot)
        // Over the timer and the waveform's end: its target reaches past the
        // slot (#2364).
        frameView.addSubview(speedButton)
        // Under the panel, outside its ground.
        addSubview(failedLabel)
        // The panel's line: the glyph's frame's height, or the timer's when
        // larger text makes it taller — the same in every state, so playing
        // never re-lays the list.
        frameView.addLayoutGuide(line)
        frameView.addLayoutGuide(slot)

        let side = Self.buttonSide(for: size)
        let padding = Self.panelPadding(for: size)
        // The panel is as wide as it may be: its host's width, up to its cap
        // (#2241) — and its length's (#2329, `applyWidthRule`).
        let fills = frameView.trailingAnchor.constraint(equalTo: trailingAnchor)
        fills.priority = .defaultHigh
        // Never past the host's edge; just under required, so a host laid
        // out narrower than the panel's content for a pass logs nothing.
        let within = frameView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        within.priority = .required - 1
        let hug = line.heightAnchor.constraint(equalToConstant: side)
        hug.priority = .defaultLow
        // ⚠️ CENTRED, ITS AIR GIVING WAY EVENLY (#2274): the air above the
        // line is the panel's own just under required, so a host that holds
        // the panel shorter takes it from both sides at once — pinned under
        // the top, a squeezed panel lost its air below only (a shelf's card,
        // the owner's recording: 6 pt above, 1 pt below).
        let air = line.topAnchor.constraint(equalTo: frameView.topAnchor, constant: padding)
        air.priority = .required - 1
        let slotWidth = slot.widthAnchor.constraint(equalToConstant: 0)
        let slotHeight = slot.heightAnchor.constraint(equalToConstant: 0)
        self.slotWidth = slotWidth
        self.slotHeight = slotHeight
        var constraints: [NSLayoutConstraint] = [
            frameView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            frameView.topAnchor.constraint(equalTo: topAnchor),
            fills, within,

            line.centerYAnchor.constraint(equalTo: frameView.centerYAnchor),
            air,
            line.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: padding),
            line.trailingAnchor.constraint(equalTo: frameView.trailingAnchor, constant: -Self.panelTrailingPadding),
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: side),
            hug,

            playButton.leadingAnchor.constraint(equalTo: line.leadingAnchor),
            playButton.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: side),
            playButton.heightAnchor.constraint(equalToConstant: side),
            loader.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            loader.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),

            // The waveform runs from the glyph to the slot, whatever the
            // length and whatever the slot shows.
            scrubber.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: Spacing.sm),
            scrubber.trailingAnchor.constraint(equalTo: slot.leadingAnchor, constant: -Spacing.sm),
            scrubber.topAnchor.constraint(equalTo: line.topAnchor),
            scrubber.bottomAnchor.constraint(equalTo: line.bottomAnchor),
            waveform.leadingAnchor.constraint(equalTo: scrubber.leadingAnchor),
            waveform.trailingAnchor.constraint(equalTo: scrubber.trailingAnchor),
            waveform.centerYAnchor.constraint(equalTo: scrubber.centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: Self.waveformHeight(for: size)),

            // The slot: one size (`refreshSlotSize`), level with the line.
            slot.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            slotWidth, slotHeight,
            line.heightAnchor.constraint(greaterThanOrEqualTo: slot.heightAnchor),
            // The timer against its trailing edge (#2364): the spare goes
            // toward the waveform.
            timerLabel.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            timerLabel.leadingAnchor.constraint(greaterThanOrEqualTo: slot.leadingAnchor),
            timerLabel.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            line.heightAnchor.constraint(greaterThanOrEqualTo: timerLabel.heightAnchor),
            // The speed fills it, its words against the same edge.
            speedButton.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            speedButton.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            speedButton.topAnchor.constraint(equalTo: slot.topAnchor),
            speedButton.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
            // The dot keeps its own place after the slot.
            dot.leadingAnchor.constraint(equalTo: slot.trailingAnchor, constant: Spacing.xs),
            dot.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSide),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSide),

            failedLabel.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            failedLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            failedLabel.topAnchor.constraint(equalTo: frameView.bottomAnchor, constant: Spacing.xs),
        ]
        if let maxPanelWidth {
            constraints.append(frameView.widthAnchor.constraint(lessThanOrEqualToConstant: maxPanelWidth))
        }
        NSLayoutConstraint.activate(constraints)
        endsAtSlot = slot.trailingAnchor.constraint(equalTo: line.trailingAnchor)
        endsAtDot = dot.trailingAnchor.constraint(equalTo: line.trailingAnchor)
        panelEndsView = frameView.bottomAnchor.constraint(equalTo: bottomAnchor)
        panelEndsView?.isActive = true
        failedBottom = failedLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        updateTrailingEnd()
        applyWidthRule()
        refreshSlotSize()
        showSlot(.timer, animated: false)
        applyInks()
        // A new text size re-measures the slot, once the timer's font has
        // followed it.
        _ = registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: VoiceView, _: UITraitCollection) in
            view.setNeedsUpdateConstraints()
        }

        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var failedBottom: NSLayoutConstraint?
    /// Who sent it, for VoiceOver: "Ava", or nil for the viewer's own.
    private var senderName: String?

    public override func updateConstraints() {
        refreshSlotSize()
        super.updateConstraints()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutGround()
        playElement.accessibilityFrameInContainerSpace = frameView.frame
    }

    /// The ground on the panel's middle: the panel's size, or swollen
    /// (#2284). The bars are drawn as finely as the content's swell needs.
    private func layoutGround() {
        let resting = frameView.bounds.size
        let grown = isSwollen ? Self.swelledGroundSize(for: resting) : resting
        panelGround.bounds = CGRect(origin: .zero, size: grown)
        panelGround.center = CGPoint(x: resting.width / 2, y: resting.height / 2)
        panelGround.layer.cornerRadius = isSwollen ? swollenCornerRadius(resting: resting, grown: grown) : Self.panelCornerRadius(for: size)
        frameView.sendSubviewToBack(panelGround)
        waveform.swellFactor = PressFeedback.swell(for: resting).content
    }

    /// The ground's corner grown to `grown`: the media tiles' corner (#2329)
    /// kept as it is — a capsule, were it ever one, kept a capsule.
    private func swollenCornerRadius(resting: CGSize, grown: CGSize) -> CGFloat {
        let radius = Self.panelCornerRadius(for: size)
        let growth = CGSize(width: grown.width - resting.width, height: grown.height - resting.height)
        return PressFeedback.grownCornerRadius(radius, of: resting, by: growth)
    }

    // MARK: - Showing

    /// Shows `state` — nil hides the bubble (a message that is not a voice
    /// message). Nothing of a previous message survives.
    public func configure(_ state: State?, senderName: String? = nil) {
        guard let state else {
            fingerOnWaveform = false
            isScrubbing = false
            syncSwell(animated: false)
            pendingLoader?.cancel()
            pendingLoader = nil
            isHidden = true
            self.state = State()
            waveform.configure(levels: nil, progress: 0)
            showSlot(.timer, animated: false)
            return
        }
        isHidden = false
        self.senderName = senderName
        // The bars are re-binned to the waveform's own width as it is laid
        // out — the length's width (#2329) or the host's.
        waveform.configure(levels: state.levels, progress: state.progress)
        apply(state, animated: false, onScreen: false)
    }

    /// Updates what changes while it plays — progress, the glyph, the slot —
    /// without re-laying the bars.
    public func update(_ state: State) {
        guard !isHidden else { return }
        waveform.setProgress(state.progress)
        apply(state, animated: window != nil && !reducesMotion(), onScreen: window != nil)
    }

    /// - Parameters:
    ///   - animated: on screen, and motion not reduced.
    ///   - onScreen: on screen, whatever the motion: the slot cross-fades
    ///     under Reduce Motion (#2329) where the rest cuts.
    private func apply(_ state: State, animated: Bool, onScreen: Bool) {
        let previous = self.state
        self.state = state
        // The width says the length (#2329): rebuilt when its whole
        // seconds change.
        applyWidthRule()
        let sending = state.delivery == .sending
        let failedSend = state.delivery == .failed
        frameView.alpha = sending ? 0.5 : 1
        failedLabel.isHidden = !failedSend
        // The "Not sent" line under the panel closes the view, or the panel does.
        if failedSend {
            panelEndsView?.isActive = false
            failedBottom?.isActive = true
        } else {
            failedBottom?.isActive = false
            panelEndsView?.isActive = true
        }

        // The glyph turns on the tap — a play waiting on its audio already
        // shows pause — and the loader takes its place only when the wait
        // lasts (the owner's device check, 2026-11-06: no delay).
        if state.playback == .loading, !sending {
            if loader.isHidden, pendingLoader == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingLoader = nil
                    self?.showLoader(true)
                }
                pendingLoader = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.loaderDelay, execute: work)
            }
            setGlyph(glyphName)
        } else {
            pendingLoader?.cancel()
            pendingLoader = nil
            // ⚠️ NO LOADER OVER THE PLAY BUTTON WHILE SENDING (the owner,
            // 2026-11-07): a message's one loader is its delivery's, beside
            // "You" (`ThreadRowCell.setDelivery`); the panel stays faded
            // with its play button disabled.
            showLoader(false)
        }
        playButton.isEnabled = !sending && !failedSend

        // The slot holds the widest timer this voice can show: its total
        // length's format (#2274).
        if state.duration != previous.duration { refreshSlotSize() }
        // ⚠️ THE TIMER KEEPS ITS WORDS WHILE IT LEAVES (#2329, filmed): at a
        // tap the playing state came with the time reached, "0:00", and the
        // timer turning away from "0:34" changed its words mid-motion. It
        // is written only while it is the slot's — before it comes back.
        if Self.slotContent(for: state.playback) == .timer { showTimerText() }
        // Only on a change: written every frame of playback, it would redraw
        // the words under a finger trying to press them. On screen the new
        // speed cross-fades in place (Reduce Motion too: a fade is no move).
        if speedButton.title != state.speedLabel {
            speedButton.setTitle(state.speedLabel, animated: onScreen && previous.speedLabel != state.speedLabel)
        }
        showSlot(Self.slotContent(for: state.playback), animated: onScreen)

        // The unplayed dot fades once playback starts.
        let showsDot = state.unplayed && !state.isUnderway && state.playback != .loading
        if showsDot != !dot.isHidden {
            if showsDot || window == nil || reducesMotion() {
                dot.isHidden = !showsDot
                dot.alpha = 1
            } else {
                UIView.animate(withDuration: AppearMotion.fadeDuration, animations: { self.dot.alpha = 0 }) { _ in
                    self.dot.isHidden = true
                    self.dot.alpha = 1
                }
            }
        }
        // The waveform rises in when it ARRIVES for the message shown — not
        // when a row is filled afresh (a reused cell, the sent copy taking
        // the pending one's place: it is already there).
        if previous.levels == nil, previous.duration > 0, state.levels != nil, window != nil { waveform.riseIn() }
        updateAccessibility()
    }

    /// What the glyph says the button does next.
    private var glyphName: String {
        if !loader.isHidden { return "" }
        return switch state.playback {
        case .failed: "arrow.clockwise"
        case .playing, .loading: AppSymbol.pause.rawValue
        default: AppSymbol.play.rawValue
        }
    }

    private func showLoader(_ shown: Bool) {
        loader.isHidden = !shown
        if shown { loader.startAnimating() } else { loader.stopAnimating() }
        setGlyph(glyphName)
    }

    /// The button's glyph — none while the loader stands in its place —
    /// swapped by the scale and fade (`PlayPauseGlyph.swap(for: .voicePanel)`,
    /// #2329): the old glyph on a copy while the new one grows in, a glyph
    /// on every frame; under Reduce Motion, a cross-fade (#2276).
    private func setGlyph(_ name: String) {
        guard name != shownGlyph else { return }
        let animated = window != nil && !shownGlyph.isEmpty && !name.isEmpty
        shownGlyph = name
        // Unanimated (a dequeued row), the glyph lands with no transition.
        glyphStill = !animated
        playButton.setContent(.symbol(name), animated: animated)
        glyphStill = false
    }

    // MARK: - The slot (#2274)

    /// The slot's one size (#2364, `slotSize(forLength:style:font:)`): as
    /// wide as the widest of its words — the widest timer this voice can
    /// show, its total length in its own format (a post's seconds, a
    /// message's clock, #2294), the digits monospaced, and the bare
    /// "1.5×" — at the view's text size; as tall as a line of them.
    /// Re-measured for a new voice, a new format or a new text size, never
    /// for a state.
    private func refreshSlotSize() {
        let category = traitCollection.preferredContentSizeCategory
        let style = timerStyle
        if let sized = slotSizedFor, sized.duration == state.duration, sized.style == style, sized.category == category {
            return
        }
        slotSizedFor = (state.duration, style, category)
        // The words' font at the view's own text size — the window's, under
        // the app's ceiling — set on both, so what is measured is drawn.
        let font = Self.timerFont(compatibleWith: category == .unspecified ? nil : traitCollection)
        timerLabel.font = font
        speedButton.font = font
        let measured = Self.slotSize(forLength: state.duration, style: style, font: font)
        guard measured.width != slotWidth?.constant || measured.height != slotHeight?.constant else { return }
        slotWidth?.constant = measured.width
        slotHeight?.constant = measured.height
        relayout()
    }

    /// ⚠️ A CONSTRAINT CHANGED: LAY THE PANEL OUT AGAIN (#2329). A constant
    /// or a constraint changed on a panel already laid out — a reused row
    /// shown with another length or role, at the same width — left its
    /// frames as they were: nothing marked the view, so the next layout pass
    /// (a host's `layoutIfNeeded`) skipped it and the panel kept the last
    /// voice's width and slot. Both the view (the panel's frame) and the
    /// panel (the parts' frames, whose size may not change) are marked.
    private func relayout() {
        setNeedsLayout()
        frameView.setNeedsLayout()
    }

    /// The length the timer says now: the total at rest and at the end; the
    /// time reached mid-way — the one a pause resumes from (the owner,
    /// 2026-11-10).
    private var shownTime: TimeInterval {
        state.isUnderway ? state.duration * state.progress : state.duration
    }

    /// The timer's text, in the voice's own format (#2294).
    private func showTimerText() {
        timerLabel.text = Self.timerText(shownTime, style: timerStyle)
    }

    /// The timer or the speed (#2274) — one motion between them (#2329,
    /// `slotMotion`), the words against the slot's trailing edge (#2364):
    ///
    /// ```
    ///  to playing   the timer's words go up a few points and fade out as
    ///               "1×" comes up from below and fades in — a counter's
    ///               digit turning, in place
    ///  to paused    the reverse: "1×" goes down and out, the time comes
    ///               down and in
    /// ```
    ///
    /// One motion, `slotMorphDuration`, eased in and out with no overshoot,
    /// interruptible from where it is. The two overlap throughout — the one
    /// fading out as the other fades in, never an empty slot — and the slot
    /// keeps its one size, so nothing beside it moves. No ground grows any
    /// more (#2364: the speed has none). Under Reduce Motion a plain
    /// cross-fade; off screen, a cut.
    ///
    /// ⚠️ NOTHING IS LAID OUT HERE. A spring around `layoutIfNeeded` held
    /// the play button's new glyph back until it settled (filmed, 2026-11-06);
    /// the chip used to re-bin the waveform narrower and push the timer
    /// aside (the owner's recording, 2026-11-10: the bars' end moved 43 pt).
    /// The change moves transforms and opacities only.
    private func showSlot(_ content: SlotContent, animated: Bool) {
        guard content != shownSlot else { return }
        shownSlot = content
        slotChangeID += 1
        let speed = content == .speed
        let motion = Self.slotMotion(animated: animated && window != nil, reducesMotion: reducesMotion())
        lastSlotMotion = motion
        switch motion {
        case .cut: settleSlot(speed: speed)
        case .crossFade: crossFadeSlot(speed: speed)
        case .morph: morphSlot(speed: speed)
        }
        refreshAccessibilityElements()
    }

    /// Counts the slot's changes: a change's completion acts only if no
    /// other has come since.
    private var slotChangeID = 0

    /// No change in flight on the slot's parts.
    private func stopSlotAnimations() {
        for layer in [speedButton.layer, timerLabel.layer] { layer.removeAllAnimations() }
    }

    /// The speed takes touches only while it is the slot's: a tap on a
    /// fading speed is the waveform's or the panel's.
    private func setSpeedTakesTouches(_ speed: Bool) {
        speedButton.isUserInteractionEnabled = speed
    }

    /// The slot at rest on the speed or the timer: whole, in place.
    private func settleSlot(speed: Bool) {
        stopSlotAnimations()
        setSpeedTakesTouches(speed)
        speedButton.transform = .identity
        speedButton.alpha = speed ? 1 : 0
        speedButton.isHidden = !speed
        timerLabel.transform = .identity
        timerLabel.alpha = speed ? 0 : 1
    }

    /// Reduce Motion: one dissolves into the other in place.
    private func crossFadeSlot(speed: Bool) {
        let id = slotChangeID
        stopSlotAnimations()
        setSpeedTakesTouches(speed)
        speedButton.transform = .identity
        timerLabel.transform = .identity
        if speed { speedButton.isHidden = false }
        UIView.animate(
            withDuration: Self.slotCrossFadeDuration, delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.speedButton.alpha = speed ? 1 : 0
            self.timerLabel.alpha = speed ? 0 : 1
        } completion: { _ in
            guard id == self.slotChangeID else { return }
            self.speedButton.isHidden = !speed
        }
    }

    /// The turn (#2329, #2364): the timer's words and the speed's trade
    /// places in the slot, each rising and fading — up and out, up and in —
    /// against its trailing edge. No mask, no ground: the words alone.
    private func morphSlot(speed: Bool) {
        let id = slotChangeID
        let up = CGAffineTransform(translationX: 0, y: -Self.slotTurnDistance)
        let down = CGAffineTransform(translationX: 0, y: Self.slotTurnDistance)
        setSpeedTakesTouches(speed)
        // From rest, each part starts where the other direction leaves it;
        // mid-way, from where it is now (`beginFromCurrentState`).
        let resting = [speedButton.layer, timerLabel.layer].allSatisfy { ($0.animationKeys() ?? []).isEmpty }
        UIView.performWithoutAnimation {
            if resting {
                if speed {
                    speedButton.alpha = 0
                    speedButton.transform = down
                    timerLabel.transform = .identity
                    timerLabel.alpha = 1
                } else {
                    speedButton.alpha = 1
                    speedButton.transform = .identity
                    timerLabel.transform = up
                    timerLabel.alpha = 0
                }
            }
            speedButton.isHidden = false
        }
        UIView.animate(
            withDuration: Self.slotMorphDuration, delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            if speed {
                self.speedButton.alpha = 1
                self.speedButton.transform = .identity
                self.timerLabel.transform = up
                self.timerLabel.alpha = 0
            } else {
                self.speedButton.alpha = 0
                self.speedButton.transform = down
                self.timerLabel.transform = .identity
                self.timerLabel.alpha = 1
            }
        } completion: { _ in
            guard id == self.slotChangeID else { return }
            // At rest: the timer back in place; the speed gone, back in
            // place too.
            self.timerLabel.transform = .identity
            if !speed {
                self.speedButton.isHidden = true
                self.speedButton.transform = .identity
            }
        }
    }

    // MARK: - The width says the length (#2329)

    /// What the width rule was last built for: the length's whole seconds,
    /// or -1 for none (the host's width); -2 before it is first built.
    private var lengthRuleKey: TimeInterval = -2

    /// The panel's width for its length (#2329), as constraints — no pass
    /// through `layoutSubviews`: at most the length's share of the host's
    /// width less the leading inset, plus the narrowest's rest
    /// (`panelWidth(forLength:available:)` spelled as `width ≤ host ×
    /// share + constant`), and at most the same for the cap. The panel
    /// takes the most these allow; a host narrower than the narrowest
    /// gives its own width (`within`). Rebuilt when the whole seconds
    /// change.
    private func applyWidthRule() {
        let key: TimeInterval = widthFollowsLength ? max(0, state.duration.rounded(.down)) : -1
        guard key != lengthRuleKey else { return }
        lengthRuleKey = key
        NSLayoutConstraint.deactivate(lengthRule)
        lengthRule = []
        relayout()
        guard widthFollowsLength else { return }
        let share = Self.lengthShare(state.duration)
        let narrowest = Self.minimumPanelWidth
        let byHost: NSLayoutConstraint = share > 0
            ? frameView.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor, multiplier: share,
                constant: narrowest * (1 - share) - leadingInset * share
            )
            : frameView.widthAnchor.constraint(lessThanOrEqualToConstant: narrowest)
        var rule = [byHost]
        if let maxPanelWidth {
            rule.append(frameView.widthAnchor.constraint(
                lessThanOrEqualToConstant: Self.panelWidth(forLength: state.duration, available: maxPanelWidth)
            ))
        }
        // Just under required, as `within`: a host laid out narrower than
        // the panel's content for a pass logs nothing.
        for constraint in rule { constraint.priority = .required - 1 }
        NSLayoutConstraint.activate(rule)
        lengthRule = rule
    }

    /// What the panel's content ends at: the unplayed dot's place for a
    /// message — kept whether the dot shows or not, so playing a message
    /// never moves its slot — and the slot for a post, which has no dot.
    private func updateTrailingEnd() {
        let message = role == .message
        // Off first: two ends at once would conflict.
        if message { endsAtSlot?.isActive = false } else { endsAtDot?.isActive = false }
        if message { endsAtDot?.isActive = true } else { endsAtSlot?.isActive = true }
        relayout()
    }

    /// The host's inks on every part (#2241): the bars, the play glyph, the
    /// timer's and the speed's words — one ink (#2329) — the panel's
    /// ground derived from the played ink, and the unplayed dot in the
    /// label's ink — never the brand's colour.
    private func applyInks() {
        timerLabel.textColor = inks.timer
        speedButton.ink = inks.timer
        waveform.playedInk = inks.played
        waveform.unplayedInk = inks.unplayed
        // The bare glyph in the played bars' ink (#2274).
        playButton.inkColor = inks.played
        panelGround.backgroundColor = inks.panel
        dot.backgroundColor = Self.dotInk
    }

    /// The unplayed dot's ink (#2241): the label's black or white — neutral,
    /// where it was the brand's tint.
    public static let dotInk: UIColor = .label

    // MARK: - The swell (#2274)

    /// A finger landed on the waveform (true), or lifted or was cancelled.
    private func fingerChanged(_ down: Bool) {
        fingerOnWaveform = down
        syncSwell(animated: window != nil)
    }

    /// Under a finger on the waveform — from its landing, through a scrub,
    /// to its lift — the whole panel swells as one, as the app's buttons
    /// do, with their springs (`PressFeedback.Metrics.swellIn` /
    /// `swellOut`): its ground grows to the app's swell on the panel's size,
    /// its corner kept at every frame, and everything in it — the glyph, the
    /// bars, the slot — scales by one factor on both axes (#2284). It goes
    /// over what surrounds the panel and moves nothing in the list. Never
    /// under Reduce Motion, as for the app's buttons; never on a message
    /// still on its way.
    private func syncSwell(animated: Bool) {
        let swollen = (fingerOnWaveform || isScrubbing) && state.delivery == .sent && !isHidden && !reducesMotion()
        guard swollen != isSwollen else { return }
        isSwollen = swollen
        let target: CGAffineTransform = swollen ? Self.swelledScale(for: frameView.bounds.size) : .identity
        guard animated else {
            frameView.transform = target
            layoutGround()
            return
        }
        let curve = swollen ? PressFeedback.Metrics.swellIn : PressFeedback.Metrics.swellOut
        UIView.animate(
            springDuration: curve.response, bounce: 1 - curve.dampingRatio,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.frameView.transform = target
            self.layoutGround()
        }
    }

    /// The share of the waveform at `point` (own coordinates), read on the
    /// panel AT REST: the frames laid out, not the swollen ones — so a still
    /// finger keeps its bar while the panel swells round it (#2274).
    func restingFraction(at point: CGPoint) -> Double {
        let bars = restingWaveformFrame
        let reach = min(waveform.barsWidth, bars.width)
        guard reach > 0 else { return 0 }
        return Double(min(1, max(0, (point.x - bars.minX) / reach)))
    }

    /// The waveform's frame in this view with the panel at rest: its centre
    /// and bounds, which a transform never changes.
    private var restingWaveformFrame: CGRect {
        let panelOrigin = CGPoint(
            x: frameView.center.x - frameView.bounds.width / 2,
            y: frameView.center.y - frameView.bounds.height / 2
        )
        return CGRect(
            x: panelOrigin.x + scrubber.frame.minX + waveform.frame.minX,
            y: panelOrigin.y + scrubber.frame.minY + waveform.frame.minY,
            width: waveform.bounds.width, height: waveform.bounds.height
        )
    }

    // MARK: - Scrubbing

    private func seek(_ fraction: Double, scrubbing: Bool) {
        guard state.delivery == .sent else { return }
        isScrubbing = scrubbing
        syncSwell(animated: window != nil)
        // A tick every 10 %, under the finger.
        let step = Int(fraction * 10)
        if scrubbing, step != scrubSteps {
            if scrubSteps >= 0 { Haptics.play(.tick) }
            scrubSteps = step
        }
        if !scrubbing { scrubSteps = -1 }
        onSeek?(fraction, scrubbing)
    }

    @objc private func retryTapped() { onRetry?() }

    /// Whether a press at `point` (own coordinates) is the bubble's: on the
    /// play button, the waveform or the speed's target — never the row's
    /// long press.
    public func keepsPress(at point: CGPoint) -> Bool {
        guard !isHidden, let hit = hitTest(point, with: nil) else { return false }
        return sequence(first: hit, next: { $0.superview })
            .prefix { $0 !== self }
            .contains { $0 === playButton || $0 === waveform || $0 === speedButton }
    }

    /// The play button's hold: every other drag waits for it, so the
    /// list's scroll and the screen's swipes never take a drag that starts
    /// on the button.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        WaveformBars.yields(other, to: self) || screenPops.contains { $0 === other }
    }

    /// The bubble's own gestures — the scrub, the button's hold — run
    /// alongside its holds.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        other.view?.isDescendant(of: self) == true
    }

    /// The side hold takes only a sideways drag. (Asked as its delegate:
    /// it hangs on the bubble's frame, not on this view.)
    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === sideHold else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let velocity = sideHold.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    /// The play button's hold, the panel's sideways hold and the
    /// waveform's scrub, on or off together (`dragsAreOwn`).
    private func applyDragRule() {
        playHold.isEnabled = dragsAreOwn
        sideHold.isEnabled = dragsAreOwn
        waveform.scrubs = dragsAreOwn
    }

    /// Whether a drag at `point` (own coordinates) starts on the bubble
    /// itself — not on the row's room beside it.
    public func keepsDrag(at point: CGPoint) -> Bool {
        !isHidden && frameView.frame.contains(point)
    }

    /// The navigation's back swipes — whatever class they are, not only
    /// pans.
    private var screenPops: [UIGestureRecognizer] {
        var responder = next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let navigation = (responder as? UIViewController)?.navigationController else { return [] }
        return [navigation.interactivePopGestureRecognizer, navigation.interactiveContentPopGestureRecognizer]
            .compactMap { $0 }
    }

    // MARK: - Accessibility

    /// The panel reads as one element — its label, its time and speed, its
    /// ±5 s adjustment, play on a double tap — and, while the speed shows,
    /// the speed as its own element beside it (#2274): "Playback speed",
    /// "1×" (`VoiceSpeedButton`).
    private func updateAccessibility() {
        let label = Self.accessibilityLabel(
            role: role, senderName: senderName, duration: state.duration, unplayed: state.unplayed
        )
        // The play button's value: the time the slot's timer says, and the
        // speed (#2274) — a post's "12 seconds", never its sign (#2294).
        let time = Self.spokenTime(shownTime, style: timerStyle)
        let value = "\(time), speed \(state.speedLabel)"
        let playing: Bool = if case .playing = state.playback { true } else { false }
        var actions = [
            UIAccessibilityCustomAction(name: playing ? "Pause" : "Play") { [weak self] _ in
                self?.onPlayTap?()
                return true
            },
        ]
        // The speed changes only while it plays (#2274), as on WhatsApp.
        if shownSlot == .speed {
            actions.append(UIAccessibilityCustomAction(name: "Speed \(state.speedLabel)") { [weak self] _ in
                self?.onSpeedTap?()
                return true
            })
        }
        accessibilityLabel = label
        accessibilityValue = value
        accessibilityCustomActions = actions
        playElement.accessibilityLabel = label
        playElement.accessibilityValue = value
        playElement.accessibilityTraits = .adjustable
        playElement.accessibilityCustomActions = actions
    }

    /// One element, or the voice and the speed while the speed shows.
    private func refreshAccessibilityElements() {
        let speedShows = shownSlot == .speed
        isAccessibilityElement = !speedShows
        let elements: [Any] = [playElement, speedButton]
        accessibilityElements = speedShows ? elements : nil
        updateAccessibility()
    }

    /// What VoiceOver reads (#2104, #2205): "Voice message from Ava, 12
    /// seconds, not played"; "Voice post by Ava, 32 seconds"; "Voice comment
    /// by Ava, 13 seconds" (#2309).
    public static func accessibilityLabel(
        role: Role, senderName: String?, duration: TimeInterval, unplayed: Bool
    ) -> String {
        let seconds = Int(duration.rounded())
        let length = seconds == 1 ? "1 second" : "\(seconds) seconds"
        switch role {
        case .post(let author):
            return author.map { "Voice post by \($0), \(length)" } ?? "Voice post, \(length)"
        case .comment(let author):
            return author.map { "Voice comment by \($0), \(length)" } ?? "Voice comment, \(length)"
        case .message:
            let from = senderName.map { "Voice message from \($0)" } ?? "Your voice message"
            let heard = unplayed ? "not played" : "played"
            return "\(from), \(length), \(heard)"
        }
    }

    /// ±5 s.
    public override func accessibilityIncrement() { nudge(by: 5) }
    public override func accessibilityDecrement() { nudge(by: -5) }

    /// A double tap plays or pauses: the panel is the play button's element.
    public override func accessibilityActivate() -> Bool {
        guard playButton.isEnabled else { return false }
        onPlayTap?()
        return true
    }

    private func nudge(by seconds: TimeInterval) {
        guard state.duration > 0 else { return }
        let fraction = min(1, max(0, state.progress + seconds / state.duration))
        onSeek?(fraction, false)
    }

    #if DEBUG
    public var debugPlayButton: UIView { playButton }
    public var debugSideHoldEnabled: Bool { sideHold.isEnabled }
    public var debugPlayHoldEnabled: Bool { debugPlayButtonHold?.isEnabled ?? false }
    public var debugTimerText: String? { timerLabel.text }
    /// The speed shows in the slot (#2274).
    public var debugShowsSpeed: Bool { shownSlot == .speed && !speedButton.isHidden }
    /// The timer shows in the slot (#2274).
    public var debugShowsTimer: Bool { shownSlot == .timer }
    public var debugSlotContent: SlotContent? { shownSlot }
    /// The timer's and the speed's opacity now (their model values).
    public var debugTimerAlpha: CGFloat { timerLabel.alpha }
    public var debugSpeedAlpha: CGFloat { speedButton.alpha }
    /// Whether the slot is fading now (an opacity animation on the timer or
    /// the speed).
    public var debugSlotIsFading: Bool {
        [timerLabel.layer, speedButton.layer].contains { $0.animationKeys()?.contains("opacity") == true }
    }
    /// Whether the words are turning now (#2329): a transform animation on
    /// the timer and on the speed.
    public var debugSlotIsTurning: Bool {
        [timerLabel.layer, speedButton.layer].allSatisfy { $0.animationKeys()?.contains("transform") == true }
    }
    /// The slot's last change (#2329).
    public var debugSlotMotion: SlotMotion { lastSlotMotion }
    /// The timer's and the speed's opacity animations' durations now — one
    /// each while they trade places, the same: they overlap throughout.
    public var debugSlotOpacityDurations: [CFTimeInterval] {
        [timerLabel.layer, speedButton.layer].compactMap { $0.animation(forKey: "opacity")?.duration }
    }
    /// The speed's and the timer's transforms now (their model values).
    public var debugSpeedTransform: CGAffineTransform { speedButton.transform }
    public var debugTimerTransform: CGAffineTransform { timerLabel.transform }
    /// The timer's font, and the speed's.
    public var debugTimerFont: UIFont? { timerLabel.font }
    public var debugSpeedFont: UIFont? { speedButton.font }
    /// The speed's words' ink.
    public var debugSpeedInk: UIColor? { speedButton.ink }
    public var debugSpeedTitle: String? { speedButton.title }
    /// The speed's button (#2364): its accessibility, its taps.
    public var debugSpeedButton: UIControl { speedButton }
    /// The speed's words' opacity — dimmed under the finger (#2364).
    public var debugSpeedWordsAlpha: CGFloat { speedButton.wordsAlpha }
    /// Whether the speed draws anything but its words (#2364): a fill, a
    /// border, a shadow, a corner, another view — none.
    public var debugSpeedHasAGround: Bool { speedButton.hasAGround }
    public var debugShowsDot: Bool { !dot.isHidden }
    public var debugWaveformRising: Bool { waveform.debugRising }
    public var debugPlayEnabled: Bool { playButton.isEnabled }
    public var debugShowsLoader: Bool { !loader.isHidden }
    /// The speed's button, in this view: the slot (#2364).
    public var debugSpeedFrame: CGRect { speedButton.convert(speedButton.bounds, to: self) }
    /// The speed's words, in this view (#2364).
    public var debugSpeedWordsFrame: CGRect { speedButton.convert(speedButton.wordsFrame, to: self) }
    /// The speed's invisible target, in this view (#2364).
    public var debugSpeedTargetFrame: CGRect { speedButton.convert(speedButton.targetFrame, to: self) }
    public var debugTimerFrame: CGRect { timerLabel.convert(timerLabel.bounds, to: self) }
    /// The slot (#2274), in this view.
    public var debugSlotFrame: CGRect { frameView.convert(slot.layoutFrame, to: self) }
    /// The panel's line, in this view.
    public var debugLineFrame: CGRect { frameView.convert(line.layoutFrame, to: self) }
    public var debugWaveformFrame: CGRect { waveform.convert(waveform.bounds, to: self) }
    public var debugScrubberFrame: CGRect { scrubber.convert(scrubber.bounds, to: self) }
    public func debugSetSpeedLabel(_ label: String) {
        speedButton.setTitle(label, animated: false)
        layoutIfNeeded()
    }
    /// What a press at `point` (own coordinates) lands on.
    public var debugSideHold: UIGestureRecognizer { sideHold }
    public func debugPressTarget(at point: CGPoint) -> String {
        let hit = hitTest(point, with: nil)
        if hit === speedButton || hit?.isDescendant(of: speedButton) == true { return "speed" }
        if hit === waveform { return "waveform" }
        return "other"
    }
    /// The play button's own drag, which every other pan waits on.
    public var debugPlayButtonHold: UIGestureRecognizer? {
        playButton.gestureRecognizers?.first { $0 is UIPanGestureRecognizer && $0.delegate === self }
    }
    /// The waveform's scrub, which every other pan waits on while it is on.
    public var debugScrub: UIGestureRecognizer? {
        waveform.gestureRecognizers?.first { $0 is UIPanGestureRecognizer }
    }
    public func debugLoaderWaitEnds() {
        pendingLoader?.perform()
    }
    public var debugGlyph: String { shownGlyph }
    public var debugButtonImage: UIImage? { playButton.configuration?.image }
    public var debugButtonSize: CGSize { playButton.bounds.size }
    /// The play button is the app's icon button as a bare glyph (#2274) —
    /// no disc, no ground — not a system one.
    public var debugPlayButtonIsABareGlyph: Bool { playButton.style == .glyph && playButton.currentGround == nil }
    /// The glyph's ink and its point size, as the button draws them now.
    public var debugGlyphInk: UIColor? { playButton.configuration?.baseForegroundColor }
    public var debugGlyphPointSize: CGFloat? { playButton.symbolPointSize }
    /// The panel (#2241), in this view: its frame, its ground, its corner.
    public var debugPanelFrame: CGRect { frameView.frame }
    /// The panel's size at rest — its bounds, which the swell never changes.
    public var debugPanelRestingSize: CGSize { frameView.bounds.size }
    /// The panel's transform: the content's even swell (#2274, #2284).
    public var debugPanelTransform: CGAffineTransform { frameView.transform }
    /// The ground's size in the panel's own points, under its transform —
    /// the panel's at rest, grown under a finger (#2284) — and drawn.
    public var debugGroundSize: CGSize { panelGround.bounds.size }
    public var debugDrawnGroundSize: CGSize { panelGround.bounds.size.applying(frameView.transform) }
    /// How finely the bars are drawn: the content's swell (#2284).
    public var debugWaveformSwellFactor: CGFloat { waveform.swellFactor }
    /// The transforms of what the panel holds — none of them swells alone.
    public var debugPartTransforms: [CGAffineTransform] {
        [
            playButton.transform, waveform.transform, scrubber.transform, timerLabel.transform,
            speedButton.transform, dot.transform,
        ]
    }
    public var debugPanelFill: UIColor? { panelGround.backgroundColor }
    public var debugPanelCornerRadius: CGFloat { panelGround.layer.cornerRadius }
    public var debugDotFill: UIColor? { dot.backgroundColor }
    public var debugTimerInk: UIColor? { timerLabel.textColor }
    /// The seek fraction a finger at `point` (own coordinates) reads (#2274).
    public func debugSeekFraction(at point: CGPoint) -> Double { restingFraction(at: point) }
    /// VoiceOver's elements while the speed shows; nil while the panel is one.
    public var debugAccessibilityElements: [Any]? { accessibilityElements }
    public var debugPlayElementValue: String? { playElement.accessibilityValue }
    public func debugTapPlay() { onPlayTap?() }
    public func debugTapSpeed() { onSpeedTap?() }
    #endif
}

/// VoiceOver's voice while the speed shows beside it (#2274): what the
/// panel reads as one element otherwise — its label, its time and speed, its
/// ±5 s adjustment, play on a double tap.
@MainActor
private final class VoicePlayElement: UIAccessibilityElement {
    private weak var owner: VoiceView?

    init(owner: VoiceView) {
        self.owner = owner
        super.init(accessibilityContainer: owner)
    }

    override func accessibilityIncrement() { owner?.accessibilityIncrement() }
    override func accessibilityDecrement() { owner?.accessibilityDecrement() }
    override func accessibilityActivate() -> Bool { owner?.accessibilityActivate() ?? false }
}


/// The voice message's waveform: 2 pt round-capped bars, the played ones in
/// a dark grey (`ink`). A tap seeks; a horizontal drag scrubs (a vertical
/// one is the list's; the row's long press does not start here). The played
/// bars are the only mark of the finger: no playhead (the owner's device
/// check, 2026-11-06).
///
/// Under a finger the voice panel swells as one, the bars with it
/// (`VoiceView`, #2274): the waveform has no swell of its own; it says when
/// a finger is down (`onFinger`), and a host that swells it reads the finger
/// on its resting geometry (`fractionReader`).
///
/// **Filling its width (#2241, `fillsWidth`):** the voice panel's waveform
/// re-bins the voice to however many bars its own width holds, as it is
/// laid out, and spreads them edge to edge — the mark and the composer keep
/// the count they ask for.
public final class WaveformBars: UIView, UIGestureRecognizerDelegate {
    public var onSeek: ((_ fraction: Double, _ scrubbing: Bool) -> Void)?
    /// Whether a horizontal drag scrubs (the panel's `dragsAreOwn`); a tap
    /// always seeks.
    public var scrubs = true {
        didSet { scrub?.isEnabled = scrubs }
    }
    /// The played and unplayed bars' colours (`VoiceView.inks`).
    public var playedInk: UIColor = VoiceView.ink {
        didSet { setNeedsDisplay() }
    }
    public var unplayedInk: UIColor = .tertiaryLabel {
        didSet { setNeedsDisplay() }
    }
    /// The bars fill the view's width (#2241): as many as it holds
    /// (`VoiceView.barCount(forWidth:)`), re-binned whenever it changes,
    /// spread from edge to edge. Off: the count `configure` asks for, from
    /// the leading edge, and the view as wide as its bars.
    public var fillsWidth = false {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
    /// The bars stand at the voice's own contrast (`VoiceView.drawnShares`,
    /// #2241) rather than at their raw level.
    public var spreadsLevels = false {
        didSet {
            shares = Self.shares(of: bars, spreads: spreadsLevels)
            setNeedsDisplay()
        }
    }
    private weak var scrub: UIPanGestureRecognizer?
    /// Told when a finger lands on the bars (true) and when it lifts or is
    /// cancelled (false) — a tap's and a drag's alike (#2274).
    public var onFinger: ((_ down: Bool) -> Void)?
    /// Where a tap or a drag lands, 0…1, as its host reads it — on the
    /// geometry at rest, for a host that swells the bars (#2274). Nil, or
    /// nil back: the bars' own bounds.
    public var fractionReader: ((UIGestureRecognizer) -> Double?)?

    /// The voice's levels as given, before re-binning.
    private var levels: [UInt8] = []
    public private(set) var bars: [UInt8] = []
    /// Each bar's share of the height, 0…1.
    public private(set) var shares: [CGFloat] = []
    public private(set) var progress: Double = 0
    /// The progress drawn: it follows `progress` in a tenth of a second, so
    /// a seek or a finger never flips a bar's colour at once (the owner's
    /// device check, 2026-11-07).
    public private(set) var drawnProgress: Double = 0
    private var progressLink: CADisplayLink?
    private var progressStepAt: CFTimeInterval = 0
    /// How long the drawn progress takes to close most of a gap.
    public static let progressEase: CFTimeInterval = 0.08
    private var waiting = true
    private var rise: CGFloat = 1

    /// How much finer than the screen bars are drawn by default, so they
    /// stay sharp scaled by a swell (#2274): the most a swell's content
    /// scales by — a square's (`PressFeedback.swell(for:)`).
    public static let drawnFiner: CGFloat = 1 + 2 * PressFeedback.Metrics.swellDown
    /// The factor a host swells these bars by, and so how much finer than
    /// the screen they are drawn (#2284): the voice panel's content factor,
    /// set as it is laid out; `drawnFiner` otherwise.
    public var swellFactor: CGFloat = WaveformBars.drawnFiner {
        didSet {
            guard swellFactor != oldValue else { return }
            applyContentScale()
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        scrub = pan
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func configure(levels: [UInt8]?, barCount: Int, progress: Double) {
        waiting = levels == nil
        self.levels = levels ?? []
        // Waiting for a waveform: a flat row of minimum bars.
        setBars(VoiceView.rebin(self.levels, to: barCount))
        self.progress = progress
        drawnProgress = progress
        rise = 1
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    /// The voice's levels, as many bars as the view's width holds
    /// (`fillsWidth`, #2241) — none until it has a width; laying it out
    /// re-bins them.
    public func configure(levels: [UInt8]?, progress: Double) {
        let count = bounds.width > 0 ? VoiceView.barCount(forWidth: bounds.width) : 0
        configure(levels: levels, barCount: count, progress: progress)
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard fillsWidth, bounds.width > 0 else { return }
        let count = VoiceView.barCount(forWidth: bounds.width)
        guard count != bars.count else { return }
        setBars(VoiceView.rebin(levels, to: count))
        setNeedsDisplay()
    }

    private func setBars(_ newBars: [UInt8]) {
        bars = newBars
        shares = Self.shares(of: newBars, spreads: spreadsLevels)
    }

    /// The bars' shares of the height: the voice's own contrast, or the raw
    /// level out of 31.
    private static func shares(of bars: [UInt8], spreads: Bool) -> [CGFloat] {
        if spreads { return VoiceView.drawnShares(of: bars) }
        return bars.map { CGFloat($0) / 31 }
    }

    /// The bars' own width: the view is exactly as wide as what it draws,
    /// so whatever is centred on it is centred on the bars — its whole width
    /// when it fills it.
    public var barsWidth: CGFloat {
        if fillsWidth { return bounds.width }
        return bars.isEmpty ? 0 : CGFloat(bars.count) * (VoiceView.barWidth + VoiceView.barGap) - VoiceView.barGap
    }

    /// From one bar's start to the next: 2 pt bars 2 pt apart, or spread
    /// edge to edge when the view fills its width.
    public var barStep: CGFloat {
        let natural = VoiceView.barWidth + VoiceView.barGap
        guard fillsWidth, bars.count > 1 else { return natural }
        return (bounds.width - VoiceView.barWidth) / CGFloat(bars.count - 1)
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: fillsWidth ? UIView.noIntrinsicMetric : barsWidth, height: UIView.noIntrinsicMetric)
    }

    public func setProgress(_ progress: Double) {
        guard abs(progress - self.progress) > 0.0005 else { return }
        self.progress = progress
        guard window != nil, !MotionPreference.reducesMotion else {
            drawnProgress = progress
            return setNeedsDisplay()
        }
        guard progressLink == nil else { return }
        progressStepAt = CACurrentMediaTime()
        let link = CADisplayLink(target: RiseStep { [weak self] link in
            guard let self else { return link.invalidate() }
            stepProgress()
        }, selector: #selector(RiseStep.fire(_:)))
        link.add(to: .main, forMode: .common)
        progressLink = link
    }

    /// Eases the drawn progress toward the real one, frame by frame.
    private func stepProgress() {
        let now = CACurrentMediaTime()
        let dt = now - progressStepAt
        progressStepAt = now
        let gap = progress - drawnProgress
        if abs(gap) < 0.0005 {
            drawnProgress = progress
            progressLink?.invalidate()
            progressLink = nil
        } else {
            drawnProgress += gap * (1 - exp(-dt / Self.progressEase))
        }
        setNeedsDisplay()
    }

    /// Whether it is rising in now.
    public var debugRising: Bool { rise < 1 }

    /// The waveform arriving rises into place, once.
    public func riseIn() {
        guard !MotionPreference.reducesMotion else { return }
        rise = 0
        let start = CACurrentMediaTime()
        let link = CADisplayLink(target: RiseStep { [weak self] link in
            guard let self else { return link.invalidate() }
            let t = min(1, (CACurrentMediaTime() - start) / 0.3)
            rise = CGFloat(1 - pow(1 - t, 3))
            setNeedsDisplay()
            if t >= 1 { link.invalidate() }
        }, selector: #selector(RiseStep.fire(_:)))
        link.add(to: .main, forMode: .common)
    }

    /// Drawn finer than the screen, so the bars stay sharp swollen.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        applyContentScale()
    }

    /// The screen's scale times the swell's (`swellFactor`).
    private func applyContentScale() {
        let screen = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        contentScaleFactor = screen * max(1, swellFactor)
        setNeedsDisplay()
    }

    public override func draw(_ rect: CGRect) {
        guard !bars.isEmpty else { return }
        let step = barStep
        // A bar fills by the share of it the progress has covered: the one
        // under the finger blends, none flips.
        let reached = drawnProgress * Double(bars.count)
        let played = playedInk.resolvedColor(with: traitCollection)
        let unplayed = unplayedInk.resolvedColor(with: traitCollection)
        for index in bars.indices {
            let tall: CGFloat = index < shares.count ? shares[index] : 0
            let full: CGFloat = waiting ? 0 : tall * bounds.height * rise
            let height = max(VoiceView.minBarHeight, full)
            let bar = CGRect(
                x: CGFloat(index) * step, y: (bounds.height - height) / 2,
                width: VoiceView.barWidth, height: height
            )
            let covered = CGFloat(min(1, max(0, reached - Double(index))))
            Self.blend(unplayed, played, covered).setFill()
            UIBezierPath(roundedRect: bar, cornerRadius: VoiceView.barWidth / 2).fill()
        }
    }

    /// `from` to `to`, `share` of the way, channel by channel.
    public static func blend(_ from: UIColor, _ to: UIColor, _ share: CGFloat) -> UIColor {
        guard share > 0 else { return from }
        guard share < 1 else { return to }
        var a = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        var b = a
        from.getRed(&a.r, green: &a.g, blue: &a.b, alpha: &a.a)
        to.getRed(&b.r, green: &b.g, blue: &b.b, alpha: &b.a)
        return UIColor(
            red: a.r + (b.r - a.r) * share, green: a.g + (b.g - a.g) * share,
            blue: a.b + (b.b - a.b) * share, alpha: a.a + (b.a - a.a) * share
        )
    }

    // MARK: - The finger (#2274)

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        onFinger?(true)
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        onFinger?(false)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        onFinger?(false)
    }

    // MARK: - Seeking

    private func fraction(at point: CGPoint) -> Double {
        Double(min(1, max(0, point.x / max(1, min(barsWidth, bounds.width)))))
    }

    /// Where `gesture` lands: as the host reads it, or on the bars' bounds.
    private func fraction(of gesture: UIGestureRecognizer) -> Double {
        fractionReader?(gesture) ?? fraction(at: gesture.location(in: self))
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        onSeek?(fraction(of: tap), false)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let share = fraction(of: pan)
        switch pan.state {
        case .began, .changed:
            onSeek?(share, true)
        default:
            onSeek?(share, false)
        }
    }

    /// Only a horizontal drag scrubs.
    public override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    /// A horizontal drag on the bars goes before the list's scroll and the
    /// screen's swipes, which wait for it to fail.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        // Not the bubble's own holds: waiting on the scrub, they failed when
        // it began and let the screen's swipes through.
        guard !(other.delegate is VoiceView) else { return false }
        return Self.yields(other, to: self)
    }

    /// Whether `other` waits for a voice message's own drag: any pan that
    /// is not the bubble's — the list's scroll, the content pop, the
    /// screen's swipe stages.
    public static func yields(_ other: UIGestureRecognizer, to view: UIView) -> Bool {
        guard other is UIPanGestureRecognizer, let owner = other.view else { return false }
        return !owner.isDescendant(of: view)
    }

    private final class RiseStep: NSObject {
        let action: (CADisplayLink) -> Void
        init(_ action: @escaping (CADisplayLink) -> Void) { self.action = action }
        @objc func fire(_ link: CADisplayLink) { action(link) }
    }

    #if DEBUG
    public var debugWaiting: Bool { waiting }
    /// A finger landing on the bars (true) or lifting (false), as a touch
    /// would say it.
    public func debugFinger(_ down: Bool) { onFinger?(down) }
    #endif
}

/// The voice panel's speed as a bare text button (#2364, the owner
/// 2026-11-12): "1×", "1.5×", "2×" as words — no capsule, no ground — in the
/// timer's font and ink, against its trailing edge (the slot's).
///
/// - **A target of at least 44 × 44 pt round the words**, invisible
///   (`VoiceView.speedTarget(around:)`): it may reach over the waveform's
///   end and the panel's trailing air.
/// - **Pressed, the words dim** (`VoiceView.speedPressedAlpha`), as a text
///   button's do; nothing else appears.
/// - **VoiceOver:** "Playback speed", its value the words.
final class VoiceSpeedButton: UIControl {
    /// Told on a tap (and VoiceOver's activation).
    var onTap: (() -> Void)?
    private let label = UILabel()

    var font: UIFont {
        get { label.font }
        set { label.font = newValue }
    }

    var ink: UIColor {
        get { label.textColor }
        set { label.textColor = newValue }
    }

    private(set) var title = "1×"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = nil
        label.text = title
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .natural
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // Against the trailing edge; the spare, if any, before the words.
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Playback speed"
        accessibilityValue = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The words — on screen, a short cross-fade in place.
    func setTitle(_ newTitle: String, animated: Bool) {
        guard newTitle != title else { return }
        title = newTitle
        accessibilityValue = newTitle
        guard animated else {
            label.text = newTitle
            return
        }
        UIView.transition(
            with: label, duration: VoiceView.speedChangeDuration,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
        ) {
            self.label.text = newTitle
        }
    }

    /// The words' frame, in its own space.
    var wordsFrame: CGRect { label.frame }

    /// Where a finger counts, in its own space: at least 44 × 44 round the
    /// words, and the whole slot.
    var targetFrame: CGRect { VoiceView.speedTarget(around: label.frame).union(bounds) }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        targetFrame.contains(point)
    }

    /// Pressed, the words dim — at once under the finger, back in a beat.
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let alpha: CGFloat = isHighlighted ? VoiceView.speedPressedAlpha : 1
            guard !isHighlighted, window != nil else {
                label.alpha = alpha
                return
            }
            UIView.animate(withDuration: AppearMotion.fadeDuration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.label.alpha = alpha
            }
        }
    }

    override func accessibilityActivate() -> Bool {
        onTap?()
        return true
    }

    /// The words' opacity now (their model value).
    var wordsAlpha: CGFloat { label.alpha }

    /// Whether it draws anything but its words: a fill, a border, a
    /// shadow, a corner, another view.
    var hasAGround: Bool {
        let fill = backgroundColor.map { $0.cgColor.alpha > 0 } ?? false
        let drawn = layer.backgroundColor.map { $0.alpha > 0 } ?? false
        let edge = layer.borderWidth > 0 || layer.shadowOpacity > 0 || layer.cornerRadius > 0
        return fill || drawn || edge || subviews != [label]
    }
}

/// The panel's play glyph: never an accessibility element of its own — the
/// panel is the element and says play, pause and the time (#2274).
/// ⚠️ `AppIconButton.refreshAccessibility` turns a button back into an element
/// on every refresh, which the bare glyph's ink and face changes run.
final class VoicePlayGlyphButton: AppIconButton {
    override func refreshAccessibility() {
        super.refreshAccessibility()
        isAccessibilityElement = false
    }
}
