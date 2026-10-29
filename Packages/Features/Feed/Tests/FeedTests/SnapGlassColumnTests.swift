import CoreModels
import Testing
import UIKit
@testable import Feed

/// The action column as one glass (#1872): which items stand in which
/// bubble, the fold into the sound, and that each item stays a live view in
/// its bubble's glass, on its station.
@MainActor
struct SnapGlassColumnTests {
    private static let face = SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false)

    private func mediaChrome(postActions: Bool) -> SnapChromeView {
        let chrome = SnapChromeView(frame: SnapActionColumnLayoutTests.screen)
        chrome.setFixedInsets(SnapActionColumnLayoutTests.insets)
        chrome.configure(with: SnapActionColumnLayoutTests.mediaModel())
        chrome.showsPostActions = postActions
        chrome.setSoundFace(Self.face)
        chrome.layoutIfNeeded()
        return chrome
    }

    /// The media layout: one bubble per station, top to bottom.
    @Test func theMediaLayoutStandsEachStationInItsBubble() {
        #expect(mediaChrome(postActions: true).debugColumnItems == [["like"], ["actions"], ["sound"]])
        #expect(mediaChrome(postActions: false).debugColumnItems == [["like"], ["sound"]])
    }

    /// The comments layout folds everything into the sound, which stays on
    /// its station; closing them stands the stations again.
    @Test func theCommentsFoldTheColumnIntoTheSound() {
        let chrome = mediaChrome(postActions: true)
        let sound = chrome.debugFrame(of: chrome.debugSoundBubble)
        chrome.setColumnCollapsed(true, animated: false)
        chrome.layoutIfNeeded()
        #expect(chrome.debugColumnItems == [["sound"]])
        #expect(chrome.debugGlassColumn.debugShapes.count == 1)
        #expect(chrome.debugFrame(of: chrome.debugSoundBubble) == sound, "the sound bubble moved")
        #expect(chrome.debugBoostButton.superview == nil, "the like stayed in the glass")
        chrome.setColumnCollapsed(false, animated: false)
        chrome.layoutIfNeeded()
        #expect(chrome.debugColumnItems == [["like"], ["actions"], ["sound"]])
        #expect(chrome.debugBoostButton.superview != nil)
    }

    /// A page with no sound face (a text page) has nothing to fold into: its
    /// like stands where it stood.
    @Test func withNoSoundTheColumnDoesNotFold() {
        let chrome = SnapChromeView(frame: SnapActionColumnLayoutTests.screen)
        chrome.setFixedInsets(SnapActionColumnLayoutTests.insets)
        chrome.configure(with: SnapActionColumnLayoutTests.mediaModel(mediaURL: nil))
        chrome.layoutIfNeeded()
        chrome.setColumnCollapsed(true, animated: false)
        #expect(chrome.debugColumnItems == [["like"]])
    }

    /// Each item is hosted IN its bubble's glass — the only way a touch
    /// reaches the glass (the lab's finding 3) — at its station's frame.
    @Test func eachItemLivesInItsBubblesGlass() throws {
        let column = SnapGlassColumn(frame: CGRect(x: 0, y: 0, width: 100, height: 300))
        let like = UIButton()
        let sound = UIButton()
        column.register(like, for: "like")
        column.register(sound, for: "sound")
        let likeFrame = CGRect(x: 40, y: 20, width: 48, height: 120)
        let soundFrame = CGRect(x: 40, y: 200, width: 48, height: 48)
        column.layout = { [[.init(id: "like", frame: likeFrame)], [.init(id: "sound", frame: soundFrame)]] }
        column.refresh(animated: false)
        let glass = try #require(like.superview?.superview as? UIVisualEffectView)
        #expect(glass.isDescendant(of: column))
        #expect(like.convert(like.bounds, to: column) == likeFrame)
        #expect(sound.convert(sound.bounds, to: column) == soundFrame)
    }

    /// Between two bubbles the touch is the page's, not the column's.
    @Test func betweenTheBubblesTheColumnTakesNoTouch() {
        let column = SnapGlassColumn(frame: CGRect(x: 0, y: 0, width: 100, height: 300))
        let like = UIButton()
        column.register(like, for: "like")
        column.layout = { [[.init(id: "like", frame: CGRect(x: 40, y: 20, width: 48, height: 120))]] }
        column.refresh(animated: false)
        #expect(column.hitTest(CGPoint(x: 64, y: 80), with: nil) != nil)
        #expect(column.hitTest(CGPoint(x: 64, y: 200), with: nil) == nil)
        #expect(column.hitTest(CGPoint(x: 10, y: 80), with: nil) == nil)
    }

    /// The anchor is the sound: everything is born from it and folds into it.
    @Test func theSoundIsTheAnchor() {
        #expect(mediaChrome(postActions: true).debugGlassColumn.anchorID == "sound")
    }
}
