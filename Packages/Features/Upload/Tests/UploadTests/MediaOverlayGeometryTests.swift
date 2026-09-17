import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// Where an overlay stands on the page, and what a finger does to it.
///
/// ⚠️ **FIT AND FILL ARE BOTH ASKED, WITH NUMBERS THAT DIFFER.** A 400×200
/// picture on a 300×600 page is 300×150 fitted and 1200×600 filled, so the same
/// 30-point drag is worth a tenth of the picture in one lay and a fortieth in
/// the other — a layer that used the page's bounds instead of the picture's
/// rectangle passes neither.
@MainActor
struct MediaOverlayGeometryTests {
    private static let page = CGRect(x: 0, y: 0, width: 300, height: 600)
    private static let wide = CGSize(width: 400, height: 200)

    private func layer(fit: ContentFit, overlays: [FrameOverlay], chrome: UIEdgeInsets = .zero)
        -> (MediaOverlayLayerView, Recorder) {
        let layer = MediaOverlayLayerView(frame: Self.page)
        let recorder = Recorder()
        layer.rasterize = { _, _, _ in nil }
        layer.onEvent = { recorder.events.append($0) }
        layer.contentSize = Self.wide
        layer.fit = fit
        layer.chromeInsets = chrome
        layer.isEditable = true
        layer.show(overlays)
        layer.layoutIfNeeded()
        return (layer, recorder)
    }

    @MainActor
    private final class Recorder {
        var events: [MediaOverlayLayerView.Event] = []
        var lastPlacement: OverlayPlacement? {
            for event in events.reversed() {
                if case .placed(let overlay) = event { return overlay.placement }
            }
            return nil
        }
    }

    private static let hello = FrameOverlay(id: "hello", content: .text(TextOverlay(text: "Hello")))

    @Test func theMediaRectFitsAndFills() {
        #expect(MediaOverlayGeometry.mediaRect(contentSize: Self.wide, bounds: Self.page, fit: .fit)
                == CGRect(x: 0, y: 225, width: 300, height: 150))
        #expect(MediaOverlayGeometry.mediaRect(contentSize: Self.wide, bounds: Self.page, fit: .fill)
                == CGRect(x: -450, y: 0, width: 1200, height: 600))
    }

    @Test(arguments: [
        (ContentFit.fit, CGPoint(x: 0.6, y: 0.6)),
        (ContentFit.fill, CGPoint(x: 0.525, y: 0.525))
    ])
    func panMovesThePlacementInMediaSpace(fit: ContentFit, expected: CGPoint) throws {
        let (layer, recorder) = layer(fit: fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))
        let before = item.center

        layer.item(item, panned: .began, by: CGPoint(x: 10, y: 5), at: .zero)
        layer.item(item, panned: .changed, by: CGPoint(x: 20, y: 10), at: .zero)
        layer.item(item, panned: .ended, by: .zero, at: .zero)

        let placed = try #require(recorder.lastPlacement)
        #expect(abs(placed.centre.x - expected.x) < 1e-9, "x: \(placed.centre.x)")
        #expect(abs(placed.centre.y - expected.y) < 1e-9, "y: \(placed.centre.y)")
        // And the view went exactly where the finger did.
        #expect(abs(item.center.x - before.x - 30) < 0.001 && abs(item.center.y - before.y - 15) < 0.001,
                "moved from \(before) to \(item.center)")
    }

    /// A filled picture spills past the page: a drag is held inside what can
    /// be seen, so an overlay cannot be pushed where nobody can grab it again.
    @Test func aDragIsHeldInsideTheVisiblePicture() throws {
        let (layer, recorder) = layer(fit: .fill, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))

        layer.item(item, panned: .began, by: CGPoint(x: 1000, y: 0), at: .zero)
        layer.item(item, panned: .ended, by: .zero, at: .zero)

        // The page shows x from 450 to 750 of 1200.
        let placed = try #require(recorder.lastPlacement)
        #expect(abs(placed.centre.x - 0.625) < 1e-9, "x: \(placed.centre.x)")
    }

    /// With the chrome over the lower two thirds, the middle of the picture is
    /// hidden: a new overlay is held at the foot of what is left.
    @Test func aNewOverlayIsClampedIntoTheVisiblePart() {
        let (covered, _) = layer(fit: .fill, overlays: [], chrome: UIEdgeInsets(top: 0, left: 0, bottom: 400, right: 0))
        #expect(abs(covered.newCentre.y - 1.0 / 3) < 1e-9, "\(covered.newCentre)")
        #expect(abs(covered.newCentre.x - 0.5) < 1e-9)

        // The witness: nothing covered, the middle it is.
        let (clear, _) = layer(fit: .fill, overlays: [])
        #expect(clear.newCentre == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func pinchScales() throws {
        let (layer, recorder) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))
        let base = item.bounds.width

        layer.item(item, pinched: .began, by: 1.5)
        layer.item(item, pinched: .ended, by: 1.5)

        let placed = try #require(recorder.lastPlacement)
        #expect(abs(placed.scale - 2.25) < 1e-9, "scale: \(placed.scale)")
        #expect(abs(item.transform.a - 2.25) < 1e-9, "the view wears it: \(item.transform)")
        #expect(abs(item.frame.width - base * 2.25) < 0.01, "and is that much wider on screen")
    }

    @Test func aPinchIsHeldInsideItsRange() throws {
        let (layer, recorder) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))

        layer.item(item, pinched: .ended, by: 100)

        #expect(recorder.lastPlacement?.scale == MediaOverlayGeometry.scaleRange.upperBound)
    }

    /// Clockwise as the viewer sees it: in UIKit's y-down space, a positive
    /// angle has a positive `b`.
    @Test func rotateRotates() throws {
        let (layer, recorder) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))

        layer.item(item, rotated: .began, by: .pi / 8)
        layer.item(item, rotated: .ended, by: .pi / 8)

        let placed = try #require(recorder.lastPlacement)
        #expect(abs(placed.rotation - .pi / 4) < 1e-9, "rotation: \(placed.rotation)")
        #expect(abs(atan2(item.transform.b, item.transform.a) - .pi / 4) < 1e-9)
        #expect(item.transform.b > 0, "clockwise on screen")
    }

    @Test func trashDeletes() throws {
        let (layer, recorder) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))
        let bin = layer.trash.center

        layer.item(item, panned: .began, by: .zero, at: item.center)
        #expect(!layer.trash.isHidden, "the bin shows for a drag")
        layer.item(item, panned: .changed, by: .zero, at: bin)
        #expect(layer.trash.isArmed)
        layer.item(item, panned: .ended, by: .zero, at: bin)

        #expect(recorder.events.last == .delete(id: "hello"), "\(recorder.events)")
    }

    /// The witness: the same drag, let go away from the bin, only moves.
    @Test func aDropBesideTheTrashKeepsTheOverlay() throws {
        let (layer, recorder) = layer(fit: .fit, overlays: [Self.hello])
        let item = try #require(layer.item(for: "hello"))
        let beside = CGPoint(x: layer.trash.center.x, y: layer.trash.center.y - 120)

        layer.item(item, panned: .began, by: .zero, at: item.center)
        layer.item(item, panned: .ended, by: .zero, at: beside)

        #expect(!recorder.events.contains(.delete(id: "hello")))
        #expect(recorder.lastPlacement != nil)
    }
}
