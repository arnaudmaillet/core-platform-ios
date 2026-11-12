import CoreModels
import Testing
import UIKit
@testable import Feed

/// The action column as one glass (#1872): which items stand in which
/// bubble, the fold into the sound, and that each item stays a live view in
/// its bubble's glass, on its station.
@MainActor
struct SnapGlassColumnTests {
    private static let face = SnapSoundFace(coverURL: nil, isAvailable: true)

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

    /// Horizontally (#2344, the composer's capsule): two items side by side
    /// in one bubble, the anchor in its own; each item hosted in its
    /// bubble's glass at its frame; the anchor alone once the capsule folds;
    /// a covered anchor drawn as a point inside its frame.
    @Test func aHorizontalColumnStandsACapsuleBesideItsAnchor() throws {
        let column = SnapGlassColumn(frame: CGRect(x: 0, y: 0, width: 143, height: 45))
        column.axis = .horizontal
        column.anchorID = "anchor"
        column.revealsInOneCapsule = false
        let camera = UIButton()
        let library = UIButton()
        column.register(camera, for: "camera")
        column.register(library, for: "library")
        let cameraFrame = CGRect(x: 0, y: 0, width: 45, height: 45)
        let libraryFrame = CGRect(x: 45, y: 0, width: 45, height: 45)
        let anchorFrame = CGRect(x: 98, y: 0, width: 45, height: 45)
        var folded = false
        column.layout = {
            let anchor = [SnapGlassColumn.Slot(id: "anchor", frame: anchorFrame)]
            guard !folded else { return [anchor] }
            return [[.init(id: "camera", frame: cameraFrame), .init(id: "library", frame: libraryFrame)], anchor]
        }
        column.refresh(animated: false)
        #expect(column.debugShapes == [CGRect(x: 0, y: 0, width: 90, height: 45), anchorFrame])
        #expect(camera.convert(camera.bounds, to: column) == cameraFrame)
        #expect(library.convert(library.bounds, to: column) == libraryFrame)
        #expect(camera.superview === library.superview, "the two items are not one bubble's")

        column.setCover("anchor", amount: 1)
        let drawn = try #require(column.debugDrawnShapes.last)
        #expect(drawn.width <= 2 && anchorFrame.contains(CGPoint(x: drawn.midX, y: drawn.midY)), "\(drawn)")

        folded = true
        column.refresh(animated: false)
        #expect(column.debugShapes == [anchorFrame])
        #expect(camera.superview == nil && library.superview == nil, "a folded item still stands")
    }

    /// The anchor is the sound: everything is born from it and folds into it.
    @Test func theSoundIsTheAnchor() {
        #expect(mediaChrome(postActions: true).debugGlassColumn.anchorID == "sound")
    }
}
