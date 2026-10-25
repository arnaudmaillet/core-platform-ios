import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// #1724: the scrub card in the clip's own shape, and the flight replica's
/// caption at the landing page's seat.
@MainActor
struct SnapScrubPreviewShapeTests {
    /// Landscape: 118 pt wide. Portrait: 150 pt tall, as narrow as the clip.
    @Test func theCardTakesTheClipsShape() {
        let landscape = SnapScrubPreviewView.frameSize(aspect: 16.0 / 9.0)
        #expect(landscape.width == SnapScrubPreviewView.maxFrameWidth)
        #expect(abs(landscape.height - 66) <= 1)

        let portrait = SnapScrubPreviewView.frameSize(aspect: 9.0 / 16.0)
        #expect(portrait.height == SnapScrubPreviewView.maxFrameHeight)
        #expect(abs(portrait.width / portrait.height - 9.0 / 16.0) < 0.01, "a vertical clip's card is not vertical")
    }

    /// A frame arriving in another shape than declared reshapes the card.
    @Test func aFrameOfAnotherShapeReshapesTheCard() throws {
        let card = SnapScrubPreviewView()
        card.aspect = 16.0 / 9.0
        var reshaped = false
        card.onShapeChange = { reshaped = true }
        let context = try #require(CGContext(
            data: nil, width: 90, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        card.setPicture(try #require(context.makeImage()))
        #expect(reshaped)
        #expect(abs(card.aspect - 90.0 / 160.0) < 0.01)
    }

    /// ⚠️ The caption's seat is applied at `configure`: a replica that never
    /// receives a page count (a single picture's flight) stands where the page
    /// will — the caption on the cover's line.
    @Test func aReplicaTakesTheCaptionSeatAtConfigure() {
        let replica = SnapChromeView(frame: SnapActionColumnLayoutTests.screen)
        replica.setFixedInsets(SnapActionColumnLayoutTests.insets)
        replica.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false))
        replica.configure(with: SnapActionColumnLayoutTests.mediaModel(mediaURL: URL(string: "mock://media/1")))
        replica.layoutIfNeeded()

        let page = SnapActionColumnLayoutTests.chrome()
        page.setSoundFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false))
        page.setMediaPageCount(1, current: 0)
        page.layoutIfNeeded()
        #expect(abs(replica.debugCaptionFrame.maxY - page.debugCaptionFrame.maxY) < 0.5,
                "the replica's caption flies at \(replica.debugCaptionFrame.maxY), the page's lands at \(page.debugCaptionFrame.maxY)")
    }
}

/// #1730: the comments' composer follows the page as the side list opens,
/// and still clears the keyboard while it is moved.
@MainActor
struct ComposerSideListTests {
    @Test func theComposerFollowsThePagesOverlay() {
        let (controller, _) = SnapActionColumnLayoutTests.engagedPanel()
        let composer = SnapActionColumnLayoutTests.firstView(CommentsInputBar.self, in: controller.view)
        let before = composer.map { $0.convert($0.bounds, to: nil) }
        controller.setOverlayOffset(40)
        #expect(controller.debugComposerOverlayOffset == 40)
        if let composer, let before {
            #expect(abs(composer.convert(composer.bounds, to: nil).minY - before.minY - 40) < 0.5, "the composer did not move with the page")
        }
        controller.setOverlayOffset(0)
        #expect(controller.debugComposerOverlayOffset == 0)
    }

    /// The owner's video (2026-10-25): comments closed and reopened over the
    /// open side list — the panel released at 0, re-engaged at the list's
    /// offset — drew the composer without the offset for the whole entrance,
    /// then jumped. The entrance carries the bar from its MODEL transform.
    @Test func aReengagedPanelEntersAtTheOffset() throws {
        let (controller, window) = SnapActionColumnLayoutTests.engagedPanel()
        defer { window.isHidden = true }
        let composer = try #require(SnapActionColumnLayoutTests.firstView(CommentsInputBar.self, in: controller.view))
        // Released at 0 and committed — the presentation layer shows identity.
        controller.setOverlayOffset(0)
        CATransaction.flush()
        // Re-engaged over the open list.
        controller.setOverlayOffset(40)
        controller.animateEngagedTransition(toEngaged: true, duration: 0.3)
        let entrance = try #require(composer.layer.animation(forKey: "comments-engage-transform") as? CABasicAnimation)
        let from = try #require((entrance.fromValue as? NSValue)?.caTransform3DValue ?? entrance.fromValue as? CATransform3D)
        #expect(abs(from.m42 - 40) < 0.5, "the entrance starts the composer at \(from.m42), not at the list's offset")
    }

    /// The owner's video (2026-10-25): with the side list open, the keyboard
    /// left the risen row `offset` too low, half behind its suggestion bar.
    /// The row rides `sm` above the keyboard whatever the bar's offset, and
    /// at rest the whole bar still moves with the page.
    @Test func theRisenRowClearsTheKeyboardWhileTheBarIsMoved() throws {
        let bar = CommentsInputBar()
        bar.onPageSwipe = { _, _, _ in }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        host.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        let field = try #require(SnapActionColumnLayoutTests.fieldView(in: bar))
        let keyboard = SnapActionColumnLayoutTests.fakeKeyboard(in: host, for: bar, top: host.bounds.height + 80)
        SnapActionColumnLayoutTests.relayout(host, bar)
        let rest = field.convert(field.bounds, to: host).maxY

        // At rest: the row moves with the bar.
        bar.setOverlayOffset(40)
        SnapActionColumnLayoutTests.relayout(host, bar)
        #expect(abs(field.convert(field.bounds, to: host).maxY - (rest + 40)) < 0.5, "the row did not move with the page")

        // Keyboard up: the row sits sm above it, as with no offset.
        keyboard.constant = 300
        SnapActionColumnLayoutTests.relayout(host, bar)
        let risen = field.convert(field.bounds, to: host).maxY
        #expect(abs(risen - (300 - Spacing.sm)) < 0.5, "the risen row sits at \(risen), the keyboard at 300")

        bar.setOverlayOffset(0)
        SnapActionColumnLayoutTests.relayout(host, bar)
        #expect(abs(field.convert(field.bounds, to: host).maxY - (300 - Spacing.sm)) < 0.5)
    }

    /// ⚠️ The keyboard guide ignores the card's scale (measured on the SE):
    /// with the page drawn ×0.82 and the bar moved 42 pt in it, the ceiling
    /// that draws the row `sm` over the keyboard is −28.4, not −8 (the row
    /// 9 pt into the keyboard) nor −50 (17 pt too high).
    @Test func theCeilingSeesThroughTheCardsScale() throws {
        #expect(abs(CommentsInputBar.keyboardCeilingConstant(
            keyboardTop: 407, ownerDrawnOrigin: 53.744, ownerScale: 0.8209,
            ownerLaidOutOrigin: 0, barOffset: 42.014
        ) + 28.43) < 0.1)
        // No transform: the plain ceiling, less the bar's offset.
        #expect(abs(CommentsInputBar.keyboardCeilingConstant(
            keyboardTop: 407, ownerDrawnOrigin: 0, ownerScale: 1, ownerLaidOutOrigin: 0, barOffset: 0
        ) + Spacing.sm) < 0.001)

        // Drawn: a page scaled into a card, the bar moved down in it. In a
        // window: without one, `convert(_:to: nil)` converts nothing.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        window.isHidden = false
        defer { window.isHidden = true }
        let page = UIView(frame: window.bounds)
        window.addSubview(page)
        let bar = CommentsInputBar()
        bar.onPageSwipe = { _, _, _ in }
        page.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        let field = try #require(SnapActionColumnLayoutTests.fieldView(in: bar))
        // The guide reads the keyboard's top as if nothing were scaled.
        let keyboardTop: CGFloat = 330
        _ = SnapActionColumnLayoutTests.fakeKeyboard(in: page, for: bar, top: keyboardTop)
        page.transform = CGAffineTransform(translationX: 0, y: 20).scaledBy(x: 0.82, y: 0.82)
        bar.setOverlayOffset(42)
        bar.debugSetKeyboardTop(inWindow: keyboardTop)
        SnapActionColumnLayoutTests.relayout(page, bar)
        let drawn = field.convert(field.bounds, to: nil).maxY
        #expect(abs(drawn - (keyboardTop - Spacing.sm)) < 0.5, "the row is drawn at \(drawn), the keyboard at \(keyboardTop)")
    }
}
