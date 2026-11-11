import CoreModels
import DesignSystem
import FeedInterface
import Testing
import UIKit
import VoiceKitUI
@testable import Feed

/// The voice message's bubble (#2104) — the neutral panel since #2241.
@MainActor
struct ThreadVoiceViewTests {
    /// The thread's panel starts at the text column and takes the row's
    /// width, capped at `conversationMaxWidth` (#2241) — whatever the
    /// message's length.
    @Test func aMessagesPanelTakesTheTextColumnCapped() {
        let leading = CommentRowView.avatarSize + CommentRowView.avatarGap
        func panel(width: CGFloat, duration: TimeInterval) -> CGRect {
            let view = ThreadVoiceView.thread()
            view.configure(ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: duration), senderName: nil)
            view.frame = CGRect(x: 0, y: 0, width: width, height: ThreadVoiceView.panelHeight(for: .full))
            view.layoutIfNeeded()
            return view.debugPanelFrame
        }
        let phone = panel(width: 300, duration: 2)
        #expect(phone.minX == leading)
        #expect(abs(phone.width - (300 - leading)) < 0.5, "\(phone)")
        let wide = panel(width: 900, duration: 2)
        #expect(abs(wide.width - ThreadVoiceView.conversationMaxWidth) < 0.5, "\(wide)")
        #expect(panel(width: 900, duration: 50) == wide, "the length changed the width")
    }

    /// 2 pt bars 2 pt apart: about 45 at 180 pt, re-binned from 100 levels
    /// by their peak.
    @Test func theBarsComeFromTheWidthAndTheLevels() {
        #expect(ThreadVoiceView.barCount(forWidth: 180) == 45)
        var levels = [UInt8](repeating: 3, count: 100)
        levels[2] = 31
        let bars = ThreadVoiceView.rebin(levels, to: 45)
        #expect(bars.count == 45)
        #expect(bars[0] == 31 || bars[1] == 31, "a bin's peak was lost")
        #expect(bars.filter { $0 == 31 }.count == 1)
        #expect(ThreadVoiceView.rebin([], to: 10) == Array(repeating: 0, count: 10))
    }

    @Test func theTimerReadsAsAClock() {
        #expect(ThreadVoiceView.clock(12.9) == "0:12")
        #expect(ThreadVoiceView.clock(65) == "1:05")
        #expect(ThreadVoiceView.clock(3_723) == "1:02:03")
        #expect(ThreadVoiceView.clock(-1) == "0:00")
    }

    private func view(_ state: ThreadVoiceView.State) -> ThreadVoiceView {
        let view = ThreadVoiceView.thread()
        view.frame = CGRect(x: 0, y: 0, width: 360, height: ThreadVoiceView.panelHeight(for: .full))
        view.configure(state, senderName: "Ava")
        view.layoutIfNeeded()
        return view
    }

    /// At rest the duration and, unplayed, the dot; playing the chip takes
    /// the timer's slot and the dot goes; paused mid-way the elapsed time
    /// back in the slot (#2274).
    @Test func theTimerTheChipAndTheDotFollowThePlayback() {
        var state = ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 12, unplayed: true)
        let view = view(state)
        #expect(view.debugTimerText == "0:12")
        #expect(view.debugShowsDot)
        #expect(!view.debugShowsChip)
        #expect(view.accessibilityLabel == "Voice message from Ava, 12 seconds, not played")

        state.playback = .playing(progress: 0.5)
        state.speedLabel = "1.5×"
        view.update(state)
        #expect(view.debugShowsChip)
        #expect(view.debugChipTitle == "1.5×")
        #expect(view.debugTimerText == "0:06")
        #expect(view.debugGlyph == AppSymbol.pause.rawValue)

        state.unplayed = false
        state.playback = .paused(progress: 0.25)
        view.update(state)
        #expect(!view.debugShowsDot)
        #expect(!view.debugShowsChip && view.debugShowsTimer, "paused, the slot shows the time reached")
        #expect(view.debugTimerText == "0:03")
        #expect(view.debugGlyph == AppSymbol.play.rawValue)
        #expect(view.accessibilityLabel?.hasSuffix(", played") == true)

        state.playback = .loading
        view.update(state)
        #expect(view.debugGlyph == AppSymbol.pause.rawValue, "the glyph turns on the tap, not when the audio is ready")
        #expect(!view.debugShowsLoader)
        view.debugLoaderWaitEnds()
        #expect(view.debugShowsLoader, "a wait that lasts shows the loader")
        state.playback = .failed
        view.update(state)
        #expect(view.debugGlyph == "arrow.clockwise")
    }

    /// The sent copy keeps the pending one's bars (the owner, 2026-11-07):
    /// its length comes back to a tenth of a second, and the panel no longer
    /// reads its width from the length (#2241), so nothing moves.
    @Test func theSentCopyKeepsThePendingOnesBars() {
        let pending = view(ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 4.37))
        let sent = view(ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 4.4))
        #expect(pending.debugPanelFrame == sent.debugPanelFrame)
        #expect(pending.waveform.bars.count == sent.waveform.bars.count)
    }

    /// A row filled afresh — the sent copy in the pending one's place —
    /// draws its waveform at once; it rises only when it arrives for the
    /// message already shown.
    @Test func aFreshRowDoesNotRiseItsWaveform() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 200))
        window.isHidden = false
        defer { window.isHidden = true }
        let view = ThreadVoiceView.thread()
        view.frame = CGRect(x: 0, y: 0, width: 360, height: ThreadVoiceView.panelHeight(for: .full))
        window.addSubview(view)
        view.configure(ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 4), senderName: nil)
        #expect(!view.debugWaveformRising, "a fresh row's waveform rose")
        var waiting = ThreadVoiceView.State(levels: nil, duration: 4)
        view.configure(waiting, senderName: "Ava")
        waiting.levels = Array(repeating: 9, count: 100)
        view.configure(waiting, senderName: "Ava")
        #expect(view.debugWaveformRising, "an arriving waveform did not rise")
    }

    /// Sending, the bubble keeps its play glyph — no loader over it (the
    /// owner, 2026-11-07): the message's one loader is beside "You".
    @Test func sendingShowsNoLoaderOverThePlayButton() {
        var state = ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 3)
        state.delivery = .sending
        let view = view(state)
        #expect(!view.debugShowsLoader)
        #expect(view.debugGlyph == AppSymbol.play.rawValue)
        #expect(!view.debugPlayEnabled)
    }

    /// No disc (#2274): the app's icon button as a bare glyph, in a 40 pt
    /// frame in full — where the disc was.
    @Test func thePlayButtonHasNoDisc() {
        let view = view(ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 3))
        view.layoutIfNeeded()
        #expect(view.debugButtonImage != nil)
        #expect(view.debugPlayButtonIsABareGlyph)
        #expect(view.debugButtonSize == CGSize(width: 40, height: 40))
    }

    /// A voice message owns horizontal drags: the conversation's leftward
    /// swipe never starts on its waveform or its play button.
    @Test func aVoiceMessageOwnsItsHorizontalDrags() {
        let screen = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        let voice = ThreadVoiceView.thread()
        voice.configure(ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 3), senderName: nil)
        voice.frame = CGRect(x: 0, y: 100, width: 402, height: 60)
        screen.addSubview(voice)
        screen.layoutIfNeeded()
        let composer = UIView(frame: CGRect(x: 0, y: 340, width: 402, height: 60))
        screen.addSubview(composer)
        #expect(ConversationThreadViewController.ownsHorizontalDrag(at: CGPoint(x: 100, y: 116), in: screen, composer: composer))
        #expect(!ConversationThreadViewController.ownsHorizontalDrag(at: CGPoint(x: 200, y: 20), in: screen, composer: composer))
        #expect(!ConversationThreadViewController.ownsHorizontalDrag(at: CGPoint(x: 398, y: 120), in: screen, composer: composer),
                "the row's room beside a capped panel is the screen's")
    }

    /// Playing, the chip takes the timer's slot (#2274): its pill fills the
    /// slot the timer was centred in, level with it, off the bars, and the
    /// row keeps its height: playing never re-lays the list.
    @Test func theChipFillsTheTimersSlot() {
        var state = ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 12)
        let view = view(state)
        let rest = view.systemLayoutSizeFitting(CGSize(width: 360, height: 0)).height
        let slot = view.debugSlotFrame, timer = view.debugTimerFrame, bars = view.debugWaveformFrame
        #expect(abs(timer.midX - slot.midX) < 0.5 && abs(timer.midY - slot.midY) < 0.5, "\(timer) in \(slot)")
        state.playback = .playing(progress: 0.5)
        view.update(state)
        view.layoutIfNeeded()
        #expect(view.systemLayoutSizeFitting(CGSize(width: 360, height: 0)).height == rest)
        #expect(rest == ThreadVoiceView.panelHeight(for: .full))
        #expect(view.debugChipIsTheAppsPill, "the app's pill, not a system button")
        let chip = view.debugChipFrame
        #expect(chip == slot, "\(chip) doesn't fill \(slot)")
        #expect(view.debugWaveformFrame == bars, "the chip moved the bars")
        #expect(!chip.intersects(bars), "off the bars")
    }

    /// Whatever the speed reads, the chip stands in the same slot and takes
    /// its press; the bars keep theirs.
    @Test(arguments: ["1×", "1.5×", "2×"])
    func theChipKeepsTheSlotAtEverySpeed(_ speed: String) {
        var state = ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 12)
        let resting = view(state)
        let slot = resting.debugSlotFrame
        state.playback = .playing(progress: 0.3)
        state.speedLabel = speed
        let playing = view(state)
        playing.debugSetSpeedLabel(speed)
        let chip = playing.debugChipFrame, bars = playing.debugWaveformFrame
        #expect(abs(bars.width - playing.waveform.barsWidth) < 0.5, "the view is its bars")
        #expect(chip == slot && playing.debugSlotFrame == slot, "\(speed): \(chip) vs \(slot)")
        #expect(playing.debugPressTarget(at: CGPoint(x: chip.midX, y: chip.midY)) == "chip")
        #expect(playing.debugPressTarget(at: CGPoint(x: bars.minX + 2, y: bars.midY)) == "waveform")
    }

    /// A finger scrubbing the bars swells the whole panel as one (#2274) —
    /// the bars, the timer and the chip move nothing inside it, and scale by
    /// one factor while the ground grows (#2284); it settles when the scrub
    /// ends.
    @Test func scrubbingSwellsThePanel() {
        var state = ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 12)
        state.playback = .playing(progress: 0.3)
        let view = view(state)
        view.reducesMotion = { false }
        #expect(view.debugShowsChip && view.debugPanelTransform == .identity)
        view.waveform.onSeek?(0.5, true)
        #expect(view.debugShowsChip, "the chip stays")
        let resting = view.debugPanelRestingSize
        #expect(view.debugPanelTransform == ThreadVoiceView.swelledScale(for: resting))
        #expect(view.debugPanelTransform.a == view.debugPanelTransform.d, "the panel's content is stretched")
        #expect(view.debugGroundSize == ThreadVoiceView.swelledGroundSize(for: resting), "the ground didn't grow")
        #expect(view.debugGroundSize.height > resting.height)
        #expect(view.debugPartTransforms.allSatisfy { $0 == .identity }, "a part moved inside the panel")
        view.waveform.onSeek?(0.6, false)
        #expect(view.debugPanelTransform == .identity)
    }

    /// The bar the progress is in fills by its share, and the drawn progress
    /// eases to a new one: no bar flips colour at once.
    @Test func theFillIsProgressive() {
        let half = WaveformBars.blend(.black, .white, 0.5)
        var white: CGFloat = 0
        half.getWhite(&white, alpha: nil)
        #expect(abs(white - 0.5) < 0.01, "half-way blended")
        #expect(WaveformBars.blend(.black, .white, 0) == .black && WaveformBars.blend(.black, .white, 1) == .white)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        window.isHidden = false
        defer { window.isHidden = true }
        let bars = WaveformBars(frame: CGRect(x: 0, y: 0, width: 198, height: 20))
        window.addSubview(bars)
        bars.configure(levels: Array(repeating: 20, count: 100), barCount: 50, progress: 0)
        bars.setProgress(0.5)
        #expect(bars.progress == 0.5)
        #expect(bars.drawnProgress < 0.5, "a jump eases in, it does not land at once")
    }

    /// A sideways drag anywhere on the bubble is the bubble's: the screen's
    /// pans wait for its hold, the bubble's own run alongside, a vertical
    /// drag is not taken.
    @Test func aSidewaysDragAnywhereOnTheBubbleIsItsOwn() throws {
        let view = view(ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 3))
        let side = view.debugSideHold
        #expect(side.view?.isDescendant(of: view) == true && side.view !== view, "on the bubble, not the whole row")
        #expect(!side.cancelsTouchesInView)
        let list = UIScrollView()
        #expect(view.gestureRecognizer(side, shouldBeRequiredToFailBy: list.panGestureRecognizer))
        let scrub = try #require(view.waveform.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
        #expect(view.gestureRecognizer(side, shouldRecognizeSimultaneouslyWith: scrub))
        #expect(!view.waveform.gestureRecognizer(scrub, shouldBeRequiredToFailBy: side), "a scrub never makes the hold fail")
        #expect(!view.gestureRecognizer(side, shouldRecognizeSimultaneouslyWith: list.panGestureRecognizer))
    }

    /// A drag that starts on the play button is the button's: the list's
    /// scroll and every other pan wait for it; the bubble's own do not.
    @Test func thePlayButtonHoldsItsDrags() throws {
        let view = view(ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 3))
        let hold = try #require(view.debugPlayButtonHold)
        #expect(!hold.cancelsTouchesInView, "a press that drifts is still a press")
        let list = UIScrollView()
        #expect(view.gestureRecognizer(hold, shouldBeRequiredToFailBy: list.panGestureRecognizer))
        let screen = UIView()
        let swipe = UIPanGestureRecognizer()
        screen.addGestureRecognizer(swipe)
        #expect(view.gestureRecognizer(hold, shouldBeRequiredToFailBy: swipe))
        #expect(!view.gestureRecognizer(hold, shouldBeRequiredToFailBy: UITapGestureRecognizer()))
        let scrub = try #require(view.waveform.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
        #expect(!view.gestureRecognizer(hold, shouldBeRequiredToFailBy: scrub))
        #expect(view.waveform.gestureRecognizer(scrub, shouldBeRequiredToFailBy: list.panGestureRecognizer))
    }

    /// A press on the play button or the waveform is the bubble's, never
    /// the row's long press; the timer's spot is still the row's.
    @Test func itsControlsKeepThePressFromTheRow() {
        let view = view(ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 12))
        let leading = CommentRowView.avatarSize + CommentRowView.avatarGap
        let side = ThreadVoiceView.buttonSide(for: .full)
        let pad = ThreadVoiceView.panelPadding(for: .full)
        let mid = pad + side / 2
        #expect(view.keepsPress(at: CGPoint(x: leading + mid, y: mid)), "the play button")
        #expect(view.keepsPress(at: CGPoint(x: leading + pad + side + Spacing.sm + 20, y: mid)), "the waveform")
        #expect(!view.keepsPress(at: CGPoint(x: 2, y: mid)), "beside the panel")
        view.configure(nil)
        #expect(!view.keepsPress(at: CGPoint(x: leading + mid, y: mid)), "a row with no voice")
    }

    /// The conversation's list gives its controls the touch at once, and a
    /// scroll may still start on one — but not on a voice message.
    @Test func theListAnswersAtOnceAndLeavesTheVoiceItsDrags() {
        let list = ConversationCollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        #expect(!list.delaysContentTouches)
        #expect(list.touchesShouldCancel(in: UIButton()), "a scroll may start on any other control")
        let voice = ThreadVoiceView.thread()
        let inside = UIButton()
        voice.addSubview(inside)
        #expect(!list.touchesShouldCancel(in: inside))
        #expect(list.touchesShouldCancel(in: UIView()))
    }

    /// The bubble stands right under the name line, beside the avatar,
    /// where a body would be.
    @Test func theBubbleStandsUnderTheName() {
        let cell = ThreadRowCell(frame: CGRect(x: 0, y: 0, width: 402, height: 200))
        cell.row.configure(with: CommentDisplayModel(
            id: "v", authorID: ProfileID("a"), authorName: "Ava", metaText: "2:43 PM", body: "", avatarURL: nil
        ))
        cell.voiceView.configure(ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 3))
        func laidOut() -> (row: CGRect, voice: CGRect) {
            let height = cell.contentView.systemLayoutSizeFitting(
                CGSize(width: 402, height: 0),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height
            cell.frame = CGRect(x: 0, y: 0, width: 402, height: height)
            cell.layoutIfNeeded()
            return (cell.row.convert(cell.row.bounds, to: cell), cell.voiceView.convert(cell.voiceView.bounds, to: cell))
        }
        cell.tucksVoice = true
        let tucked = laidOut()
        let gap = tucked.voice.minY - tucked.row.minY - CommentRowView.nameLineHeight(for: cell.traitCollection)
        #expect(abs(gap - Spacing.xs) < 0.5, "\(tucked)")
        cell.tucksVoice = false
        let under = laidOut()
        #expect(under.voice.minY >= under.row.maxY, "\(under)")
    }

    /// A reused bubble keeps nothing of the message it showed.
    @Test func reuseResets() {
        let view = view(ThreadVoiceView.State(duration: 40, playback: .playing(progress: 0.8)))
        view.configure(nil)
        #expect(view.isHidden)
        view.configure(ThreadVoiceView.State(duration: 5), senderName: nil)
        #expect(view.debugTimerText == "0:05", "the previous message's progress showed")
        #expect(!view.debugShowsChip)
        #expect(view.state.progress == 0)
        #expect(view.waveform.debugWaiting, "no waveform yet draws the flat row")
    }

    /// A tap on the waveform seeks there.
    @Test func scrubbingSeeks() {
        let view = view(ThreadVoiceView.State(levels: Array(repeating: 9, count: 100), duration: 10))
        var seeks: [Double] = []
        view.onSeek = { fraction, _ in seeks.append(fraction) }
        view.accessibilityIncrement()
        #expect(seeks == [0.5], "VoiceOver's +5 s on a 10 s message")
    }

    /// The next one plays on its own only when it is the very next message,
    /// received, a voice message, unplayed.
    @Test func autoplayPicksOnlyTheNextReceivedUnplayedVoice() {
        func message(_ id: String, voice: Bool, mine: Bool = false) -> ConversationThreadMessage {
            ConversationThreadMessage(
                id: id, senderID: ProfileID(mine ? "me" : "them"), body: voice ? "" : "hi", sentAt: Date(),
                isMine: mine, quote: nil,
                media: voice ? ConversationThreadMedia(kind: .voice, url: URL(string: "file:///\(id).m4a")) : nil,
                delivery: .sent
            )
        }
        let messages = [
            message("a", voice: true), message("b", voice: true), message("c", voice: true, mine: true),
            message("d", voice: true), message("e", voice: false), message("f", voice: true),
        ]
        let next = { (id: String, played: Set<String>) in
            ConversationThreadViewController.nextVoice(after: id, in: messages, isPlayed: { played.contains($0) })
        }
        #expect(next("a", []) == "b")
        #expect(next("a", ["b"]) == nil, "an already played one")
        #expect(next("b", []) == nil, "the viewer's own")
        #expect(next("d", []) == nil, "a text stops it")
        #expect(next("c", []) == nil, "after the viewer's own")
        #expect(next("f", []) == nil, "the last")
    }
}
