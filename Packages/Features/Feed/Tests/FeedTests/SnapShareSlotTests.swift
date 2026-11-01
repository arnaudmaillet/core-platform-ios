import CoreModels
import Testing
import UIKit
@testable import Feed

/// A pushed text page's Share, in the slot right of the comment field
/// (#1999): the toolbar's action, the way back over it (#1929), and
/// VoiceOver's road while the chevron shows.
@MainActor
struct SnapShareSlotTests {
    private typealias Layout = SnapActionColumnLayoutTests

    /// The bar's face: the toolbar's glyph, label and identifier; a tap is
    /// the host's action.
    @Test func theShareFaceIsTheToolbarsShare() {
        let bar = CommentsInputBar()
        bar.railFace = .share
        #expect(bar.debugRailSymbol == CommentsInputBar.shareRailSymbol)
        #expect(bar.debugRailButton.accessibilityLabel == "Share")
        #expect(bar.debugRailButton.accessibilityIdentifier == SnapFooterToolbar.ID.share)
        var taps = 0
        bar.onRailAction = { taps += 1 }
        bar.debugRailButton.sendActions(for: .primaryActionTriggered)
        #expect(taps == 1)
        bar.railFace = .pin(isPinned: false)
        #expect(bar.debugRailButton.accessibilityIdentifier == nil, "another face kept Share's identifier")
    }

    /// The panel: a tap shares; scrolled away the slot is the way back, its
    /// hold arms nothing (a text post has no sound) and VoiceOver offers
    /// "Share"; back at the top, Share returns.
    @Test func theWayBackTakesShareAndGivesItBack() async throws {
        let (panel, window) = Layout.engagedPanel()
        defer { window.isHidden = true }
        var shares = 0
        var sheets = 0
        panel.setActionColumnHostedByPage(false)
        panel.setRailShare { shares += 1 }
        panel.setRailSoundFace(nil, keepsSlot: true)
        panel.setRailSoundActions(tap: { sheets += 1 }, hold: nil)
        #expect(panel.debugRailFace == .share)
        panel.debugTapRail()
        #expect(shares == 1)
        #expect(sheets == 0, "Share opened the sound sheet")

        panel.debugScroll(to: 3000, userScroll: true)
        #expect(panel.debugRailFace == .returnTo(down: false))
        let hold = try #require(panel.debugRailSoundHold)
        #expect(!hold.isEnabled, "the way back's hold arms something on a text page")
        let action = try #require(panel.debugRailCustomActions?.first)
        #expect(action.name == "Share")
        _ = action.actionHandler?(action)
        #expect(shares == 2)

        panel.debugScroll(to: panel.debugStreamTopOffset, userScroll: false)
        #expect(panel.debugRailFace == .share)
        #expect(panel.debugRailCustomActions == nil)
    }

    /// The page's column on a pushed text page: its bubble is Share — a tap
    /// shares; under the way back the hold arms nothing and VoiceOver keeps
    /// "Share" (#1999).
    @Test func thePagesBubbleIsShareOnATextPage() throws {
        let chrome = SnapChromeView()
        chrome.setSoundFace(nil)
        chrome.setSlotSharesPost(true)
        var shares = 0
        var sheets = 0
        chrome.onShareRequested = { shares += 1 }
        chrome.onSoundSheetRequested = { sheets += 1 }
        let bubble = chrome.debugSoundBubble
        #expect(!bubble.isHidden, "a text page's column has no Share")
        #expect(bubble.accessibilityLabel == "Share")
        #expect(bubble.accessibilityIdentifier == SnapFooterToolbar.ID.share)
        #expect(bubble.isEnabled)
        #expect(bubble.debugShareGlyphAlpha == 1)
        #expect(bubble.debugRecord.recordAlpha == 0, "the record shows under Share")
        bubble.sendActions(for: .primaryActionTriggered)
        #expect(shares == 1)
        #expect(sheets == 0)

        chrome.setSoundShowsReturn(true, animated: false)
        #expect(bubble.debugShareGlyphAlpha == 0)
        #expect(bubble.debugReturnGlyphAlpha == 1)
        let hold = try #require(chrome.debugSoundHold)
        #expect(!hold.isEnabled, "the way back's hold arms something on a text page")
        let action = try #require(bubble.accessibilityCustomActions?.first)
        #expect(action.name == "Share")
        _ = action.actionHandler?(action)
        #expect(shares == 2)

        chrome.setSoundShowsReturn(false, animated: false)
        #expect(bubble.debugShareGlyphAlpha == 1)
        #expect(bubble.accessibilityLabel == "Share")
        chrome.setSlotSharesPost(false)
        #expect(bubble.isHidden, "a page with no sound and no Share kept its bubble")
    }

    /// A media page's column ends on Share (#1999): under the way back its
    /// hold arms Share — the slot's own action (#1929) — with Share's glyph.
    @Test func aMediaPagesWayBackHoldArmsShare() throws {
        let chrome = SnapChromeView()
        chrome.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true))
        chrome.setSlotSharesPost(true, holdArmsShare: true)
        var shares = 0
        var sheets = 0
        chrome.onShareRequested = { shares += 1 }
        chrome.onSoundSheetRequested = { sheets += 1 }
        let bubble = chrome.debugSoundBubble
        #expect(bubble.accessibilityLabel == "Share")
        #expect(!bubble.debugIsSpinning)
        let hold = try #require(chrome.debugSoundHold)
        #expect(!hold.isEnabled, "Share has a hold at rest")

        chrome.setSoundShowsReturn(true, animated: false)
        #expect(hold.isEnabled, "the way back's hold over a media page's Share is off")
        hold.onFire?()
        #expect(shares == 1)
        #expect(sheets == 0, "the hold opened the sound sheet")
    }

    /// The composer's slot on a media page: the same rule.
    @Test func aMediaPagesComposerHoldArmsShare() throws {
        let (panel, window) = Layout.engagedPanel()
        defer { window.isHidden = true }
        var shares = 0
        panel.setActionColumnHostedByPage(false)
        panel.setRailShare({ shares += 1 }, holdArms: true)
        panel.setRailSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true))
        #expect(panel.debugRailFace == .share)
        panel.debugScroll(to: 3000, userScroll: true)
        let hold = try #require(panel.debugRailSoundHold)
        #expect(hold.isEnabled)
        hold.onFire?()
        #expect(shares == 1)
    }
}
