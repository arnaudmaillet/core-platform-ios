import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// Away from the comments' start, the sound offers the way back (#1929): the
/// record cross-fades with `chevron.up`, a tap goes back to the top, and a
/// hold arms the sound sheet — the bubble's own tap action.
@MainActor
struct SnapSoundReturnTests {
    private typealias Layout = SnapActionColumnLayoutTests
    private static let face = SnapSoundFace(coverURL: nil, isAvailable: true)

    /// The page's bubble: the record fades inside the glass, the chevron
    /// arrives, and the record stops turning until it comes back.
    @Test func theBubbleCrossFadesItsRecordWithTheWayBack() {
        let bubble = SnapSoundBubbleButton()
        bubble.setFace(Self.face, pipeline: nil)
        bubble.setSpinning(true)

        bubble.setShowsReturn(true, animated: false)
        #expect(bubble.debugRecord.recordAlpha == 0, "the record still shows under the chevron")
        #expect(bubble.debugReturnGlyphAlpha == 1)
        #expect(bubble.debugRecord.alpha == 1, "the glass faded with the record")
        #expect(bubble.accessibilityLabel == "Back to top")
        #expect(!bubble.debugIsSpinning, "the hidden record kept turning")

        bubble.setShowsReturn(false, animated: false)
        #expect(bubble.debugRecord.recordAlpha == 1)
        #expect(bubble.debugReturnGlyphAlpha == 0)
        #expect(bubble.accessibilityLabel == "Sound")
        if !MotionPreference.reducesMotion {
            #expect(bubble.debugIsSpinning, "the record did not turn again when it came back")
        }
    }

    /// A greyed sound (no audio) still answers on its way back.
    @Test func theWayBackAnswersOnAGreyedSound() {
        let bubble = SnapSoundBubbleButton()
        bubble.setFace(SnapSoundFace(coverURL: nil, isAvailable: false), pipeline: nil)
        #expect(!bubble.isEnabled)
        bubble.setShowsReturn(true, animated: false)
        #expect(bubble.isEnabled, "the way back refused a tap")
        #expect(bubble.alpha == 1)
        bubble.setShowsReturn(false, animated: false)
        #expect(!bubble.isEnabled)
    }

    /// The column: a tap goes back while the chevron shows, the sheet
    /// otherwise; the hold arms the sheet only then, and VoiceOver keeps it.
    @Test func theChromesTapGoesBackAndItsHoldArmsTheSheet() throws {
        let chrome = SnapChromeView()
        chrome.setSoundFace(Self.face)
        var sheets = 0
        var returns = 0
        chrome.onSoundSheetRequested = { sheets += 1 }
        chrome.onSoundReturnRequested = { returns += 1 }
        let bubble = chrome.debugSoundBubble
        let hold = try #require(chrome.debugSoundHold)

        bubble.sendActions(for: .primaryActionTriggered)
        #expect(sheets == 1)
        #expect(!hold.isEnabled, "the record has a hold of its own again")

        chrome.setSoundShowsReturn(true, animated: false)
        bubble.sendActions(for: .primaryActionTriggered)
        #expect(returns == 1, "the chevron's tap did not go back")
        #expect(sheets == 1, "the chevron's tap opened the sheet")
        #expect(hold.isEnabled, "the chevron's hold is off")
        hold.onFire?()
        #expect(sheets == 2, "the hold did not open the sheet")
        let action = try #require(bubble.accessibilityCustomActions?.first)
        #expect(action.name == "Sound")
        _ = action.actionHandler?(action)
        #expect(sheets == 3)
        // The sound gone under the chevron: nothing left to arm.
        chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: false))
        #expect(!hold.isEnabled, "the hold arms a sheet for a post with no audio")
        #expect(bubble.accessibilityCustomActions == nil)
        chrome.setSoundFace(Self.face)
        #expect(hold.isEnabled)

        chrome.setSoundShowsReturn(false, animated: false)
        #expect(!hold.isEnabled)
        #expect(bubble.accessibilityCustomActions == nil)
    }

    /// A reused page starts on its record.
    @Test func aResetPageStartsOnItsRecord() {
        let chrome = SnapChromeView()
        chrome.setSoundFace(Self.face)
        chrome.setSoundShowsReturn(true, animated: false)
        chrome.reset()
        #expect(!chrome.debugSoundBubble.showsReturn)
    }

    /// The stream says when the way back comes and goes — on the reader's
    /// own scroll only — and a programmatic move never shows it.
    @Test func theStreamTellsItsHostOnTheReadersScrollOnly() {
        let (panel, window) = Layout.engagedPanel()
        defer { window.isHidden = true }
        var told: [Bool] = []
        panel.onScrollAwayChange = { told.append($0) }

        panel.debugScroll(to: 3000, userScroll: false)
        #expect(told.isEmpty, "a programmatic move showed the way back")
        panel.debugScroll(to: 3000, userScroll: true)
        #expect(told == [true])
        #expect(panel.showsScrollAwayReturn)
        panel.debugScroll(to: panel.debugStreamTopOffset, userScroll: false)
        #expect(told == [true, false], "back at the text, the way back stayed")
    }

    /// Under a page's column, the composer's slot stays the sound: the page's
    /// bubble wears the way back.
    @Test func underAPagesColumnTheSlotStaysTheSound() {
        let (panel, window) = Layout.engagedPanel()
        defer { window.isHidden = true }
        panel.setActionColumnHostedByPage(true)
        panel.setRailSoundFace(Self.face)
        panel.debugScroll(to: 3000, userScroll: true)
        #expect(panel.debugRailFace == .sound(Self.face))
        #expect(panel.debugRailSoundHold?.isEnabled == false)
    }

    /// A composer that draws its own column (the loading page, a pushed
    /// post): the slot becomes `chevron.up`, its tap goes back to the text,
    /// and its hold arms the sound's tap action.
    @Test func aComposerDrawingItsColumnWearsTheWayBack() async throws {
        let (panel, window) = Layout.engagedPanel()
        defer { window.isHidden = true }
        var sheets = 0
        panel.setActionColumnHostedByPage(false)
        panel.setRailSoundFace(Self.face)
        panel.setRailSoundActions(tap: { sheets += 1 }, hold: nil)

        panel.debugScroll(to: 3000, userScroll: true)
        #expect(panel.debugRailFace == .returnTo(down: false))
        let hold = try #require(panel.debugRailSoundHold)
        #expect(hold.isEnabled)
        hold.onFire?()
        #expect(sheets == 1)

        let away = panel.debugStreamOffset
        panel.debugTapRail()
        #expect(sheets == 1, "the chevron's tap opened the sheet")
        for _ in 0..<100 where panel.debugStreamOffset >= away { try await Task.sleep(for: .milliseconds(10)) }
        #expect(panel.debugStreamOffset < away, "the tap did not head for the text")
        // The arrival's own scroll callback hides the way back.
        panel.debugScroll(to: panel.debugStreamTopOffset, userScroll: false)
        #expect(panel.debugRailFace == .sound(Self.face))
        #expect(!hold.isEnabled)
        panel.debugTapRail()
        #expect(sheets == 2)
    }

    /// A text post with no sound has no slot (#1790), so no way back.
    @Test func noSlotMeansNoWayBack() {
        let (panel, window) = Layout.engagedPanel()
        defer { window.isHidden = true }
        panel.setActionColumnHostedByPage(false)
        panel.setRailSoundFace(nil, keepsSlot: false)
        panel.debugScroll(to: 3000, userScroll: true)
        #expect(panel.debugRailFace == .noSlot)
    }
}
